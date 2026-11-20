"""API REST, WebSocket y cámara."""

from __future__ import annotations

import asyncio
import contextlib
import json
import secrets
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel, Field

from .. import __version__
from ..manager import PrinterManager
from ..notify.events import Event
from ..printer import commands as C
from ..printer.base import BasePrinter

router = APIRouter(prefix="/api")

PRINTING = ("RUNNING", "PAUSE", "PREPARE")


# ---- dependencias ------------------------------------------------------
def manager(request: Request) -> PrinterManager:
    return request.app.state.manager


def _check_token(mgr: PrinterManager, token: str | None) -> None:
    if not token or not secrets.compare_digest(token, mgr.settings.api_token):
        raise HTTPException(401, "Token inválido")


def auth(request: Request, token: str | None = Query(None)) -> None:
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        token = header[7:]
    _check_token(manager(request), token)


def printer(printer_id: str, request: Request) -> BasePrinter:
    p = manager(request).printers.get(printer_id)
    if not p:
        raise HTTPException(404, "Impresora no encontrada")
    return p


async def run(p: BasePrinter, payload: dict) -> dict:
    try:
        return await p.send(payload)
    except ConnectionError as e:
        raise HTTPException(503, str(e)) from e


def build(fn, *args):
    try:
        return fn(*args)
    except C.CommandError as e:
        raise HTTPException(422, str(e)) from e


def require_idle(p: BasePrinter) -> None:
    if p.state.snapshot()["state"] in PRINTING:
        raise HTTPException(409, "No disponible mientras se imprime")


# ---- modelos de entrada ------------------------------------------------
class SpeedIn(BaseModel):
    level: int = Field(ge=1, le=4)


class TempIn(BaseModel):
    target: Literal["nozzle", "bed"]
    value: int = Field(ge=0, le=350)


class FanIn(BaseModel):
    fan: Literal["part", "aux", "chamber"]
    percent: int = Field(ge=0, le=100)


class LightIn(BaseModel):
    on: bool


class MoveIn(BaseModel):
    axis: Literal["X", "Y", "Z", "x", "y", "z"]
    distance: float


class ExtrudeIn(BaseModel):
    distance: float


class GcodeIn(BaseModel):
    gcode: str = Field(min_length=1, max_length=4000)


class TrayIn(BaseModel):
    tray: int


class AmsControlIn(BaseModel):
    action: Literal["resume", "reset", "pause"]


class FilamentIn(BaseModel):
    tray: int
    type: str
    color: str
    nozzle_min: int | None = None
    nozzle_max: int | None = None


# ---- endpoints ---------------------------------------------------------
@router.get("/health")
async def health():
    return {"name": "OpenBambu", "version": __version__}


@router.get("/printers", dependencies=[Depends(auth)])
async def list_printers(mgr: PrinterManager = Depends(manager)):
    return [{**p.info(), "status": p.state.snapshot()} for p in mgr.printers.values()]


@router.get("/printers/{printer_id}", dependencies=[Depends(auth)])
async def get_printer(p: BasePrinter = Depends(printer)):
    return {**p.info(), "status": p.state.snapshot()}


@router.get("/printers/{printer_id}/status", dependencies=[Depends(auth)])
async def get_status(p: BasePrinter = Depends(printer)):
    return p.state.snapshot()


@router.post("/printers/{printer_id}/refresh", dependencies=[Depends(auth)])
async def refresh(p: BasePrinter = Depends(printer)):
    return await run(p, C.pushall())


@router.post("/printers/{printer_id}/print/{action}", dependencies=[Depends(auth)])
async def print_action(action: Literal["pause", "resume", "stop"], p: BasePrinter = Depends(printer)):
    return await run(p, {"pause": C.pause, "resume": C.resume, "stop": C.stop}[action]())


@router.post("/printers/{printer_id}/speed", dependencies=[Depends(auth)])
async def speed(body: SpeedIn, p: BasePrinter = Depends(printer)):
    return await run(p, build(C.print_speed, body.level))


@router.post("/printers/{printer_id}/temperature", dependencies=[Depends(auth)])
async def temperature(body: TempIn, p: BasePrinter = Depends(printer)):
    return await run(p, build(C.set_temperature, p.cfg.model, body.target, body.value))


@router.post("/printers/{printer_id}/fan", dependencies=[Depends(auth)])
async def fan(body: FanIn, p: BasePrinter = Depends(printer)):
    return await run(p, build(C.set_fan, p.cfg.model, body.fan, body.percent))


@router.post("/printers/{printer_id}/light", dependencies=[Depends(auth)])
async def light(body: LightIn, p: BasePrinter = Depends(printer)):
    return await run(p, C.light(body.on))


@router.post("/printers/{printer_id}/home", dependencies=[Depends(auth)])
async def home(p: BasePrinter = Depends(printer)):
    require_idle(p)
    return await run(p, C.home())


@router.post("/printers/{printer_id}/move", dependencies=[Depends(auth)])
async def move(body: MoveIn, p: BasePrinter = Depends(printer)):
    require_idle(p)
    return await run(p, build(C.move, body.axis, body.distance))


@router.post("/printers/{printer_id}/extrude", dependencies=[Depends(auth)])
async def extrude(body: ExtrudeIn, p: BasePrinter = Depends(printer)):
    require_idle(p)
    if p.state.snapshot()["temps"]["nozzle"] < 170:
        raise HTTPException(409, "La boquilla debe estar a más de 170 °C para extruir")
    return await run(p, build(C.extrude, body.distance))


