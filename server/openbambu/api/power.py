"""API de energía (enchufe de Home Assistant)."""

from __future__ import annotations

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..manager import PrinterManager
from ..printer.base import BasePrinter
from .routes import auth, manager, printer

router = APIRouter(prefix="/api", dependencies=[Depends(auth)])


def _ha_error(e: Exception) -> HTTPException:
    if isinstance(e, PermissionError):
        return HTTPException(403, str(e))
    if isinstance(e, httpx.HTTPError):
        return HTTPException(502, "No se pudo conectar con Home Assistant")
    return HTTPException(422, str(e))


class PowerConfigIn(BaseModel):
    url: str | None = None
    token: str | None = None
    entities: dict[str, str] | None = None
    auto_off: bool | None = None
    auto_off_delay_min: int | None = Field(None, ge=0, le=240)
    auto_off_max_nozzle: int | None = Field(None, ge=30, le=120)
    auto_on_queue: bool | None = None


@router.get("/power/config")
async def get_config(mgr: PrinterManager = Depends(manager)):
    return mgr.power.public_config()


@router.put("/power/config")
async def put_config(body: PowerConfigIn, mgr: PrinterManager = Depends(manager)):
    data = body.model_dump()
    if data.get("url"):
        data["url"] = data["url"].strip().rstrip("/")
        if not data["url"].startswith(("http://", "https://")):
            data["url"] = "http://" + data["url"]
    mgr.power.save(**data)
    return mgr.power.public_config()


@router.get("/power/entities")
async def entities(mgr: PrinterManager = Depends(manager)):
    if not mgr.power.cfg.configured:
        raise HTTPException(422, "Configurá la URL y el token de Home Assistant")
    try:
        return await mgr.power.ha.entities()
    except Exception as e:  # noqa: BLE001
        raise _ha_error(e) from e


@router.get("/printers/{printer_id}/power")
async def power_status(printer_id: str, p: BasePrinter = Depends(printer), mgr: PrinterManager = Depends(manager)):
    return await mgr.power.status(printer_id)


class PowerIn(BaseModel):
    on: bool
    force: bool = False


@router.post("/printers/{printer_id}/power")
async def set_power(printer_id: str, body: PowerIn, p: BasePrinter = Depends(printer),
                    mgr: PrinterManager = Depends(manager)):
    if not body.on and not body.force and p.state.snapshot()["state"] in ("RUNNING", "PREPARE", "PAUSE"):
        raise HTTPException(409, "La impresora está imprimiendo")
    try:
        await mgr.power.set(printer_id, body.on)
    except Exception as e:  # noqa: BLE001
        raise _ha_error(e) from e
    return await mgr.power.status(printer_id)
