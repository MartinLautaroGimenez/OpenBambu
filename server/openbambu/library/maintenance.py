"""Mantenimiento por impresora: tareas con intervalo en horas de impresión.

Las horas se cuentan con el historial de OpenBambu. Cuando una tarea vence
(al terminar una impresión) se avisa una sola vez, hasta que se marque hecha.
"""

from __future__ import annotations

import logging

from .store import Store

log = logging.getLogger(__name__)

# (nombre, intervalo en horas, nota) — valores orientativos, se pueden editar
DEFAULTS: dict[str, list[tuple[str, float, str]]] = {
    "A1": [
        ("Limpiar la cama (agua y detergente)", 50, "Lavar la placa PEI y secarla sin tocar la superficie"),
        ("Limpiar y lubricar el eje X", 200, "Pasar un paño por la varilla y aplicar grasa"),
        ("Lubricar los husillos del eje Z", 300, "Grasa en los dos husillos, subir y bajar el eje"),
        ("Revisar la tensión de las correas", 300, "Ajuste automático desde la pantalla o revisar a mano"),
        ("Limpiar la boquilla y el hotend", 200, "Quitar restos de filamento; revisar la silicona"),
        ("Limpiar el cortador y el extrusor", 300, "Restos de filamento en el cortador y los engranajes"),
    ],
    "A1MINI": [
        ("Limpiar la cama (agua y detergente)", 50, "Lavar la placa PEI y secarla sin tocar la superficie"),
        ("Limpiar y lubricar el eje X", 200, "Pasar un paño por la varilla y aplicar grasa"),
        ("Lubricar el husillo del eje Z", 300, "Grasa en el husillo, subir y bajar el eje"),
        ("Limpiar la boquilla y el hotend", 200, "Quitar restos de filamento; revisar la silicona"),
    ],
    "CORE_XY": [
        ("Limpiar la cama (agua y detergente)", 50, "Lavar la placa PEI y secarla sin tocar la superficie"),
        ("Limpiar y lubricar las varillas X/Y", 200, "Pasar un paño por las varillas de carbono y del eje Y"),
        ("Lubricar los husillos del eje Z", 300, "Grasa en los tres husillos"),
        ("Limpiar la boquilla y el hotend", 200, "Quitar restos de filamento; revisar la silicona"),
        ("Cambiar el filtro de carbón", 500, "Solo P1S / X1"),
    ],
}


def defaults_for(model: str) -> list[tuple[str, float, str]]:
    if model in DEFAULTS:
        return DEFAULTS[model]
    return DEFAULTS["CORE_XY"]


class MaintenanceService:
    def __init__(self, store: Store, printers: dict, emit=None):
        self.store = store
        self.printers = printers
        self.emit = emit  # fn(printer_id, type, title, message)
        self.listeners: list = []

    def _model(self, pid: str) -> str:
        p = self.printers.get(pid)
        return p.cfg.model if p else "A1"

    def ensure_defaults(self, pid: str) -> None:
        if self.store.maintenance(pid):
            return
        hours = self.store.printer_hours(pid)
        for name, interval, notes in defaults_for(self._model(pid)):
            self.store.add_maintenance(pid, name, interval, hours, notes)

    @staticmethod
    def describe(task: dict, hours: float) -> dict:
        used = max(0.0, hours - task["last_hours"])
        left = task["interval_h"] - used
        return {
            **task,
            "notified": bool(task["notified"]),
            "hours_since": round(used, 1),
            "hours_left": round(left, 1),
            "fraction": round(min(used / task["interval_h"], 1.5), 3) if task["interval_h"] > 0 else 0,
            "due": left <= 0,
            "soon": 0 < left <= task["interval_h"] * 0.1,
        }

    def overview(self, pid: str) -> dict:
        self.ensure_defaults(pid)
        hours = self.store.printer_hours(pid)
        tasks = [self.describe(t, hours) for t in self.store.maintenance(pid)]
        tasks.sort(key=lambda t: t["hours_left"])
        return {"printer_id": pid, "hours": hours, "tasks": tasks, "due": sum(1 for t in tasks if t["due"]),
                "log": self.store.maintenance_log(pid, 30)}

    def mark_done(self, tid: int, notes: str = "") -> dict | None:
        task = self.store.get_maintenance(tid)
        if not task:
            return None
        hours = self.store.printer_hours(task["printer_id"])
        self.store.log_maintenance(task, hours, notes)
        import time
        self.store.update_maintenance(tid, last_done=time.time(), last_hours=hours, notified=0)
        self._changed(task["printer_id"])
        return self.store.get_maintenance(tid)

    def _changed(self, pid: str) -> None:
        for fn in list(self.listeners):
            try:
                fn(pid)
            except Exception:  # noqa: BLE001
                log.exception("Error al avisar cambios de mantenimiento")

    def check(self, pid: str, *_args) -> list[dict]:
        """Al terminar una impresión: avisar las tareas que vencieron."""
        self.ensure_defaults(pid)
        hours = self.store.printer_hours(pid)
        due = []
        for t in self.store.maintenance(pid):
            d = self.describe(t, hours)
            if d["due"] and not t["notified"]:
                due.append(d)
                self.store.update_maintenance(t["id"], notified=1)
        if due and self.emit:
            names = ", ".join(t["name"] for t in due[:3]) + ("…" if len(due) > 3 else "")
            self.emit(pid, "maintenance", "Mantenimiento pendiente", names)
        if due:
            self._changed(pid)
        return due
