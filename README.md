# VPS Panel

Panel propio de administración de VPS para un servicio de VPN/proxy
multi-protocolo orientado a clientes que pagan por un acceso seguro
y de buena latencia. Construido desde cero con herramientas estándar,
auditables y de código abierto — sin componentes de origen desconocido.

## Protocolos incluidos

| Protocolo | Puerto por defecto | Notas |
|---|---|---|
| OpenSSH | 22 | Hardening aplicado (sin root por password, forwarding controlado) |
| Dropbear | 442 | SSH liviano, con banner configurable |
| Stunnel (TLS) | 443 | Envuelve SSH/Dropbear en TLS real |
| WireGuard | 51820/udp | VPN moderna recomendada (Curve25519/ChaCha20) |
| Xray (VLESS+TLS) | 443 | Tráfico camuflado como HTTPS, requiere dominio + certificado real |
| OpenVPN | 1194/udp | PKI propia por cliente (easy-rsa), cifrado AES-256-GCM |
| Hysteria 2 | 443/udp | QUIC + TLS 1.3, control de congestión Brutal — mejor "ping" en redes con pérdida/latencia alta |
| BadVPN UDPGW | 7300 (interno, 127.0.0.1) | Relay de UDP *dentro* del túnel SSH/Dropbear — habilita juegos/VoIP sobre SOCKS |
| WebSocket->SSH | 8880/tcp (o 443/tcp si se cifra con Stunnel) | Puente liviano WS/WSS hacia SSH/Dropbear, sin la capa extra de parsing VLESS de Xray — ideal para celulares de gama baja |

Protocolos deliberadamente **excluidos** por no ser estándares
auditables o no aportar valor real: Squid como "túnel" (es solo un
proxy HTTP, sin cifrado), "UDP-Custom"/"SSHGo" (scripts caseros sin
documentación pública verificable).

### TLS 1.3 forzado como mínimo en todos los protocolos que usan TLS

TLS 1.3 (RFC 8446) reduce el handshake a 1 solo intercambio (vs 2 en
TLS 1.2), elimina del protocolo los cifrados débiles/legacy en lugar
de depender de que el administrador los deshabilite manualmente, y
exige forward secrecy en toda conexión. El panel fuerza esta versión
como mínima en cada protocolo que la soporta:

| Protocolo | Cómo se fuerza | Nota |
|---|---|---|
| Xray (VLESS+TLS) | `"minVersion": "1.3"` en `tlsSettings` | Clientes con solo TLS 1.2 o menor son rechazados |
| Stunnel | `sslVersionMin = TLSv1.3` | Igual |
| OpenVPN | `tls-version-min 1.3` (server y cliente) | Requiere OpenVPN 2.4.6+/OpenSSL 1.1.1+ (Ubuntu 22.04/24.04 cumplen) |
| Hysteria 2 | No requiere configuración | QUIC exige TLS 1.3 por especificación del protocolo, no existe modo TLS 1.2 sobre QUIC |
| SSH/Dropbear | No aplica | SSH no usa TLS, usa su propio protocolo de cifrado (independiente de SSL/TLS) |

### Camuflaje de Xray con sitio señuelo (Nginx + fallback)

