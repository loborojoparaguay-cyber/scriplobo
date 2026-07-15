#!/bin/bash
# =====================================================================
# modules/users.sh - Gestión de usuarios del servicio VPN/proxy
#
# Los usuarios creados aquí son cuentas UNIX reales, usadas como
# credenciales para SSH, Dropbear, Stunnel y (opcionalmente) como
# base para generar configuraciones de WireGuard/Xray por cliente.
#
# Características:
#   - Alta con fecha de vencimiento (chage -E)
#   - Shell restringida (sin acceso a shell real, solo túnel)
#   - Límite de conexiones simultáneas (via /etc/security/limits.d
#     + un script de conteo con `who`/`ss`)
#   - Bloqueo/desbloqueo (passwd -l / -u)
#   - Listado con días restantes
#   - Eliminación de usuarios vencidos (para cron)
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

NOLOGIN_BIN="$(command -v nologin || echo /usr/sbin/nologin)"

# ---------------------------------------------------------------------
# Crear usuario
#   $1 username  $2 password  $3 dias_validez  $4 limite_conexiones
# ---------------------------------------------------------------------
create_user() {
    local username="$1" password="$2" days="$3" limit="$4"

    if id "$username" &>/dev/null; then
        err "El usuario '$username' ya existe."
        return 1
    fi

    local expire_date
    expire_date=$(date -d "+${days} days" +%Y-%m-%d)

    useradd -m -s "$NOLOGIN_BIN" -G "$VPN_GROUP" -e "$expire_date" "$username"
    echo "${username}:${password}" | chpasswd

    # Guardamos el límite de conexiones simultáneas para este usuario
    echo "$limit" > "$LIMITS_DIR/${username}"

    # Registramos metadata en la DB simple del panel
    echo "${username}:${limit}:creado=$(date +%Y-%m-%d)" >> "$USERS_DB"

    ok "Usuario '$username' creado. Vence: $expire_date | Límite conexiones: $limit"
}

# ---------------------------------------------------------------------
# Crear usuario temporal (en horas)
# ---------------------------------------------------------------------
create_temp_user() {
    local username="$1" password="$2" hours="$3" limit="$4"

    if id "$username" &>/dev/null; then
        err "El usuario '$username' ya existe."
        return 1
    fi

    useradd -m -s "$NOLOGIN_BIN" -G "$VPN_GROUP" "$username"
    echo "${username}:${password}" | chpasswd
    echo "$limit" > "$LIMITS_DIR/${username}"
    echo "${username}:${limit}:temporal:creado=$(date +%Y-%m-%d_%H:%M)" >> "$USERS_DB"

    # Programamos su expiración exacta vía `at` (si no está, usamos systemd-run)
    if command -v at >/dev/null 2>&1; then
        echo "userdel -r '$username'" | at now + "${hours}" hours 2>/dev/null
    else
        systemd-run --on-active="${hours}h" --unit="expire-${username}" \
            /usr/sbin/userdel -r "$username" >/dev/null 2>&1
    fi

    ok "Usuario temporal '$username' creado, expira en ${hours}h. Límite: $limit"
}

# ---------------------------------------------------------------------
# Eliminar usuario
# ---------------------------------------------------------------------
delete_user() {
    local username="$1"
    if ! id "$username" &>/dev/null; then
        err "El usuario '$username' no existe."
        return 1
    fi
    userdel -r "$username" 2>/dev/null
    rm -f "$LIMITS_DIR/${username}"
    sed -i "/^${username}:/d" "$USERS_DB"
    ok "Usuario '$username' eliminado."
}

# ---------------------------------------------------------------------
# Renovar usuario (agrega N días a la fecha de vencimiento actual)
# ---------------------------------------------------------------------
renew_user() {
    local username="$1" days="$2"
    if ! id "$username" &>/dev/null; then
        err "El usuario '$username' no existe."
        return 1
    fi
    local new_date
    new_date=$(date -d "+${days} days" +%Y-%m-%d)
    chage -E "$new_date" "$username"
    ok "Usuario '$username' renovado. Nueva fecha de vencimiento: $new_date"
}

# ---------------------------------------------------------------------
# Bloquear / Desbloquear
# ---------------------------------------------------------------------
lock_user()   { passwd -l "$1" >/dev/null && ok "Usuario '$1' bloqueado."; }
unlock_user() { passwd -u "$1" >/dev/null && ok "Usuario '$1' desbloqueado."; }

