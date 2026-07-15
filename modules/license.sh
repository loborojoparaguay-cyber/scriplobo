#!/bin/bash
# =====================================================================
# modules/license.sh - Verificación de licencia (Ed25519, sin servidor)
#
# El código de este panel se distribuye públicamente, pero solo puede
# usarse en producción con un archivo de licencia firmado por el autor.
#
# Solo la CLAVE PÚBLICA vive en este repo (config/license_public.pem).
# La clave PRIVADA nunca se publica: la genera y guarda el vendedor en
# admin-tools/ (fuera de este repo). Con la clave pública es imposible
# falsificar una licencia, solo verificar las que el autor firmó.
#
# Formato del archivo de licencia (una sola línea):
#   <payload_json_base64>.<firma_base64>
#
# El payload incluye: license_id, client, server_id (huella de la
# máquina), issued, expiry, max_users.
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

LICENSE_FILE="/etc/vps-panel/license.lic"
PUBKEY_FILE="$SCRIPT_DIR/config/license_public.pem"
TRIAL_FLAG="/etc/vps-panel/trial_mode"
REVOKED_URL="${VPSPANEL_REVOKED_URL:-}"     # opcional: URL a un revoked.json
REVOKED_CACHE="$PANEL_DATA/revoked_cache.json"

# ---------------------------------------------------------------------
# Huella única del servidor (machine-id + primera MAC de red).
# Esto es lo que el "cliente" te debe enviar para que le generes su
# licencia, y lo que impide copiar el .lic a otro servidor.
# ---------------------------------------------------------------------
machine_id() {
    local mid mac
    mid=$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null)
    mac=$(cat /sys/class/net/*/address 2>/dev/null | sort | head -1)
    echo -n "${mid}${mac}" | sha256sum | awk '{print $1}'
}

_b64d() { base64 -d 2>/dev/null; }

# El sistema de licencias usa Ed25519 vía `openssl pkeyutl -rawin`, que
# solo esta soportado desde OpenSSL 3.0+ (Ubuntu 22.04/24.04). En
# OpenSSL 1.1.1 (Ubuntu 20.04) esta operacion no existe.
check_openssl_version() {
    local ver major
    ver=$(openssl version 2>/dev/null | awk '{print $2}')
    major=$(echo "$ver" | cut -d. -f1)
    if [[ -z "$major" || "$major" -lt 3 ]]; then
        err "Se requiere OpenSSL 3.0 o superior para el sistema de licencias (detectado: ${ver:-no instalado})."
        err "Usa Ubuntu 22.04 o 24.04 para este panel."
        return 1
    fi
    return 0
}

verify_license() {
    check_openssl_version || return 1
    [[ -f "$PUBKEY_FILE" ]] || { err "Falta la clave pública de licencias (config/license_public.pem)."; return 1; }
    [[ -f "$LICENSE_FILE" ]] || { err "No se encontró archivo de licencia en $LICENSE_FILE"; return 1; }

    local content payload_b64 sig_b64 tmpdir
    content=$(cat "$LICENSE_FILE")
    payload_b64="${content%%.*}"
    sig_b64="${content#*.}"
    if [[ "$payload_b64" == "$content" || -z "$sig_b64" ]]; then
        err "Formato de licencia inválido."
        return 1
    fi

    tmpdir=$(mktemp -d)
    echo -n "$payload_b64" | _b64d > "$tmpdir/payload.raw" 2>/dev/null
    echo -n "$sig_b64"     | _b64d > "$tmpdir/sig.bin" 2>/dev/null

    if ! openssl pkeyutl -verify -pubin -inkey "$PUBKEY_FILE" -rawin \
            -in "$tmpdir/payload.raw" -sigfile "$tmpdir/sig.bin" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        err "La firma de la licencia no es válida (archivo corrupto, editado o falsificado)."
        return 1
    fi

    local json expiry server_id license_id max_users
    json=$(cat "$tmpdir/payload.raw")
    rm -rf "$tmpdir"

    expiry=$(echo "$json"     | python3 -c "import json,sys;print(json.load(sys.stdin)['expiry'])" 2>/dev/null)
    server_id=$(echo "$json"  | python3 -c "import json,sys;print(json.load(sys.stdin)['server_id'])" 2>/dev/null)
    license_id=$(echo "$json" | python3 -c "import json,sys;print(json.load(sys.stdin)['license_id'])" 2>/dev/null)
    max_users=$(echo "$json"  | python3 -c "import json,sys;print(json.load(sys.stdin).get('max_users',0))" 2>/dev/null)

    if [[ -z "$server_id" || "$server_id" != "$(machine_id)" ]]; then
        err "Esta licencia no corresponde a este servidor."
        return 1
    fi

    local today_epoch expiry_epoch
    today_epoch=$(date +%s)
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
    if [[ -z "$expiry_epoch" || "$today_epoch" -gt "$expiry_epoch" ]]; then
        err "La licencia venció el ${expiry}. Contacta al vendedor para renovarla."
        return 1
    fi

    # Revocación remota opcional (best-effort: si no hay internet, se
    # usa el último cache conocido y no bloquea el arranque del panel)
    if [[ -n "$REVOKED_URL" ]]; then
        curl -s --max-time 3 "$REVOKED_URL" -o "${REVOKED_CACHE}.tmp" 2>/dev/null \
            && mv "${REVOKED_CACHE}.tmp" "$REVOKED_CACHE"
        if [[ -f "$REVOKED_CACHE" ]] && grep -q "\"$license_id\"" "$REVOKED_CACHE" 2>/dev/null; then
            err "Esta licencia fue revocada por el vendedor."
            return 1
        fi
    fi

    export VPSPANEL_LICENSE_ID="$license_id"
    export VPSPANEL_LICENSE_EXPIRY="$expiry"
    export VPSPANEL_LICENSE_MAX_USERS="$max_users"
    return 0
}

# ---------------------------------------------------------------------
# Se llama al arrancar panel.sh. Permite modo prueba local (sin
# licencia) creando manualmente /etc/vps-panel/trial_mode -- pensado
# para que TÚ, como desarrollador, puedas probar en tu VPS de pruebas
# sin generarte una licencia a ti mismo cada vez.
# ---------------------------------------------------------------------
require_license() {
    if [[ -f "$TRIAL_FLAG" ]]; then
        warn "PANEL EN MODO PRUEBA (trial_mode activo) — sin verificación de licencia."
        warn "Elimina /etc/vps-panel/trial_mode antes de entregar este servidor a un cliente."
        return 0
    fi

    if ! verify_license; then
        echo
        warn "Este panel requiere una licencia válida para funcionar."
        warn "Huella de este servidor (envíasela al vendedor para generar la licencia):"
        echo -e "  ${C_BOLD}$(machine_id)${C_RESET}"
        exit 1
    fi
}

show_license_info() {
    if [[ -f "$TRIAL_FLAG" ]]; then
        warn "Modo prueba activo (sin licencia)."
        return 0
    fi
    if verify_license; then
        ok "Licencia válida."
        echo "  ID:        $VPSPANEL_LICENSE_ID"
        echo "  Vence:     $VPSPANEL_LICENSE_EXPIRY"
        echo "  Máx users: $VPSPANEL_LICENSE_MAX_USERS"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        machine_id) machine_id ;;
        verify)     verify_license && ok "Licencia OK" ;;
        info)       show_license_info ;;
        *) echo "Uso: $0 {machine_id|verify|info}" ;;
    esac
fi
