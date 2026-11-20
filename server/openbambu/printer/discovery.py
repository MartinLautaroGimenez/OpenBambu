"""Descubrimiento de impresoras Bambu Lab en la red local (SSDP).

Las impresoras anuncian periódicamente su IP, número de serie y modelo con
mensajes SSDP ``NOTIFY`` (multicast 239.255.255.250:1990 y broadcast al
puerto 2021, que es lo que escucha Bambu Studio). Requiere que el contenedor
use ``network_mode: host``.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import socket
import struct
import time

log = logging.getLogger(__name__)

SSDP_GROUP = "239.255.255.250"
PORTS = (2021, 1990)
SEARCH = (
    "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nMAN: \"ssdp:discover\"\r\n"
    "MX: 3\r\nST: urn:bambulab-com:device:3dprinter:1\r\n\r\n"
).encode()

# Código de modelo (DevModel.bambu.com) → modelo de OpenBambu
MODEL_CODES = {
    "N2S": "A1",
    "N1": "A1MINI",
    "C11": "P1P",
    "C12": "P1S",
    "BL-P001": "X1C",
    "BL-P002": "X1C",
    "C13": "X1E",
}
TTL = 120  # segundos que se recuerda una impresora sin anuncios nuevos


def parse_notify(data: bytes, sender_ip: str) -> dict | None:
    try:
        text = data.decode("utf-8", "replace")
    except Exception:  # noqa: BLE001
        return None
    if "bambulab" not in text.lower():
        return None
    headers = {}
    for line in text.split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    serial = headers.get("usn", "").split("::")[0].replace("uuid:", "").strip()
    if not serial:
        return None
    code = headers.get("devmodel.bambu.com", "")
    return {
        "serial": serial,
        "host": headers.get("location", "").replace("http://", "").split("/")[0] or sender_ip,
        "name": headers.get("devname.bambu.com") or serial,
        "model_code": code,
        "model": MODEL_CODES.get(code),
        "connection": headers.get("devconnect.bambu.com"),  # "lan" o "cloud"
        "signal": headers.get("devsignal.bambu.com"),
        "seen": time.time(),
    }


class _Proto(asyncio.DatagramProtocol):
    def __init__(self, owner: Discovery):
        self.owner = owner

    def datagram_received(self, data: bytes, addr) -> None:
        if found := parse_notify(data, addr[0]):
            self.owner.found[found["serial"]] = found


class Discovery:
    def __init__(self):
        self.found: dict[str, dict] = {}
        self._transports: list[asyncio.DatagramTransport] = []
        self.error: str | None = None

    async def start(self) -> None:
        loop = asyncio.get_running_loop()
        for port in PORTS:
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                with contextlib.suppress(AttributeError, OSError):
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                sock.bind(("", port))
                with contextlib.suppress(OSError):
                    mreq = struct.pack("4sl", socket.inet_aton(SSDP_GROUP), socket.INADDR_ANY)
                    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
                transport, _ = await loop.create_datagram_endpoint(lambda: _Proto(self), sock=sock)
                self._transports.append(transport)
            except OSError as e:
                self.error = f"No se pudo escuchar el puerto {port}: {e}"
                log.warning("Descubrimiento: %s", self.error)

    def search(self) -> None:
        """Pide a las impresoras que se anuncien (además de sus anuncios periódicos)."""
        for t in self._transports:
            with contextlib.suppress(OSError):
                t.sendto(SEARCH, (SSDP_GROUP, 1990))
                t.sendto(SEARCH, ("255.255.255.255", 2021))

    def printers(self) -> list[dict]:
        now = time.time()
        for k in [k for k, v in self.found.items() if now - v["seen"] > TTL]:
            del self.found[k]
        return sorted(self.found.values(), key=lambda x: x["name"])

    async def stop(self) -> None:
        for t in self._transports:
            t.close()
        self._transports.clear()


async def test_connection(host: str, serial: str, access_code: str, timeout: float = 12) -> dict:
    """Prueba MQTT contra la impresora: credenciales y que responda con su estado."""
    import json
    import secrets

    import aiomqtt

    from .lan import MQTT_PORT, USERNAME, insecure_tls

    try:
        async with asyncio.timeout(timeout):
            async with aiomqtt.Client(host, MQTT_PORT, username=USERNAME, password=access_code,
                                      identifier=f"openbambu-test-{secrets.token_hex(3)}",
                                      tls_context=insecure_tls(), tls_insecure=True, timeout=8) as c:
                await c.subscribe(f"device/{serial}/report")
                await c.publish(f"device/{serial}/request",
                                json.dumps({"pushing": {"command": "pushall", "sequence_id": "1"}}))
                async for msg in c.messages:
                    data = json.loads(msg.payload)
                    p = data.get("print", {})
                    return {"ok": True, "state": p.get("gcode_state"),
                            "message": "Conexión correcta: la impresora respondió"}
    except TimeoutError:
        return {"ok": False, "message": "La impresora no respondió. Revisá la IP y el número de serie "
                                        "(si es incorrecto la conexión funciona pero no llegan datos)."}
    except aiomqtt.MqttError as e:
        text = str(e).lower()
        if "not authorized" in text or "bad user name or password" in text or "code:5" in text:
            msg = "Código de acceso incorrecto"
        elif "refused" in text or "timed out" in text or "unreachable" in text:
            msg = "No se pudo conectar: revisá la IP y que el modo LAN esté activo"
        else:
            msg = f"Error de conexión: {e}"
        return {"ok": False, "message": msg}
    except OSError as e:
        return {"ok": False, "message": f"No se pudo conectar: {e}"}
    return {"ok": False, "message": "Sin respuesta"}
