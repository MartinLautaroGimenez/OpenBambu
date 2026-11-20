"""Cola de impresión.

Flujo de cada trabajo:  queued → uploading → starting → printing → done | failed | cancelled

La A1 no puede retirar la pieza sola: después de cualquier impresión la cola
queda esperando que el usuario confirme "cama libre" antes de arrancar el
siguiente trabajo.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections.abc import Callable

from ..notify.events import CANCELLED_ERROR, Event
from ..printer import commands as C
from ..printer.base import BasePrinter
from .mapping import build_ams_payload
from .store import Store

log = logging.getLogger(__name__)

PRINTING = ("RUNNING", "PAUSE", "PREPARE")
READY = ("IDLE", "FINISH", "FAILED")
START_TIMEOUT = 240  # s sin que la impresora arranque → falla


class QueueManager:
    def __init__(self, store: Store, printers: dict[str, BasePrinter], emit: Callable[[Event], None]):
        self.store = store
        self.printers = printers
        self.emit = emit
        self.upload_progress: dict[int, float] = {}
        self.listeners: list[Callable[[str], None]] = []
        self._wake: dict[str, asyncio.Event] = {}
        self._prev_state: dict[str, str] = {}
        self._asked_bed: dict[str, int] = {}
        self._tasks: dict[str, asyncio.Task] = {}
        self.power = None  # PowerManager (opcional)
        self._powering: set[str] = set()

    # ---- ciclo de vida -------------------------------------------------
    def start(self) -> None:
        for pid in self.printers:
            self.add_printer(pid)

    def add_printer(self, pid: str) -> None:
        if pid in self._tasks:
            return
        self._wake[pid] = asyncio.Event()
        self._tasks[pid] = asyncio.create_task(self._loop(pid), name=f"queue-{pid}")

    async def remove_printer(self, pid: str) -> None:
        t = self._tasks.pop(pid, None)
        self._wake.pop(pid, None)
        if t:
            t.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await t

    async def stop(self) -> None:
        for pid in list(self._tasks):
            await self.remove_printer(pid)

    def wake(self, pid: str) -> None:
        if ev := self._wake.get(pid):
            ev.set()

    def changed(self, pid: str) -> None:
        for fn in list(self.listeners):
            with contextlib.suppress(Exception):
                fn(pid)

    def on_status(self, pid: str, snap: dict) -> None:
        prev = self._prev_state.get(pid)
        state = snap["state"]
        self._prev_state[pid] = state
        # Cualquier impresión que termina (de la cola o no) deja algo en la cama
        if prev in PRINTING and state in ("FINISH", "FAILED"):
            self.store.set_queue_state(pid, bed_clear=False)
            self.changed(pid)
        if prev != state:
            self.wake(pid)

    # ---- API -----------------------------------------------------------
    def snapshot(self, pid: str) -> dict:
        st = self.store.queue_state(pid)
        jobs = self.store.jobs(pid)
        for j in jobs:
            j["upload_progress"] = self.upload_progress.get(j["id"])
        queued = [j for j in jobs if j["status"] == "queued"]
        printer = self.printers[pid].state.snapshot()
        waiting_bed = bool(queued) and not st["bed_clear"] and not st["paused"] and printer["state"] in READY \
            and self.store.active_job(pid) is None
        return {**st, "waiting_bed_clear": waiting_bed, "jobs": jobs}

    def confirm_bed_clear(self, pid: str) -> None:
        self.store.set_queue_state(pid, bed_clear=True)
        self._asked_bed.pop(pid, None)
        self.changed(pid)
        self.wake(pid)

    def set_paused(self, pid: str, paused: bool) -> None:
        self.store.set_queue_state(pid, paused=paused)
        self.changed(pid)
        self.wake(pid)

    # ---- motor ---------------------------------------------------------
    async def _loop(self, pid: str) -> None:
        while True:
            ev = self._wake[pid]
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(ev.wait(), 5)
            ev.clear()
            try:
                await self._step(pid)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                log.exception("Error en la cola de %s", pid)

    def _event(self, p: BasePrinter, type_: str, title: str, msg: str, severity: str = "info", **kw) -> None:
        self.emit(Event(p.cfg.id, p.cfg.name, type_, title, msg, severity=severity, **kw))

    async def _step(self, pid: str) -> None:
        p = self.printers[pid]
        s = p.state.snapshot()
        active = self.store.active_job(pid)

        if active:
            await self._track(p, s, active)
            return

        st = self.store.queue_state(pid)
        if not s["connected"] and not st["paused"] and st["bed_clear"] and self.power \
                and self.power.entity(pid) and pid not in self._powering and self.store.next_queued(pid):
            # Impresora apagada con un trabajo listo: prenderla con el enchufe
            self._powering.add(pid)
            try:
                await self.power.ensure_on(pid)
            finally:
                self._powering.discard(pid)
            return
        if st["paused"] or not s["connected"] or s["state"] not in READY:
            return
        job = self.store.next_queued(pid)
        if not job:
            return
        if not st["bed_clear"]:
            if self._asked_bed.get(pid) != job["id"]:
                self._asked_bed[pid] = job["id"]
                self._event(p, "queue_bed_clear", "Retirá la pieza",
                            f"«{job['name']}» espera en la cola. Confirmá en la app que la cama está libre.",
                            severity="warning", snapshot=True)
                self.changed(pid)
            return
        await self._start(p, job)

    async def _track(self, p: BasePrinter, s: dict, job: dict) -> None:
        jid, state = job["id"], s["state"]
        if job["status"] == "starting":
            if state in PRINTING:
                self.store.update_job(jid, status="printing")
                self.changed(p.cfg.id)
            elif time.time() - (job["started"] or 0) > START_TIMEOUT:
                self._fail(p, job, "La impresora no comenzó la impresión")
            return
        if job["status"] == "printing":
            if state == "FINISH":
                self.store.update_job(jid, status="done")
                self.changed(p.cfg.id)
            elif state == "FAILED":
                if s["job"]["print_error"] == CANCELLED_ERROR:
                    self.store.update_job(jid, status="cancelled")
                    self.changed(p.cfg.id)
                else:
                    self._fail(p, job, f"Error {s['job']['print_error']:08X}" if s["job"]["print_error"] else "Falló")
            elif state == "IDLE" and s["connected"]:
                self._fail(p, job, "La impresora quedó inactiva")
        # "uploading" lo maneja _start en la misma tarea

    def _fail(self, p: BasePrinter, job: dict, reason: str) -> None:
        self.store.update_job(job["id"], status="failed", error=reason)
        # Por seguridad la cola se pausa tras una falla
        self.store.set_queue_state(p.cfg.id, paused=True)
        self.upload_progress.pop(job["id"], None)
        self._event(p, "queue_error", "Cola pausada", f"«{job['name']}»: {reason}", severity="error")
        self.changed(p.cfg.id)

    async def _start(self, p: BasePrinter, job: dict) -> None:
        pid, jid = p.cfg.id, job["id"]
        item = self.store.get_file(job["library_id"])
        if not item:
            self._fail(p, job, "El archivo ya no está en la biblioteca")
            return
        plate = next((x for x in item["meta"]["plates"] if x["index"] == job["plate"]), None)
        if not plate:
            self._fail(p, job, f"El archivo no tiene la placa {job['plate']}")
            return

        local = self.store.file_path(item)
        remote = f"ob_{item['id']}.gcode.3mf"
        size = local.stat().st_size
        self.store.update_job(jid, status="uploading")
        self.upload_progress[jid] = 0.0
        self.changed(pid)
        try:
            existing = {f["name"]: f["size"] for f in await p.files.alist("/")}
            if existing.get(remote) != size:
                last = [0.0]

                def progress(sent: int) -> None:
                    pct = round(sent / size * 100, 1) if size else 100.0
                    self.upload_progress[jid] = pct
                    if pct - last[0] >= 5:
                        last[0] = pct
                        self.changed(pid)

                await p.files.aupload(local, f"/{remote}", progress)
        except Exception as e:  # noqa: BLE001
            self._fail(p, job, f"No se pudo subir el archivo: {e}")
            return
        self.upload_progress.pop(jid, None)

        mapping = {m["filament_id"]: m["tray"] for m in job["ams_mapping"] if m.get("tray") is not None}
        ams, ams2, use_ams = build_ams_payload(plate["filaments"], mapping)
        o = job["options"]
        cmd = C.project_file(
            remote, job["plate"], job["name"], ams, ams2, use_ams,
            bed_leveling=o.get("bed_leveling", True),
            flow_cali=o.get("flow_cali", False),
            timelapse=o.get("timelapse", False),
            vibration_cali=o.get("vibration_cali", False),
        )
        try:
            res = await p.send(cmd)
        except ConnectionError as e:
            self._fail(p, job, str(e))
            return
        if res.get("result") == "failed":
            self._fail(p, job, "La impresora rechazó el trabajo")
            return
        self.store.update_job(jid, status="starting")
        self.store.set_queue_state(pid, bed_clear=False)
        self._asked_bed.pop(pid, None)
        self.changed(pid)