Para que las conexiones VLESS+TLS sean lo más indistinguibles posible
de un sitio HTTPS normal, el panel puede instalar un **sitio señuelo**
con Nginx y vincularlo a Xray usando su mecanismo nativo de
`fallbacks` (documentado en el proyecto oficial
[XTLS/Xray-core](https://github.com/XTLS/Xray-core)):

- Nginx escucha **solo en `127.0.0.1`** (nunca expuesto directamente
  a internet) y sirve una página web real.
- Xray escucha en el puerto público (443/tcp) con TLS real.
- Si una conexión entrante **no** completa el handshake VLESS válido
  (un escáner, un sistema de inspección de tráfico, alguien
  investigando el dominio), Xray la reenvía automáticamente al sitio
  señuelo — quien la mira desde afuera solo ve un sitio web normal.
- Solo los clientes con la configuración VLESS/UUID correcta llegan
  al túnel real.

Orden de instalación: primero Xray (opción 9), luego el sitio señuelo
(opción 24), y por último vincularlo (opción 25) usando el mismo
puerto interno en ambos pasos (por defecto 8080).

### WebSocket->SSH liviano (alternativa a Xray para hardware limitado)

Xray (VLESS+TLS) agrega dos o tres capas de cifrado/parsing superpuestas
(TLS 1.3 + protocolo VLESS + a veces SSH adentro), lo cual puede notarse
en CPUs muy limitadas (celulares viejos/gama baja). Como alternativa
más liviana, `modules/proto_wsssh.sh` usa
[websockify](https://github.com/novnc/websockify) (LGPL, paquete
oficial de Ubuntu/Debian) para traducir WebSocket <-> TCP crudo,
reenviando directo al puerto de SSH/Dropbear -- sin agregar cifrado
propio. La única capa de cifrado real es la de SSH mismo.

- **Modo `ws://` (sin TLS):** el más liviano posible. El handshake
  WebSocket inicial no va cifrado, pero el contenido SSH que viaja
  adentro sí lo está (por SSH mismo).
- **Modo `wss://` (con TLS 1.3):** se vincula a Stunnel (opción 28 del
  menú) para cifrar también el handshake. Sigue siendo más liviano que
  Xray porque no hay parsing de VLESS de por medio -- solo TLS + SSH,
  en vez de TLS + VLESS + SSH.

### Sobre BadVPN/UDPGW (corrección importante)

En una primera versión de este panel se excluyó BadVPN por error,
asumiendo que "no tener cifrado propio" era una debilidad. Esa lectura
estaba mal: BadVPN **no es un túnel independiente**, es un relay que
vive dentro de un túnel SSH/Dropbear ya cifrado — el tráfico UDP del
cliente (juegos, VoIP) llega primero por SSH y luego `badvpn-udpgw`
solo lo reenvía a su destino real en internet. Por eso escucha
únicamente en `127.0.0.1` y **nunca debe exponerse directamente a
internet** en el firewall — su seguridad depende por completo del
túnel SSH/Dropbear que ya lo protege. Se compila desde el código
fuente oficial de [ambrop72/badvpn](https://github.com/ambrop72/badvpn).

### Sobre Hysteria 2 y por qué mejora el ping

Hysteria 2 corre sobre QUIC (UDP) en vez de TCP, evitando el
overhead de "handshake" y retransmisión de TCP. Usa un control de
congestión propio (Brutal) pensado específicamente para redes con
alta latencia o pérdida de paquetes — por eso suele sentirse "más
rápido" que WireGuard/OpenVPN en conexiones móviles inestables,
aunque WireGuard sigue siendo la opción más liviana en CPU para
conexiones estables. Fuente: proyecto oficial
[apernet/hysteria](https://github.com/apernet/hysteria) (Apache 2.0).

Los usuarios de Hysteria se administran por separado con
`add_hy_user`/`remove_hy_user` (usa el mismo usuario/contraseña que
el resto del panel, pero requiere habilitarlo explícitamente porque
Hysteria necesita la contraseña en texto claro para autenticar, a
diferencia de SSH/Dropbear que solo guardan el hash del sistema).

## Estructura

```
vps-panel/
├── panel.sh              # Menú principal interactivo
├── install.sh            # Instalador maestro
├── lib/common.sh         # Funciones y variables compartidas
└── modules/
    ├── users.sh          # Gestión de usuarios (alta/baja/renovación/límites)
    ├── proto_ssh.sh       # OpenSSH + Dropbear
    ├── proto_stunnel.sh   # Stunnel (TLS)
    ├── proto_wireguard.sh # WireGuard + gestión de peers
    ├── proto_xray.sh      # Xray VLESS+TLS + gestión de clientes
    ├── proto_openvpn.sh   # OpenVPN + easy-rsa
    ├── proto_hysteria.sh   # Hysteria 2 (QUIC/UDP) + sync de usuarios
    ├── proto_badvpn.sh     # BadVPN UDPGW (relay UDP interno para SSH/Dropbear)
    ├── proto_nginx.sh      # Sitio senuelo (Nginx) para camuflar Xray
    ├── proto_wsssh.sh      # WebSocket->SSH liviano (websockify), alternativa a Xray
    ├── ssl.sh             # Certificados Let's Encrypt (acme.sh)
    ├── hardening.sh       # ufw + fail2ban
    └── monitor.sh         # Info de sistema y conexiones activas
```

## Instalación

```bash
sudo ./install.sh
sudo vps-panel
```

Esto instala el panel en `/opt/vps-panel`, crea el comando global
`vps-panel`, prepara `/etc/vps-panel` (datos, banner, logs) y registra
dos tareas de cron:
- Cada minuto: aplica el límite de conexiones simultáneas por usuario.
- Cada hora: elimina automáticamente usuarios vencidos.

## Orden recomendado de configuración

1. **Firewall**: `Seguridad > Instalar firewall (ufw)`
2. **Fail2ban**: `Seguridad > Instalar Fail2ban`
3. **SSH/Dropbear**: `Protocolos > Instalar SSH` y `Instalar Dropbear`
4. **Certificado real** (si tienes un dominio apuntando al servidor):
   `Seguridad > Emitir certificado SSL real`
5. **Stunnel** con el certificado real, o **Xray** (VLESS+TLS) para
   máxima resistencia a inspección de tráfico.
6. **WireGuard** como VPN principal recomendada para los clientes.
7. **Hysteria 2** como opción premium de baja latencia (requiere el
   mismo dominio/certificado que Xray/Stunnel).
8. Crear usuarios/clientes desde los menús correspondientes.

## Requisito de sistema para el módulo de licencias

El sistema de licencias usa Ed25519 vía `openssl pkeyutl -rawin`, disponible
solo desde **OpenSSL 3.0+**. Usa **Ubuntu 22.04 o 24.04** (Ubuntu 20.04 trae
OpenSSL 1.1.1 y el módulo de licencias no funcionará). Verifica con:
```bash
openssl version
```

## Máquina de pruebas (recomendado antes de tocar tu servidor real)

Levanta un VPS/VM desechable (Oracle Cloud Free Tier, Contabo, Vultr,
DigitalOcean — el más barato) con Ubuntu 22.04/24.04, y clona el repo ahí:

```bash
sudo apt update && sudo apt upgrade -y
git clone https://github.com/TU_USUARIO/vps-panel.git
cd vps-panel
sudo touch /etc/vps-panel/trial_mode   # antes de instalar, o después: crea la carpeta primero
sudo mkdir -p /etc/vps-panel && sudo touch /etc/vps-panel/trial_mode
sudo ./install.sh
sudo vps-panel
```

El archivo `/etc/vps-panel/trial_mode` desactiva la verificación de licencia
solo en esa máquina — así prueba todo libremente sin generarte una licencia.
**Bórralo antes de vender/entregar el servidor a un cliente real.**

## Sistema de licencias (para vender el servicio a terceros)

El repositorio es público, así que una contraseña fija no protege nada —
en su lugar se usa una **licencia firmada con Ed25519**, ligada a la huella
de hardware del servidor del cliente y con fecha de vencimiento.

- La clave **privada** (`admin-tools/keys/license_private.pem`) la generas
  una sola vez, en tu máquina personal, y **nunca se sube al repo**
  (ya está en `.gitignore`).
- La clave **pública** (`config/license_public.pem`) sí va en el repo —
  con ella solo se puede verificar, no falsificar, una licencia.

Flujo para vender una licencia:
```bash
# 1. Una sola vez, en TU máquina:
./admin-tools/keygen.sh
cp admin-tools/keys/license_public.pem config/license_public.pem
git add config/license_public.pem && git commit -m "clave pública de licencias"

# 2. El cliente, en SU servidor, obtiene su huella:
sudo ./modules/license.sh machine_id
# (te pasa ese ID, por ejemplo por chat, junto con el pago)

# 3. Tú generas su licencia:
./admin-tools/issue_license.sh <server_id_del_cliente> "nombre_cliente" 30 10
# genera admin-tools/issued/nombre_cliente_<uuid>.lic

# 4. Le envías ese .lic al cliente, y él lo coloca en su servidor:
sudo cp nombre_cliente_xxxx.lic /etc/vps-panel/license.lic
sudo vps-panel   # ya arranca con licencia válida
```

Si el cliente copia el `.lic` a otro servidor, la huella no coincide y el
panel no arranca. Si quieres poder revocar licencias ya emitidas de forma
remota, define `VPSPANEL_REVOKED_URL` apuntando a un JSON con IDs revocados
que tú controles (opcional, no requerido para empezar).

## Notas de seguridad

- Todas las cuentas de sistema usan `nologin` como shell — solo sirven
  para autenticar túneles, no dan acceso a una terminal real.
- Los certificados TLS reales (Let's Encrypt) requieren que tengas un
  **dominio propio** apuntando por DNS a la IP del servidor.
- Revisa y ajusta los puertos abiertos en el firewall según qué
  protocolos actives realmente (no dejes puertos abiertos sin uso).