# ---------------------------------------------------------------------
# Cambiar límite de conexiones simultáneas
# ---------------------------------------------------------------------
set_limit() {
    local username="$1" limit="$2"
    echo "$limit" > "$LIMITS_DIR/${username}"
    ok "Límite de conexiones de '$username' actualizado a $limit."
}

# ---------------------------------------------------------------------
# Listar usuarios con info de vencimiento
# ---------------------------------------------------------------------
list_users() {
    printf "%-18s %-12s %-10s %-8s\n" "USUARIO" "VENCE" "ESTADO" "LIMITE"
    echo "----------------------------------------------------------"
    while IFS=: read -r username _; do
        [[ -z "$username" ]] && continue
        id "$username" &>/dev/null || continue
        local exp
        exp=$(chage -l "$username" 2>/dev/null | grep "Account expires" | cut -d: -f2 | sed 's/^ *//')
        [[ -z "$exp" || "$exp" == "never" ]] && exp="sin límite"
        local status="activo"
        passwd -S "$username" 2>/dev/null | grep -q " L " && status="bloqueado"
        local limit
        limit=$(cat "$LIMITS_DIR/${username}" 2>/dev/null || echo "-")
        printf "%-18s %-12s %-10s %-8s\n" "$username" "$exp" "$status" "$limit"
    done < "$USERS_DB"
}

# ---------------------------------------------------------------------
# Eliminar usuarios vencidos (pensado para correr por cron)
# ---------------------------------------------------------------------
purge_expired_users() {
    local today_epoch
    today_epoch=$(date +%s)
    while IFS=: read -r username _; do
        [[ -z "$username" ]] && continue
        id "$username" &>/dev/null || continue
        local exp_epoch
        exp_epoch=$(chage -l "$username" 2>/dev/null | grep "Account expires" | cut -d: -f2 | sed 's/^ *//')
        [[ "$exp_epoch" == "never" || -z "$exp_epoch" ]] && continue
        exp_epoch=$(date -d "$exp_epoch" +%s 2>/dev/null) || continue
        if (( exp_epoch < today_epoch )); then
            msg "Usuario vencido detectado: $username -> eliminando"
            delete_user "$username"
        fi
    done < "$USERS_DB"
}

# ---------------------------------------------------------------------
# Monitor de conexiones activas por usuario (SSH/Dropbear)
# ---------------------------------------------------------------------
online_users() {
    printf "%-18s %-10s %-8s\n" "USUARIO" "CONEXIONES" "LIMITE"
    echo "-------------------------------------------"
    for f in "$LIMITS_DIR"/*; do
        [[ -e "$f" ]] || continue
        local username
        username=$(basename "$f")
        local count
        count=$(who | awk -v u="$username" '$1==u' | wc -l)
        local limit
        limit=$(cat "$f")
        printf "%-18s %-10s %-8s\n" "$username" "$count" "$limit"
    done
}

# ---------------------------------------------------------------------
# Aplicación de límite de conexiones en vivo (para correr por cron
# cada minuto): si un usuario supera su límite, mata las sesiones más
# nuevas hasta volver al límite permitido.
# ---------------------------------------------------------------------
enforce_limits() {
    for f in "$LIMITS_DIR"/*; do
        [[ -e "$f" ]] || continue
        local username limit sessions count excess
        username=$(basename "$f")
        limit=$(cat "$f")
        [[ "$limit" -le 0 ]] && continue 2>/dev/null
        mapfile -t sessions < <(who | awk -v u="$username" '$1==u {print $2}')
        count=${#sessions[@]}
        if (( count > limit )); then
            excess=$(( count - limit ))
            warn "Usuario '$username' excede su límite ($count/$limit). Cerrando $excess sesión(es)."
            for ((i=0; i<excess; i++)); do
                pkill -KILL -t "${sessions[$i]}" 2>/dev/null
            done
        fi
    done
}

# --- CLI directa del módulo (permite llamarlo desde cron o el menú) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    init_dirs
    case "$1" in
        create)       create_user "$2" "$3" "$4" "$5" ;;
        create_temp)  create_temp_user "$2" "$3" "$4" "$5" ;;
        delete)       delete_user "$2" ;;
        renew)        renew_user "$2" "$3" ;;
        lock)         lock_user "$2" ;;
        unlock)       unlock_user "$2" ;;
        set_limit)    set_limit "$2" "$3" ;;
        list)         list_users ;;
        online)       online_users ;;
        purge)        purge_expired_users ;;
        enforce)      enforce_limits ;;
        *) echo "Uso: $0 {create|create_temp|delete|renew|lock|unlock|set_limit|list|online|purge|enforce} [args]" ;;
    esac
fi
