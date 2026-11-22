"""Laminado con OrcaSlicer en modo consola.

En la imagen Docker OrcaSlicer queda extraído en ``/opt/orca`` y se ejecuta
dentro de ``xvfb-run`` (necesita un display virtual para generar miniaturas).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import secrets
import shutil
import tempfile
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

import re

from ..library.ingest import safe_name
from ..library.threemf import InvalidFile, read_3mf, sanitize_project
from .profiles import MACHINE_FOR_MODEL, ProfileError, apply_overrides, get_library, write_profile

log = logging.getLogger(__name__)

BIN_CANDIDATES = ["/opt/orca/AppRun", "/opt/orca/squashfs-root/AppRun", "/usr/bin/orca-slicer"]
MESH_EXT = (".stl", ".obj", ".step", ".stp", ".3mf", ".amf")
SLICE_TIMEOUT = int(os.getenv("OB_SLICE_TIMEOUT", "1800"))


class SliceError(RuntimeError):
    pass


def orca_binary() -> str | None:
    for c in [os.getenv("OB_ORCA_BIN", ""), *BIN_CANDIDATES]:
        if c and os.access(c, os.X_OK):
            return c
    return None


def orca_version() -> str | None:
    f = Path("/opt/orca/VERSION")
    return f.read_text().strip() if f.exists() else None


@dataclass
class SliceJob:
    id: str
    library_id: str
    name: str
    printer_id: str
    status: str = "queued"  # queued | slicing | done | failed
    created: float = field(default_factory=time.time)
    started: float | None = None
    finished: float | None = None
    error: str | None = None
    result_id: str | None = None
    log_tail: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["elapsed"] = round((self.finished or time.time()) - (self.started or time.time()), 1) if self.started else 0
        return d


async def run_orca(
    inputs: list[Path],
    machine: dict,
    process: dict | None,
    filaments: list[dict],
    workdir: Path,
    on_line=None,
    plate: int = 0,
    arrange: bool = True,
    allow_newer: bool = False,
) -> Path:
    """Lamina ``inputs`` y devuelve la ruta del .gcode.3mf generado.

    ``plate`` 0 lamina todas las placas; ``process`` None conserva los ajustes del proyecto .3mf.
    """
    binary = orca_binary()
    if not binary:
        raise SliceError("OrcaSlicer no está instalado en el servidor")
    workdir.mkdir(parents=True, exist_ok=True)
    out = workdir / "out"
    out.mkdir(exist_ok=True)
    m = write_profile(machine, workdir / "machine.json")
    settings = [str(m)]
    if process is not None:
        settings.append(str(write_profile(process, workdir / "process.json", " (OpenBambu)")))
    fils = [write_profile(f, workdir / f"filament_{i}.json") for i, f in enumerate(filaments)]
    result = out / "result.gcode.3mf"
    result.unlink(missing_ok=True)

    cmd = [
        binary,
        "--slice", str(plate),
        *(["--arrange", "1"] if arrange else []),
        # Proyectos guardados con un Bambu Studio más nuevo que este OrcaSlicer
        *(["--allow-newer-file"] if allow_newer else []),
        "--load-settings", ";".join(settings),
        "--load-filaments", ";".join(str(f) for f in fils),
        "--outputdir", str(out),
        "--export-3mf", result.name,
        *[str(i) for i in inputs],
    ]
    if shutil.which("xvfb-run") and not os.getenv("DISPLAY"):
        cmd = ["xvfb-run", "-a", "-s", "-screen 0 1024x768x24", *cmd]
    log.info("Laminando: %s", " ".join(cmd))

    runtime = workdir / "xdg"
    runtime.mkdir(mode=0o700, exist_ok=True)
    env = {**os.environ, "HOME": str(workdir), "LC_ALL": "C.UTF-8", "APPIMAGE_EXTRACT_AND_RUN": "1",
           "XDG_RUNTIME_DIR": str(runtime)}
    proc = await asyncio.create_subprocess_exec(
        *cmd, cwd=workdir, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT
    )

    async def pump():
        assert proc.stdout
        async for raw in proc.stdout:
            line = raw.decode(errors="replace").rstrip()
            if line and on_line:
                on_line(line)

    try:
        await asyncio.wait_for(asyncio.gather(pump(), proc.wait()), SLICE_TIMEOUT)
    except asyncio.TimeoutError as e:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        raise SliceError("El laminado tardó demasiado") from e

    # OrcaSlicer deja un result.json con el código de error
    info = {}
    with contextlib.suppress(OSError, ValueError):
        info = json.loads((out / "result.json").read_text())
    if proc.returncode != 0 or not result.exists():
        msg = info.get("error_string") or info.get("message") or f"OrcaSlicer terminó con código {proc.returncode}"
        raise SliceError(translate_error(msg))
    return result


ERRORS_ES = {
    "Unsupported 3MF version": "El proyecto se guardó con una versión de Bambu Studio que OrcaSlicer no reconoce.",
    "Invalid parameter value(s) included in the 3mf": "El proyecto tiene ajustes con valores que OrcaSlicer no acepta.",
    "The selected printer is not compatible with the 3mf": "Este proyecto no se puede laminar para tu impresora.",
    "not compatible with the process preset in the 3mf":
        "Los ajustes del autor no son compatibles con tu impresora: desactivá «Usar los ajustes del autor».",
    "bed size is smaller": "La cama de tu impresora es más chica que la del proyecto.",
    "The plate has nothing to slice": "La placa está vacía o las piezas quedan fuera de la cama.",
    "Some objects are located over the boundary": "Hay piezas fuera de los bordes de la cama.",
    "Out of memory": "El servidor se quedó sin memoria laminando. Probá con una placa por vez.",
    "Failed slicing the model": "OrcaSlicer no pudo laminar el modelo.",
    "Objects conflicts were detected": "Hay piezas que se superponen.",
    "Object conflicts were detected": "Hay piezas que se superponen.",
    "Filaments are not compatible with the plate type": "El filamento no es compatible con el tipo de cama del proyecto.",
}


def translate_error(msg: str) -> str:
    for en, es in ERRORS_ES.items():
        if en.lower() in msg.lower():
            return f"{es} ({msg})"
    return msg


BAD_PARAM = re.compile(r"^\s*([a-z_0-9]+): .*not in range")


async def slice_file(
    src: Path,
    machine: dict,
    process: dict | None,
    filaments: list[dict],
    work: Path,
    plate: int = 0,
    copies: int = 1,
    on_line=None,
) -> Path:
    """Lamina un modelo o un proyecto .3mf.

    Los proyectos (.3mf de Bambu Studio / MakerWorld) conservan la distribución de sus placas;
    se limpian los ajustes que OrcaSlicer rechaza y, si igual falla por un valor fuera de
    rango, se quita ese ajuste y se reintenta.
    """
    is_project = src.name.lower().endswith(".3mf")
    if not is_project:
        return await run_orca([src] * max(1, copies), machine, process, filaments, work, on_line)
    if copies > 1:
        raise SliceError("Las copias se arman en la placa del proyecto; elegí 1 copia")

    drop: set[str] = set()
    lines: list[str] = []

    def collect(line: str) -> None:
        lines.append(line)
        if on_line:
            on_line(line)

    for attempt in range(4):
        work.mkdir(parents=True, exist_ok=True)
        clean = work / f"proyecto_{attempt}.3mf"
        removed = sanitize_project(src, clean, drop, any_printer=process is None)
        if removed:
            collect(f"OpenBambu: ajustes del proyecto ignorados: {', '.join(sorted(removed))}")
        lines.clear()
        try:
            return await run_orca([clean], machine, process, filaments, work / f"run{attempt}", collect,
                                  plate=plate, arrange=False, allow_newer=True)
        except SliceError:
            bad = {m[1] for line in lines if (m := BAD_PARAM.match(line))} - drop
            if not bad:
                raise
            drop |= bad
    raise SliceError("El proyecto tiene ajustes que OrcaSlicer no acepta")


class SliceManager:
    """Ejecuta los laminados de a uno (la Raspberry Pi tiene poca memoria)."""

    def __init__(self, store, printers):
        self.store = store
        self.printers = printers
        self.jobs: dict[str, SliceJob] = {}
        self.listeners: list = []
        self._lock = asyncio.Lock()
        self._tasks: set[asyncio.Task] = set()

    @staticmethod
    def available() -> bool:
        return orca_binary() is not None and get_library() is not None

    def machine_name(self, printer_id: str) -> str:
        p = self.printers.get(printer_id)
        if not p:
            raise ProfileError("Impresora no encontrada")
        return MACHINE_FOR_MODEL[p.cfg.model]

    def submit(self, item: dict, printer_id: str, process: str | None, filaments: list[str],
               overrides: dict, copies: int, plate: int = 0) -> SliceJob:
        lib = get_library()
        if lib is None or not orca_binary():
            raise SliceError("OrcaSlicer no está instalado en el servidor")
        machine_name = self.machine_name(printer_id)
        # Validar todo antes de encolar
        machine = lib.resolve(machine_name)
        # process None = usar los ajustes del proyecto .3mf (capa, soportes, relleno del autor)
        proc = apply_overrides(lib.resolve(process), overrides) if process else None
        if not filaments:
            raise ProfileError("Elegí al menos un filamento")
        fils = [lib.resolve(f) for f in filaments]
        src = self.store.file_path(item)
        if not src.name.lower().endswith(MESH_EXT):
            raise SliceError("Formato no soportado para laminar")
        is_project = src.name.lower().endswith(".3mf")
        if proc is None and not is_project:
            raise ProfileError("Elegí un perfil de calidad")
        if is_project and copies > 1:
            raise SliceError("Las copias se arman en la placa del proyecto; elegí 1 copia")

        name = item["name"]
        if plate:
            plates = item["meta"].get("project_plates") or []
            if len(plates) > 1:
                pl = next((p for p in plates if p["index"] == plate), None)
                name = f"{name} · {pl['name'] if pl and pl.get('name') else f'placa {plate}'}"
        job = SliceJob(secrets.token_hex(6), item["id"], name, printer_id)
        self.jobs[job.id] = job
        t = asyncio.create_task(self._run(job, src, machine, proc, fils, copies, overrides, plate))
        self._tasks.add(t)
        t.add_done_callback(self._tasks.discard)
        self._changed()
        return job

    def _changed(self) -> None:
        for fn in list(self.listeners):
            with contextlib.suppress(Exception):
                fn()

    async def _run(self, job: SliceJob, src: Path, machine, process, filaments, copies, overrides,
                   plate: int = 0) -> None:
        async with self._lock:
            job.status, job.started = "slicing", time.time()
            self._changed()
            work = Path(tempfile.mkdtemp(prefix="ob-slice-"))
            try:
                def on_line(line: str) -> None:
                    job.log_tail = (job.log_tail + [line])[-15:]

                result = await slice_file(src, machine, process, filaments, work, plate, copies, on_line)
                try:
                    meta = read_3mf(result)
                except InvalidFile as e:
                    raise SliceError("OrcaSlicer generó un archivo inválido") from e
                if not meta["sliced"]:
                    raise SliceError("OrcaSlicer no generó G-code")
                lid, folder = self.store.new_file_dir()
                suffix = f" ×{copies}" if copies > 1 else ""
                # El nombre del modelo puede traer "/" (p. ej. "Ratón chef / NO AMS"): no es una carpeta
                filename = safe_name(f"{job.name}{suffix}".replace("/", "-").replace("\\", "-") + ".gcode.3mf")
                shutil.move(str(result), folder / filename)
                meta["slice_settings"] = {
                    "process": process.get("name") if process else "Ajustes del proyecto",
                    "plate": plate or None,
                    "filaments": [f.get("name") for f in filaments],
                    "overrides": overrides,
                    "copies": copies,
                    "source": job.library_id,
                }
                item = self.store.insert_file(lid, f"{job.name}{suffix}", filename,
                                              (folder / filename).stat().st_size, f"slice:{job.library_id}", meta)
                job.result_id = item["id"]
                job.status = "done"
            except (SliceError, ProfileError) as e:
                job.status, job.error = "failed", str(e)
            except Exception as e:  # noqa: BLE001
                log.exception("Error laminando")
                job.status, job.error = "failed", f"Error inesperado: {e}"
            finally:
                job.finished = time.time()
                shutil.rmtree(work, ignore_errors=True)
                self._changed()
