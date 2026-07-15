#!/bin/bash
# =====================================================================
# admin-tools/issue_license.sh - Emite una licencia firmada para un
# cliente concreto (ejecutar en tu máquina personal, con tu clave
# privada, NUNCA en el servidor del cliente).
#
# Uso:
#   ./issue_license.sh <server_id_del_cliente> <nombre_cliente> <dias_validez> [max_users]
#
# El <server_id_del_cliente> se lo pide el cliente ejecutando en SU
# servidor:  sudo ./modules/license.sh machine_id
# =====================================================================
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVKEY="$DIR/keys/license_private.pem"

server_id="$1"; client="$2"; days="$3"; max_users="${4:-0}"

if [[ -z "$server_id" || -z "$client" || -z "$days" ]]; then
    echo "Uso: $0 <server_id> <nombre_cliente> <dias_validez> [max_users]"
    exit 1
fi
if [[ ! -f "$PRIVKEY" ]]; then
    echo "No existe admin-tools/keys/license_private.pem. Ejecuta primero ./keygen.sh"
    exit 1
fi
ver_major=$(openssl version 2>/dev/null | awk '{print $2}' | cut -d. -f1)
if [[ -z "$ver_major" || "$ver_major" -lt 3 ]]; then
    echo "Se requiere OpenSSL 3.0+ para Ed25519 vía pkeyutl (tu máquina tiene: $(openssl version 2>/dev/null || echo 'no instalado'))."
    exit 1
fi

license_id=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
issued=$(date +%Y-%m-%d)
expiry=$(date -d "+${days} days" +%Y-%m-%d)

payload=$(python3 -c "
import json
print(json.dumps({
    'license_id': '$license_id',
    'client': '$client',
    'server_id': '$server_id',
    'issued': '$issued',
    'expiry': '$expiry',
    'max_users': $max_users
}))
")

tmpdir=$(mktemp -d)
echo -n "$payload" > "$tmpdir/payload.raw"
openssl pkeyutl -sign -inkey "$PRIVKEY" -rawin -in "$tmpdir/payload.raw" -out "$tmpdir/sig.bin"

payload_b64=$(base64 -w0 "$tmpdir/payload.raw")
sig_b64=$(base64 -w0 "$tmpdir/sig.bin")
rm -rf "$tmpdir"

mkdir -p "$DIR/issued"
outfile="$DIR/issued/${client}_${license_id}.lic"
echo "${payload_b64}.${sig_b64}" > "$outfile"

echo "[OK] Licencia emitida: $outfile"
echo "     Cliente:    $client"
echo "     ID:         $license_id"
echo "     Vence:      $expiry"
echo "     Max users:  $max_users (0 = sin límite)"
echo
echo "Entrega este archivo al cliente como /etc/vps-panel/license.lic"
