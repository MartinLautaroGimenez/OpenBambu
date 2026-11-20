"""Conexión LAN a impresoras Bambu Lab (MQTT + cámara TCP).

Requisitos en la impresora (A1/P1):
  * Modo "Solo LAN" activado
  * Modo Desarrollador activado (firmware con "Authorization Control")
  * Código de acceso (Ajustes > WLAN en la pantalla)
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import secrets
import ssl
import struct
from collections.abc import AsyncIterator

import aiomqtt

from .base import BasePrinter
from .commands import pushall

log = logging.getLogger(__name__)

MQTT_PORT = 8883
CAMERA_PORT = 6000
USERNAME = "bblp"
PUSHALL_INTERVAL = 300  # segundos; la A1 no necesita pushall frecuentes


def insecure_tls() -> ssl.SSLContext:
    # La impresora usa un certificado firmado por la CA propia de Bambu.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


class LanPrinter(BasePrinter):
    def __init__(self, cfg):
        super().__init__(cfg)
        self._client: aiomqtt.Client | None = None
        self._pending: dict[str, asyncio.Future] = {}

    @property
    def report_topic(self) -> str:
        return f"device/{self.cfg.serial}/report"

    @property
    def request_topic(self) -> str:
        return f"device/{self.cfg.serial}/request"

    async def _run(self) -> None:
        backoff = 2.0
        while True:
            try:
                async with aiomqtt.Client(
                    self.cfg.host,
                    MQTT_PORT,
                    username=USERNAME,
                    password=self.cfg.access_code,
                    identifier=f"openbambu-{secrets.token_hex(4)}",
                    tls_context=insecure_tls(),
                    tls_insecure=True,
                    keepalive=30,
                    timeout=10,
                ) as client:
                    self._client = client
                    await client.subscribe(self.report_topic)
                    log.info("Conectado a %s (%s)", self.cfg.name, self.cfg.host)
                    self.state.connected = True
                    backoff = 2.0
                    refresher = asyncio.create_task(self._periodic_pushall())
                    try:
                        async for msg in client.messages:
                            self._handle(msg.payload)
                    finally:
                        refresher.cancel()
            except asyncio.CancelledError:
                raise
            except aiomqtt.MqttError as e:
                log.warning("MQTT %s: %s (reintento en %.0fs)", self.cfg.name, e, backoff)
            except Exception:  # noqa: BLE001
                log.exception("Error inesperado en conexión MQTT")
            self._client = None
            if self.state.connected:
                self.state.connected = False
                self._emit()
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 60)

    async def _periodic_pushall(self) -> None:
        while True:
            with contextlib.suppress(Exception):
                await self.send(pushall(), wait=False)
            await asyncio.sleep(PUSHALL_INTERVAL)

    def _handle(self, payload: bytes | bytearray | str) -> None:
        try:
            data = json.loads(payload)
        except (ValueError, TypeError):
            return
        if not isinstance(data, dict):
            return
        # Respuestas a comandos: resolver futures pendientes
        for section in data.values():
            if (
                isinstance(section, dict)
                and section.get("command") not in (None, "push_status")
                and (seq := str(section.get("sequence_id"))) in self._pending
            ):
                fut = self._pending.pop(seq)
                if not fut.done():
                    fut.set_result(section.get("result", "success"))
        if "print" in data:
            # No guardar en el estado campos propios de respuestas a comandos
            report = {k: v for k, v in data["print"].items() if k not in ("command", "result", "reason", "sequence_id", "param")}
            self.state.apply({"print": report})
            self._emit()

    async def send(self, payload: dict, wait: bool = True) -> dict:
        if not self._client:
            raise ConnectionError("La impresora no está conectada")
        seq = self.next_seq()
        for section in payload.values():
            section["sequence_id"] = seq
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        if wait:
            self._pending[seq] = fut
        await self._client.publish(self.request_topic, json.dumps(payload))
        if not wait:
            return {"result": "sent"}
        try:
            result = await asyncio.wait_for(fut, 5)
        except asyncio.TimeoutError:
            result = "sent"  # muchos comandos (ej. gcode_line) no siempre responden
        finally:
            self._pending.pop(seq, None)
        return {"result": str(result).lower()}

    async def camera_frames(self) -> AsyncIterator[bytes]:
        """Protocolo de cámara de A1/P1: TLS en el puerto 6000, frames JPEG."""
        if self.caps.camera != "tcp_jpeg":
            raise RuntimeError("La cámara RTSP de la serie X1 todavía no está soportada")
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(self.cfg.host, CAMERA_PORT, ssl=insecure_tls()), 10
        )
        try:
            auth = struct.pack("<IIII", 0x40, 0x3000, 0, 0)
            auth += USERNAME.encode().ljust(32, b"\x00")
            auth += self.cfg.access_code.encode().ljust(32, b"\x00")
            writer.write(auth)
            await writer.drain()
            while True:
                header = await asyncio.wait_for(reader.readexactly(16), 15)
                size = struct.unpack("<I", header[0:4])[0]
                if not 0 < size < 5_000_000:
                    raise RuntimeError(f"Tamaño de frame inválido: {size}")
                jpg = await asyncio.wait_for(reader.readexactly(size), 15)
                if jpg[:2] == b"\xff\xd8" and jpg[-2:] == b"\xff\xd9":
                    yield jpg
        finally:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
