"""API de biblioteca, tarjeta SD y cola de impresión."""

from __future__ import annotations

import posixpath
import shutil
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field

from ..library.mapping import suggest_mapping
from ..library.ingest import UPLOAD_EXT, ingest, safe_name
from ..library.threemf import InvalidFile, read_thumbnail
from ..manager import PrinterManager
from ..printer.base import BasePrinter
from .routes import auth, manager, printer

router = APIRouter(prefix="/api", dependencies=[Depends(auth)])

MAX_UPLOAD = 1024 * 1024 * 1024  # 1 GB


def _safe_name(name: str) -> str:
    return safe_name(name)


def _public(item: dict) -> dict:
    return item


def _ingest(mgr: PrinterManager, lid: str, folder: Path, filename: str, source: str) -> dict:
    try:
        return ingest(mgr.store, lid, folder, filename, source)
    except InvalidFile as e:
        raise HTTPException(422, str(e)) from e


# ---- biblioteca --------------------------------------------------------------
@router.get("/library")
async def list_library(mgr: PrinterManager = Depends(manager)):
    return [_public(x) for x in mgr.store.list_files()]


@router.put("/library")
async def upload_library(request: Request, filename: str = Query(...), mgr: PrinterManager = Depends(manager)):
    """Sube un archivo enviando el contenido crudo en el cuerpo del pedido."""
    filename = _safe_name(filename)
    if not filename.lower().endswith(UPLOAD_EXT):
        raise HTTPException(422, "Formatos aceptados: .3mf, .gcode.3mf, .stl, .obj, .step")
    lid, folder = mgr.store.new_file_dir()
    size = 0
    with open(folder / filename, "wb") as f:
        async for chunk in request.stream():
            size += len(chunk)
            if size > MAX_UPLOAD:
                f.close()
                shutil.rmtree(folder, ignore_errors=True)
                raise HTTPException(413, "Archivo demasiado grande")
            f.write(chunk)
    return _public(_ingest(mgr, lid, folder, filename, "upload"))


def _item(mgr: PrinterManager, lid: str) -> dict:
    item = mgr.store.get_file(lid)
    if not item:
        raise HTTPException(404, "Archivo no encontrado")
    return item


@router.get("/library/{lid}")
async def get_library_item(lid: str, mgr: PrinterManager = Depends(manager)):
    return _public(_item(mgr, lid))


@router.get("/library/{lid}/plates/{plate}/thumbnail.png")
async def thumbnail(lid: str, plate: int, mgr: PrinterManager = Depends(manager)):
    png = read_thumbnail(mgr.store.file_path(_item(mgr, lid)), plate)
    if not png:
        raise HTTPException(404, "Sin miniatura")
    return Response(png, media_type="image/png", headers={"Cache-Control": "max-age=86400"})


@router.get("/library/{lid}/plates/{plate}/preview")
async def gcode_preview(lid: str, plate: int, mgr: PrinterManager = Depends(manager)):
    """Trayectorias por capa para la vista previa del G-code."""
    import asyncio

    from ..library.preview import PreviewError, build_preview

    item = _item(mgr, lid)
    if not item["meta"].get("sliced"):
        raise HTTPException(422, "El archivo no está laminado")
    try:
        body = await asyncio.to_thread(build_preview, mgr.store.file_path(item), plate,
                                       Path(mgr.settings.data_dir) / "cache" / "preview")
    except PreviewError as e:
        raise HTTPException(422, str(e)) from e
    return Response(body, media_type="application/json", headers={"Cache-Control": "max-age=86400"})


@router.delete("/library/{lid}")
async def delete_library_item(lid: str, mgr: PrinterManager = Depends(manager)):
    item = _item(mgr, lid)
    for pid in mgr.printers:
        if any(j["library_id"] == lid and j["status"] in ("queued", "uploading", "starting", "printing")
               for j in mgr.store.jobs(pid)):
            raise HTTPException(409, "El archivo está en la cola de impresión")
    shutil.rmtree(mgr.store.file_path(item).parent, ignore_errors=True)
    mgr.store.delete_file(lid)
    return {"ok": True}


