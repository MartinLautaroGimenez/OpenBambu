"""Configuración del servidor OpenBambu.

Se lee desde un archivo YAML (por defecto ``/data/config.yaml``) y se puede
sobrescribir con variables de entorno para el caso de una sola impresora.
"""

from __future__ import annotations

import logging
import os
import secrets
from pathlib import Path
from typing import Literal

import yaml
from pydantic import BaseModel, Field

log = logging.getLogger(__name__)

PrinterModel = Literal["A1", "A1MINI", "P1P", "P1S", "X1C", "X1E"]


class PrinterConfig(BaseModel):
    id: str = Field(pattern=r"^[a-zA-Z0-9_-]+$")
    name: str = "Mi impresora"
    model: PrinterModel = "A1"
    host: str = ""
    serial: str = ""
    access_code: str = ""
    # "lan" = conexión real a la impresora; "simulator" = impresora falsa para pruebas
    mode: Literal["lan", "simulator"] = "lan"


class NtfyConfig(BaseModel):
    enabled: bool = False
    url: str = "https://ntfy.sh"
    topic: str = ""
    token: str = ""  # opcional, para servidores ntfy con autenticación


class NotificationsConfig(BaseModel):
    ntfy: NtfyConfig = NtfyConfig()
    # Avisar cada N % de progreso (0 = desactivado)
    progress_step: int = 25


class Settings(BaseModel):
    api_token: str = ""
    data_dir: str = "/data"
    printers: list[PrinterConfig] = []
    notifications: NotificationsConfig = NotificationsConfig()


def _env_printer() -> PrinterConfig | None:
    host = os.getenv("OB_PRINTER_HOST")
    mode = os.getenv("OB_PRINTER_MODE", "lan")
    if not host and mode != "simulator":
        return None
    return PrinterConfig(
        id=os.getenv("OB_PRINTER_ID", "a1"),
        name=os.getenv("OB_PRINTER_NAME", "Bambu Lab A1"),
        model=os.getenv("OB_PRINTER_MODEL", "A1"),  # type: ignore[arg-type]
        host=host or "",
        serial=os.getenv("OB_PRINTER_SERIAL", ""),
        access_code=os.getenv("OB_PRINTER_ACCESS_CODE", ""),
        mode=mode,  # type: ignore[arg-type]
    )


def load_settings(path: str | None = None) -> Settings:
    data_dir = os.getenv("OB_DATA_DIR", "/data")
    path = path or os.getenv("OB_CONFIG", str(Path(data_dir) / "config.yaml"))
    raw: dict = {}
    p = Path(path)
    if p.exists():
        raw = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
        log.info("Configuración cargada de %s", p)
    raw.setdefault("data_dir", data_dir)
    settings = Settings.model_validate(raw)

    if tok := os.getenv("OB_API_TOKEN"):
        settings.api_token = tok
    if env_p := _env_printer():
        settings.printers = [x for x in settings.printers if x.id != env_p.id] + [env_p]
    if topic := os.getenv("OB_NTFY_TOPIC"):
        settings.notifications.ntfy.enabled = True
        settings.notifications.ntfy.topic = topic
        settings.notifications.ntfy.url = os.getenv("OB_NTFY_URL", settings.notifications.ntfy.url)
        settings.notifications.ntfy.token = os.getenv("OB_NTFY_TOKEN", "")

    if not settings.api_token:
        settings.api_token = _persisted_token(Path(settings.data_dir))
    return settings


def _persisted_token(data_dir: Path) -> str:
    """Genera (una sola vez) un token de API y lo guarda en el directorio de datos."""
    f = data_dir / "api_token"
    try:
        if f.exists():
            return f.read_text().strip()
        data_dir.mkdir(parents=True, exist_ok=True)
        tok = secrets.token_urlsafe(24)
        f.write_text(tok)
        log.warning("=" * 60)
        log.warning("Token de API generado: %s", tok)
        log.warning("Ingresalo en la app OpenBambu. Guardado en %s", f)
        log.warning("=" * 60)
        return tok
    except OSError:
        tok = secrets.token_urlsafe(24)
        log.warning("No se pudo guardar el token. Token temporal: %s", tok)
        return tok
