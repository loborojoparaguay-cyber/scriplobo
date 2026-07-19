#!/bin/bash
# =====================================================================
# modules/proto_badvpn.sh - BadVPN UDPGW (relay de UDP dentro del túnel)
#
# Corrección de diseño: SSH/Dropbear solo tunelan TCP de forma nativa.
# Los clientes que usan la app en modo "SOCKS + tun2socks" sobre ese
# túnel SSH necesitan un puente para el tráfico UDP (juegos, VoIP,
# DNS) -- eso es exactamente lo que hace badvpn-udpgw.
#
# Importante sobre seguridad: udpgw NO es un túnel independiente ni
# necesita cifrado propio, porque el tráfico ya viaja DENTRO del
# túnel SSH/Dropbear (que sí está cifrado). Por eso solo escucha en
# 127.0.0.1 -- nunca debe expuesto directamente a internet.
#
# Fuente oficial: https://github.com/ambrop72/badvpn (BSD-like license)
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

BADVPN_REPO="https://github.com/ambrop72/badvpn.git"
BUILD_DIR="/usr/local/src/badvpn"
BIN_PATH="/usr/local/bin/badvpn-udpgw"
SERVICE_FILE="/etc/systemd/system/badvpn-udpgw.service"
DEFAULT_PORT=7300

build_badvpn() {
    apt_install git cmake build-essential

    if [[ -x "$BIN_PATH" ]]; then
        ok "badvpn-udpgw ya está compilado."
        return 0
    fi

    msg "Clonando y compilando badvpn desde el código fuente oficial (ambrop72/badvpn)."
    rm -rf "$BUILD_DIR"
    git clone --depth 1 "$BADVPN_REPO" "$BUILD_DIR" || { err "Falló el clonado de badvpn."; return 1; }

    mkdir -p "$BUILD_DIR/build"
    cd "$BUILD_DIR/build" || return 1
    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 || return 1
    make -j"$(nproc)" || return 1

    find "$BUILD_DIR/build" -name "badvpn-udpgw" -exec cp {} "$BIN_PATH" \;
    chmod +x "$BIN_PATH"

    if [[ ! -x "$BIN_PATH" ]]; then
        err "No se encontró el binario compilado. Revisa la salida de 'make' arriba."
        return 1
    fi
    ok "badvpn-udpgw compilado en ${BIN_PATH}."
}

install_badvpn() {
    local port="${1:-$DEFAULT_PORT}" max_clients="${2:-999}"

    build_badvpn || return 1

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=BadVPN UDPGW - relay UDP para clientes tunelados por SSH/Dropbear
After=network.target

[Service]
ExecStart=${BIN_PATH} --listen-addr 127.0.0.1:${port} --max-clients ${max_clients} --max-connections-for-client 15 --loglevel none
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now badvpn-udpgw
    ok "BadVPN UDPGW activo en 127.0.0.1:${port} (solo accesible desde el propio servidor, vía el túnel SSH/Dropbear)."
    warn "Este puerto se usa DENTRO del túnel SSH/Dropbear -- no debe abrirse en el firewall hacia internet."
    msg "En la app cliente (HTTP Injector, NPV Tunnel, etc.) configura: UDPGW Server = 127.0.0.1:${port} (referenciado desde dentro del túnel, no como puerto público)."
}

status_badvpn() {
    systemctl status badvpn-udpgw --no-pager 2>/dev/null || echo "BadVPN UDPGW no está instalado."
}

uninstall_badvpn() {
    systemctl disable --now badvpn-udpgw 2>/dev/null
    rm -f "$SERVICE_FILE" "$BIN_PATH"
    systemctl daemon-reload
    ok "BadVPN UDPGW desinstalado."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        install)    install_badvpn "$2" "$3" ;;
        status)     status_badvpn ;;
        uninstall)  uninstall_badvpn ;;
        *) echo "Uso: $0 {install <puerto_interno> <max_clientes>|status|uninstall}" ;;
    esac
fi
