#!/bin/bash
# =====================================================================
# modules/proto_ssh.sh - Instalación y hardening de OpenSSH + Dropbear
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DROPBEAR_CONF="/etc/default/dropbear"
SSHD_CONF="/etc/ssh/sshd_config"
BANNER_FILE="$PANEL_HOME/banner.txt"

install_openssh() {
    apt_install openssh-server
    # Hardening básico y recomendado
    cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)" 2>/dev/null

    set_sshd_option() {
        local key="$1" val="$2"
        if grep -qE "^\s*#?\s*${key}\b" "$SSHD_CONF"; then
            sed -i "s|^\s*#\?\s*${key}\b.*|${key} ${val}|" "$SSHD_CONF"
        else
            echo "${key} ${val}" >> "$SSHD_CONF"
        fi
    }

    set_sshd_option "PermitRootLogin" "prohibit-password"
    set_sshd_option "PasswordAuthentication" "yes"   # los clientes usan user/pass
    set_sshd_option "X11Forwarding" "no"
    set_sshd_option "AllowTcpForwarding" "yes"        # necesario para el túnel
    set_sshd_option "ClientAliveInterval" "60"
    set_sshd_option "ClientAliveCountMax" "3"
    set_sshd_option "MaxAuthTries" "3"
    set_sshd_option "Banner" "$BANNER_FILE"

    systemctl restart ssh 2>/dev/null || systemctl restart sshd
    ok "OpenSSH instalado y configurado (puerto por defecto: 22)."
}

install_dropbear() {
    apt_install dropbear
    local port="${1:-442}"

    sed -i "s/^NO_START=.*/NO_START=0/" "$DROPBEAR_CONF" 2>/dev/null
    if grep -q "^DROPBEAR_PORT=" "$DROPBEAR_CONF"; then
        sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=${port}/" "$DROPBEAR_CONF"
    else
        echo "DROPBEAR_PORT=${port}" >> "$DROPBEAR_CONF"
    fi
    # Deshabilitamos shell real, banner de bienvenida, y forzamos solo forwarding
    grep -q "^DROPBEAR_EXTRA_ARGS=" "$DROPBEAR_CONF" \
        && sed -i "s|^DROPBEAR_EXTRA_ARGS=.*|DROPBEAR_EXTRA_ARGS=\"-b ${BANNER_FILE}\"|" "$DROPBEAR_CONF" \
        || echo "DROPBEAR_EXTRA_ARGS=\"-b ${BANNER_FILE}\"" >> "$DROPBEAR_CONF"

    systemctl restart dropbear
    ok "Dropbear instalado y escuchando en el puerto ${port}."
}

set_banner() {
    ${EDITOR:-nano} "$BANNER_FILE"
    ok "Banner actualizado. Reinicia SSH/Dropbear para aplicar cambios."
}

change_ssh_port() {
    local port="$1"
    sed -i "s/^\s*#\?\s*Port .*/Port ${port}/" "$SSHD_CONF"
    grep -q "^Port" "$SSHD_CONF" || echo "Port ${port}" >> "$SSHD_CONF"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
    ok "Puerto de SSH cambiado a ${port}. Recuerda abrirlo en el firewall."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        install_ssh)      install_openssh ;;
        install_dropbear) install_dropbear "$2" ;;
        set_banner)       set_banner ;;
        change_port)      change_ssh_port "$2" ;;
        *) echo "Uso: $0 {install_ssh|install_dropbear <puerto>|set_banner|change_port <puerto>}" ;;
    esac
fi
