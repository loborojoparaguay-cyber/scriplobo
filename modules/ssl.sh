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
#
# IMPORTANTE: acme.sh emite certificados ECC por defecto desde hace
# varias versiones (guardados en una carpeta con sufijo "_ecc"). Si
# --issue y --install-cert no usan la MISMA bandera --ecc de forma
# consistente, acme.sh busca la carpeta equivocada internamente y
# el archivo de clave termina con un nombre corrupto/vacio (bug real
# encontrado y corregido: ver historial de commits). Por eso aquí
# se fuerza --ecc explícitamente en ambos pasos.
issue_cert() {
    local domain="$1"
    [[ -z "$domain" ]] && { err "Debes indicar un dominio."; return 1; }
    install_acme

    "$ACME_HOME/acme.sh" --issue -d "$domain" --standalone --httpport 80 --keylength ec-256

    mkdir -p "/etc/letsencrypt/live/${domain}"
    "$ACME_HOME/acme.sh" --install-cert --ecc -d "$domain" \
        --key-file       "/etc/letsencrypt/live/${domain}/privkey.pem" \
        --fullchain-file "/etc/letsencrypt/live/${domain}/fullchain.pem" \
        --reloadcmd      "systemctl restart stunnel4 xray 2>/dev/null || true"

    if [[ ! -s "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        err "El certificado no se instaló correctamente (fullchain.pem vacío o ausente)."
        err "Revisa manualmente: ${ACME_HOME}/acme.sh --install-cert --ecc -d ${domain} ..."
        return 1
    fi

    ok "Certificado emitido para ${domain} en /etc/letsencrypt/live/${domain}/"
    msg "acme.sh renueva automáticamente antes del vencimiento (cron propio)."
}

list_certs() {
    "$ACME_HOME/acme.sh" --list 2>/dev/null
}

# Reinstala/repara un certificado ya emitido (misma logica que
# issue_cert pero sin volver a solicitar uno nuevo) -- util cuando
# --install-cert fallo por el bug de --ecc descrito arriba.
repair_cert() {
    local domain="$1"
    [[ -z "$domain" ]] && { err "Debes indicar un dominio."; return 1; }
    mkdir -p "/etc/letsencrypt/live/${domain}"
    "$ACME_HOME/acme.sh" --install-cert --ecc -d "$domain" \
        --key-file       "/etc/letsencrypt/live/${domain}/privkey.pem" \
        --fullchain-file "/etc/letsencrypt/live/${domain}/fullchain.pem" \
        --reloadcmd      "systemctl restart stunnel4 xray 2>/dev/null || true"
    if [[ -s "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        ok "Certificado reparado/reinstalado para ${domain}."
    else
        err "Sigue fallando. Revisa con: ~/.acme.sh/acme.sh --list"
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        issue)  issue_cert "$2" ;;
        list)   list_certs ;;
        repair) repair_cert "$2" ;;
        *) echo "Uso: $0 {issue <dominio>|list|repair <dominio>}" ;;
    esac
fi
