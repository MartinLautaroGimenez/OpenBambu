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

    def snapshot_path(self, print_id: int) -> Path:
        return self.dir / f"{print_id}.jpg"

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
        qjob = self.store.active_job(pid)
        mapping: dict[int, int] = {}
        if qjob:
            library_id, plate, job_id, name = qjob["library_id"], qjob["plate"], qjob["id"], qjob["name"]
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
        self.store.add_print(printer_id=pid, name=name, file=job["file"], library_id=library_id, plate=plate,
                             job_id=job_id, status="printing", weight_g=weight, filaments=filaments)
        log.info("Historial: comenzó «%s» en %s", name, pid)
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
        try:
            t = asyncio.get_running_loop().create_task(self._save_snapshot(pid, rec["id"]))
            self._tasks.add(t)
            t.add_done_callback(self._tasks.discard)
        except RuntimeError:
            pass  # sin loop (llamado desde otro hilo): sin foto
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


def compute_stats(prints: list[dict], months: int = 6) -> dict:
    finished = [p for p in prints if p["status"] != "printing"]
    by_status = Counter(p["status"] for p in finished)
    done = [p for p in finished if p["status"] == "done"]
    seconds = sum((p["finished"] or p["started"]) - p["started"] for p in finished)
    grams = sum(p["weight_g"] or 0 for p in finished)
    cost = sum(p["cost"] or 0 for p in finished)

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
        "success_rate": round(len(done) / len(finished) * 100) if finished else None,
        "hours": round(seconds / 3600, 1),
        "grams": round(grams, 1),
        "cost": round(cost, 2),
        "months": [{**v, "grams": round(v["grams"], 1), "hours": round(v["hours"], 1)} for v in per_month.values()],
        "materials": dict(sorted(((k, round(v, 1)) for k, v in materials.items()), key=lambda x: -x[1])),
    }
