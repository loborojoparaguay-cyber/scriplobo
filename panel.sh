#!/bin/bash
# =====================================================================
# panel.sh - Menú principal del VPS Panel
#
# Panel propio de administración para un servicio de VPN/proxy
# multi-protocolo orientado a clientes de pago. Une los módulos de:
#   - Gestión de usuarios (SSH/Dropbear)
#   - Protocolos: SSH, Dropbear, Stunnel, WireGuard, Xray, OpenVPN
#   - SSL real (Let's Encrypt / acme.sh)
#   - Hardening: firewall (ufw), fail2ban
#   - Monitoreo del sistema y conexiones
# =====================================================================
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

for m in users proto_ssh proto_stunnel proto_wireguard proto_xray proto_openvpn proto_hysteria proto_badvpn ssl hardening monitor license; do
    source "$SCRIPT_DIR/modules/${m}.sh"
done

require_root
require_debian
init_dirs
require_license

header() {
    clear
    echo -e "${C_RED}============================================================${C_RESET}"
    echo -e "${C_YELLOW}                     VPS PANEL - $1${C_RESET}"
    echo -e "${C_RED}============================================================${C_RESET}"
}

ask() { read -rp "$1: " REPLY_VAL; clean_input "$REPLY_VAL"; }
read_option() { read -rp "Opción: " __op; clean_input "$__op"; }

# --------------------------- Menú: Usuarios ---------------------------
menu_users() {
    while true; do
        header "ADMINISTRACION DE USUARIOS (SSH/Dropbear)"
        echo " [1] Crear usuario"
        echo " [2] Crear usuario temporal (horas)"
        echo " [3] Eliminar usuario"
        echo " [4] Renovar usuario"
        echo " [5] Bloquear usuario"
        echo " [6] Desbloquear usuario"
        echo " [7] Cambiar límite de conexiones"
        echo " [8] Listar usuarios"
        echo " [9] Ver conexiones activas por usuario"
        echo "[10] Eliminar usuarios vencidos ahora"
        echo " [0] Volver"
        op=$(read_option)
        case "$op" in
            1) u=$(ask "Usuario"); p=$(ask "Contraseña"); d=$(ask "Días de validez"); l=$(ask "Límite de conexiones"); create_user "$u" "$p" "$d" "$l"; pause ;;
            2) u=$(ask "Usuario"); p=$(ask "Contraseña"); h=$(ask "Horas de validez"); l=$(ask "Límite de conexiones"); create_temp_user "$u" "$p" "$h" "$l"; pause ;;
            3) u=$(ask "Usuario a eliminar"); delete_user "$u"; pause ;;
            4) u=$(ask "Usuario"); d=$(ask "Días a agregar"); renew_user "$u" "$d"; pause ;;
            5) u=$(ask "Usuario"); lock_user "$u"; pause ;;
            6) u=$(ask "Usuario"); unlock_user "$u"; pause ;;
            7) u=$(ask "Usuario"); l=$(ask "Nuevo límite"); set_limit "$u" "$l"; pause ;;
            8) list_users; pause ;;
            9) online_users; pause ;;
            10) purge_expired_users; pause ;;
            0) break ;;
            *) err "Opción inválida: '${op}'"; pause ;;
        esac
    done
}

