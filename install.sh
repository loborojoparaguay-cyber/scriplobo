#!/bin/bash
# =====================================================================
# install.sh - Instalador maestro de LoboPanel
#
# Copia el panel a /opt/lobopanel, crea el enlace "lobopanel" en el
# PATH, prepara /etc/lobopanel (datos/config) y registra las tareas
# de cron necesarias (expiración de usuarios y límite de conexiones).
# =====================================================================
set -e

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Ejecuta este instalador como root (sudo ./install.sh)"
    exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
    echo "Este panel solo soporta Debian/Ubuntu."
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/lobopanel"

echo "[*] Instalando panel en ${INSTALL_DIR} ..."
mkdir -p "$INSTALL_DIR"
cp -r "$SRC_DIR"/* "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR"/panel.sh "$INSTALL_DIR"/modules/*.sh "$INSTALL_DIR"/lib/*.sh
[[ -d "$INSTALL_DIR/bin" ]] && chmod +x "$INSTALL_DIR"/bin/*

# Enlace ejecutable global
ln -sf "$INSTALL_DIR/panel.sh" /usr/local/bin/lobopanel

# Preparamos /etc/lobopanel (dirs, DB, banner por defecto)
mkdir -p /etc/lobopanel/data/limits /etc/lobopanel/data/wg_peers /etc/lobopanel/data/xray_clients /etc/lobopanel/data/ovpn_clients /etc/lobopanel/logs
touch /etc/lobopanel/data/users.db
if [[ ! -f /etc/lobopanel/banner.txt ]]; then
    cat > /etc/lobopanel/banner.txt <<'EOF'
============================================
   Bienvenido - Servicio VPN administrado
   Acceso autorizado unicamente.
============================================
EOF
fi

# Tareas de cron: purgar usuarios vencidos (cada hora) y aplicar
# limite de conexiones simultaneas (cada minuto)
CRON_FILE="/etc/cron.d/lobopanel"
cat > "$CRON_FILE" <<EOF
* * * * * root ${INSTALL_DIR}/modules/users.sh enforce >> /etc/lobopanel/logs/enforce.log 2>&1
0 * * * * root ${INSTALL_DIR}/modules/users.sh purge   >> /etc/lobopanel/logs/purge.log 2>&1
EOF
chmod 644 "$CRON_FILE"

echo "[OK] Instalación completa."
echo "     Ejecuta el panel con: sudo lobopanel"
