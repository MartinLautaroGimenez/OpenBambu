"""API de historial, estadísticas e inventario de filamento."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, Field

from ..library.history import REJECT_REASONS, compute_stats
from ..library.labels import parse_code, render_label
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
                  project_id: int | None = None, unrated: bool = False, mgr: PrinterManager = Depends(manager)):
    return [_with_library(mgr, p) for p in mgr.store.prints(printer_id, limit, offset, project_id, unrated)]


@router.get("/history/stats")
async def stats(printer_id: str | None = None, months: int = Query(6, ge=1, le=24),
                mgr: PrinterManager = Depends(manager)):
    return compute_stats(mgr.store.prints(printer_id, 100000, 0), months)


@router.get("/history/reject-reasons")
async def reject_reasons():
    return [{"id": k, "label": v} for k, v in REJECT_REASONS.items()]


class RatingIn(BaseModel):
    rating: str | None = Field(None, pattern="^(good|bad)$")
    reason: str | None = None


@router.post("/history/{print_id}/rating")
async def rate(print_id: int, body: RatingIn, mgr: PrinterManager = Depends(manager)):
    rec = mgr.store.get_print(print_id)
    if not rec:
        raise HTTPException(404, "Impresión no encontrada")
    if body.rating and rec["status"] == "printing":
        raise HTTPException(409, "Todavía se está imprimiendo")
    reason = body.reason if body.rating == "bad" and body.reason in REJECT_REASONS else None
    mgr.store.update_print(print_id, rating=body.rating, rating_reason=reason)
    mgr.history._changed()
    return _with_library(mgr, mgr.store.get_print(print_id))  # type: ignore[arg-type]


class PrintPatch(BaseModel):
    project_id: int | None = None
    name: str | None = Field(None, min_length=1, max_length=200)


@router.patch("/history/{print_id}")
async def patch_print(print_id: int, body: PrintPatch, mgr: PrinterManager = Depends(manager)):
    if not mgr.store.get_print(print_id):
        raise HTTPException(404, "Impresión no encontrada")
    data = body.model_dump(exclude_unset=True)
    if data.get("project_id") is not None and not mgr.store.get_project(data["project_id"]):
        raise HTTPException(422, "El proyecto no existe")
    if data:
        mgr.store.update_print(print_id, **data)
        mgr.history._changed()
    return _with_library(mgr, mgr.store.get_print(print_id))  # type: ignore[arg-type]


# ---- proyectos -------------------------------------------------------------------
class ProjectIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    color: str | None = Field(None, pattern=r"^#[0-9A-Fa-f]{6}$")
    notes: str = ""
    target: int | None = Field(None, ge=1, le=10000)


class ProjectPatch(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=120)
    color: str | None = Field(None, pattern=r"^#[0-9A-Fa-f]{6}$")
    notes: str | None = None
    target: int | None = Field(None, ge=1, le=10000)
    archived: bool | None = None


def _project_summary(mgr: PrinterManager, proj: dict) -> dict:
    prints = mgr.store.prints(limit=100000, project_id=proj["id"])
    st = compute_stats(prints, 1)
    ok = st["done"] - st["rated_bad"]
    last = max((p["started"] for p in prints), default=None)
    active = sum(1 for p in prints if p["status"] == "printing")
    queued = sum(1 for pid in mgr.printers for j in mgr.store.jobs(pid, 0)
                 if j["status"] == "queued" and j["options"].get("project_id") == proj["id"])
    return {
        **proj, "archived": bool(proj["archived"]),
        "prints": st["total"], "ok": ok, "failed": st["total"] - ok, "printing": active, "queued": queued,
        "hours": st["hours"], "grams": st["grams"], "cost": st["cost"],
        "energy_kwh": st["energy_kwh"], "energy_cost": st["energy_cost"],
        "progress": round(min(ok / proj["target"], 1) * 100) if proj["target"] else None,
        "last_print": last,
        "thumbnail_print": next((p["id"] for p in prints if p["snapshot"]), None),
    }


@router.get("/projects")
async def projects(archived: bool = False, mgr: PrinterManager = Depends(manager)):
    return [_project_summary(mgr, p) for p in mgr.store.projects(archived)]


@router.post("/projects")
async def add_project(body: ProjectIn, mgr: PrinterManager = Depends(manager)):
    proj = mgr.store.add_project(**body.model_dump())
    mgr.history._changed()
    return _project_summary(mgr, proj)


@router.get("/projects/{project_id}")
async def get_project(project_id: int, mgr: PrinterManager = Depends(manager)):
    proj = mgr.store.get_project(project_id)
    if not proj:
        raise HTTPException(404, "Proyecto no encontrado")
    return _project_summary(mgr, proj)


@router.patch("/projects/{project_id}")
async def patch_project(project_id: int, body: ProjectPatch, mgr: PrinterManager = Depends(manager)):
    if not mgr.store.get_project(project_id):
        raise HTTPException(404, "Proyecto no encontrado")
    data = body.model_dump(exclude_unset=True)
    if "archived" in data:
        data["archived"] = int(data["archived"])
    proj = mgr.store.update_project(project_id, **data)
    mgr.history._changed()
    return _project_summary(mgr, proj)  # type: ignore[arg-type]


@router.delete("/projects/{project_id}")
async def delete_project(project_id: int, mgr: PrinterManager = Depends(manager)):
    mgr.store.delete_project(project_id)
    mgr.history._changed()
    return {"ok": True}


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


@router.get("/spools/{spool_id}/label.png")
async def spool_label(spool_id: int, mgr: PrinterManager = Depends(manager)):
    spool = mgr.store.get_spool(spool_id)
    if not spool:
        raise HTTPException(404, "Carrete no encontrado")
    return Response(render_label(spool), media_type="image/png",
                    headers={"Content-Disposition": f'inline; filename="carrete_{spool_id}.png"'})


@router.get("/spools/by-code")
async def spool_by_code(code: str, mgr: PrinterManager = Depends(manager)):
    sid = parse_code(code)
    spool = mgr.store.get_spool(sid) if sid is not None else None
    if not spool:
        raise HTTPException(404, "Ese código no corresponde a ningún carrete")
    return spool


@router.delete("/spools/{spool_id}")
async def delete_spool(spool_id: int, mgr: PrinterManager = Depends(manager)):
    mgr.store.delete_spool(spool_id)
    return {"ok": True}
