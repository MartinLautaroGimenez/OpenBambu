"""Interfaz común para impresoras (reales o simuladas)."""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import logging
import time
from abc import ABC, abstractmethod
from collections.abc import AsyncIterator, Callable

from ..config import PrinterConfig
from .models import CAPABILITIES
from .state import PrinterState

log = logging.getLogger(__name__)

Listener = Callable[[dict], None]


class BasePrinter(ABC):
    def __init__(self, cfg: PrinterConfig):
        self.cfg = cfg
        self.state = PrinterState(cfg.model)
        self.caps = CAPABILITIES[cfg.model]
        self._listeners: list[Listener] = []
        self._task: asyncio.Task | None = None
        self._seq = itertools.count(1)
        self.camera = CameraHub(self)

    # ---- ciclo de vida -------------------------------------------------
    async def start(self) -> None:
        self._task = asyncio.create_task(self._run(), name=f"printer-{self.cfg.id}")

    async def stop(self) -> None:
        await self.camera.close()
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task

    @abstractmethod
    async def _run(self) -> None: ...

    # ---- estado --------------------------------------------------------
    def add_listener(self, fn: Listener) -> Callable[[], None]:
        self._listeners.append(fn)
        return lambda: self._listeners.remove(fn) if fn in self._listeners else None

    def _emit(self) -> None:
        snap = self.state.snapshot()
        for fn in list(self._listeners):
            try:
                fn(snap)
            except Exception:  # noqa: BLE001
                log.exception("Error en listener")

    def info(self) -> dict:
        return {
            "id": self.cfg.id,
            "name": self.cfg.name,
            "model": self.cfg.model,
            "mode": self.cfg.mode,
            "serial": self.cfg.serial[-4:].rjust(len(self.cfg.serial), "•") if self.cfg.serial else "",
            "capabilities": self.caps.to_dict(),
        }

    # ---- comandos ------------------------------------------------------
    def next_seq(self) -> str:
        return str(next(self._seq))

    @abstractmethod
    async def send(self, payload: dict, wait: bool = True) -> dict:
        """Envía un comando. Devuelve {"result": "success"|"failed"|"sent"}."""

    # ---- cámara --------------------------------------------------------
    @abstractmethod
    def camera_frames(self) -> AsyncIterator[bytes]:
        """Genera frames JPEG desde la fuente de la cámara."""


class CameraHub:
    """Comparte una única conexión de cámara entre varios espectadores.

    La conexión se abre cuando aparece el primer espectador y se cierra
    automáticamente tras ``idle_timeout`` segundos sin espectadores.
    """

    def __init__(self, printer: BasePrinter, idle_timeout: float = 20.0):
        self.printer = printer
        self.idle_timeout = idle_timeout
        self.frame: bytes | None = None
        self.frame_at = 0.0
        self.error: str | None = None
        self._cond = asyncio.Condition()
        self._viewers = 0
        self._last_viewer = 0.0
        self._task: asyncio.Task | None = None

    def _ensure(self) -> None:
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._pump(), name=f"camera-{self.printer.cfg.id}")

    async def _pump(self) -> None:
        backoff = 2.0
        while True:
            try:
                async for jpg in self.printer.camera_frames():
                    self.error = None
                    backoff = 2.0
                    async with self._cond:
                        self.frame, self.frame_at = jpg, time.time()
                        self._cond.notify_all()
                    if self._viewers == 0 and time.time() - self._last_viewer > self.idle_timeout:
                        log.info("Cámara %s sin espectadores, cerrando", self.printer.cfg.id)
                        return
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                self.error = str(e) or type(e).__name__
                log.warning("Cámara %s: %s", self.printer.cfg.id, self.error)
            if self._viewers == 0 and time.time() - self._last_viewer > self.idle_timeout:
                return
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)

    async def snapshot(self, timeout: float = 8.0) -> bytes | None:
        self._last_viewer = time.time()
        if self.frame and time.time() - self.frame_at < 3:
            return self.frame
        self._ensure()
        async with self._cond:
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self._cond.wait(), timeout)
        return self.frame

    async def stream(self) -> AsyncIterator[bytes]:
        self._viewers += 1
        self._ensure()
        try:
            if self.frame:
                yield self.frame
            while True:
                jpg = None
                async with self._cond:
                    with contextlib.suppress(asyncio.TimeoutError):
                        await asyncio.wait_for(self._cond.wait(), 10)
                        jpg = self.frame
                if jpg:
                    yield jpg
                self._last_viewer = time.time()
                self._ensure()
        finally:
            self._viewers -= 1
            self._last_viewer = time.time()

    async def close(self) -> None:
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
