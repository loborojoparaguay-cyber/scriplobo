#!/bin/bash
# =====================================================================
# modules/proto_hysteria.sh - Hysteria 2: proxy/VPN sobre QUIC (UDP)
#
# Hysteria 2 corre sobre QUIC (basado en UDP) con TLS 1.3 real y un
# control de congestión (Brutal) pensado para redes con alta latencia
# o pérdida de paquetes -- suele dar mejor "ping percibido" que TCP
# clásico, que es justo lo que buscan tus clientes.
#
# Nota sobre TLS: QUIC (la base de Hysteria) EXIGE TLS 1.3 por
# especificacion del protocolo mismo -- no existe forma de negociar
# TLS 1.2 o inferior sobre QUIC. No requiere configuracion adicional
# para forzarlo, a diferencia de TCP (Xray/Stunnel/OpenVPN) donde si
# hay que fijarlo explicitamente.
#
# Fuente oficial: https://github.com/apernet/hysteria (Apache 2.0)
# Instalador oficial: https://get.hy2.sh
#
# Reutiliza los mismos usuarios/contraseñas creados en modules/users.sh
# (formato auth.userpass: usuario -> password), así el vencimiento y
# el límite de conexiones se administran desde un solo lugar.
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

HY_CONF_DIR="/etc/hysteria"
HY_CONF="$HY_CONF_DIR/config.yaml"
HY_CRED_FILE="$PANEL_DATA/hysteria_userpass.yaml"   # generado desde users.db
HY_INSTALL_URL="https://get.hy2.sh"

install_hysteria() {
    local domain="$1" port="${2:-443}"
    [[ -z "$domain" ]] && { err "Debes indicar un dominio (para el certificado TLS real)."; return 1; }

    apt_install curl

    if ! command -v hysteria >/dev/null 2>&1; then
        msg "Instalando Hysteria 2 desde el instalador oficial del proyecto (apernet/hysteria)."
        bash -c "$(curl -fsSL ${HY_INSTALL_URL})"
    fi

    local cert_dir="/etc/letsencrypt/live/${domain}"
    if [[ ! -d "$cert_dir" ]]; then
        err "No hay certificado para ${domain}. Ejecuta primero el módulo SSL (Let's Encrypt)."
        return 1
    fi

    mkdir -p "$HY_CONF_DIR"
    touch "$HY_CRED_FILE"

    cat > "$HY_CONF" <<EOF
listen: :${port}

tls:
  cert: ${cert_dir}/fullchain.pem
  key: ${cert_dir}/privkey.pem

auth:
  type: userpass
  userpass: {}   # se completa dinámicamente -- ver sync_users()

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF

    echo "$domain" > "$HY_CONF_DIR/.domain"
    sync_users
    systemctl enable --now hysteria-server.service
    ok "Hysteria 2 activo en ${domain}:${port}/udp"
}

# ---------------------------------------------------------------------
# Sincroniza el bloque auth.userpass de Hysteria con los usuarios del
# panel (modules/users.sh). Se debe llamar tras crear/eliminar/renovar
# un usuario si quieres que también tenga acceso por Hysteria.
#
# Nota: las contraseñas del panel se guardan sólo como hash del sistema
# (via chpasswd), así que Hysteria necesita su PROPIA copia en texto
# claro para poder autenticar. Este módulo mantiene esa copia en
# $HY_CRED_FILE, gestionada únicamente por add_hy_user/remove_hy_user.
# ---------------------------------------------------------------------
add_hy_user() {
    local username="$1" password="$2"
    [[ -z "$username" || -z "$password" ]] && { err "Uso: add_hy_user <usuario> <password>"; return 1; }
    grep -v "^${username}:" "$HY_CRED_FILE" 2>/dev/null > "${HY_CRED_FILE}.tmp" || true
    mv "${HY_CRED_FILE}.tmp" "$HY_CRED_FILE"
    echo "${username}:${password}" >> "$HY_CRED_FILE"
    sync_users
    ok "Usuario '${username}' habilitado en Hysteria."
}

remove_hy_user() {
    local username="$1"
    grep -v "^${username}:" "$HY_CRED_FILE" 2>/dev/null > "${HY_CRED_FILE}.tmp" || true
    mv "${HY_CRED_FILE}.tmp" "$HY_CRED_FILE"
    sync_users
    ok "Usuario '${username}' eliminado de Hysteria."
}

sync_users() {
    [[ -f "$HY_CONF" ]] || return 0
    python3 - "$HY_CONF" "$HY_CRED_FILE" <<'PYEOF'
import sys
conf_path, cred_path = sys.argv[1], sys.argv[2]

users = {}
try:
    with open(cred_path) as f:
        for line in f:
            line = line.strip()
            if not line or ":" not in line:
                continue
            u, p = line.split(":", 1)
            users[u] = p
except FileNotFoundError:
    pass

with open(conf_path) as f:
    lines = f.readlines()

out = []
in_userpass = False
for line in lines:
    if line.strip().startswith("userpass:"):
        out.append("  userpass:\n")
        if users:
            for u, p in users.items():
                out.append(f"    {u}: \"{p}\"\n")
        else:
            out.append("    {}\n")
        in_userpass = True
        continue
    if in_userpass:
        # saltar líneas viejas de usuarios ya escritas (indentadas mas que "auth:")
        if line.startswith("    ") and ":" in line:
            continue
        in_userpass = False
    out.append(line)

with open(conf_path, "w") as f:
    f.writelines(out)
PYEOF
    systemctl restart hysteria-server.service 2>/dev/null || true
}

show_client_uri() {
    local username="$1"
    local password domain port
    password=$(grep "^${username}:" "$HY_CRED_FILE" 2>/dev/null | cut -d: -f2-)
    [[ -z "$password" ]] && { err "Usuario '${username}' no está habilitado en Hysteria."; return 1; }
    domain=$(cat "$HY_CONF_DIR/.domain" 2>/dev/null)
    port=$(grep -oP '(?<=listen: :)\d+' "$HY_CONF")
    echo "hysteria2://${username}:${password}@${domain}:${port}/?sni=${domain}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        install)       install_hysteria "$2" "$3" ;;
        add_user)      add_hy_user "$2" "$3" ;;
        remove_user)   remove_hy_user "$2" ;;
        sync)          sync_users ;;
        client_uri)    show_client_uri "$2" ;;
        *) echo "Uso: $0 {install <dominio> <puerto>|add_user <usuario> <pass>|remove_user <usuario>|sync|client_uri <usuario>}" ;;
    esac
fi
