#!/bin/bash
# =====================================================================
# modules/monitor.sh - Estado del sistema y conexiones activas
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

system_info() {
    echo -e "${C_BOLD}--- Sistema ---${C_RESET}"
    echo "S.O:   $(source /etc/os-release; echo "$PRETTY_NAME")"
    echo "IP:    $(get_public_ip)"
    echo "Fecha: $(date +%Y-%m-%d) | Hora: $(date +%H:%M:%S)"
    echo
    echo -e "${C_BOLD}--- CPU ---${C_RESET}"
    echo "Núcleos: $(nproc)"
    echo "Uso:     $(top -bn1 | grep "Cpu(s)" | awk '{print $2+$4"%"}')"
    echo
    echo -e "${C_BOLD}--- RAM ---${C_RESET}"
    free -h | awk 'NR==2{printf "Total: %s  Uso: %s  Libre: %s\n", $2, $3, $4}'
    echo
    echo -e "${C_BOLD}--- Disco ---${C_RESET}"
    df -h / | awk 'NR==2{printf "Total: %s  Uso: %s  Libre: %s\n", $2, $3, $4}'
}

protocol_status() {
    echo -e "${C_BOLD}--- Estado de protocolos ---${C_RESET}"
    for svc in ssh dropbear stunnel4 wg-quick@wg0 xray openvpn-server@server fail2ban; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${C_GREEN}[ON]${C_RESET}  $svc"
        else
            echo -e "  ${C_RED}[OFF]${C_RESET} $svc"
        fi
    done
}

live_connections() {
    echo -e "${C_BOLD}--- Conexiones SSH/Dropbear activas ---${C_RESET}"
    who
    echo
    echo -e "${C_BOLD}--- Conexiones WireGuard ---${C_RESET}"
    wg show wg0 2>/dev/null || echo "WireGuard no instalado/activo."
    echo
    echo -e "${C_BOLD}--- Puertos en escucha ---${C_RESET}"
    ss -tulnp 2>/dev/null | grep -E "LISTEN|UNCONN"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        system)  system_info ;;
        proto)   protocol_status ;;
        live)    live_connections ;;
        *) echo "Uso: $0 {system|proto|live}" ;;
    esac
fi
