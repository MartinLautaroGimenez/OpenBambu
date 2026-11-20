"""Notificaciones push vía ntfy (https://ntfy.sh o servidor propio).

Sirve para recibir alertas aunque el teléfono esté fuera de la red de casa o
la app esté cerrada. Se instala la app ntfy y se suscribe al topic configurado.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable

import httpx

from ..config import NtfyConfig
from .events import Event

log = logging.getLogger(__name__)

PRIORITY = {"error": "urgent", "warning": "high", "success": "default", "info": "low"}
TAGS = {
    "print_started": "arrow_forward",
    "print_paused": "pause_button",
    "print_resumed": "arrow_forward",
    "print_finished": "white_check_mark",
    "print_cancelled": "stop_button",
    "print_failed": "x",
    "first_layer": "mag",
    "progress": "hourglass_flowing_sand",
    "filament_runout": "warning",
    "hms": "rotating_light",
    "offline": "electric_plug",
}

SnapshotFn = Callable[[str], Awaitable[bytes | None]]


class NtfyNotifier:
    def __init__(self, cfg: NtfyConfig, snapshot: SnapshotFn | None = None):
        self.cfg = cfg
        self.snapshot = snapshot
        self.client = httpx.AsyncClient(timeout=15)

    async def __call__(self, ev: Event) -> None:
        if not (self.cfg.enabled and self.cfg.topic):
            return
        url = f"{self.cfg.url.rstrip('/')}/{self.cfg.topic}"
        headers = {
            "Title": f"{ev.printer_name}: {ev.title}",
            "Priority": PRIORITY.get(ev.severity, "default"),
            "Tags": TAGS.get(ev.type, "printer"),
        }
        if self.cfg.token:
            headers["Authorization"] = f"Bearer {self.cfg.token}"
        try:
            jpg = await self.snapshot(ev.printer_id) if ev.snapshot and self.snapshot else None
            if jpg:
                # Con adjunto: el mensaje va en un header (codificado RFC 2047)
                headers["Message"] = ev.message
                headers["Filename"] = "camara.jpg"
                headers = {k: _rfc2047(v) for k, v in headers.items()}
                r = await self.client.put(url, content=jpg, headers=headers)
            else:
                headers = {k: _rfc2047(v) for k, v in headers.items()}
                r = await self.client.post(url, content=ev.message.encode(), headers=headers)
            r.raise_for_status()
        except Exception as e:  # noqa: BLE001
            log.warning("No se pudo enviar notificación ntfy: %s", e)


def _rfc2047(value: str) -> str:
    try:
        value.encode("ascii")
        return value
    except UnicodeEncodeError:
        import base64

        return f"=?UTF-8?B?{base64.b64encode(value.encode()).decode()}?="
