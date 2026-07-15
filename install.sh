#!/bin/bash
# =====================================================================
# install.sh - Instalador maestro del VPS Panel
#
# Copia el panel a /opt/vps-panel, crea el enlace "vps-panel" en el
# PATH, prepara /etc/vps-panel (datos/config) y registra las tareas
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
INSTALL_DIR="/opt/vps-panel"

echo "[*] Instalando panel en ${INSTALL_DIR} ..."
mkdir -p "$INSTALL_DIR"
cp -r "$SRC_DIR"/* "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR"/panel.sh "$INSTALL_DIR"/modules/*.sh "$INSTALL_DIR"/lib/*.sh

# Enlace ejecutable global
ln -sf "$INSTALL_DIR/panel.sh" /usr/local/bin/vps-panel

# Preparamos /etc/vps-panel (dirs, DB, banner por defecto)
mkdir -p /etc/vps-panel/data/limits /etc/vps-panel/data/wg_peers /etc/vps-panel/data/xray_clients /etc/vps-panel/data/ovpn_clients /etc/vps-panel/logs
touch /etc/vps-panel/data/users.db
if [[ ! -f /etc/vps-panel/banner.txt ]]; then
    cat > /etc/vps-panel/banner.txt <<'EOF'
============================================
   Bienvenido - Servicio VPN administrado
   Acceso autorizado unicamente.
============================================
EOF
fi

# Tareas de cron: purgar usuarios vencidos (cada hora) y aplicar
# limite de conexiones simultaneas (cada minuto)
CRON_FILE="/etc/cron.d/vps-panel"
cat > "$CRON_FILE" <<EOF
* * * * * root ${INSTALL_DIR}/modules/users.sh enforce >> /etc/vps-panel/logs/enforce.log 2>&1
0 * * * * root ${INSTALL_DIR}/modules/users.sh purge   >> /etc/vps-panel/logs/purge.log 2>&1
EOF
chmod 644 "$CRON_FILE"

echo "[OK] Instalación completa."
echo "     Ejecuta el panel con: sudo vps-panel"
