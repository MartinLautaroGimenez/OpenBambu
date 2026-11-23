"""Editor 3D de placas: escena, mallas y guardado como proyecto 3MF."""

from __future__ import annotations

import asyncio
import copy
import threading
from collections import OrderedDict
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field

from ..library.ingest import ingest, safe_name
from ..library.scene import (
    Placement,
    Scene,
    SceneError,
    SceneObject,
    decimate,
    decode_png,
    mesh_bin,
    part_bbox,
    read_scene,
    write_project,
)
from ..library.threemf import InvalidFile
from ..manager import PrinterManager
from ..printer.models import CAPABILITIES
from .routes import auth, manager

router = APIRouter(prefix="/api", dependencies=[Depends(auth)])

EDITABLE = (".3mf", ".stl", ".obj")


class SceneCache:
    """Escenas leídas recientemente (leer un 3MF grande en la Pi tarda unos segundos)."""

    def __init__(self, size: int = 4):
        self.size = size
        self._data: OrderedDict[str, Scene] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, mgr: PrinterManager, lid: str, bed: tuple[float, float]) -> Scene:
        item = mgr.store.get_file(lid)
        if not item:
            raise HTTPException(404, "Archivo no encontrado")
        if item["meta"].get("sliced"):
            raise HTTPException(422, "Este archivo ya está laminado: editá el modelo original")
        if not item["filename"].lower().endswith(EDITABLE):
            raise HTTPException(422, "Este formato no se puede editar (STEP): laminalo directamente")
        with self._lock:
            if lid in self._data:
                self._data.move_to_end(lid)
                return self._data[lid]
        try:
            scene = read_scene(mgr.store.file_path(item), bed, item["name"])
        except (SceneError, OSError) as e:
            raise HTTPException(422, str(e)) from e
        with self._lock:
            self._data[lid] = scene
            while len(self._data) > self.size:
                self._data.popitem(last=False)
        return scene


CACHE = SceneCache()


def _bed(mgr: PrinterManager, printer_id: str | None) -> tuple[float, float]:
    p = mgr.printers.get(printer_id or "") or next(iter(mgr.printers.values()), None)
    size = CAPABILITIES[p.cfg.model].bed_size if p else (256, 256, 256)
    return float(size[0]), float(size[1])


def _cache_dir(mgr: PrinterManager, lid: str) -> Path:
    d = Path(mgr.settings.data_dir) / "cache" / "scene" / lid
    d.mkdir(parents=True, exist_ok=True)
    return d


def _describe(lid: str, scene: Scene) -> dict:
    objects = []
    for key, obj in scene.objects.items():
        los, his = zip(*(part_bbox(p) for p in obj.parts)) if obj.parts else ((), ())
        lo = [float(min(x[i] for x in los)) for i in range(3)] if los else [0, 0, 0]
        hi = [float(max(x[i] for x in his)) for i in range(3)] if his else [0, 0, 0]
        objects.append({
            "key": f"{lid}:{key}",
            "name": obj.name,
            "extruder": obj.extruder,
            "bbox": [lo, hi],
            "triangles": int(sum(len(p.triangles) for p in obj.parts)),
            "parts": [{"mesh": f"/api/scene/{lid}/{key}/{i}.bin", "transform": p.transform,
                       "extruder": p.extruder, "subtype": p.subtype, "painted": bool(p.paint)}
                      for i, p in enumerate(obj.parts)],
        })
    return {
        "library_id": lid,
        "plates": scene.plates,
        "objects": objects,
        "items": [{"key": f"{lid}:{it.key}", "plate": it.plate, "matrix": it.matrix, "extruder": it.extruder}
                  for it in scene.items],
        "filaments": scene.filaments,
        "has_settings": scene.settings is not None,
    }


@router.get("/library/{lid}/scene")
async def get_scene(lid: str, printer_id: str | None = None, mgr: PrinterManager = Depends(manager)):
    bed = _bed(mgr, printer_id)
    scene = await asyncio.to_thread(CACHE.get, mgr, lid, bed)
    item = mgr.store.get_file(lid)
    return {**_describe(lid, scene), "name": item["name"] if item else "", "source": item["source"] if item else "",
            "bed": {"w": bed[0], "d": bed[1]}}


