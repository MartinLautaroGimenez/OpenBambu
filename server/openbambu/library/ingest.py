"""Alta de archivos en la biblioteca (subidas, SD, catálogo)."""

from __future__ import annotations

import re
import shutil
from pathlib import Path

from .store import Store
from .threemf import InvalidFile, read_3mf, read_project

UPLOAD_EXT = (".3mf", ".stl", ".obj", ".step", ".stp")


def safe_name(name: str) -> str:
    name = Path(name).name.strip()
    name = re.sub(r"[^\w.\- ()áéíóúñÁÉÍÓÚÑ]", "_", name)
    return name or "archivo.3mf"


def display_name(filename: str) -> str:
    for ext in (".gcode.3mf", ".3mf", ".gcode", ".stl", ".obj", ".step", ".stp"):
        if filename.lower().endswith(ext):
            return filename[: -len(ext)]
    return filename


def ingest(store: Store, lid: str, folder: Path, filename: str, source: str,
           name: str | None = None, extra_meta: dict | None = None) -> dict:
    """Registra un archivo ya guardado en ``folder``. Lanza InvalidFile si no sirve."""
    path = folder / filename
    if not filename.lower().endswith(".3mf"):
        # Modelo sin laminar (STL/OBJ/STEP): se lamina en el servidor
        meta = {"sliced": False, "plates": [], "format": Path(filename).suffix[1:].lower()}
    else:
        try:
            meta = read_3mf(path)
        except InvalidFile:
            shutil.rmtree(folder, ignore_errors=True)
            raise
        if not meta["sliced"]:
            meta["format"] = "3mf"
            meta.update(read_project(path))
    meta.update(extra_meta or {})
    return store.insert_file(lid, name or display_name(filename), filename, path.stat().st_size, source, meta)