# --------------------------- Menú: Protocolos ---------------------------
menu_protocols() {
    while true; do
        header "ADMINISTRACION DE PROTOCOLOS"
        protocol_status
        echo
        echo " [1] Instalar/configurar SSH"
        echo " [2] Instalar/configurar Dropbear"
        echo " [3] Instalar Stunnel (TLS sobre SSH/Dropbear)"
        echo " [4] Usar certificado real en Stunnel"
        echo " [5] Instalar WireGuard"
        echo " [6] Agregar peer WireGuard"
        echo " [7] Eliminar peer WireGuard"
        echo " [8] Listar peers WireGuard"
        echo " [9] Instalar Xray (VLESS+TLS)"
        echo "[10] Agregar cliente Xray"
        echo "[11] Eliminar cliente Xray"
        echo "[12] Instalar OpenVPN"
        echo "[13] Agregar cliente OpenVPN"
        echo "[14] Eliminar cliente OpenVPN"
        echo "[15] Instalar Hysteria 2 (UDP/QUIC, baja latencia)"
        echo "[16] Habilitar usuario en Hysteria"
        echo "[17] Deshabilitar usuario en Hysteria"
        echo "[18] Ver link de conexión Hysteria de un usuario"
        echo "[19] Editar banner de conexión"
        echo "[20] Cambiar puerto de SSH"
        echo "[21] Instalar BadVPN UDPGW (mejora ping de juegos/VoIP en SSH/Dropbear)"
        echo "[22] Ver estado de BadVPN UDPGW"
        echo "[23] Desinstalar BadVPN UDPGW"
        echo " [0] Volver"
        op=$(read_option)
        case "$op" in
            1) install_openssh; pause ;;
            2) pr=$(ask "Puerto Dropbear [442]"); install_dropbear "${pr:-442}"; pause ;;
            3) lp=$(ask "Puerto de escucha TLS [443]"); bp=$(ask "Puerto backend SSH/Dropbear [22]"); install_stunnel "${lp:-443}" "${bp:-22}"; pause ;;
            4) d=$(ask "Dominio con certificado Let's Encrypt"); use_real_cert "$d"; pause ;;
            5) pr=$(ask "Puerto WireGuard [51820]"); install_wireguard "${pr:-51820}"; pause ;;
            6) n=$(ask "Nombre del cliente"); add_peer "$n"; pause ;;
            7) n=$(ask "Nombre del cliente"); remove_peer "$n"; pause ;;
            8) list_peers; pause ;;
            9) d=$(ask "Dominio (debe apuntar a este servidor)"); pr=$(ask "Puerto [443]"); install_xray "$d" "${pr:-443}"; pause ;;
            10) n=$(ask "Nombre del cliente"); add_client "$n"; pause ;;
            11) n=$(ask "Nombre del cliente"); remove_client "$n"; pause ;;
            12) pr=$(ask "Puerto [1194]"); pt=$(ask "Protocolo udp/tcp [udp]"); install_openvpn "${pr:-1194}" "${pt:-udp}"; pause ;;
            13) n=$(ask "Nombre del cliente"); add_client "$n"; pause ;;
            14) n=$(ask "Nombre del cliente"); remove_client "$n"; pause ;;
            15) d=$(ask "Dominio (debe apuntar a este servidor)"); pr=$(ask "Puerto [443]"); install_hysteria "$d" "${pr:-443}"; pause ;;
            16) u=$(ask "Usuario"); p=$(ask "Contraseña para Hysteria"); add_hy_user "$u" "$p"; pause ;;
            17) u=$(ask "Usuario"); remove_hy_user "$u"; pause ;;
            18) u=$(ask "Usuario"); show_client_uri "$u"; pause ;;
            19) set_banner ;;
            20) pr=$(ask "Nuevo puerto SSH"); change_ssh_port "$pr"; pause ;;
            21) pr=$(ask "Puerto interno UDPGW [7300]"); mc=$(ask "Máx clientes [999]"); install_badvpn "${pr:-7300}" "${mc:-999}"; pause ;;
            22) status_badvpn; pause ;;
            23) uninstall_badvpn; pause ;;
            0) break ;;
            *) err "Opción inválida: '${op}'"; pause ;;
        esac
    done
}

# --------------------------- Menú: SSL / Hardening ---------------------------
menu_security() {
    while true; do
        header "SEGURIDAD: SSL / FIREWALL / FAIL2BAN"
        echo " [1] Emitir certificado SSL real (Let's Encrypt)"
        echo " [2] Listar certificados"
        echo " [3] Instalar y activar firewall (ufw)"
        echo " [4] Abrir puerto"
        echo " [5] Cerrar puerto"
        echo " [6] Instalar Fail2ban"
        echo " [7] Ver estado de Fail2ban"
        echo " [0] Volver"
        op=$(read_option)
        case "$op" in
            1) d=$(ask "Dominio"); issue_cert "$d"; pause ;;
            2) list_certs; pause ;;
            3) install_firewall; pause ;;
            4) p=$(ask "Puerto"); pt=$(ask "Protocolo tcp/udp [tcp]"); open_port "$p" "${pt:-tcp}"; pause ;;
            5) p=$(ask "Puerto"); pt=$(ask "Protocolo tcp/udp [tcp]"); close_port "$p" "${pt:-tcp}"; pause ;;
            6) install_fail2ban; pause ;;
            7) fail2ban_status; pause ;;
            0) break ;;
            *) err "Opción inválida: '${op}'"; pause ;;
        esac
    done
}

# --------------------------- Menú: Monitor ---------------------------
menu_monitor() {
    while true; do
        header "MONITOR DEL SISTEMA"
        echo " [1] Información del sistema (CPU/RAM/Disco)"
        echo " [2] Estado de protocolos"
        echo " [3] Conexiones activas en vivo"
        echo " [0] Volver"
        op=$(read_option)
        case "$op" in
            1) system_info; pause ;;
            2) protocol_status; pause ;;
            3) live_connections; pause ;;
            0) break ;;
            *) err "Opción inválida: '${op}'"; pause ;;
        esac
    done
}

# --------------------------- Menú principal ---------------------------
main_menu() {
    while true; do
        header "MENU PRINCIPAL"
        system_info
        echo
        echo " [1] Administrar usuarios (SSH/Dropbear)"
        echo " [2] Administrar protocolos"
        echo " [3] Seguridad (SSL/Firewall/Fail2ban)"
        echo " [4] Monitor del sistema"
        echo " [5] Info de licencia"
        echo " [0] Salir"
        op=$(read_option)
        case "$op" in
            1) menu_users ;;
            2) menu_protocols ;;
            3) menu_security ;;
            4) menu_monitor ;;
            5) show_license_info; pause ;;
            0) echo "Saliendo..."; exit 0 ;;
            *) err "Opción inválida: '${op}'"; pause ;;
        esac
    done
}

main_menu