@router.get("/scene/{lid}/{key}/{part}.bin")
async def scene_mesh(lid: str, key: str, part: int, mgr: PrinterManager = Depends(manager)):
    cached = _cache_dir(mgr, lid) / f"{safe_name(key)}_{part}.bin"
    if not cached.exists():
        scene = await asyncio.to_thread(CACHE.get, mgr, lid, _bed(mgr, None))
        obj = scene.objects.get(key)
        if not obj or not 0 <= part < len(obj.parts):
            raise HTTPException(404, "Pieza no encontrada")
        p = obj.parts[part]
        data = await asyncio.to_thread(lambda: mesh_bin(*decimate(p.vertices, p.triangles)))
        cached.write_bytes(data)
    return Response(cached.read_bytes(), media_type="application/octet-stream",
                    headers={"Cache-Control": "max-age=86400"})


class ItemIn(BaseModel):
    key: str
    plate: int = Field(1, ge=1, le=100)
    matrix: list[float] = Field(min_length=12, max_length=12)
    extruder: int | None = Field(None, ge=1, le=32)


class PlateIn(BaseModel):
    index: int = Field(ge=1, le=100)
    name: str = ""


class SaveIn(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    printer_id: str | None = None
    plates: list[PlateIn] = []
    items: list[ItemIn] = Field(min_length=1, max_length=500)
    thumbnails: dict[int, str] = {}
    # Reemplazar el archivo si el original ya salió del editor
    replace: bool = False


@router.post("/library/{lid}/scene")
async def save_scene(lid: str, body: SaveIn, mgr: PrinterManager = Depends(manager)):
    bed = _bed(mgr, body.printer_id)
    base = await asyncio.to_thread(CACHE.get, mgr, lid, bed)
    scenes: dict[str, Scene] = {lid: base}
    objects: dict[str, SceneObject] = {}
    items: list[Placement] = []
    for it in body.items:
        src, _, key = it.key.partition(":")
        if src not in scenes:
            scenes[src] = await asyncio.to_thread(CACHE.get, mgr, src, bed)
        obj = scenes[src].objects.get(key)
        if not obj:
            raise HTTPException(422, f"Pieza desconocida: {it.key}")
        # Un objeto por combinación de pieza y filamento (el filamento se guarda por objeto)
        ident = f"{it.key}#{it.extruder or ''}"
        if ident not in objects:
            o = copy.copy(obj)
            o.key = ident
            if it.extruder:
                o.extruder = it.extruder
                if len(obj.parts) == 1:
                    o.parts = [copy.copy(obj.parts[0])]
                    o.parts[0].extruder = None
            objects[ident] = o
        items.append(Placement(ident, it.plate, it.matrix, it.extruder))
    for it in items:
        lo, hi = _world_bbox(objects[it.key], it.matrix)
        if hi[2] > 400 or max(abs(lo[0]), abs(lo[1]), abs(hi[0]), abs(hi[1])) > 2000:
            raise HTTPException(422, "Hay piezas muy lejos de la cama")

    item = mgr.store.get_file(lid)
    replace = body.replace and item and item["source"].startswith("editor")
    thumbs = {k: png for k, v in body.thumbnails.items() if (png := decode_png(v))}
    plates = [p.model_dump() for p in body.plates] or base.plates
    if replace:
        new_lid, folder = lid, mgr.store.file_path(item).parent
    else:
        new_lid, folder = mgr.store.new_file_dir()
    filename = safe_name(body.name.replace("/", "-")) + ".3mf"
    tmp = folder / (filename + ".tmp")
    try:
        await asyncio.to_thread(write_project, tmp, objects, items, plates, bed, base.settings, thumbs, body.name)
    except SceneError as e:
        tmp.unlink(missing_ok=True)
        raise HTTPException(422, str(e)) from e
    if replace:
        for old in folder.iterdir():
            if old != tmp:
                old.unlink(missing_ok=True)
        mgr.store.delete_file(lid)
    tmp.rename(folder / filename)
    source = item["source"] if replace else f"editor:{lid}"
    try:
        new = ingest(mgr.store, new_lid, folder, filename, source, name=body.name,
                     extra_meta={"edited_from": (item or {}).get("meta", {}).get("edited_from") or lid,
                                 "catalog": (item or {}).get("meta", {}).get("catalog")})
    except InvalidFile as e:
        raise HTTPException(422, str(e)) from e
    with CACHE._lock:
        CACHE._data.pop(new_lid, None)
    import shutil
    shutil.rmtree(Path(mgr.settings.data_dir) / "cache" / "scene" / new_lid, ignore_errors=True)
    return new


def _world_bbox(obj: SceneObject, matrix: list[float]):
    from ..library.scene import apply

    pts = []
    for p in obj.parts:
        lo, hi = part_bbox(p)
        corners = [[x, y, z] for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2])]
        import numpy as np

        pts.append(apply(np.array(corners), matrix))
    import numpy as np

    allp = np.vstack(pts)
    return allp.min(0), allp.max(0)
