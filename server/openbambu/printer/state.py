"""Estado de la impresora.

Las impresoras Bambu (A1/P1) mandan un reporte completo tras ``pushall`` y
después solo *deltas* con los campos que cambiaron. Acá se fusionan esos
reportes en un estado crudo y se deriva un estado normalizado y estable para
la app.
"""

from __future__ import annotations

import copy
import time
from typing import Any

from .models import CAPABILITIES, GCODE_STATES, SPEED_LEVELS, STAGES


def deep_merge(base: dict, delta: dict) -> dict:
    """Fusiona ``delta`` sobre ``base`` (in-place). Las listas se reemplazan."""
    for k, v in delta.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = copy.deepcopy(v)
    return base


def _f(v: Any, default: float = 0.0) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _i(v: Any, default: int = 0) -> int:
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def fan_percent(level: Any) -> int:
    """Los ventiladores se reportan como nivel 0-15 (string)."""
    return round(_i(level) / 15 * 100)


def hms_code(attr: int, code: int) -> str:
    return f"{attr >> 16:04X}_{attr & 0xFFFF:04X}_{code >> 16:04X}_{code & 0xFFFF:04X}"


HMS_SEVERITY = {1: "fatal", 2: "serious", 3: "common", 4: "info"}


def parse_hms(items: list[dict] | None) -> list[dict]:
    out = []
    for it in items or []:
        attr, code = _i(it.get("attr")), _i(it.get("code"))
        full = hms_code(attr, code)
        out.append(
            {
                "code": full,
                "severity": HMS_SEVERITY.get(code >> 16, "info"),
                "url": f"https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/{full}",
            }
        )
    return out


def _color(c: str | None) -> str | None:
    if not c:
        return None
    c = c.strip().lstrip("#")
    return f"#{c[:6].upper()}" if len(c) >= 6 else None


def _tray(t: dict, ams_id: int, active: int) -> dict:
    tid = _i(t.get("id"))
    gid = 254 if ams_id == 255 else ams_id * 4 + tid
    loaded = bool(t.get("tray_type"))
    return {
        "id": tid,
        "global_id": gid,
        "loaded": loaded,
        "type": t.get("tray_type") or None,
        "name": t.get("tray_sub_brands") or t.get("tray_type") or None,
        "color": _color(t.get("tray_color")),
        "remain": _i(t.get("remain"), -1) if loaded else -1,
        "nozzle_temp_min": _i(t.get("nozzle_temp_min")) or None,
        "nozzle_temp_max": _i(t.get("nozzle_temp_max")) or None,
        "info_idx": t.get("tray_info_idx") or None,
        "active": gid == active,
    }


def normalize(raw: dict, model: str, connected: bool, updated_at: float) -> dict:
    """Convierte el reporte crudo en el estado que consume la app."""
    p = raw.get("print", {})
    caps = CAPABILITIES.get(model, CAPABILITIES["A1"])
    state = p.get("gcode_state") or ("OFFLINE" if not connected else "IDLE")
    if not connected:
        state = "OFFLINE"
    stage = _i(p.get("stg_cur"), -1)
    spd = _i(p.get("spd_lvl"), 2)

    ams_block = p.get("ams") or {}
    active = _i(ams_block.get("tray_now"), 255)
    units = []
    for unit in ams_block.get("ams") or []:
        aid = _i(unit.get("id"))
        units.append(
            {
                "id": aid,
                "humidity": _i(unit.get("humidity"), -1),
                "temp": _f(unit.get("temp")),
                "trays": [_tray(t, aid, active) for t in unit.get("tray") or []],
            }
        )
    vt = p.get("vt_tray")
    external = _tray(vt, 255, active) if isinstance(vt, dict) else None

    lights = {x.get("node"): x.get("mode") == "on" for x in p.get("lights_report") or []}

    remaining_min = _i(p.get("mc_remaining_time"))
    printing = state in ("RUNNING", "PAUSE", "PREPARE")
    return {
        "connected": connected,
        "updated_at": updated_at,
        "state": state,
        "state_label": GCODE_STATES.get(state, state.title()),
        "stage": stage,
        "stage_label": STAGES.get(stage, f"Etapa {stage}"),
        "job": {
            "name": p.get("subtask_name") or None,
            "file": p.get("gcode_file") or None,
            "progress": _i(p.get("mc_percent")),
            "layer": _i(p.get("layer_num")),
            "total_layers": _i(p.get("total_layer_num")),
            "remaining_min": remaining_min,
            "eta": (updated_at + remaining_min * 60) if printing and remaining_min else None,
            "print_error": _i(p.get("print_error")),
        },
        "temps": {
            "nozzle": round(_f(p.get("nozzle_temper")), 1),
            "nozzle_target": round(_f(p.get("nozzle_target_temper")), 1),
            "bed": round(_f(p.get("bed_temper")), 1),
            "bed_target": round(_f(p.get("bed_target_temper")), 1),
            "chamber": round(_f(p.get("chamber_temper")), 1) if caps.has_chamber_temp else None,
        },
        "fans": {
            "part": fan_percent(p.get("cooling_fan_speed")),
            "aux": fan_percent(p.get("big_fan1_speed")) if caps.has_aux_fan else None,
            "chamber": fan_percent(p.get("big_fan2_speed")) if caps.has_chamber_fan else None,
            "heatbreak": fan_percent(p.get("heatbreak_fan_speed")),
        },
        "speed": {"level": spd, "label": SPEED_LEVELS.get(spd, str(spd)), "percent": _i(p.get("spd_mag"), 100)},
        "light": lights.get("chamber_light", False),
        "ams": {
            "units": units,
            "external": external,
            "active_tray": None if active == 255 else active,
        },
        "hms": parse_hms(p.get("hms")),
        "wifi_signal": p.get("wifi_signal"),
        "nozzle_diameter": p.get("nozzle_diameter"),
        "sdcard": p.get("sdcard"),
        "skipped_objects": [_i(x) for x in p.get("s_obj") or []],
    }


class PrinterState:
    """Mantiene el estado crudo fusionado y su versión normalizada."""

    def __init__(self, model: str):
        self.model = model
        self.raw: dict = {}
        self.connected = False
        self.updated_at = 0.0

    def apply(self, report: dict) -> None:
        deep_merge(self.raw, report)
        self.updated_at = time.time()

    def snapshot(self) -> dict:
        return normalize(self.raw, self.model, self.connected, self.updated_at)
