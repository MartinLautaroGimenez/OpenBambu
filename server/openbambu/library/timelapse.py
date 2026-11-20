"""Timelapse propio: una foto de la cámara por capa y un video al terminar.

Las fotos se guardan en ``data/timelapse/<id de impresión>/`` y al terminar se
arma ``data/timelapse/<id>.mp4`` con ffmpeg (luego se borran las fotos).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import shutil
from pathlib import Path

from pydantic import BaseModel, Field

log = logging.getLogger(__name__)


class TimelapseConfig(BaseModel):
    enabled: bool = True
    fps: int = Field(24, ge=5, le=60)
    # Segundos que se repite la última foto al final del video
    hold_s: float = Field(1.5, ge=0, le=5)


class TimelapseRecorder:
    def __init__(self, store, printers: dict, data_dir: Path):
        self.store = store
        self.printers = printers
        self.dir = Path(data_dir) / "timelapse"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.cfg_path = Path(data_dir) / "timelapse.json"
        self.cfg = self._load()
        self._layer: dict[str, int] = {}
        self._active: dict[str, int] = {}  # pid -> id de impresión que se está grabando
        self._tasks: set[asyncio.Task] = set()
        self._encode_lock = asyncio.Lock()
        self.listeners: list = []

    # ---- configuración ---------------------------------------------------------
    def _load(self) -> TimelapseConfig:
        try:
            return TimelapseConfig.model_validate(json.loads(self.cfg_path.read_text()))
        except (OSError, ValueError):
            return TimelapseConfig()

    def save(self, **changes) -> TimelapseConfig:
        self.cfg = TimelapseConfig.model_validate({**self.cfg.model_dump(),
                                                   **{k: v for k, v in changes.items() if v is not None}})
        self.cfg_path.write_text(json.dumps(self.cfg.model_dump()))
        return self.cfg

    def video_path(self, print_id: int) -> Path:
        return self.dir / f"{print_id}.mp4"

    def frames_dir(self, print_id: int) -> Path:
        return self.dir / str(print_id)

    @staticmethod
    def available() -> bool:
        return shutil.which("ffmpeg") is not None

    # ---- grabación ---------------------------------------------------------------
    def _spawn(self, coro) -> None:
        try:
            t = asyncio.get_running_loop().create_task(coro)
        except RuntimeError:
            coro.close()
            return
        self._tasks.add(t)
        t.add_done_callback(self._tasks.discard)

    def on_status(self, pid: str, snap: dict) -> None:
        state = snap["state"]
        rec = self.store.open_print(pid)
        if rec and state in ("RUNNING", "PAUSE"):
            if self.cfg.enabled and self._active.get(pid) != rec["id"]:
                self._active[pid] = rec["id"]
                self._layer[pid] = -1
            if self._active.get(pid) == rec["id"]:
                layer = snap["job"]["layer"]
                if layer > self._layer.get(pid, -1) and state == "RUNNING":
                    self._layer[pid] = layer
                    self._spawn(self._capture(pid, rec["id"], layer))
            return
        # Terminó (o se canceló): armar el video
        if pid in self._active and not rec:
            print_id = self._active.pop(pid)
            self._layer.pop(pid, None)
            self._spawn(self._finish(pid, print_id))

    async def _capture(self, pid: str, print_id: int, layer: int) -> None:
        p = self.printers.get(pid)
        if not p:
            return
        try:
            jpg = await p.camera.snapshot(timeout=8)
        except Exception:  # noqa: BLE001
            jpg = None
        if jpg:
            d = self.frames_dir(print_id)
            d.mkdir(parents=True, exist_ok=True)
            (d / f"{layer:05d}.jpg").write_bytes(jpg)

    async def _finish(self, pid: str, print_id: int) -> None:
        # Última foto con la pieza terminada
        p = self.printers.get(pid)
        if p and self.frames_dir(print_id).exists():
            with contextlib.suppress(Exception):
                await asyncio.sleep(2)
                if jpg := await p.camera.snapshot(timeout=8):
                    (self.frames_dir(print_id) / "99999.jpg").write_bytes(jpg)
        await self.encode(print_id)

    async def encode(self, print_id: int) -> Path | None:
        d = self.frames_dir(print_id)
        frames = sorted(d.glob("*.jpg")) if d.exists() else []
        if len(frames) < 5:
            shutil.rmtree(d, ignore_errors=True)
            return None
        if not self.available():
            log.warning("ffmpeg no está instalado: no se puede armar el timelapse")
            return None
        # Renumerar en orden y repetir la última foto para que el final se vea
        seq = d / "seq"
        seq.mkdir(exist_ok=True)
        hold = round(self.cfg.hold_s * self.cfg.fps)
        for i, f in enumerate(frames + [frames[-1]] * hold):
            target = seq / f"{i:06d}.jpg"
            if not target.exists():
                try:
                    os.link(f, target)
                except OSError:
                    shutil.copyfile(f, target)
        out = self.video_path(print_id)
        tmp = out.with_suffix(".tmp.mp4")
        cmd = ["nice", "-n", "15", "ffmpeg", "-y", "-loglevel", "error", "-framerate", str(self.cfg.fps),
               "-i", str(seq / "%06d.jpg"), "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264",
               "-preset", "veryfast", "-crf", "26", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(tmp)]
        if not shutil.which("nice"):
            cmd = cmd[3:]
        async with self._encode_lock:  # de a uno: la Pi tiene poca CPU
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.DEVNULL,
                                                        stderr=asyncio.subprocess.PIPE)
            _, err = await proc.communicate()
        if proc.returncode != 0 or not tmp.exists():
            log.warning("ffmpeg falló armando el timelapse %s: %s", print_id, err.decode()[-300:])
            tmp.unlink(missing_ok=True)
            return None
        tmp.replace(out)
        shutil.rmtree(d, ignore_errors=True)
        log.info("Timelapse %s listo (%d fotos)", print_id, len(frames))
        for fn in list(self.listeners):
            with contextlib.suppress(Exception):
                fn()
        return out
