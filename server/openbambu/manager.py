"""Orquesta impresoras, detección de eventos y notificaciones."""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

from .config import PrinterConfig, Settings
from .library.history import HistoryRecorder
from .library.queue import QueueManager
from .library.store import Store
from .catalog.service import CatalogService
from .slicer.orca import SliceManager
from .notify.events import Event, EventBus, EventDetector
from .notify.ntfy import NtfyNotifier
from .printer.base import BasePrinter
from .printer.lan import LanPrinter
from .printer.simulator import SimulatedPrinter

log = logging.getLogger(__name__)


def create_printer(cfg: PrinterConfig) -> BasePrinter:
    if cfg.mode == "simulator":
        return SimulatedPrinter(cfg)
    if not (cfg.host and cfg.serial and cfg.access_code):
        raise ValueError(f"Impresora {cfg.id}: faltan host, serial o access_code")
    return LanPrinter(cfg)


class PrinterManager:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.printers: dict[str, BasePrinter] = {}
        self.bus = EventBus()
        self._detectors: dict[str, EventDetector] = {}
        self._tasks: set[asyncio.Task] = set()
        self.ntfy = NtfyNotifier(settings.notifications.ntfy, snapshot=self.snapshot)
        self.bus.notifiers.append(self.ntfy)
        self.store = Store(Path(settings.data_dir))
        self.queue = QueueManager(self.store, self.printers, self.emit)
        self.slicer = SliceManager(self.store, self.printers)
        self.history = HistoryRecorder(self.store, self.printers, Path(settings.data_dir))
        self.catalog = CatalogService(settings.catalog, self.store)
        # Token de MakerWorld guardado desde la app (tiene prioridad sobre config.yaml)
        from .catalog.bambu_auth import load_secrets
        if tok := load_secrets(settings.data_dir).get("makerworld_token"):
            self.catalog.set_makerworld_token(tok)

    async def start(self) -> None:
        for cfg in self.settings.printers:
            try:
                printer = create_printer(cfg)
            except ValueError as e:
                log.error("%s", e)
                continue
            det = EventDetector(cfg.id, cfg.name, self.settings.notifications.progress_step)
            self._detectors[cfg.id] = det
            printer.add_listener(lambda snap, d=det: self._on_status(d, snap))
            # El historial se registra antes que la cola para asociar el trabajo activo
            printer.add_listener(lambda snap, pid=cfg.id: self.history.on_status(pid, snap))
            printer.add_listener(lambda snap, pid=cfg.id: self.queue.on_status(pid, snap))
            self.printers[cfg.id] = printer
            await printer.start()
            log.info("Impresora %s (%s, %s) iniciada", cfg.id, cfg.model, cfg.mode)
        self.queue.start()
        if not self.printers:
            log.warning("No hay impresoras configuradas. Ver docs/CONFIGURAR_A1.md")

    async def stop(self) -> None:
        await self.queue.stop()
        for p in self.printers.values():
            await p.stop()

    def _on_status(self, det: EventDetector, snap: dict) -> None:
        for ev in det.feed(snap):
            self.emit(ev)

    def emit(self, ev: Event) -> None:
        self.bus.publish(ev)
        log.info("Evento %s: %s - %s", ev.printer_id, ev.title, ev.message)
        for notifier in self.bus.notifiers:
            t = asyncio.create_task(notifier(ev))
            self._tasks.add(t)
            t.add_done_callback(self._tasks.discard)

    async def snapshot(self, printer_id: str) -> bytes | None:
        p = self.printers.get(printer_id)
        if not p:
            return None
        try:
            return await p.camera.snapshot(timeout=6)
        except Exception:  # noqa: BLE001
            return None