@router.get("/library/{lid}/mapping")
async def mapping(lid: str, printer_id: str, plate: int = 1, mgr: PrinterManager = Depends(manager)):
    item = _item(mgr, lid)
    p = mgr.printers.get(printer_id)
    if not p:
        raise HTTPException(404, "Impresora no encontrada")
    pl = next((x for x in item["meta"]["plates"] if x["index"] == plate), None)
    if not pl:
        raise HTTPException(404, "Placa no encontrada")
    return suggest_mapping(pl["filaments"], p.state.snapshot())


# ---- tarjeta SD ----------------------------------------------------------------
def _sd_path(path: str) -> str:
    norm = posixpath.normpath("/" + path.lstrip("/"))
    if ".." in norm.split("/"):
        raise HTTPException(422, "Ruta inválida")
    return norm


@router.get("/printers/{printer_id}/files")
async def list_sd(path: str = "/", p: BasePrinter = Depends(printer)):
    try:
        return await p.files.alist(_sd_path(path))
    except Exception as e:  # noqa: BLE001
        raise HTTPException(503, f"No se pudo leer la tarjeta SD: {e}") from e


@router.delete("/printers/{printer_id}/files")
async def delete_sd(path: str, p: BasePrinter = Depends(printer)):
    try:
        await p.files.adelete(_sd_path(path))
    except Exception as e:  # noqa: BLE001
        raise HTTPException(503, f"No se pudo borrar: {e}") from e
    return {"ok": True}


class ImportIn(BaseModel):
    path: str


@router.post("/printers/{printer_id}/files/import")
async def import_sd(body: ImportIn, p: BasePrinter = Depends(printer), mgr: PrinterManager = Depends(manager)):
    """Copia un archivo de la SD a la biblioteca (para ver placas y filamentos)."""
    remote = _sd_path(body.path)
    filename = _safe_name(posixpath.basename(remote))
    if not filename.lower().endswith(".3mf"):
        raise HTTPException(422, "Solo se pueden importar archivos .3mf")
    lid, folder = mgr.store.new_file_dir()
    try:
        await p.files.adownload(remote, folder / filename)
    except Exception as e:  # noqa: BLE001
        shutil.rmtree(folder, ignore_errors=True)
        raise HTTPException(503, f"No se pudo descargar: {e}") from e
    return _public(_ingest(mgr, lid, folder, filename, f"printer:{p.cfg.id}"))


# ---- omitir objetos ------------------------------------------------------------
class SkipIn(BaseModel):
    ids: list[int] = Field(min_length=1)


@router.get("/printers/{printer_id}/objects")
async def printing_objects(printer_id: str, p: BasePrinter = Depends(printer), mgr: PrinterManager = Depends(manager)):
    from ..library.objects import ObjectsError

    try:
        return await mgr.objects.objects(printer_id)
    except ObjectsError as e:
        raise HTTPException(409, str(e)) from e


@router.post("/printers/{printer_id}/objects/skip")
async def skip_objects(body: SkipIn, printer_id: str, p: BasePrinter = Depends(printer),
                       mgr: PrinterManager = Depends(manager)):
    from ..library.objects import ObjectsError

    try:
        await mgr.objects.skip(printer_id, body.ids)
        return await mgr.objects.objects(printer_id)
    except ObjectsError as e:
        raise HTTPException(422, str(e)) from e
    except ConnectionError as e:
        raise HTTPException(503, str(e)) from e


# ---- cola --------------------------------------------------------------------
class MappingIn(BaseModel):
    filament_id: int
    tray: int | None


class OptionsIn(BaseModel):
    bed_leveling: bool = True
    flow_cali: bool = False
    timelapse: bool = False
    vibration_cali: bool = False


class JobIn(BaseModel):
    library_id: str
    plate: int = 1
    mapping: list[MappingIn] = []
    options: OptionsIn = OptionsIn()
    copies: int = Field(1, ge=1, le=50)
    # Al frente de la cola y confirmando que la cama está libre
    start_now: bool = False
    bed_clear: bool = False
    # Hora de inicio programada (epoch en segundos); None = cuando la impresora esté libre
    start_after: float | None = None


@router.get("/printers/{printer_id}/queue")
async def get_queue(printer_id: str, p: BasePrinter = Depends(printer), mgr: PrinterManager = Depends(manager)):
    return mgr.queue.snapshot(printer_id)


