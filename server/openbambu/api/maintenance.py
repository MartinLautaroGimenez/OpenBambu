"""API de mantenimiento por impresora."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..manager import PrinterManager
from ..printer.base import BasePrinter
from .routes import auth, manager, printer

router = APIRouter(prefix="/api", dependencies=[Depends(auth)])


class TaskIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    interval_h: float = Field(gt=0, le=10000)
    notes: str = ""


class TaskPatch(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=120)
    interval_h: float | None = Field(None, gt=0, le=10000)
    notes: str | None = None


class DoneIn(BaseModel):
    notes: str = ""


def _task(mgr: PrinterManager, printer_id: str, task_id: int) -> dict:
    t = mgr.store.get_maintenance(task_id)
    if not t or t["printer_id"] != printer_id:
        raise HTTPException(404, "Tarea no encontrada")
    return t


@router.get("/maintenance")
async def all_maintenance(mgr: PrinterManager = Depends(manager)):
    """Resumen de todas las impresoras (para el panel)."""
    return [mgr.maintenance.overview(pid) for pid in mgr.printers]


@router.get("/printers/{printer_id}/maintenance")
async def get_maintenance(printer_id: str, p: BasePrinter = Depends(printer), mgr: PrinterManager = Depends(manager)):
    return mgr.maintenance.overview(printer_id)


@router.post("/printers/{printer_id}/maintenance")
async def add_task(printer_id: str, body: TaskIn, p: BasePrinter = Depends(printer),
                   mgr: PrinterManager = Depends(manager)):
    mgr.maintenance.ensure_defaults(printer_id)
    mgr.store.add_maintenance(printer_id, body.name, body.interval_h, mgr.store.printer_hours(printer_id),
                              body.notes)
    return mgr.maintenance.overview(printer_id)


@router.patch("/printers/{printer_id}/maintenance/{task_id}")
async def patch_task(printer_id: str, task_id: int, body: TaskPatch, p: BasePrinter = Depends(printer),
                     mgr: PrinterManager = Depends(manager)):
    _task(mgr, printer_id, task_id)
    mgr.store.update_maintenance(task_id, **body.model_dump(exclude_unset=True))
    return mgr.maintenance.overview(printer_id)


@router.delete("/printers/{printer_id}/maintenance/{task_id}")
async def delete_task(printer_id: str, task_id: int, p: BasePrinter = Depends(printer),
                      mgr: PrinterManager = Depends(manager)):
    _task(mgr, printer_id, task_id)
    mgr.store.delete_maintenance(task_id)
    return mgr.maintenance.overview(printer_id)


@router.post("/printers/{printer_id}/maintenance/{task_id}/done")
async def task_done(printer_id: str, task_id: int, body: DoneIn, p: BasePrinter = Depends(printer),
                    mgr: PrinterManager = Depends(manager)):
    _task(mgr, printer_id, task_id)
    mgr.maintenance.mark_done(task_id, body.notes)
    return mgr.maintenance.overview(printer_id)
