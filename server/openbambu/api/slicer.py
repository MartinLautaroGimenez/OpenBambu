"""API del laminador (OrcaSlicer en el servidor)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..manager import PrinterManager
from ..slicer.orca import SliceError, orca_version
from ..slicer.profiles import ProfileError, get_library
from .routes import auth, manager

router = APIRouter(prefix="/api", dependencies=[Depends(auth)])


@router.get("/slicer")
async def slicer_status(mgr: PrinterManager = Depends(manager)):
    return {"available": mgr.slicer.available(), "engine": "OrcaSlicer", "version": orca_version()}


@router.get("/slicer/profiles")
async def slicer_profiles(printer_id: str, mgr: PrinterManager = Depends(manager)):
    lib = get_library()
    if lib is None:
        raise HTTPException(503, "Los perfiles de OrcaSlicer no están instalados")
    try:
        machine = mgr.slicer.machine_name(printer_id)
    except ProfileError as e:
        raise HTTPException(404, str(e)) from e
    processes = lib.processes(machine)
    default = next((p["name"] for p in processes if p["name"].startswith("0.20mm Standard")),
                   processes[0]["name"] if processes else None)

    # Filamento sugerido según lo que hay cargado (bandeja activa, o la primera cargada)
    status = mgr.printers[printer_id].state.snapshot()
    trays = [t for u in status["ams"]["units"] for t in u["trays"] if t["loaded"]]
    ext = status["ams"].get("external")
    if ext and ext.get("loaded"):
        trays.append(ext)
    active = next((t for t in trays if t["active"]), trays[0] if trays else None)
    suggested = lib.default_filament(machine, active["type"]) if active and active.get("type") else None
    suggested = suggested or lib.default_filament(machine, "PLA")
    return {
        "machine": machine,
        "processes": processes,
        "filaments": lib.filaments(machine),
        "default_process": default,
        "default_filament": suggested,
        "tray_filaments": [
            {"tray": t["global_id"], "type": t["type"], "color": t["color"],
             "profile": lib.default_filament(machine, t["type"] or "PLA")}
            for t in trays
        ],
    }


class OverridesIn(BaseModel):
    layer_height: float | None = None
    infill: int | None = Field(None, ge=0, le=100)
    infill_pattern: str | None = None
    walls: int | None = Field(None, ge=1, le=10)
    supports: str | None = None
    brim: bool | None = None


class SliceIn(BaseModel):
    printer_id: str
    process: str
    filaments: list[str]
    overrides: OverridesIn = OverridesIn()
    copies: int = Field(1, ge=1, le=30)


@router.post("/library/{lid}/slice")
async def slice_item(lid: str, body: SliceIn, mgr: PrinterManager = Depends(manager)):
    item = mgr.store.get_file(lid)
    if not item:
        raise HTTPException(404, "Archivo no encontrado")
    try:
        job = mgr.slicer.submit(item, body.printer_id, body.process, body.filaments,
                                body.overrides.model_dump(exclude_none=True), body.copies)
    except (SliceError, ProfileError) as e:
        raise HTTPException(422, str(e)) from e
    return job.to_dict()


@router.get("/slicer/jobs")
async def slice_jobs(mgr: PrinterManager = Depends(manager)):
    return sorted((j.to_dict() for j in mgr.slicer.jobs.values()), key=lambda j: -j["created"])[:20]


@router.get("/slicer/jobs/{job_id}")
async def slice_job(job_id: str, mgr: PrinterManager = Depends(manager)):
    job = mgr.slicer.jobs.get(job_id)
    if not job:
        raise HTTPException(404, "Trabajo de laminado no encontrado")
    return job.to_dict()
