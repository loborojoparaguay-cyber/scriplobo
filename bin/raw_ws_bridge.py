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
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def _read_initial_request(reader: asyncio.StreamReader) -> bytes:
    """Lee y descarta el handshake HTTP inicial (headers hasta la
    linea vacia). No valida su contenido a proposito: el cliente solo
    necesita que la conexion "parezca" HTTP, no cumplir RFC 6455."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = await reader.read(4096)
        if not chunk:
            break
        buf += chunk
        if len(buf) > 65536:  # limite de seguridad ante clientes maliciosos
            break
    return buf


async def handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    backend_host: str,
    backend_port: int,
) -> None:
    peer = client_writer.get_extra_info("peername")
    try:
        await _read_initial_request(client_reader)
        client_writer.write(HANDSHAKE_RESPONSE)
        await client_writer.drain()

        backend_reader, backend_writer = await asyncio.open_connection(
            backend_host, backend_port
        )
        log.info("%s -> conectado, reenviando a %s:%s", peer, backend_host, backend_port)

        await asyncio.gather(
            _pipe(client_reader, backend_writer),
            _pipe(backend_reader, client_writer),
        )
    except Exception as exc:  # noqa: BLE001 - queremos loguear cualquier fallo y seguir
        log.warning("%s -> error: %s", peer, exc)
    finally:
        try:
            client_writer.close()
        except Exception:
            pass
        log.info("%s -> conexion cerrada", peer)


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
