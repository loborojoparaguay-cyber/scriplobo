#!/bin/bash
# =====================================================================
# modules/hardening.sh - Firewall (ufw) + Fail2ban + límites básicos
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

install_firewall() {
    apt_install ufw
    ufw default deny incoming
    ufw default allow outgoing
    # Puertos base: SSH, Dropbear, Stunnel/HTTPS, WireGuard, OpenVPN
    ufw allow 22/tcp    comment "SSH"
    ufw allow 442/tcp   comment "Dropbear"
    ufw allow 443/tcp   comment "Stunnel/Xray TLS"
    ufw allow 80/tcp    comment "ACME HTTP-01"
    ufw allow 51820/udp comment "WireGuard"
    ufw allow 1194/udp  comment "OpenVPN"
    ufw allow 443/udp   comment "Hysteria 2 (QUIC)"
    # Nota: el sitio senuelo (Nginx) NO se abre aca a proposito -- solo
    # escucha en 127.0.0.1, nunca debe ser accesible directamente desde
    # internet. Solo Xray (443/tcp, ya abierto arriba) debe recibir
    # trafico publico y reenviar internamente al senuelo si corresponde.
    ufw --force enable
    ok "Firewall (ufw) activo con reglas base."
}

open_port() {
    local port="$1" proto="${2:-tcp}"
    ufw allow "${port}/${proto}"
    ok "Puerto ${port}/${proto} abierto."
}

close_port() {
    local port="$1" proto="${2:-tcp}"
    ufw delete allow "${port}/${proto}"
    ok "Puerto ${port}/${proto} cerrado."
}

install_fail2ban() {
    apt_install fail2ban
    cat > /etc/fail2ban/jail.d/vps-panel.conf <<'EOF'
[sshd]
enabled = true
port    = 22,442
maxretry = 5
findtime = 600
bantime  = 3600

[dropbear]
enabled = true
port    = 442
logpath = /var/log/auth.log
maxretry = 5
bantime  = 3600
EOF
    systemctl enable --now fail2ban
    systemctl restart fail2ban
    ok "Fail2ban instalado y protegiendo SSH/Dropbear contra fuerza bruta."
}

fail2ban_status() {
    fail2ban-client status
    echo
    fail2ban-client status sshd 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian
    case "$1" in
        install_firewall)  install_firewall ;;
        open_port)         open_port "$2" "$3" ;;
        close_port)        close_port "$2" "$3" ;;
        install_fail2ban)  install_fail2ban ;;
        fail2ban_status)   fail2ban_status ;;
        *) echo "Uso: $0 {install_firewall|open_port <p> <tcp|udp>|close_port <p> <tcp|udp>|install_fail2ban|fail2ban_status}" ;;
    esac
fi