@router.post("/printers/{printer_id}/gcode", dependencies=[Depends(auth)])
async def gcode(body: GcodeIn, p: BasePrinter = Depends(printer)):
    require_idle(p)
    return await run(p, C.gcode(body.gcode))


@router.post("/printers/{printer_id}/ams/load", dependencies=[Depends(auth)])
async def ams_load(body: TrayIn, p: BasePrinter = Depends(printer)):
    require_idle(p)
    return await run(p, build(C.ams_load, body.tray))


@router.post("/printers/{printer_id}/ams/unload", dependencies=[Depends(auth)])
async def ams_unload(p: BasePrinter = Depends(printer)):
    require_idle(p)
    return await run(p, C.ams_unload())


@router.post("/printers/{printer_id}/ams/control", dependencies=[Depends(auth)])
async def ams_control(body: AmsControlIn, p: BasePrinter = Depends(printer)):
    return await run(p, build(C.ams_control, body.action))


@router.post("/printers/{printer_id}/ams/filament", dependencies=[Depends(auth)])
async def ams_filament(body: FilamentIn, p: BasePrinter = Depends(printer)):
    return await run(
        p, build(C.ams_filament_setting, body.tray, body.type, body.color, body.nozzle_min, body.nozzle_max)
    )


# ---- cámara ------------------------------------------------------------
@router.get("/printers/{printer_id}/camera/snapshot.jpg", dependencies=[Depends(auth)])
async def camera_snapshot(p: BasePrinter = Depends(printer)):
    jpg = await p.camera.snapshot()
    if not jpg:
        raise HTTPException(503, p.camera.error or "Cámara no disponible")
    return Response(jpg, media_type="image/jpeg", headers={"Cache-Control": "no-store"})


BOUNDARY = "openbambuframe"


@router.get("/printers/{printer_id}/camera/stream.mjpg", dependencies=[Depends(auth)])
async def camera_stream(p: BasePrinter = Depends(printer)):
    async def gen():
        async for jpg in p.camera.stream():
            yield (
                f"--{BOUNDARY}\r\nContent-Type: image/jpeg\r\nContent-Length: {len(jpg)}\r\n\r\n".encode()
                + jpg
                + b"\r\n"
            )

    return StreamingResponse(
        gen(),
        media_type=f"multipart/x-mixed-replace; boundary={BOUNDARY}",
        headers={"Cache-Control": "no-store"},
    )


# ---- eventos y notificaciones -----------------------------------------
@router.get("/events", dependencies=[Depends(auth)])
async def events(after: int = 0, printer_id: str | None = None, limit: int = Query(100, le=300),
                 mgr: PrinterManager = Depends(manager)):
    return mgr.bus.since(after, printer_id, limit)


@router.post("/notifications/test", dependencies=[Depends(auth)])
async def test_notification(mgr: PrinterManager = Depends(manager)):
    pid, name = next(((p.cfg.id, p.cfg.name) for p in mgr.printers.values()), ("-", "OpenBambu"))
    ev = Event(pid, name, "test", "Notificación de prueba", "Si ves esto, las notificaciones funcionan 🎉")
    mgr.emit(ev)
    return ev.to_dict()


# ---- WebSocket ---------------------------------------------------------
@router.websocket("/ws")
async def websocket(ws: WebSocket, token: str | None = None):
    mgr: PrinterManager = ws.app.state.manager
    try:
        _check_token(mgr, token)
    except HTTPException:
        await ws.close(code=4401)
        return
    await ws.accept()

    latest: dict[str, dict] = {}
    queue: asyncio.Queue[dict] = asyncio.Queue(maxsize=100)
    wake = asyncio.Event()

    def on_status(pid: str, snap: dict) -> None:
        latest[pid] = snap
        wake.set()

    def on_event(ev: Event) -> None:
        with contextlib.suppress(asyncio.QueueFull):
            queue.put_nowait({"type": "event", "data": ev.to_dict()})
        wake.set()

    def on_queue(pid: str) -> None:
        with contextlib.suppress(asyncio.QueueFull):
            queue.put_nowait({"type": "queue", "printer_id": pid})
        wake.set()

    removers = [p.add_listener(lambda s, pid=pid: on_status(pid, s)) for pid, p in mgr.printers.items()]
    mgr.bus.listeners.append(on_event)
    mgr.queue.listeners.append(on_queue)

    def on_slice() -> None:
        with contextlib.suppress(asyncio.QueueFull):
            queue.put_nowait({"type": "slice"})
        wake.set()

    mgr.slicer.listeners.append(on_slice)

    async def sender():
        for pid, p in mgr.printers.items():
            await ws.send_text(json.dumps({"type": "status", "printer_id": pid, "data": p.state.snapshot()}))
        while True:
            await wake.wait()
            wake.clear()
            while not queue.empty():
                await ws.send_text(json.dumps(queue.get_nowait()))
            for pid in list(latest):
                await ws.send_text(json.dumps({"type": "status", "printer_id": pid, "data": latest.pop(pid)}))
            await asyncio.sleep(0.4)  # agrupar actualizaciones

    async def receiver():
        while True:
            msg = await ws.receive_text()
            if msg == "ping":
                await ws.send_text(json.dumps({"type": "pong"}))

    tasks = [asyncio.create_task(sender()), asyncio.create_task(receiver())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    except WebSocketDisconnect:
        pass
    finally:
        for t in tasks:
            t.cancel()
        for r in removers:
            r()
        if on_event in mgr.bus.listeners:
            mgr.bus.listeners.remove(on_event)
        if on_queue in mgr.queue.listeners:
            mgr.queue.listeners.remove(on_queue)
        if on_slice in mgr.slicer.listeners:
            mgr.slicer.listeners.remove(on_slice)
