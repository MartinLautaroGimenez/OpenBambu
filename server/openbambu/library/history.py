"""Historial de impresiones e inventario de filamento.

Cada impresión que arranca se registra. Al terminar se guarda una foto de la
cámara, se calcula lo consumido (con los gramos que informó el laminador,
proporcional al avance si se canceló o falló) y se descuenta de los carretes
asignados a cada bandeja, calculando el costo.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re
import time
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

from ..notify.events import CANCELLED_ERROR
from .store import Store

log = logging.getLogger(__name__)

PRINTING = ("RUNNING", "PAUSE", "PREPARE")
LIB_FILE = re.compile(r"ob_([0-9a-f]{16})\.gcode\.3mf$")


class HistoryRecorder:
    def __init__(self, store: Store, printers: dict, data_dir: Path):
        self.store = store
        self.printers = printers
        self.dir = Path(data_dir) / "history"
        self.dir.mkdir(parents=True, exist_ok=True)
        self._prev: dict[str, str] = {}
        self._tasks: set[asyncio.Task] = set()
        self.listeners: list = []
        self.finish_listeners: list = []  # fn(printer_id, record)
        self.power = None  # PowerManager (medición de energía)
        self._meters: dict[int, asyncio.Task] = {}
        self._meter_kwh: dict[int, float] = {}

    def snapshot_path(self, print_id: int) -> Path:
        return self.dir / f"{print_id}.jpg"

    def _spawn(self, coro) -> None:
        try:
            t = asyncio.get_running_loop().create_task(coro)
        except RuntimeError:
            coro.close()  # sin loop (llamado desde otro hilo)
            return
        self._tasks.add(t)
        t.add_done_callback(self._tasks.discard)

    def _changed(self) -> None:
        for fn in list(self.listeners):
            with contextlib.suppress(Exception):
                fn()

    # ---- detección -----------------------------------------------------------
    def on_status(self, pid: str, snap: dict) -> None:
        if not snap["connected"]:
            return
        state, prev = snap["state"], self._prev.get(pid)
        self._prev[pid] = state
        open_ = self.store.open_print(pid)
        if state in PRINTING and not open_ and (prev is None or prev not in PRINTING):
            self._start(pid, snap)
        elif open_ and state in ("FINISH", "FAILED", "IDLE") and (prev in PRINTING or prev is None):
            self._finish(pid, open_, snap)

    def _start(self, pid: str, snap: dict) -> None:
        job = snap["job"]
        library_id, plate, job_id, name = None, 1, None, job["name"] or "Impresión"
        project_id = None
        qjob = self.store.active_job(pid)
        mapping: dict[int, int] = {}
        if qjob:
            library_id, plate, job_id, name = qjob["library_id"], qjob["plate"], qjob["id"], qjob["name"]
            project_id = qjob["options"].get("project_id")
            mapping = {m["filament_id"]: m["tray"] for m in qjob["ams_mapping"] if m.get("tray") is not None}
        elif job["file"] and (m := LIB_FILE.search(job["file"])):
            library_id = m[1]

        filaments, weight = [], None
        item = self.store.get_file(library_id) if library_id else None
        if item:
            pl = next((p for p in item["meta"].get("plates", []) if p["index"] == plate), None)
            if pl:
                weight = pl.get("weight_g")
                active = snap["ams"]["active_tray"]
                for f in pl.get("filaments", []):
                    tray = mapping.get(f["id"], active if len(pl["filaments"]) == 1 else None)
                    filaments.append({"filament_id": f["id"], "type": f.get("type"), "color": f.get("color"),
                                      "used_g": f.get("used_g"), "tray": tray})
        if not filaments and snap["ams"]["active_tray"] is not None:
            # Sin datos del laminador: registrar al menos la bandeja en uso
            filaments.append({"filament_id": 1, "type": None, "color": None, "used_g": None,
                              "tray": snap["ams"]["active_tray"]})
        if project_id is not None and not self.store.get_project(project_id):
            project_id = None
        print_id = self.store.add_print(printer_id=pid, name=name, file=job["file"], library_id=library_id,
                                        plate=plate, job_id=job_id, status="printing", weight_g=weight,
                                        filaments=filaments, project_id=project_id)
        log.info("Historial: comenzó «%s» en %s", name, pid)
        self._spawn(self._energy_start(pid, print_id))
        self._changed()

    # ---- energía (sensor de Home Assistant) ----------------------------------------
    async def _energy_start(self, pid: str, print_id: int) -> None:
        if not self.power:
            return
        r = await self.power.energy_reading(pid)
        if not r:
            return
        kind, value = r
        if kind == "energy":
            self.store.update_print(print_id, energy_start=value)
        else:
            self._meter_kwh[print_id] = 0.0
            self._meters[print_id] = asyncio.get_running_loop().create_task(self._integrate(pid, print_id, value))

    async def _integrate(self, pid: str, print_id: int, watts: float, every: float = 30) -> None:
        """Sensor de potencia (W): integra el consumo mientras dure la impresión."""
        last = time.monotonic()
        while True:
            await asyncio.sleep(every)
            now = time.monotonic()
            self._meter_kwh[print_id] = self._meter_kwh.get(print_id, 0) + watts * (now - last) / 3_600_000
            last = now
            r = await self.power.energy_reading(pid) if self.power else None
            if r and r[0] == "power":
                watts = r[1]

    async def _energy_finish(self, pid: str, rec: dict) -> None:
        kwh = None
        meter = self._meters.pop(rec["id"], None)
        if meter:
            meter.cancel()
            kwh = self._meter_kwh.pop(rec["id"], None)
        elif rec.get("energy_start") is not None and self.power:
            r = await self.power.energy_reading(pid)
            if r and r[0] == "energy" and r[1] >= rec["energy_start"]:
                kwh = r[1] - rec["energy_start"]
        if kwh is None:
            return
        price = self.power.cfg.price_kwh if self.power else 0
        self.store.update_print(rec["id"], energy_kwh=round(kwh, 3),
                                energy_cost=round(kwh * price, 2) if price else None)
        self._changed()

    def _finish(self, pid: str, rec: dict, snap: dict) -> None:
        state, job = snap["state"], snap["job"]
        if state == "FINISH":
            status, progress = "done", 100
        elif state == "FAILED" and job["print_error"] == CANCELLED_ERROR:
            status, progress = "cancelled", job["progress"]
        else:
            status, progress = "failed", job["progress"]
        factor = 1.0 if status == "done" else max(0, min(progress, 100)) / 100

        total_cost, total_g, filaments = 0.0, 0.0, []
        for f in rec["filaments"]:
            f = dict(f)
            used = (f.get("used_g") or 0) * factor
            if used and f.get("tray") is not None:
                spool = self.store.spool_in_tray(pid, f["tray"])
                if spool:
                    self.store.consume(spool["id"], used)
                    f["spool_id"] = spool["id"]
                    if spool["weight_g"]:
                        cost = used * spool["price"] / spool["weight_g"]
                        f["cost"] = round(cost, 2)
                        total_cost += cost
            f["consumed_g"] = round(used, 2) if used else None
            total_g += used
            filaments.append(f)

        self.store.update_print(
            rec["id"], status=status, finished=time.time(), progress=progress, filaments=filaments,
            weight_g=round(total_g, 2) if total_g else rec["weight_g"] if status == "done" else None,
            cost=round(total_cost, 2) if total_cost else None,
            error=f"{job['print_error']:08X}" if status == "failed" and job["print_error"] else None,
        )
        log.info("Historial: «%s» terminó (%s, %.1f g)", rec["name"], status, total_g)
        self._spawn(self._save_snapshot(pid, rec["id"]))
        self._spawn(self._energy_finish(pid, rec))
        for fn in list(self.finish_listeners):
            try:
                fn(pid, rec)
            except Exception:  # noqa: BLE001
                log.exception("Error al procesar el fin de impresión")
        self._changed()

    async def _save_snapshot(self, pid: str, print_id: int) -> None:
        p = self.printers.get(pid)
        if not p:
            return
        try:
            jpg = await p.camera.snapshot(timeout=10)
        except Exception:  # noqa: BLE001
            jpg = None
        if jpg:
            self.snapshot_path(print_id).write_bytes(jpg)
            self.store.update_print(print_id, snapshot=True)
            self._changed()


REJECT_REASONS = {
    "adhesion": "Se despegó de la cama",
    "spaghetti": "Spaghetti / se soltó",
    "layer_shift": "Capas corridas",
    "under_extrusion": "Falta de extrusión",
    "stringing": "Hilos / stringing",
    "warping": "Warping",
    "dimensions": "Medidas incorrectas",
    "surface": "Mala terminación",
    "other": "Otro",
}


def print_ok(p: dict) -> bool:
    """Terminó y no fue rechazada al calificarla."""
    return p["status"] == "done" and p.get("rating") != "bad"


def compute_stats(prints: list[dict], months: int = 6) -> dict:
    finished = [p for p in prints if p["status"] != "printing"]
    by_status = Counter(p["status"] for p in finished)
    ok = [p for p in finished if print_ok(p)]
    seconds = sum((p["finished"] or p["started"]) - p["started"] for p in finished)
    grams = sum(p["weight_g"] or 0 for p in finished)
    cost = sum(p["cost"] or 0 for p in finished)
    kwh = sum(p.get("energy_kwh") or 0 for p in finished)
    energy_cost = sum(p.get("energy_cost") or 0 for p in finished)
    rated_good = sum(1 for p in finished if p["status"] == "done" and p.get("rating") == "good")
    rated_bad = sum(1 for p in finished if p.get("rating") == "bad")
    unrated = sum(1 for p in finished if p["status"] == "done" and not p.get("rating"))

    # Análisis de fallas de los últimos 30 días
    since = time.time() - 30 * 86400
    issues: Counter[str] = Counter()
    for p in finished:
        if p["started"] < since:
            continue
        if p["status"] == "failed":
            issues["Error de la impresora" + (f" ({p['error']})" if p.get("error") else "")] += 1
        elif p["status"] == "cancelled":
            issues["Cancelada"] += 1
        elif p.get("rating") == "bad":
            issues[REJECT_REASONS.get(p.get("rating_reason") or "other", "Otro")] += 1
    recent = [p for p in finished if p["started"] >= since]
    now = datetime.now()
    keys = []
    y, m = now.year, now.month
    for _ in range(months):
        keys.append(f"{y}-{m:02d}")
        m -= 1
        if m == 0:
            y, m = y - 1, 12
    keys.reverse()
    per_month = {k: {"month": k, "prints": 0, "grams": 0.0, "hours": 0.0} for k in keys}
    materials: dict[str, float] = defaultdict(float)
    for p in finished:
        k = datetime.fromtimestamp(p["started"]).strftime("%Y-%m")
        if k in per_month:
            per_month[k]["prints"] += 1
            per_month[k]["grams"] += p["weight_g"] or 0
            per_month[k]["hours"] += ((p["finished"] or p["started"]) - p["started"]) / 3600
        for f in p["filaments"]:
            if f.get("consumed_g") and f.get("type"):
                materials[f["type"]] += f["consumed_g"]
    return {
        "total": len(finished),
        "done": by_status.get("done", 0),
        "failed": by_status.get("failed", 0),
        "cancelled": by_status.get("cancelled", 0),
        "success_rate": round(len(ok) / len(finished) * 100) if finished else None,
        "rated_good": rated_good,
        "rated_bad": rated_bad,
        "unrated": unrated,
        "energy_kwh": round(kwh, 2),
        "energy_cost": round(energy_cost, 2),
        "recent_total": len(recent),
        "recent_success_rate": round(sum(1 for p in recent if print_ok(p)) / len(recent) * 100) if recent else None,
        "issues": [{"reason": k, "count": v} for k, v in issues.most_common()],
        "hours": round(seconds / 3600, 1),
        "grams": round(grams, 1),
        "cost": round(cost, 2),
        "months": [{**v, "grams": round(v["grams"], 1), "hours": round(v["hours"], 1)} for v in per_month.values()],
        "materials": dict(sorted(((k, round(v, 1)) for k, v in materials.items()), key=lambda x: -x[1])),
    }
