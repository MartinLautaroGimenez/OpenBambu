"""Constructores de comandos MQTT para impresoras Bambu Lab.

Cada función devuelve el diccionario que se publica en
``device/{serial}/request``. Los campos ``sequence_id`` se agregan al enviar.
"""

from __future__ import annotations

from .models import CAPABILITIES, GENERIC_FILAMENTS


class CommandError(ValueError):
    pass


def pushall() -> dict:
    return {"pushing": {"command": "pushall", "version": 1, "push_target": 1}}


def get_version() -> dict:
    return {"info": {"command": "get_version"}}


def pause() -> dict:
    return {"print": {"command": "pause", "param": ""}}


def resume() -> dict:
    return {"print": {"command": "resume", "param": ""}}


def stop() -> dict:
    return {"print": {"command": "stop", "param": ""}}


def gcode(lines: str) -> dict:
    if not lines.endswith("\n"):
        lines += "\n"
    return {"print": {"command": "gcode_line", "param": lines}}


def print_speed(level: int) -> dict:
    if level not in (1, 2, 3, 4):
        raise CommandError("Nivel de velocidad inválido (1-4)")
    return {"print": {"command": "print_speed", "param": str(level)}}


def set_temperature(model: str, target: str, value: int) -> dict:
    caps = CAPABILITIES[model]
    if target == "nozzle":
        if not 0 <= value <= caps.max_nozzle_temp:
            raise CommandError(f"Temperatura de boquilla fuera de rango (0-{caps.max_nozzle_temp})")
        return gcode(f"M104 S{value}")
    if target == "bed":
        if not 0 <= value <= caps.max_bed_temp:
            raise CommandError(f"Temperatura de cama fuera de rango (0-{caps.max_bed_temp})")
        return gcode(f"M140 S{value}")
    raise CommandError("Objetivo de temperatura inválido")


FAN_INDEX = {"part": 1, "aux": 2, "chamber": 3}


def set_fan(model: str, fan: str, percent: int) -> dict:
    caps = CAPABILITIES[model]
    if fan not in FAN_INDEX:
        raise CommandError("Ventilador inválido")
    if fan == "aux" and not caps.has_aux_fan or fan == "chamber" and not caps.has_chamber_fan:
        raise CommandError(f"La {model} no tiene ese ventilador")
    if not 0 <= percent <= 100:
        raise CommandError("Porcentaje inválido (0-100)")
    return gcode(f"M106 P{FAN_INDEX[fan]} S{round(percent * 255 / 100)}")


def light(on: bool, node: str = "chamber_light") -> dict:
    return {
        "system": {
            "command": "ledctrl",
            "led_node": node,
            "led_mode": "on" if on else "off",
            "led_on_time": 500,
            "led_off_time": 500,
            "loop_times": 0,
            "interval_time": 0,
        }
    }


def home() -> dict:
    return gcode("G28")


def move(axis: str, distance: float, feed: int | None = None) -> dict:
    """Movimiento relativo, igual que el panel de jog de Bambu Studio."""
    axis = axis.upper()
    if axis not in ("X", "Y", "Z"):
        raise CommandError("Eje inválido")
    if not -100 <= distance <= 100:
        raise CommandError("Distancia inválida (±100 mm)")
    feed = feed or (600 if axis == "Z" else 3000)
    return gcode(
        "M211 S\nM211 X1 Y1 Z1\nM1002 push_ref_mode\nG91\n"
        f"G1 {axis}{distance:.1f} F{feed}\nM1002 pop_ref_mode\nM211 R"
    )


def extrude(distance: float) -> dict:
    if not -50 <= distance <= 50:
        raise CommandError("Distancia inválida (±50 mm)")
    return gcode(f"M83\nG1 E{distance:.1f} F300")


def _tray_ids(global_id: int) -> tuple[int, int]:
    if global_id == 254:
        return 255, 254
    if not 0 <= global_id < 16 * 4:
        raise CommandError("Bandeja inválida")
    return global_id // 4, global_id % 4


def ams_load(global_id: int) -> dict:
    ams_id, slot_id = _tray_ids(global_id)
    return {
        "print": {
            "command": "ams_change_filament",
            "target": global_id,
            "ams_id": ams_id,
            "slot_id": slot_id,
            "curr_temp": -1,
            "tar_temp": -1,
        }
    }


def ams_unload() -> dict:
    return {
        "print": {
            "command": "ams_change_filament",
            "target": 255,
            "ams_id": 255,
            "slot_id": 255,
            "curr_temp": -1,
            "tar_temp": -1,
        }
    }


def ams_control(action: str) -> dict:
    if action not in ("resume", "reset", "pause"):
        raise CommandError("Acción AMS inválida")
    return {"print": {"command": "ams_control", "param": action}}


def ams_filament_setting(
    global_id: int,
    filament_type: str,
    color: str,
    nozzle_min: int | None = None,
    nozzle_max: int | None = None,
) -> dict:
    ams_id, tray_id = _tray_ids(global_id)
    ftype = filament_type.upper()
    if ftype not in GENERIC_FILAMENTS:
        raise CommandError(f"Tipo de filamento no soportado: {filament_type}")
    idx, tmin, tmax = GENERIC_FILAMENTS[ftype]
    c = color.lstrip("#").upper()
    if len(c) == 6:
        c += "FF"
    if len(c) != 8 or any(ch not in "0123456789ABCDEF" for ch in c):
        raise CommandError("Color inválido (usar RRGGBB)")
    return {
        "print": {
            "command": "ams_filament_setting",
            "ams_id": ams_id,
            "tray_id": tray_id,
            "tray_info_idx": idx,
            "tray_color": c,
            "nozzle_temp_min": nozzle_min or tmin,
            "nozzle_temp_max": nozzle_max or tmax,
            "tray_type": ftype,
            "setting_id": "",
        }
    }


def project_file(
    filename: str,
    plate: int,
    name: str,
    ams_mapping: list[int],
    ams_mapping2: list[dict],
    use_ams: bool,
    bed_leveling: bool = True,
    flow_cali: bool = False,
    timelapse: bool = False,
    vibration_cali: bool = False,
) -> dict:
    """Inicia la impresión de una placa de un .gcode.3mf que ya está en la SD."""
    return {
        "print": {
            "command": "project_file",
            "param": f"Metadata/plate_{plate}.gcode",
            "url": f"file:///sdcard/{filename}",
            "file": filename,
            "md5": "",
            "project_id": "0",
            "profile_id": "0",
            "task_id": "0",
            "subtask_id": "0",
            "subtask_name": name,
            "bed_type": "auto",
            "bed_leveling": bed_leveling,
            "bed_levelling": bed_leveling,
            "flow_cali": flow_cali,
            "vibration_cali": vibration_cali,
            "layer_inspect": False,
            "timelapse": timelapse,
            "use_ams": use_ams,
            "ams_mapping": ams_mapping,
            "ams_mapping2": ams_mapping2,
        }
    }


def skip_objects(ids: list[int]) -> dict:
    """Omitir objetos de la impresión en curso (lista completa de los omitidos)."""
    return {"print": {"command": "skip_objects", "obj_list": [int(i) for i in ids]}}
