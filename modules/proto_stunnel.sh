#!/bin/bash
# =====================================================================
# modules/proto_stunnel.sh - Stunnel: envuelve SSH/Dropbear en TLS real
#
# Esto permite que el tráfico entrante en el puerto 443 sea TLS
# genuino (indistinguible de HTTPS normal a nivel de handshake) y
# lo redirige internamente al puerto de SSH/Dropbear.
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

STUNNEL_CONF="/etc/stunnel/lobopanel.conf"
CERT_DIR="/etc/lobopanel/certs"

install_stunnel() {
    local listen_port="${1:-443}" backend_port="${2:-22}"

    apt_install stunnel4

    mkdir -p "$CERT_DIR"
    if [[ ! -f "$CERT_DIR/stunnel.pem" ]]; then
        msg "Generando certificado autofirmado (usa el módulo SSL para uno real de Let's Encrypt)."
        openssl req -new -x509 -days 3650 -nodes \
            -out "$CERT_DIR/stunnel.pem" -keyout "$CERT_DIR/stunnel.pem" \
            -subj "/CN=lobopanel" 2>/dev/null
    fi

    cat > "$STUNNEL_CONF" <<EOF
cert = ${CERT_DIR}/stunnel.pem
pid = /var/run/stunnel-lobopanel.pid
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
sslVersionMin = TLSv1.3

[ssh-tls]
accept = ${listen_port}
connect = 127.0.0.1:${backend_port}
EOF

    # Habilitar el servicio (Debian/Ubuntu usan /etc/default/stunnel4)
    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || echo "ENABLED=1" >> /etc/default/stunnel4
    echo "FILES=\"$STUNNEL_CONF\"" >> /etc/default/stunnel4

    systemctl restart stunnel4
    ok "Stunnel activo: puerto ${listen_port} (TLS) -> 127.0.0.1:${backend_port}"
}

use_real_cert() {
    local domain="$1"
    local le_dir="/etc/letsencrypt/live/${domain}"
    if [[ ! -d "$le_dir" ]]; then
        err "No se encontró certificado Let's Encrypt para ${domain}. Ejecuta primero el módulo SSL."
        return 1
    fi
    cat "$le_dir/fullchain.pem" "$le_dir/privkey.pem" > "$CERT_DIR/stunnel.pem"
    systemctl restart stunnel4
    ok "Stunnel ahora usa el certificado real de ${domain}."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        install)   install_stunnel "$2" "$3" ;;
        use_cert)  use_real_cert "$2" ;;
        *) echo "Uso: $0 {install <puerto_escucha> <puerto_backend>|use_cert <dominio>}" ;;
    esac
fi
