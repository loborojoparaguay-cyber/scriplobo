#!/bin/bash
# =====================================================================
# modules/ssl.sh - Certificados TLS reales vía Let's Encrypt (acme.sh)
#
# Un certificado real (no autofirmado) es necesario para que Xray
# (VLESS+TLS/Trojan) y Stunnel sean indistinguibles de HTTPS normal
# y para que los clientes no vean advertencias de seguridad.
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

ACME_HOME="$HOME/.acme.sh"

install_acme() {
    if [[ -x "$ACME_HOME/acme.sh" ]]; then
        ok "acme.sh ya está instalado."
        return 0
    fi
    apt_install curl socat cron
    curl https://get.acme.sh | sh -s email="admin@$(hostname -f 2>/dev/null || echo localhost)"
    ok "acme.sh instalado."
}

# Emite certificado usando validación HTTP (puerto 80 debe estar libre)
issue_cert() {
    local domain="$1"
    [[ -z "$domain" ]] && { err "Debes indicar un dominio."; return 1; }
    install_acme

    "$ACME_HOME/acme.sh" --issue -d "$domain" --standalone --httpport 80

    mkdir -p "/etc/letsencrypt/live/${domain}"
    "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
        --key-file       "/etc/letsencrypt/live/${domain}/privkey.pem" \
        --fullchain-file "/etc/letsencrypt/live/${domain}/fullchain.pem" \
        --reloadcmd      "systemctl restart stunnel4 xray 2>/dev/null || true"

    ok "Certificado emitido para ${domain} en /etc/letsencrypt/live/${domain}/"
    msg "acme.sh renueva automáticamente antes del vencimiento (cron propio)."
}

list_certs() {
    "$ACME_HOME/acme.sh" --list 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        issue) issue_cert "$2" ;;
        list)  list_certs ;;
        *) echo "Uso: $0 {issue <dominio>|list}" ;;
    esac
fi
