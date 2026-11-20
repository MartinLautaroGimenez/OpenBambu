"""Alta, edición y baja de impresoras desde la app, y descubrimiento en la red."""

from __future__ import annotations

import re
import unicodedata

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..config import PrinterConfig, PrinterModel
from ..manager import PrinterManager
from ..printer.discovery import test_connection
from .routes import auth, manager

router = APIRouter(prefix="/api", dependencies=[Depends(auth)])


def _public(mgr: PrinterManager, pid: str) -> dict:
    p = mgr.printers[pid]
    c = p.cfg
    return {
        "id": c.id, "name": c.name, "model": c.model, "host": c.host, "serial": c.serial, "mode": c.mode,
        "has_access_code": bool(c.access_code), "editable": pid not in mgr.config_printers,
        "connected": p.state.connected,
    }


def _slug(name: str, taken: set[str]) -> str:
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")[:24] or "impresora"
    base, i = s, 2
    while s in taken:
        s, i = f"{base}-{i}", i + 1
    return s


class PrinterIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    model: PrinterModel = "A1"
    mode: str = Field("lan", pattern="^(lan|simulator)$")
    host: str = ""
    serial: str = ""
    access_code: str = ""  # vacío al editar = mantener el actual


def _validate(body: PrinterIn) -> None:
    if body.mode == "lan":
        if not re.fullmatch(r"[A-Za-z0-9.\-]+", body.host.strip()):
            raise HTTPException(422, "Ingresá la IP de la impresora")
        if not re.fullmatch(r"[A-Za-z0-9]{8,20}", body.serial.strip()):
            raise HTTPException(422, "Número de serie inválido")


@router.get("/admin/printers")
async def list_printers(mgr: PrinterManager = Depends(manager)):
    return [_public(mgr, pid) for pid in mgr.printers]


@router.post("/admin/printers")
async def add_printer(body: PrinterIn, mgr: PrinterManager = Depends(manager)):
    _validate(body)
    if body.mode == "lan" and not re.fullmatch(r"\S{4,32}", body.access_code.strip()):
        raise HTTPException(422, "Ingresá el código de acceso")
    if body.mode == "lan" and any(p.cfg.serial == body.serial.strip() for p in mgr.printers.values()):
        raise HTTPException(409, "Esa impresora ya está agregada")
    cfg = PrinterConfig(id=_slug(body.name, set(mgr.printers)), name=body.name.strip(), model=body.model,
                        mode=body.mode, host=body.host.strip(), serial=body.serial.strip().upper(),
                        access_code=body.access_code.strip())
    try:
        await mgr.add_printer(cfg)
    except ValueError as e:
        raise HTTPException(422, str(e)) from e
    return _public(mgr, cfg.id)


@router.put("/admin/printers/{printer_id}")
async def update_printer(printer_id: str, body: PrinterIn, mgr: PrinterManager = Depends(manager)):
    p = mgr.printers.get(printer_id)
    if not p:
        raise HTTPException(404, "Impresora no encontrada")
    _validate(body)
    cfg = PrinterConfig(id=printer_id, name=body.name.strip(), model=body.model, mode=body.mode,
                        host=body.host.strip(), serial=body.serial.strip().upper(),
                        access_code=body.access_code.strip() or p.cfg.access_code)
    try:
        await mgr.update_printer(printer_id, cfg)
    except PermissionError as e:
        raise HTTPException(403, str(e)) from e
    except ValueError as e:
        raise HTTPException(422, str(e)) from e
    return _public(mgr, printer_id)


@router.delete("/admin/printers/{printer_id}")
async def delete_printer(printer_id: str, mgr: PrinterManager = Depends(manager)):
    try:
        await mgr.remove_printer(printer_id)
    except PermissionError as e:
        raise HTTPException(403, str(e)) from e
    except KeyError as e:
        raise HTTPException(404, "Impresora no encontrada") from e
    return {"ok": True}


class TestIn(BaseModel):
    host: str
    serial: str
    access_code: str = ""
    printer_id: str | None = None  # para probar con el código guardado


@router.post("/admin/printers/test")
async def test_printer(body: TestIn, mgr: PrinterManager = Depends(manager)):
    code = body.access_code.strip()
    if not code and body.printer_id and body.printer_id in mgr.printers:
        code = mgr.printers[body.printer_id].cfg.access_code
    if not (body.host.strip() and body.serial.strip() and code):
        raise HTTPException(422, "Completá IP, número de serie y código de acceso")
    return await test_connection(body.host.strip(), body.serial.strip().upper(), code)


@router.get("/admin/discovery")
async def discovery(mgr: PrinterManager = Depends(manager)):
    mgr.discovery.search()
    known = {p.cfg.serial for p in mgr.printers.values()}
    return {
        "error": mgr.discovery.error,
        "printers": [{**d, "added": d["serial"] in known} for d in mgr.discovery.printers()],
    }
