"""Orquesta impresoras, detección de eventos y notificaciones."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
from pathlib import Path

from .config import PrinterConfig, Settings
from .library.history import HistoryRecorder
from .library.queue import QueueManager
from .library.store import Store
from .catalog.service import CatalogService
from .power import PowerManager
from .slicer.orca import SliceManager
from .notify.events import Event, EventBus, EventDetector
from .notify.ntfy import NtfyNotifier
from .printer.base import BasePrinter
from .printer.discovery import Discovery
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
        self.config_printers: set[str] = set()
        self.printer_listeners: list = []
        self._started = False
        self.discovery = Discovery()
        self.store = Store(Path(settings.data_dir))
        self.queue = QueueManager(self.store, self.printers, self.emit)
        self.slicer = SliceManager(self.store, self.printers)
        self.history = HistoryRecorder(self.store, self.printers, Path(settings.data_dir))
        self.power = PowerManager(settings.data_dir, self.printers, emit=self._power_event)
        self.queue.power = self.power
        self.catalog = CatalogService(settings.catalog, self.store)
        # Token de MakerWorld guardado desde la app (tiene prioridad sobre config.yaml)
        from .catalog.bambu_auth import load_secrets
        if tok := load_secrets(settings.data_dir).get("makerworld_token"):
            self.catalog.set_makerworld_token(tok)

    # ---- impresoras -------------------------------------------------------------
    @property
    def _printers_file(self) -> Path:
        return Path(self.settings.data_dir) / "printers.json"

    def _load_app_printers(self) -> list[PrinterConfig]:
        try:
            return [PrinterConfig.model_validate(x) for x in json.loads(self._printers_file.read_text())]
        except (OSError, ValueError) as e:
            if self._printers_file.exists():
                log.error("No se pudo leer %s: %s", self._printers_file, e)
            return []

    def _save_app_printers(self) -> None:
        data = [p.cfg.model_dump() for pid, p in self.printers.items() if pid not in self.config_printers]
        self._printers_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._printers_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=1))
        os.chmod(tmp, 0o600)
        tmp.replace(self._printers_file)

    async def add_printer(self, cfg: PrinterConfig, persist: bool = True) -> BasePrinter:
        if cfg.id in self.printers:
            raise ValueError(f"Ya existe una impresora con id {cfg.id}")
        printer = create_printer(cfg)
        det = EventDetector(cfg.id, cfg.name, self.settings.notifications.progress_step)
        self._detectors[cfg.id] = det
        printer.add_listener(lambda snap, d=det: self._on_status(d, snap))
        # El historial se registra antes que la cola para asociar el trabajo activo
        printer.add_listener(lambda snap, pid=cfg.id: self.history.on_status(pid, snap))
        printer.add_listener(lambda snap, pid=cfg.id: self.queue.on_status(pid, snap))
        printer.add_listener(lambda snap, pid=cfg.id: self.power.on_status(pid, snap))
        self.printers[cfg.id] = printer
        await printer.start()
        if self._started:
            self.queue.add_printer(cfg.id)
        if persist:
            self._save_app_printers()
            self._printers_changed()
        log.info("Impresora %s (%s, %s) iniciada", cfg.id, cfg.model, cfg.mode)
        return printer

    async def remove_printer(self, pid: str) -> None:
        if pid in self.config_printers:
            raise PermissionError("Esta impresora está definida en config.yaml; editala ahí")
        p = self.printers.pop(pid, None)
        if not p:
            raise KeyError(pid)
        self._detectors.pop(pid, None)
        await self.queue.remove_printer(pid)
        await p.stop()
        self._save_app_printers()
        self._printers_changed()

    async def update_printer(self, pid: str, cfg: PrinterConfig) -> BasePrinter:
        """Reemplaza la configuración (reconecta). El id no cambia."""
        if pid in self.config_printers:
            raise PermissionError("Esta impresora está definida en config.yaml; editala ahí")
        old = self.printers.get(pid)
        if not old:
            raise KeyError(pid)
        cfg = cfg.model_copy(update={"id": pid})
        create_printer(cfg)  # valida antes de tocar la que funciona
        await self.queue.remove_printer(pid)
        await old.stop()
        del self.printers[pid]
        return await self.add_printer(cfg)

    def _printers_changed(self) -> None:
        for fn in list(self.printer_listeners):
            with contextlib.suppress(Exception):
                fn()

    async def start(self) -> None:
        for cfg in self.settings.printers:
            self.config_printers.add(cfg.id)
        for cfg in [*self.settings.printers, *[c for c in self._load_app_printers()
                                               if c.id not in self.config_printers]]:
            try:
                await self.add_printer(cfg, persist=False)
            except ValueError as e:
                log.error("%s", e)
        self.queue.start()
        self._started = True
        await self.discovery.start()
        if not self.printers:
            log.warning("No hay impresoras configuradas: agregalas desde la app (Ajustes → Impresoras)")

    async def stop(self) -> None:
        await self.discovery.stop()
        await self.queue.stop()
        for p in self.printers.values():
            await p.stop()

    def _on_status(self, det: EventDetector, snap: dict) -> None:
        for ev in det.feed(snap):
            # Si la apagó OpenBambu (enchufe), no avisar "desconectada"
            if ev.type == "offline" and self.power.recently_powered_off(ev.printer_id):
                continue
            self.emit(ev)

    def _power_event(self, pid: str, type_: str, title: str, message: str) -> None:
        p = self.printers.get(pid)
        self.emit(Event(pid, p.cfg.name if p else pid, type_, title, message))

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
