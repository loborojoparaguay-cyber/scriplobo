#!/bin/bash
# =====================================================================
# modules/proto_nginx.sh - Sitio "señuelo" (decoy) para camuflar Xray
#
# Nginx corre SOLO en 127.0.0.1 (nunca expuesto a internet directamente)
# sirviendo una página web normal. Xray escucha en el puerto público
# (443) y usa su mecanismo nativo de "fallback": si la conexión TLS
# no trae credenciales VLESS válidas (un escáner, un sistema de censura
# inspeccionando, un curioso), Xray reenvía esa conexión a Nginx, que
# responde con un sitio real -- indistinguible de un servidor HTTPS
# normal. Solo los clientes con la config VLESS correcta llegan al
# túnel real.
#
# Referencia del mecanismo: XTLS/Xray-core "fallbacks" (proyecto
# oficial, https://github.com/XTLS/Xray-core).
# =====================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DECOY_ROOT="/var/www/decoy"
DECOY_SITE_CONF="/etc/nginx/sites-available/decoy"
DECOY_SITE_LINK="/etc/nginx/sites-enabled/decoy"
DECOY_PORT_DEFAULT=8080

install_decoy_site() {
    local port="${1:-$DECOY_PORT_DEFAULT}"

    apt_install nginx

    mkdir -p "$DECOY_ROOT"
    cat > "$DECOY_ROOT/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<title>Servicio en mantenimiento</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: -apple-system, Arial, sans-serif; background:#f5f7fa; color:#2c3e50;
         display:flex; align-items:center; justify-content:center; height:100vh; margin:0; }
  .box { text-align:center; padding:40px; }
  h1 { font-size:1.6rem; margin-bottom:.5rem; }
  p  { color:#7f8c8d; }
</style>
</head>
<body>
  <div class="box">
    <h1>Servicio temporalmente en mantenimiento</h1>
    <p>Estamos realizando tareas de actualización. Vuelve a intentarlo más tarde.</p>
  </div>
</body>
</html>
EOF

    # Nginx SOLO escucha en localhost -- nunca se expone directamente
    # a internet. El puerto público real lo maneja Xray (TLS), que
    # reenvía aquí únicamente cuando la conexión NO es un túnel válido.
    cat > "$DECOY_SITE_CONF" <<EOF
server {
    listen 127.0.0.1:${port};
    server_name _;
    root ${DECOY_ROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    rm -f /etc/nginx/sites-enabled/default
    ln -sf "$DECOY_SITE_CONF" "$DECOY_SITE_LINK"

    nginx -t || { err "La configuración de Nginx tiene errores. Revisa ${DECOY_SITE_CONF}."; return 1; }
    systemctl enable --now nginx
    systemctl reload nginx

    echo "$port" > "$PANEL_DATA/decoy_port"
    ok "Sitio señuelo activo en 127.0.0.1:${port} (no accesible directamente desde internet)."
    warn "Falta vincularlo a Xray: usa 'Vincular sitio señuelo a Xray (fallback)' en el menú de protocolos."
}

decoy_status() {
    systemctl status nginx --no-pager 2>/dev/null || echo "Nginx no está instalado."
    echo
    if [[ -f "$PANEL_DATA/decoy_port" ]]; then
        msg "Puerto interno del señuelo: $(cat "$PANEL_DATA/decoy_port")"
        curl -s -o /dev/null -w "Respuesta local del señuelo: HTTP %{http_code}\n" \
            "http://127.0.0.1:$(cat "$PANEL_DATA/decoy_port")/" 2>/dev/null
    fi
}

uninstall_decoy_site() {
    systemctl disable --now nginx 2>/dev/null
    rm -f "$DECOY_SITE_CONF" "$DECOY_SITE_LINK" "$PANEL_DATA/decoy_port"
    ok "Sitio señuelo desinstalado."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root; require_debian; init_dirs
    case "$1" in
        install)    install_decoy_site "$2" ;;
        status)     decoy_status ;;
        uninstall)  uninstall_decoy_site ;;
        *) echo "Uso: $0 {install <puerto_interno>|status|uninstall}" ;;
    esac
fi
