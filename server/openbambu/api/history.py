"""API de historial, estadísticas e inventario de filamento."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from ..library.history import compute_stats
from ..manager import PrinterManager
from .routes import auth, manager

router = APIRouter(prefix="/api", dependencies=[Depends(auth)])


# ---- historial ---------------------------------------------------------------
def _with_library(mgr: PrinterManager, p: dict) -> dict:
    p["reprintable"] = bool(p["library_id"] and mgr.store.get_file(p["library_id"]))
    p["timelapse"] = mgr.timelapse.video_path(p["id"]).exists()
    return p


@router.get("/history")
async def history(printer_id: str | None = None, limit: int = Query(30, le=200), offset: int = 0,
                  mgr: PrinterManager = Depends(manager)):
    return [_with_library(mgr, p) for p in mgr.store.prints(printer_id, limit, offset)]


@router.get("/history/stats")
async def stats(printer_id: str | None = None, months: int = Query(6, ge=1, le=24),
                mgr: PrinterManager = Depends(manager)):
    return compute_stats(mgr.store.prints(printer_id, 100000, 0), months)


@router.get("/history/{print_id}/snapshot.jpg")
async def history_snapshot(print_id: int, mgr: PrinterManager = Depends(manager)):
    path = mgr.history.snapshot_path(print_id)
    if not path.exists():
        raise HTTPException(404, "Sin foto")
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "max-age=604800"})


@router.delete("/history/{print_id}")
async def delete_history(print_id: int, mgr: PrinterManager = Depends(manager)):
    mgr.store.delete_print(print_id)
    mgr.history.snapshot_path(print_id).unlink(missing_ok=True)
    mgr.timelapse.video_path(print_id).unlink(missing_ok=True)
    return {"ok": True}


@router.get("/history/{print_id}/timelapse.mp4")
async def history_timelapse(print_id: int, mgr: PrinterManager = Depends(manager)):
    path = mgr.timelapse.video_path(print_id)
    if not path.exists():
        raise HTTPException(404, "Esta impresión no tiene timelapse")
    return FileResponse(path, media_type="video/mp4", filename=f"timelapse_{print_id}.mp4",
                        content_disposition_type="inline")


class TimelapseConfigIn(BaseModel):
    enabled: bool | None = None
    fps: int | None = Field(None, ge=5, le=60)


@router.get("/timelapse/config")
async def timelapse_config(mgr: PrinterManager = Depends(manager)):
    return {**mgr.timelapse.cfg.model_dump(), "available": mgr.timelapse.available()}


@router.put("/timelapse/config")
async def save_timelapse_config(body: TimelapseConfigIn, mgr: PrinterManager = Depends(manager)):
    mgr.timelapse.save(**body.model_dump())
    return {**mgr.timelapse.cfg.model_dump(), "available": mgr.timelapse.available()}


# ---- inventario de filamento ---------------------------------------------------
class SpoolIn(BaseModel):
    brand: str = ""
    material: str = Field(min_length=1, max_length=20)
    color: str | None = Field(None, pattern=r"^#[0-9A-Fa-f]{6}$")
    color_name: str = ""
    weight_g: float = Field(1000, gt=0, le=10000)
    remaining_g: float | None = Field(None, ge=0, le=10000)
    price: float = Field(0, ge=0)
    printer_id: str | None = None
    tray: int | None = None
    notes: str = ""


class SpoolPatch(BaseModel):
    brand: str | None = None
    material: str | None = None
    color: str | None = Field(None, pattern=r"^#[0-9A-Fa-f]{6}$")
    color_name: str | None = None
    weight_g: float | None = Field(None, gt=0, le=10000)
    remaining_g: float | None = Field(None, ge=0, le=10000)
    price: float | None = Field(None, ge=0)
    printer_id: str | None = None
    tray: int | None = None
    archived: bool | None = None
    notes: str | None = None
    unassign: bool = False


@router.get("/spools")
async def spools(archived: bool = False, mgr: PrinterManager = Depends(manager)):
    return mgr.store.spools(archived)


@router.post("/spools")
async def add_spool(body: SpoolIn, mgr: PrinterManager = Depends(manager)):
    data = body.model_dump()
    if data["remaining_g"] is None:
        data["remaining_g"] = data["weight_g"]
    data["material"] = data["material"].upper()
    if data["tray"] is not None and not data["printer_id"]:
        data["printer_id"] = next(iter(mgr.printers), None)
    return mgr.store.add_spool(**data)


@router.patch("/spools/{spool_id}")
async def update_spool(spool_id: int, body: SpoolPatch, mgr: PrinterManager = Depends(manager)):
    if not mgr.store.get_spool(spool_id):
        raise HTTPException(404, "Carrete no encontrado")
    data = body.model_dump(exclude_unset=True, exclude={"unassign"})
    if body.unassign:
        data["tray"] = None
    elif data.get("tray") is not None and not data.get("printer_id"):
        data["printer_id"] = (mgr.store.get_spool(spool_id) or {}).get("printer_id") or next(iter(mgr.printers), None)
    if data.get("material"):
        data["material"] = data["material"].upper()
    if "archived" in data:
        data["archived"] = int(data["archived"])
    return mgr.store.update_spool(spool_id, **data)


@router.delete("/spools/{spool_id}")
async def delete_spool(spool_id: int, mgr: PrinterManager = Depends(manager)):
    mgr.store.delete_spool(spool_id)
    return {"ok": True}
