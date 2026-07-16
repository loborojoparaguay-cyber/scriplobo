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
    for svc in ssh dropbear stunnel4 wg-quick@wg0 xray openvpn-server@server hysteria-server badvpn-udpgw nginx ws-ssh fail2ban; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${C_GREEN}[ON]${C_RESET}  $svc"
        else
            echo -e "  ${C_RED}[OFF]${C_RESET} $svc"
        fi
    done
}

# ---------------------------------------------------------------------
# Puerto configurado de cada protocolo (si está instalado), para
# mostrar en el dashboard principal, similar a paneles de referencia.
# ---------------------------------------------------------------------
# _first_match: devuelve el primer valor encontrado por el patrón, o
# "-" si no hay ninguno. Necesario porque "grep | head -1 || echo -"
# NO funciona: head siempre sale con código 0 aunque no reciba nada,
# así que el "||" nunca se activa y queda una cadena vacía en su lugar.
_first_match() {
    local val
    val=$(grep -oP "$1" "$2" 2>/dev/null | head -1)
    [[ -n "$val" ]] && echo "$val" || echo "-"
}

_port_ssh()       { local v; v=$(_first_match '^Port \K\d+' /etc/ssh/sshd_config); [[ "$v" == "-" ]] && echo 22 || echo "$v"; }
_port_dropbear()  { _first_match '(?<=DROPBEAR_PORT=)\d+' /etc/default/dropbear; }
_port_stunnel()   { _first_match '(?<=accept = )\d+' /etc/stunnel/vps-panel.conf; }
_port_wireguard() { _first_match '(?<=ListenPort = )\d+' /etc/wireguard/wg0.conf; }
_port_xray()      { _first_match '"port":\s*\K\d+' /usr/local/etc/xray/config.json; }
_port_openvpn()   { _first_match '^port \K\d+' /etc/openvpn/server/server.conf; }
_port_hysteria()  { _first_match '(?<=listen: :)\d+' /etc/hysteria/config.yaml; }
_port_badvpn()    { echo "7300"; }
_port_decoy()     { local v; v=$(cat "$PANEL_DATA/decoy_port" 2>/dev/null); [[ -n "$v" ]] && echo "$v" || echo "-"; }
_port_wsssh()     { local v; v=$(cat "$PANEL_DATA/wsssh_port" 2>/dev/null); [[ -n "$v" ]] && echo "$v" || echo "-"; }

# ---------------------------------------------------------------------
# Contadores de usuarios para el dashboard (activos / vencidos /
# bloqueados / total), leyendo la misma base que modules/users.sh
# ---------------------------------------------------------------------
user_counters() {
    local db="$USERS_DB"
    local total=0 activos=0 vencidos=0 bloqueados=0
    local today_epoch
    today_epoch=$(date +%s)
    [[ -f "$db" ]] || { echo "0 0 0 0"; return; }
    while IFS=: read -r username _; do
        [[ -z "$username" ]] && continue
        id "$username" &>/dev/null || continue
        total=$((total+1))
        if passwd -S "$username" 2>/dev/null | grep -q " L "; then
            bloqueados=$((bloqueados+1))
            continue
        fi
        local exp_str exp_epoch
        exp_str=$(chage -l "$username" 2>/dev/null | grep "Account expires" | cut -d: -f2 | sed 's/^ *//')
        if [[ "$exp_str" == "never" || -z "$exp_str" ]]; then
            activos=$((activos+1))
        else
            exp_epoch=$(date -d "$exp_str" +%s 2>/dev/null)
            if [[ -n "$exp_epoch" && "$exp_epoch" -lt "$today_epoch" ]]; then
                vencidos=$((vencidos+1))
            else
                activos=$((activos+1))
            fi
        fi
    done < "$db"
    echo "$total $activos $vencidos $bloqueados"
}

# ---------------------------------------------------------------------
# Dashboard principal (estilo panel de referencia): marca, sistema,
# puertos por protocolo, y contadores de usuarios, todo con datos
# reales leidos de la configuracion instalada -- sin datos de relleno.
# ---------------------------------------------------------------------
dashboard() {
    local ip os_name cpu_cores ram_total ram_used ram_free
    ip=$(get_public_ip)
    os_name=$(source /etc/os-release; echo "$PRETTY_NAME")
    cpu_cores=$(nproc)
    read -r ram_total ram_used ram_free < <(free -m | awk 'NR==2{print $2, $3, $4}')

    read -r u_total u_activos u_vencidos u_bloqueados < <(user_counters)

    echo -e "${C_CYAN}============================================================${C_RESET}"
    echo -e "${C_YELLOW}                        ${PANEL_BRAND}${C_RESET}"
    echo -e "${C_CYAN}============================================================${C_RESET}"
    echo -e " ${C_GREEN}ACTIVOS: ${u_activos}${C_RESET}   ${C_RED}VENCIDOS: ${u_vencidos}${C_RESET}   ${C_YELLOW}BLOQUEADOS: ${u_bloqueados}${C_RESET}   TOTAL: ${u_total}"
    echo -e "${C_CYAN}------------------------------------------------------------${C_RESET}"
    echo -e " S.O: ${os_name}          IP: ${ip}"
    echo -e " Fecha: $(date +%Y-%m-%d)        Hora: $(date +%H:%M:%S)"
    echo -e " CPU núcleos: ${cpu_cores}      RAM: ${ram_used}MB / ${ram_total}MB usados (libre: ${ram_free}MB)"
    echo -e "${C_CYAN}------------------------------------------------------------${C_RESET}"
    printf "  %-22s %-8s   %-22s %-8s\n" "SSH: $(_port_ssh)" "" "DROPBEAR: $(_port_dropbear)" ""
    printf "  %-22s %-8s   %-22s %-8s\n" "STUNNEL(TLS): $(_port_stunnel)" "" "WIREGUARD: $(_port_wireguard)" ""
    printf "  %-22s %-8s   %-22s %-8s\n" "XRAY: $(_port_xray)" "" "OPENVPN: $(_port_openvpn)" ""
    printf "  %-22s %-8s   %-22s %-8s\n" "HYSTERIA2: $(_port_hysteria)" "" "BADVPN(interno): $(_port_badvpn)" ""
    printf "  %-22s %-8s   %-22s %-8s\n" "SENUELO(interno): $(_port_decoy)" "" "WS->SSH: $(_port_wsssh)" ""
    echo -e "${C_CYAN}============================================================${C_RESET}"
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
