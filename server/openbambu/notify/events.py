"""Detección de eventos a partir de cambios en el estado de la impresora."""

from __future__ import annotations

import time
from collections import deque
from collections.abc import Awaitable, Callable
from dataclasses import asdict, dataclass, field

CANCELLED_ERROR = 50348044  # print_error cuando el usuario cancela la impresión


@dataclass
class Event:
    printer_id: str
    printer_name: str
    type: str
    title: str
    message: str
    severity: str = "info"  # info | success | warning | error
    progress: int | None = None
    ts: float = field(default_factory=time.time)
    id: int = 0
    # Adjuntar una captura de la cámara al notificar
    snapshot: bool = False

    def to_dict(self) -> dict:
        d = asdict(self)
        d.pop("snapshot")
        return d


def _fmt_min(m: int) -> str:
    h, mm = divmod(max(0, m), 60)
    return f"{h} h {mm:02d} min" if h else f"{mm} min"


class EventDetector:
    """Compara estados consecutivos y genera eventos."""

    def __init__(self, printer_id: str, printer_name: str, progress_step: int = 25):
        self.pid = printer_id
        self.name = printer_name
        self.step = progress_step
        self.prev: dict | None = None
        self.seen_hms: set[str] = set()
        self.last_milestone = 0

    def _ev(self, type_: str, title: str, message: str, **kw) -> Event:
        return Event(self.pid, self.name, type_, title, message, **kw)

    def feed(self, s: dict) -> list[Event]:
        prev, self.prev = self.prev, s
        events: list[Event] = []
        if prev is None:
            self.seen_hms = {h["code"] for h in s["hms"]}
            self.last_milestone = self._milestone(s["job"]["progress"])
            return events

        job, pjob = s["job"], prev["job"]
        name = job["name"] or "la impresión"
        st, pst = s["state"], prev["state"]

        # Conexión
        if prev["connected"] and not s["connected"]:
            events.append(self._ev("offline", "Impresora desconectada",
                                   f"Se perdió la conexión con {self.name}", severity="warning"))
            return events
        if not prev["connected"] or pst == "OFFLINE":
            # Al reconectar no se generan eventos de transición
            return events

        # Transiciones de estado
        if st != pst:
            if st in ("PREPARE", "RUNNING") and pst in ("IDLE", "FINISH", "FAILED"):
                self.last_milestone = 0
                events.append(self._ev("print_started", "Impresión iniciada", f"Comenzó «{name}»",
                                       progress=job["progress"]))
            elif st == "PAUSE":
                reason = s["stage_label"] if s["stage"] not in (16, -1, 255) else "Pausada por el usuario"
                events.append(self._ev("print_paused", "Impresión pausada", f"«{name}»: {reason}",
                                       severity="warning", progress=job["progress"], snapshot=True))
            elif st == "RUNNING" and pst == "PAUSE":
                events.append(self._ev("print_resumed", "Impresión reanudada", f"Continúa «{name}»",
                                       progress=job["progress"]))
            elif st == "FINISH":
                events.append(self._ev("print_finished", "¡Impresión terminada!", f"«{name}» está lista",
                                       severity="success", progress=100, snapshot=True))
            elif st == "FAILED":
                if job["print_error"] == CANCELLED_ERROR:
                    events.append(self._ev("print_cancelled", "Impresión cancelada",
                                           f"Se canceló «{name}»", severity="warning", snapshot=True))
                else:
                    code = f" (error {job['print_error']:08X})" if job["print_error"] else ""
                    detail = f": {job['print_error_text']}" if job.get("print_error_text") else ""
                    events.append(self._ev("print_failed", "Impresión fallida", f"Falló «{name}»{code}{detail}",
                                           severity="error", progress=job["progress"], snapshot=True))

        # Primera capa
        if st == "RUNNING" and pjob["layer"] == 1 and job["layer"] >= 2:
            events.append(self._ev("first_layer", "Primera capa terminada",
                                   f"Revisá la cámara para confirmar que «{name}» se pegó bien",
                                   progress=job["progress"], snapshot=True))

        # Hitos de progreso
        if st == "RUNNING" and self.step:
            m = self._milestone(job["progress"])
            if m > self.last_milestone and 0 < m < 100:
                events.append(self._ev("progress", f"{name}: {m}%",
                                       f"Quedan {_fmt_min(job['remaining_min'])} · capa {job['layer']}/{job['total_layers']}",
                                       progress=job["progress"]))
            self.last_milestone = max(self.last_milestone, m)

        # Filamento agotado
        if s["stage"] == 6 and prev["stage"] != 6:
            events.append(self._ev("filament_runout", "Se terminó el filamento",
                                   f"«{name}» está pausada. Cargá filamento para continuar.",
                                   severity="error", snapshot=True))

        # Errores HMS nuevos
        current = {h["code"]: h for h in s["hms"]}
        for code, h in current.items():
            if code not in self.seen_hms:
                sev = "error" if h["severity"] in ("fatal", "serious") else "warning"
                events.append(self._ev("hms", "Alerta de la impresora",
                                       h.get("description") or f"Código HMS {code}",
                                       severity=sev, snapshot=sev == "error"))
        self.seen_hms = set(current)
        return events

    def _milestone(self, progress: int) -> int:
        return (progress // self.step) * self.step if self.step else 0


Notifier = Callable[[Event], Awaitable[None]]


class EventBus:
    """Historial de eventos en memoria + despacho a notificadores."""

    def __init__(self, maxlen: int = 300):
        self.events: deque[Event] = deque(maxlen=maxlen)
        self.notifiers: list[Notifier] = []
        self.listeners: list[Callable[[Event], None]] = []
        self._last_id = 0

    def publish(self, ev: Event) -> Event:
        self._last_id = max(self._last_id + 1, int(ev.ts * 1000))
        ev.id = self._last_id
        self.events.append(ev)
        for fn in list(self.listeners):
            fn(ev)
        return ev

    def since(self, after: int = 0, printer_id: str | None = None, limit: int = 100) -> list[dict]:
        out = [e.to_dict() for e in self.events
               if e.id > after and (printer_id is None or e.printer_id == printer_id)]
        return out[-limit:]