@router.post("/printers/{printer_id}/queue")
async def add_job(body: JobIn, printer_id: str, p: BasePrinter = Depends(printer),
                  mgr: PrinterManager = Depends(manager)):
    item = _item(mgr, body.library_id)
    plate = next((x for x in item["meta"]["plates"] if x["index"] == body.plate), None)
    if not plate:
        raise HTTPException(422, "Ese archivo no tiene esa placa laminada")
    mapped = {m.filament_id: m.tray for m in body.mapping}
    missing = [f["id"] for f in plate["filaments"] if mapped.get(f["id"]) is None]
    if missing:
        raise HTTPException(422, f"Falta asignar bandeja a los filamentos {missing}")
    if body.start_after is not None:
        import time as _t
        if body.start_now:
            raise HTTPException(422, "Elegí imprimir ya o programar, no las dos")
        if body.start_after < _t.time() - 60 or body.start_after > _t.time() + 30 * 86400:
            raise HTTPException(422, "La hora programada tiene que ser en los próximos 30 días")
    if body.start_now and p.state.snapshot()["state"] in ("RUNNING", "PAUSE", "PREPARE"):
        raise HTTPException(409, "La impresora está ocupada; agregalo a la cola")

    name = item["name"] + (f" (placa {body.plate})" if len(item["meta"]["plates"]) > 1 else "")
    jobs = []
    for i in range(body.copies):
        label = f"{name} · copia {i + 1}/{body.copies}" if body.copies > 1 else name
        # Con start_now, las copias van al frente manteniendo su orden
        jobs.append(mgr.store.add_job(printer_id, item["id"], label, body.plate,
                                      [m.model_dump() for m in body.mapping], body.options.model_dump(),
                                      front=False, start_after=body.start_after))
    if body.start_now:
        ids = [j["id"] for j in jobs] + [j["id"] for j in mgr.store.jobs(printer_id)
                                          if j["status"] == "queued" and j["id"] not in {x["id"] for x in jobs}]
        mgr.store.reorder(printer_id, ids)
        mgr.store.set_queue_state(printer_id, paused=False)
    if body.bed_clear or body.start_now:
        mgr.queue.confirm_bed_clear(printer_id)
    mgr.queue.changed(printer_id)
    mgr.queue.wake(printer_id)
    return mgr.queue.snapshot(printer_id)


@router.delete("/printers/{printer_id}/queue/{job_id}")
async def delete_job(printer_id: str, job_id: int, p: BasePrinter = Depends(printer),
                     mgr: PrinterManager = Depends(manager)):
    job = mgr.store.get_job(job_id)
    if not job or job["printer_id"] != printer_id:
        raise HTTPException(404, "Trabajo no encontrado")
    if job["status"] in ("uploading", "starting", "printing"):
        raise HTTPException(409, "El trabajo está en curso; detené la impresión primero")
    mgr.store.delete_job(job_id)
    mgr.queue.changed(printer_id)
    return mgr.queue.snapshot(printer_id)


class ReorderIn(BaseModel):
    ids: list[int]


@router.post("/printers/{printer_id}/queue/reorder")
async def reorder(body: ReorderIn, printer_id: str, p: BasePrinter = Depends(printer),
                  mgr: PrinterManager = Depends(manager)):
    mgr.store.reorder(printer_id, body.ids)
    mgr.queue.changed(printer_id)
    return mgr.queue.snapshot(printer_id)


@router.post("/printers/{printer_id}/queue/bed-clear")
async def bed_clear(printer_id: str, p: BasePrinter = Depends(printer), mgr: PrinterManager = Depends(manager)):
    mgr.queue.confirm_bed_clear(printer_id)
    return mgr.queue.snapshot(printer_id)


class PauseIn(BaseModel):
    paused: bool


@router.post("/printers/{printer_id}/queue/pause")
async def pause_queue(body: PauseIn, printer_id: str, p: BasePrinter = Depends(printer),
                      mgr: PrinterManager = Depends(manager)):
    mgr.queue.set_paused(printer_id, body.paused)
    return mgr.queue.snapshot(printer_id)


@router.delete("/printers/{printer_id}/queue")
async def clear_history(printer_id: str, p: BasePrinter = Depends(printer), mgr: PrinterManager = Depends(manager)):
    mgr.store.clear_history(printer_id)
    mgr.queue.changed(printer_id)
    return mgr.queue.snapshot(printer_id)

