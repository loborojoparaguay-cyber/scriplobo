#!/bin/bash
# =====================================================================
# modules/proto_openvpn.sh - OpenVPN (alternativa clásica, muy probada)
#
# Usa easy-rsa para PKI propia (certificados por cliente, no solo
# usuario/contraseña) — es el estándar de facto para OpenVPN.
#
# tls-version-min 1.3 requiere OpenVPN 2.4.6+ con OpenSSL 1.1.1+
# (Ubuntu 22.04/24.04 ya cumplen). Clientes muy antiguos (antes de
# 2019 aprox.) que no soporten TLS 1.3 no podran conectar -- para la
# mayoria de apps cliente actuales (OpenVPN Connect, etc.) no es
# problema.
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

OVPN_DIR="/etc/openvpn/server"
EASYRSA_DIR="$OVPN_DIR/easy-rsa"
CLIENTS_DIR="$PANEL_DATA/ovpn_clients"

install_openvpn() {
    local port="${1:-1194}" proto="${2:-udp}"
    apt_install openvpn easy-rsa

    mkdir -p "$OVPN_DIR"
    make-cadir "$EASYRSA_DIR" 2>/dev/null || true
    cd "$EASYRSA_DIR" || return 1

    ./easyrsa init-pki
    echo -e "\n" | ./easyrsa build-ca nopass
    ./easyrsa gen-req server nopass
    echo "yes" | ./easyrsa sign-req server server
    ./easyrsa gen-dh
    openvpn --genkey secret "$OVPN_DIR/tc.key"

    cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem "$OVPN_DIR/"

    local out_if
    out_if=$(ip route show default | awk '{print $5; exit}')

    cat > "$OVPN_DIR/server.conf" <<EOF
port ${port}
proto ${proto}
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt tc.key
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
tls-version-min 1.3
persist-key
persist-tun
status /var/log/openvpn-status.log
verb 3
explicit-exit-notify 1
EOF

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
    sysctl -p /etc/sysctl.d/99-openvpn.conf >/dev/null

    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$out_if" -j MASQUERADE

    mkdir -p "$CLIENTS_DIR"
    systemctl enable --now openvpn-server@server
    ok "OpenVPN activo en puerto ${proto}/${port}."
}

add_client() {
    local client_name="$1"
    [[ -z "$client_name" ]] && { err "Debes indicar un nombre de cliente."; return 1; }
    cd "$EASYRSA_DIR" || { err "OpenVPN no está instalado."; return 1; }

    ./easyrsa gen-req "$client_name" nopass
    echo "yes" | ./easyrsa sign-req client "$client_name"

    local server_ip server_port server_proto
    server_ip=$(get_public_ip)
    server_port=$(grep -oP '^port \K\d+' "$OVPN_DIR/server.conf")
    server_proto=$(grep -oP '^proto \K\w+' "$OVPN_DIR/server.conf")

    mkdir -p "$CLIENTS_DIR"
    cat > "$CLIENTS_DIR/${client_name}.ovpn" <<EOF
client
dev tun
proto ${server_proto}
remote ${server_ip} ${server_port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
tls-version-min 1.3
verb 3
<ca>
$(cat pki/ca.crt)
</ca>
<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "pki/issued/${client_name}.crt")
</cert>
<key>
$(cat "pki/private/${client_name}.key")
</key>
<tls-crypt>
$(cat "$OVPN_DIR/tc.key")
</tls-crypt>
EOF

    ok "Cliente OpenVPN '${client_name}' creado: $CLIENTS_DIR/${client_name}.ovpn"
}

remove_client() {
    local client_name="$1"
    cd "$EASYRSA_DIR" || { err "OpenVPN no está instalado."; return 1; }
    ./easyrsa revoke "$client_name"
    ./easyrsa gen-crl
    cp pki/crl.pem "$OVPN_DIR/"
    rm -f "$CLIENTS_DIR/${client_name}.ovpn"
    systemctl restart openvpn-server@server
    ok "Cliente '${client_name}' revocado y eliminado."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        install)        install_openvpn "$2" "$3" ;;
        add_client)     add_client "$2" ;;
        remove_client)  remove_client "$2" ;;
        *) echo "Uso: $0 {install <puerto> <udp|tcp>|add_client <nombre>|remove_client <nombre>}" ;;
    esac
fi
