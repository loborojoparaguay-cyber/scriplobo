#!/bin/bash
# =====================================================================
# modules/proto_xray.sh - Xray-core: VLESS+TLS y Trojan
#
# Tráfico camuflado como HTTPS normal (TLS 1.3 real), ideal para
# clientes que necesitan buena latencia y resistencia a inspección
# de tráfico (DPI). Usa el binario oficial de Xray-core (Project X),
# software libre y ampliamente auditado.
#
# Requiere un dominio propio apuntando al servidor + certificado real
# (ver modules/ssl.sh) para que el TLS sea válido de verdad.
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_CONF_DIR/config.json"
XRAY_CLIENTS_DIR="$PANEL_DATA/xray_clients"
XRAY_INSTALL_SCRIPT_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

install_xray() {
    local domain="$1" port="${2:-443}"
    [[ -z "$domain" ]] && { err "Debes indicar el dominio (debe apuntar por DNS a este servidor)."; return 1; }

    apt_install curl unzip
    mkdir -p "$XRAY_CLIENTS_DIR"

    if ! command -v xray >/dev/null 2>&1; then
        msg "Instalando Xray-core desde el instalador oficial del proyecto (XTLS/Xray-install)."
        bash -c "$(curl -sL ${XRAY_INSTALL_SCRIPT_URL})" @ install
    fi

    local cert_dir="/etc/letsencrypt/live/${domain}"
    if [[ ! -d "$cert_dir" ]]; then
        err "No hay certificado para ${domain}. Ejecuta primero el módulo SSL (Let's Encrypt)."
        return 1
    fi

    mkdir -p "$XRAY_CONF_DIR"
    cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "${cert_dir}/fullchain.pem", "keyFile": "${cert_dir}/privkey.pem" }
          ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

    systemctl enable --now xray
    echo "$domain" > "$XRAY_CONF_DIR/.domain"
    ok "Xray (VLESS+TLS) activo en ${domain}:${port}"
}

# Agrega un cliente VLESS (genera UUID y link de conexión vless://)
add_client() {
    local client_name="$1"
    [[ -z "$client_name" ]] && { err "Debes indicar un nombre de cliente."; return 1; }
    command -v xray >/dev/null 2>&1 || { err "Xray no está instalado."; return 1; }

    local uuid domain port
    uuid=$(xray uuid)
    domain=$(cat "$XRAY_CONF_DIR/.domain" 2>/dev/null)
    port=$(grep -oP '"port":\s*\K\d+' "$XRAY_CONF" | head -1)

    # Insertamos el cliente en el array "clients" del inbound VLESS
    python3 - "$XRAY_CONF" "$uuid" "$client_name" <<'PYEOF'
import json, sys
conf_path, uuid, name = sys.argv[1], sys.argv[2], sys.argv[3]
with open(conf_path) as f:
    data = json.load(f)
data["inbounds"][0]["settings"]["clients"].append({"id": uuid, "email": name})
with open(conf_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

    systemctl restart xray

    mkdir -p "$XRAY_CLIENTS_DIR"
    local link="vless://${uuid}@${domain}:${port}?security=tls&type=tcp#${client_name}"
    echo "$link" > "$XRAY_CLIENTS_DIR/${client_name}.link"
    echo "$uuid" > "$XRAY_CLIENTS_DIR/${client_name}.uuid"

    ok "Cliente Xray '${client_name}' creado."
    msg "Link de conexión: $link"
}

remove_client() {
    local client_name="$1"
    local uuid
    uuid=$(cat "$XRAY_CLIENTS_DIR/${client_name}.uuid" 2>/dev/null)
    [[ -z "$uuid" ]] && { err "Cliente '${client_name}' no encontrado."; return 1; }

    python3 - "$XRAY_CONF" "$uuid" <<'PYEOF'
import json, sys
conf_path, uuid = sys.argv[1], sys.argv[2]
with open(conf_path) as f:
    data = json.load(f)
clients = data["inbounds"][0]["settings"]["clients"]
data["inbounds"][0]["settings"]["clients"] = [c for c in clients if c["id"] != uuid]
with open(conf_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

    systemctl restart xray
    rm -f "$XRAY_CLIENTS_DIR/${client_name}.link" "$XRAY_CLIENTS_DIR/${client_name}.uuid"
    ok "Cliente '${client_name}' eliminado de Xray."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        install)        install_xray "$2" "$3" ;;
        add_client)     add_client "$2" ;;
        remove_client)  remove_client "$2" ;;
        *) echo "Uso: $0 {install <dominio> <puerto>|add_client <nombre>|remove_client <nombre>}" ;;
    esac
fi
