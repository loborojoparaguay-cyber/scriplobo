#!/bin/bash
# =====================================================================
# modules/proto_wireguard.sh - WireGuard: VPN moderna (recomendada)
#
# WireGuard usa criptografía moderna (Curve25519, ChaCha20Poly1305,
# BLAKE2s) y es hoy el estándar más rápido y auditable para VPN.
# Cada "cliente pagante" recibe un peer (par de claves) propio.
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/wg0.conf"
WG_PEERS_DIR="$PANEL_DATA/wg_peers"
WG_IFACE="wg0"
WG_SUBNET="10.66.66"     # /24 interno para los peers
WG_PORT_DEFAULT=51820

install_wireguard() {
    local port="${1:-$WG_PORT_DEFAULT}"
    apt_install wireguard qrencode

    mkdir -p "$WG_DIR" "$WG_PEERS_DIR"
    chmod 700 "$WG_DIR"

    if [[ ! -f "$WG_DIR/server_private.key" ]]; then
        umask 077
        wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
    fi

    local priv
    priv=$(cat "$WG_DIR/server_private.key")
    local out_if
    out_if=$(ip route show default | awk '{print $5; exit}')

    cat > "$WG_CONF" <<EOF
[Interface]
Address = ${WG_SUBNET}.1/24
ListenPort = ${port}
PrivateKey = ${priv}
PostUp = iptables -A FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${out_if} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${out_if} -j MASQUERADE
EOF

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
    sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null

    systemctl enable --now wg-quick@${WG_IFACE}
    ok "WireGuard activo en puerto UDP ${port}. IP interna del servidor: ${WG_SUBNET}.1"
}

# Agrega un peer (cliente) y genera su archivo .conf + QR
add_peer() {
    local client_name="$1"
    [[ -z "$client_name" ]] && { err "Debes indicar un nombre de cliente."; return 1; }

    local last_octet
    last_octet=$(ls "$WG_PEERS_DIR" 2>/dev/null | wc -l)
    last_octet=$(( last_octet + 2 ))   # empieza en .2 (.1 es el server)

    local client_ip="${WG_SUBNET}.${last_octet}"
    local client_priv client_pub server_pub server_ip server_port psk
    umask 077
    client_priv=$(wg genkey)
    client_pub=$(echo "$client_priv" | wg pubkey)
    psk=$(wg genpsk)
    server_pub=$(cat "$WG_DIR/server_public.key")
    server_ip=$(get_public_ip)
    server_port=$(grep -oP '(?<=ListenPort = )\d+' "$WG_CONF")

    # Agregamos el peer a la config del servidor
    cat >> "$WG_CONF" <<EOF

# BEGIN_PEER ${client_name}
[Peer]
PublicKey = ${client_pub}
PresharedKey = ${psk}
AllowedIPs = ${client_ip}/32
# END_PEER ${client_name}
EOF

    mkdir -p "$WG_PEERS_DIR/${client_name}"
    cat > "$WG_PEERS_DIR/${client_name}/${client_name}.conf" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = ${client_ip}/24
DNS = 1.1.1.1

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${server_ip}:${server_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")
    qrencode -t ansiutf8 < "$WG_PEERS_DIR/${client_name}/${client_name}.conf" \
        > "$WG_PEERS_DIR/${client_name}/qr.txt"

    ok "Peer '${client_name}' creado. IP: ${client_ip}"
    msg "Config: $WG_PEERS_DIR/${client_name}/${client_name}.conf"
    msg "Para ver el QR: cat $WG_PEERS_DIR/${client_name}/qr.txt"
}

remove_peer() {
    local client_name="$1"
    if [[ ! -d "$WG_PEERS_DIR/${client_name}" ]]; then
        err "Peer '${client_name}' no encontrado."
        return 1
    fi
    # Eliminamos el bloque [Peer] correspondiente de wg0.conf
    sed -i "/# BEGIN_PEER ${client_name}$/,/# END_PEER ${client_name}$/d" "$WG_CONF"
    rm -rf "$WG_PEERS_DIR/${client_name}"
    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")
    ok "Peer '${client_name}' eliminado."
}

list_peers() {
    echo "Peers configurados:"
    ls "$WG_PEERS_DIR" 2>/dev/null
    echo
    msg "Estado en vivo (wg show):"
    wg show "$WG_IFACE" 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        install)      install_wireguard "$2" ;;
        add_peer)     add_peer "$2" ;;
        remove_peer)  remove_peer "$2" ;;
        list_peers)   list_peers ;;
        *) echo "Uso: $0 {install <puerto>|add_peer <nombre>|remove_peer <nombre>|list_peers}" ;;
    esac
fi
