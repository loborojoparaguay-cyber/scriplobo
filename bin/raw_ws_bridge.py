#!/usr/bin/env python3
# =====================================================================
# raw_ws_bridge.py - Bridge "WebSocket" crudo para apps tipo
# HTTP Custom / HTTP Injector / NPV Tunnel.
#
# Por que existe este script en vez de usar websockify:
#
# websockify implementa el protocolo WebSocket real (RFC 6455): tras el
# handshake, envuelve cada paquete en un frame binario con su propia
# cabecera. Eso es correcto para un navegador real, pero estas apps de
# Android NO hablan WebSocket de verdad -- solo envian el handshake
# HTTP inicial (para que luzca como trafico HTTP normal) y despues
# esperan que los bytes viajen CRUDOS, sin ningun framing adicional,
# igual que un simple tunel HTTP CONNECT.
#
# Con websockify, sshd recibe los bytes envueltos en frames WebSocket
# en vez del banner SSH limpio -> "kex_exchange_identification" y la
# conexion se cae. Este script evita el problema por completo: nunca
# genera frames, solo hace de "traductor" del primer request HTTP y
# despues copia bytes en ambas direcciones sin tocarlos.
#
# Es intencionalmente laxo con el handshake (no exige headers como
# Sec-WebSocket-Key/Version) porque el unico objetivo es que la
# primera linea de la conexion "parezca" HTTP para pasar por
# firewalls/proxies que inspeccionan trafico -- no se implementa el
# protocolo WebSocket real.
# =====================================================================
import argparse
import asyncio
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("raw_ws_bridge")

HANDSHAKE_RESPONSE = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Connection: Upgrade\r\n"
    b"Upgrade: websocket\r\n"
    b"\r\n"
)


async def _pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """Copia bytes de reader a writer hasta que un lado cierre. NO
    cierra 'writer' al terminar -- eso lo decide handle_client cuando
    AMBOS sentidos terminaron, para no cortar a mitad de camino el
    sentido contrario si un lado hace una pausa breve (ej. durante el
    intercambio de llaves SSH, que va en varias rondas separadas)."""
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        pass


async def _read_initial_request(reader: asyncio.StreamReader) -> bytes:
    """Lee y descarta SOLO el handshake HTTP inicial (headers hasta la
    linea vacia \r\n\r\n). No valida su contenido a proposito: el
    cliente solo necesita que la conexion "parezca" HTTP, no cumplir
    RFC 6455.

    IMPORTANTE: algunos clientes (ej. HTTP Custom) mandan el handshake
    y el primer paquete SSH pegados en un solo TCP write, sin esperar
    la respuesta 101. Si eso pasa, el buffer que llega aqui contiene
    el handshake + bytes de SSH juntos. Debemos devolver esos bytes
    "extra" (lo que vino despues del separador) para que el llamador
    los reenvie al backend -- si los descartamos, se pierde el inicio
    de la negociacion SSH y la conexion se cae en el intercambio de
    llaves (bug real detectado y reproducido en pruebas)."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = await reader.read(4096)
        if not chunk:
            break
        buf += chunk
        if len(buf) > 65536:  # limite de seguridad ante clientes maliciosos
            break
    _headers, _, extra = buf.partition(b"\r\n\r\n")
    return extra


async def handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    backend_host: str,
    backend_port: int,
) -> None:
    peer = client_writer.get_extra_info("peername")
    try:
        leftover = await _read_initial_request(client_reader)
        client_writer.write(HANDSHAKE_RESPONSE)
        await client_writer.drain()

        backend_reader, backend_writer = await asyncio.open_connection(
            backend_host, backend_port
        )
        _disable_nagle(client_writer)
        _disable_nagle(backend_writer)
        log.info("%s -> conectado, reenviando a %s:%s", peer, backend_host, backend_port)

        if leftover:
            # Bytes de SSH que llegaron pegados al handshake HTTP en el
            # mismo TCP write del cliente -- deben ir al backend antes
            # de arrancar el copiado normal en ambas direcciones.
            backend_writer.write(leftover)
            await backend_writer.drain()

        # Ambos sentidos corren en paralelo; solo cerramos los sockets
        # cuando LOS DOS terminaron (ver comentario en _pipe). Cerrar
        # uno apenas termina su lado cortaba el sentido contrario a
        # mitad del intercambio de llaves SSH (bug real detectado).
        await asyncio.gather(
            _pipe(client_reader, backend_writer),
            _pipe(backend_reader, client_writer),
        )
    except Exception as exc:  # noqa: BLE001 - queremos loguear cualquier fallo y seguir
        log.warning("%s -> error: %s", peer, exc)
    finally:
        for w in (client_writer, locals().get("backend_writer")):
            if w is None:
                continue
            try:
                w.close()
            except Exception:
                pass
        log.info("%s -> conexion cerrada", peer)


def _disable_nagle(writer: asyncio.StreamWriter) -> None:
    """Desactiva el algoritmo de Nagle (TCP_NODELAY) para evitar que el
    kernel retrase el envio de paquetes pequenos como los del
    intercambio de llaves SSH esperando poder juntarlos con mas datos."""
    import socket

    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("listen_port", type=int, help="Puerto publico donde escucha el bridge")
    parser.add_argument(
        "backend", help="Backend en formato host:puerto (ej. 127.0.0.1:22)"
    )
    args = parser.parse_args()

    backend_host, backend_port_str = args.backend.rsplit(":", 1)
    backend_port = int(backend_port_str)

    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, backend_host, backend_port),
        host="0.0.0.0",
        port=args.listen_port,
    )
    log.info("Escuchando en 0.0.0.0:%s -> %s:%s", args.listen_port, backend_host, backend_port)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
