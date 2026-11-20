"""Descripciones de errores de la impresora (HMS y print_error) en castellano.

Bambu Lab publica la base de códigos en ``https://e.bambulab.com/query.php``.
Se descarga al iniciar (si la copia local tiene más de una semana) y se guarda
en ``data/cache/hms_<idioma>.json``; sin internet se usa la última copia.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

import httpx

log = logging.getLogger(__name__)

URL = "https://e.bambulab.com/query.php"
MAX_AGE = 7 * 24 * 3600
LANGS = ("es", "en")  # español con respaldo en inglés


class HmsDatabase:
    def __init__(self):
        self.hms: dict[str, str] = {}
        self.errors: dict[str, str] = {}
        self.updated: float | None = None

    def load_dict(self, data: dict, lang: str) -> None:
        d = data.get("data") or {}
        for src, dst in (("device_hms", self.hms), ("device_error", self.errors)):
            for item in (d.get(src) or {}).get(lang) or []:
                code, text = str(item.get("ecode", "")).upper(), (item.get("intro") or "").strip()
                if code and text and code not in dst:  # el primer idioma cargado tiene prioridad
                    dst[code] = text

    def describe_hms(self, code: str) -> str | None:
        """``0300_1200_0002_0001`` → descripción."""
        return self.hms.get(code.replace("_", "").upper())

    def describe_error(self, code: int) -> str | None:
        if not code:
            return None
        return self.errors.get(f"{code:08X}")

    async def refresh(self, cache_dir: Path, client: httpx.AsyncClient | None = None) -> None:
        import os

        if os.getenv("OB_OFFLINE") == "1":
            return
        cache_dir.mkdir(parents=True, exist_ok=True)
        own = client is None
        client = client or httpx.AsyncClient(timeout=30, headers={"User-Agent": "Mozilla/5.0 OpenBambu"})
        try:
            for lang in LANGS:
                f = cache_dir / f"hms_{lang}.json"
                fresh = f.exists() and time.time() - f.stat().st_mtime < MAX_AGE
                if not fresh:
                    try:
                        r = await client.get(URL, params={"lang": lang})
                        r.raise_for_status()
                        data = r.json()
                        if (data.get("data") or {}).get("device_hms"):
                            f.write_text(json.dumps(data, ensure_ascii=False))
                    except (httpx.HTTPError, ValueError) as e:
                        log.warning("No se pudo actualizar la base de errores (%s): %s", lang, e)
                try:
                    self.load_dict(json.loads(f.read_text()), lang)
                except (OSError, ValueError):
                    pass
            self.updated = time.time()
            log.info("Base de errores: %d HMS, %d códigos", len(self.hms), len(self.errors))
        finally:
            if own:
                await client.aclose()


# Instancia global: la usa state.normalize al armar el estado
DB = HmsDatabase()
