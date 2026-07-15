#!/bin/bash
# =====================================================================
# admin-tools/keygen.sh - Genera el par de claves del vendedor
#
# EJECUTAR UNA SOLA VEZ, EN TU MAQUINA PERSONAL (nunca en un servidor
# de cliente, nunca subir "keys/license_private.pem" a GitHub).
#
# Genera:
#   keys/license_private.pem  -> la usas TU para firmar licencias
#   keys/license_public.pem   -> esta SI va dentro del repo publico
#                                 (reemplaza config/license_public.pem)
# =====================================================================
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$DIR/keys"

ver_major=$(openssl version 2>/dev/null | awk '{print $2}' | cut -d. -f1)
if [[ -z "$ver_major" || "$ver_major" -lt 3 ]]; then
    echo "Se requiere OpenSSL 3.0+ para Ed25519 vía pkeyutl (tu máquina tiene: $(openssl version 2>/dev/null || echo 'no instalado'))."
    exit 1
fi

if [[ -f "$DIR/keys/license_private.pem" ]]; then
    echo "Ya existe un par de claves en admin-tools/keys/. Bórralo manualmente si quieres regenerarlo."
    exit 1
fi

openssl genpkey -algorithm ed25519 -out "$DIR/keys/license_private.pem"
openssl pkey -in "$DIR/keys/license_private.pem" -pubout -out "$DIR/keys/license_public.pem"
chmod 600 "$DIR/keys/license_private.pem"

echo "[OK] Claves generadas en admin-tools/keys/"
echo
echo "Siguiente paso:"
echo "  cp admin-tools/keys/license_public.pem config/license_public.pem"
echo "  (y sube ese cambio al repo -- la privada JAMAS se sube)"
