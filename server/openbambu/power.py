"""Control de energía de la impresora con un enchufe de Home Assistant.

* Prender/apagar desde la app.
* Auto-apagado: cuando termina una impresión, espera a que la boquilla se
  enfríe y un tiempo extra, y apaga (si no arrancó otra cosa).
* Auto-encendido: si la cola tiene un trabajo listo y la impresora está
  apagada, la prende y espera a que se conecte.

La configuración se guarda en ``data/power.json`` (el token de Home Assistant
nunca se devuelve a la app).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import time
from pathlib import Path

import httpx
from pydantic import BaseModel, Field

log = logging.getLogger(__name__)

DOMAINS = ("switch", "light", "input_boolean", "fan")
# unidad -> (tipo, factor a kWh o a W)
ENERGY_UNITS = {"kWh": ("energy", 1.0), "Wh": ("energy", 0.001), "W": ("power", 1.0), "kW": ("power", 1000.0)}


class PowerConfig(BaseModel):
    url: str = ""
    token: str = ""
    # entidad por impresora, ej. {"a1": "switch.enchufe_a1"}
    entities: dict[str, str] = {}
    auto_off: bool = True
    auto_off_delay_min: int = Field(5, ge=0, le=240)
    auto_off_max_nozzle: int = Field(50, ge=30, le=120)
    auto_on_queue: bool = True
    # Sensor de energía (kWh, total acumulado) o de potencia (W) por impresora
    energy_entities: dict[str, str] = {}
    price_kwh: float = Field(0, ge=0)

    @property
    def configured(self) -> bool:
        return bool(self.url and self.token)


class HomeAssistant:
    def __init__(self, cfg: PowerConfig, client: httpx.AsyncClient | None = None):
        self.cfg = cfg
        self.client = client or httpx.AsyncClient(timeout=10)

    @property
    def _headers(self) -> dict:
        return {"Authorization": f"Bearer {self.cfg.token}"}

    def _url(self, path: str) -> str:
        return f"{self.cfg.url.rstrip('/')}/api{path}"

    async def state(self, entity: str) -> str:
        r = await self.client.get(self._url(f"/states/{entity}"), headers=self._headers)
        if r.status_code == 401:
            raise PermissionError("Token de Home Assistant inválido")
        r.raise_for_status()
        return r.json().get("state", "unknown")

    async def turn(self, entity: str, on: bool) -> None:
        domain = entity.split(".", 1)[0]
        if domain not in DOMAINS:
            raise ValueError(f"Entidad no soportada: {entity}")
        r = await self.client.post(self._url(f"/services/{domain}/turn_{'on' if on else 'off'}"),
                                   headers=self._headers, json={"entity_id": entity})
        if r.status_code == 401:
            raise PermissionError("Token de Home Assistant inválido")
        r.raise_for_status()

    async def sensor(self, entity: str) -> tuple[float, str] | None:
        """Valor numérico y unidad de un sensor (None si no está disponible)."""
        r = await self.client.get(self._url(f"/states/{entity}"), headers=self._headers)
        if r.status_code == 401:
            raise PermissionError("Token de Home Assistant inválido")
        r.raise_for_status()
        data = r.json()
        try:
            value = float(data.get("state"))
        except (TypeError, ValueError):
            return None
        return value, (data.get("attributes") or {}).get("unit_of_measurement") or ""

    async def entities(self, kind: str = "switch") -> list[dict]:
        r = await self.client.get(self._url("/states"), headers=self._headers)
        if r.status_code == 401:
            raise PermissionError("Token de Home Assistant inválido")
        r.raise_for_status()
        out = []
        for e in r.json():
            eid = e.get("entity_id", "")
            attrs = e.get("attributes") or {}
            item = {"entity_id": eid, "name": attrs.get("friendly_name") or eid, "state": e.get("state")}
            if kind == "energy":
                unit = attrs.get("unit_of_measurement") or ""
                if eid.startswith("sensor.") and unit in ENERGY_UNITS:
                    out.append({**item, "unit": unit})
            elif eid.split(".", 1)[0] in ("switch", "light", "input_boolean"):
                out.append(item)
        if kind == "energy":
            # Primero los de energía acumulada (más precisos)
            return sorted(out, key=lambda x: (ENERGY_UNITS[x["unit"]][0] != "energy", x["name"].lower()))
        return sorted(out, key=lambda x: (not x["entity_id"].startswith("switch."), x["name"].lower()))


class PowerManager:
    def __init__(self, data_dir: str, printers: dict, emit=None):
        self.path = Path(data_dir) / "power.json"
        self.printers = printers
        self.emit = emit
        self.cfg = self._load()
        self.ha = HomeAssistant(self.cfg)
        self._prev: dict[str, str] = {}
        self._off_tasks: dict[str, asyncio.Task] = {}
        self.off_at: dict[str, float] = {}  # cuándo se programó/ejecutó el apagado
        self.powered_off: dict[str, float] = {}  # apagados por OpenBambu (para no alertar "desconectada")

    # ---- configuración --------------------------------------------------------
    def _load(self) -> PowerConfig:
        try:
            return PowerConfig.model_validate(json.loads(self.path.read_text()))
        except (OSError, ValueError):
            return PowerConfig()

    def save(self, **changes) -> PowerConfig:
        data = self.cfg.model_dump()
        for k, v in changes.items():
            if v is None or (k == "token" and v == ""):
                continue  # token vacío = mantener el actual
            data[k] = v
        self.cfg = PowerConfig.model_validate(data)
        self.ha.cfg = self.cfg
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.cfg.model_dump()))
        os.chmod(self.path, 0o600)
        return self.cfg

    def public_config(self) -> dict:
        d = self.cfg.model_dump()
        d["token"] = ""
        d["has_token"] = bool(self.cfg.token)
        d["configured"] = self.cfg.configured
        return d

    def entity(self, pid: str) -> str | None:
        return self.cfg.entities.get(pid) if self.cfg.configured else None

    def energy_entity(self, pid: str) -> str | None:
        return self.cfg.energy_entities.get(pid) if self.cfg.configured else None

    async def energy_reading(self, pid: str) -> tuple[str, float] | None:
        """("energy", kWh acumulados) o ("power", W instantáneos), o None."""
        ent = self.energy_entity(pid)
        if not ent:
            return None
        try:
            r = await self.ha.sensor(ent)
        except Exception as e:  # noqa: BLE001
            log.debug("Sensor de energía %s no disponible: %s", ent, e)
            return None
        if not r or r[1] not in ENERGY_UNITS:
            return None
        kind, factor = ENERGY_UNITS[r[1]]
        return kind, r[0] * factor

    # ---- acciones -------------------------------------------------------------
    async def status(self, pid: str) -> dict:
        ent = self.entity(pid)
        out = {"available": bool(ent), "entity": ent, "state": None, "auto_off_at": None}
        if ent:
            try:
                out["state"] = await self.ha.state(ent)
            except Exception as e:  # noqa: BLE001
                out["error"] = str(e) or type(e).__name__
        if pid in self._off_tasks and not self._off_tasks[pid].done():
            out["auto_off_at"] = self.off_at.get(pid)
        return out

    async def set(self, pid: str, on: bool) -> None:
        ent = self.entity(pid)
        if not ent:
            raise ValueError("No hay un enchufe configurado para esta impresora")
        self.cancel_auto_off(pid)
        if not on:
            self.powered_off[pid] = time.time()
        await self.ha.turn(ent, on)

    def recently_powered_off(self, pid: str, window: float = 600) -> bool:
        return time.time() - self.powered_off.get(pid, 0) < window

    async def ensure_on(self, pid: str, timeout: float = 240) -> bool:
        """Prende la impresora (si hace falta) y espera a que se conecte."""
        p = self.printers.get(pid)
        ent = self.entity(pid)
        if not p or not ent or not self.cfg.auto_on_queue:
            return False
        if p.state.connected:
            return True
        try:
            if await self.ha.state(ent) != "on":
                log.info("Encendiendo %s para la cola", pid)
                await self.ha.turn(ent, True)
                if self.emit:
                    self.emit(pid, "power_on", "Encendiendo la impresora", "Hay un trabajo listo en la cola")
        except Exception as e:  # noqa: BLE001
            log.warning("No se pudo encender %s: %s", pid, e)
            return False
        end = time.time() + timeout
        while time.time() < end:
            if p.state.connected:
                return True
            await asyncio.sleep(3)
        return False

    # ---- auto-apagado ----------------------------------------------------------
    def cancel_auto_off(self, pid: str) -> None:
        t = self._off_tasks.pop(pid, None)
        if t and not t.done():
            t.cancel()
        self.off_at.pop(pid, None)

    def on_status(self, pid: str, snap: dict) -> None:
        state, prev = snap["state"], self._prev.get(pid)
        self._prev[pid] = state
        if state in ("RUNNING", "PREPARE", "PAUSE"):
            self.cancel_auto_off(pid)
            return
        if prev in ("RUNNING", "PREPARE", "PAUSE") and state in ("FINISH", "FAILED") \
                and self.cfg.auto_off and self.entity(pid):
            self.cancel_auto_off(pid)
            with contextlib.suppress(RuntimeError):
                self._off_tasks[pid] = asyncio.get_running_loop().create_task(self._auto_off(pid))
                self.off_at[pid] = time.time() + self.cfg.auto_off_delay_min * 60

    async def _auto_off(self, pid: str) -> None:
        p = self.printers[pid]
        # 1) Esperar a que la boquilla se enfríe (máximo 30 min)
        end = time.time() + 1800
        while time.time() < end:
            if p.state.snapshot()["temps"]["nozzle"] <= self.cfg.auto_off_max_nozzle:
                break
            await asyncio.sleep(10)
        # 2) Tiempo extra configurado
        await asyncio.sleep(self.cfg.auto_off_delay_min * 60)
        s = p.state.snapshot()
        if s["state"] in ("RUNNING", "PREPARE", "PAUSE"):
            return
        ent = self.entity(pid)
        if not ent:
            return
        try:
            self.powered_off[pid] = time.time()
            await self.ha.turn(ent, False)
            log.info("Auto-apagado de %s", pid)
            if self.emit:
                self.emit(pid, "power_off", "Impresora apagada", "Se apagó sola después de enfriarse")
        except Exception as e:  # noqa: BLE001
            log.warning("No se pudo apagar %s: %s", pid, e)
        finally:
            self.off_at.pop(pid, None)
