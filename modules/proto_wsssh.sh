#!/bin/bash
# =====================================================================
# modules/proto_wsssh.sh - WebSocket "falso" -> SSH/Dropbear (liviano)
#
# A diferencia de Xray (VLESS+TLS), esta opcion NO agrega una capa de
# cifrado propia: el bridge solo responde el handshake HTTP inicial y
# despues reenvia el trafico crudo directo al puerto de SSH/Dropbear.
# El unico cifrado real que viaja es el de SSH (que ya es fuerte por
# si solo).
#
# Resultado: una sola capa de cifrado en vez de dos o tres -- mucho
# menos trabajo de CPU para el cliente. Ideal para celulares viejos o
# de gama baja donde Xray/VLESS+TLS se siente pesado.
#
# Dos modos:
#   - Sin TLS (ws://)  -> lo mas liviano posible, pero el handshake
#     inicial viaja sin cifrar (el contenido SSH adentro SI esta
#     cifrado por SSH mismo).
#   - Con TLS (wss://) -> agrega Stunnel delante (ver proto_stunnel.sh)
#     para cifrar tambien el handshake. Un poco mas de CPU, pero sigue
#     siendo mas liviano que Xray porque no hay parsing de VLESS de
#     por medio.
#
# Por que un script propio (bin/raw_ws_bridge.py) en vez de websockify:
#
# websockify implementa el protocolo WebSocket real (RFC 6455) y
# envuelve cada paquete en un frame binario propio. Apps de Android
# como HTTP Custom / HTTP Injector / NPV Tunnel NO hablan WebSocket de
# verdad: solo mandan un handshake HTTP para "camuflar" el trafico y
# despues esperan bytes crudos, sin ningun framing -- igual que un
# tunel HTTP CONNECT simple. Con websockify, sshd recibia los bytes
# envueltos en frames en vez del banner SSH limpio y la conexion se
# caia con "kex_exchange_identification". El bridge propio evita el
# problema por completo: nunca genera frames, solo copia bytes.
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

WS_SERVICE="/etc/systemd/system/ws-ssh.service"
WS_PORT_DEFAULT=8880
WS_BRIDGE_SCRIPT="$SCRIPT_DIR/bin/raw_ws_bridge.py"

install_wsssh() {
    local ws_port="${1:-$WS_PORT_DEFAULT}" ssh_port="${2:-22}"

    apt_install python3

    cat > "$WS_SERVICE" <<EOF
[Unit]
Description=WebSocket (falso, bytes crudos) -> SSH/Dropbear bridge
After=network.target ssh.service dropbear.service

[Service]
ExecStart=/usr/bin/python3 ${WS_BRIDGE_SCRIPT} ${ws_port} 127.0.0.1:${ssh_port}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ws-ssh
    echo "$ws_port" > "$PANEL_DATA/wsssh_port"
    ok "WebSocket->SSH activo: ws://<tu-ip>:${ws_port} -> 127.0.0.1:${ssh_port}"
    warn "Este modo NO tiene TLS propio. Para wss:// (cifrado), usa la opción 'Vincular a Stunnel' luego de instalar Stunnel."
}

# Vincula este bridge detrás de Stunnel para obtener wss:// (cifrado)
# en vez de ws:// (sin cifrar) -- Stunnel escucha en el puerto público
# con TLS y reenvía internamente a este bridge.
link_stunnel() {
    local stunnel_port="${1:-443}"
    local ws_port
    ws_port=$(cat "$PANEL_DATA/wsssh_port" 2>/dev/null)
    [[ -z "$ws_port" ]] && { err "Primero instala el bridge WebSocket->SSH (opción anterior)."; return 1; }

    "$SCRIPT_DIR/modules/proto_stunnel.sh" install "$stunnel_port" "$ws_port"
    ok "wss://<tu-dominio>:${stunnel_port} ahora envuelve el WebSocket->SSH en TLS 1.3."
}

wsssh_status() {
    systemctl status ws-ssh --no-pager 2>/dev/null || echo "WebSocket->SSH no está instalado."
}

uninstall_wsssh() {
    systemctl disable --now ws-ssh 2>/dev/null
    rm -f "$WS_SERVICE" "$PANEL_DATA/wsssh_port"
    systemctl daemon-reload
    ok "WebSocket->SSH desinstalado."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        install)     install_wsssh "$2" "$3" ;;
        link_stunnel) link_stunnel "$2" ;;
        status)      wsssh_status ;;
        uninstall)   uninstall_wsssh ;;
        *) echo "Uso: $0 {install <puerto_ws> <puerto_ssh>|link_stunnel <puerto_publico>|status|uninstall}" ;;
    esac
fi
