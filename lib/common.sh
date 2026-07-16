#!/bin/bash
# =====================================================================
# lib/common.sh - Funciones y variables compartidas por todo el panel
# =====================================================================

# --- Colores para la interfaz ---
export C_RED="\e[31m"
export C_GREEN="\e[32m"
export C_YELLOW="\e[33m"
export C_CYAN="\e[36m"
export C_BOLD="\e[1m"
export C_RESET="\e[0m"

# --- Rutas base del panel ---
export PANEL_HOME="/etc/vps-panel"
export PANEL_DATA="$PANEL_HOME/data"
export PANEL_CONF="$PANEL_HOME/panel.conf"
export PANEL_LOGS="$PANEL_HOME/logs"
export USERS_DB="$PANEL_DATA/users.db"          # usuario:limite_conexiones:notas
export LIMITS_DIR="$PANEL_DATA/limits"          # un archivo por usuario con su límite
export VPN_GROUP="vpnclientes"                  # grupo unix para todos los usuarios de servicio

# --- Utilidades básicas ---
msg()    { echo -e "${C_CYAN}[*]${C_RESET} $*"; }
ok()     { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn()   { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()    { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
pause()  { read -rp "Presiona ENTER para continuar..." _; }

# Algunas apps de terminal (SSH desde Android/ChromeOS, algunos clientes
# web) envían un retorno de carro (\r) junto con el texto ingresado. Si
# no se limpia, comparaciones como [[ "$op" == "1" ]] fallan en silencio
# porque en realidad se compara "1\r" contra "1". Esta función limpia
# ese carácter invisible y los espacios sobrantes de cualquier input.
clean_input() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "Este panel debe ejecutarse como root (usa sudo)."
        exit 1
    fi
}

init_dirs() {
    mkdir -p "$PANEL_DATA" "$LIMITS_DIR" "$PANEL_LOGS"
    mkdir -p "$(dirname "$USERS_DB")"
    touch "$USERS_DB"
    if ! getent group "$VPN_GROUP" >/dev/null 2>&1; then
        groupadd "$VPN_GROUP"
    fi
}

# Detecta el gestor de paquetes (asumimos Debian/Ubuntu, pero validamos)
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        echo "unsupported"
    fi
}

require_debian() {
    if [[ "$(detect_os)" != "debian" ]]; then
        err "Este panel solo soporta distribuciones basadas en Debian/Ubuntu."
        exit 1
    fi
}

# Instala paquetes solo si faltan
apt_install() {
    local pkgs=("$@")
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        msg "Instalando paquetes: ${missing[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
}

# Obtiene la IP pública del servidor
get_public_ip() {
    curl -s --max-time 3 ifconfig.me || hostname -I | awk '{print $1}'
}
