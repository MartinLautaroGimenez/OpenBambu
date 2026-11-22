"""Lectura de archivos .gcode.3mf generados por Bambu Studio / OrcaSlicer.

Un .gcode.3mf laminado contiene, por cada placa N:
  * ``Metadata/plate_N.gcode``      el G-code
  * ``Metadata/plate_N.png``        la miniatura
  * ``Metadata/slice_info.config``  tiempo, peso y filamentos usados
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


class InvalidFile(ValueError):
    pass


def _meta(el: ET.Element) -> dict[str, str]:
    return {m.get("key", ""): m.get("value", "") for m in el.findall("metadata")}


def _float(v: str | None) -> float | None:
    try:
        return float(v) if v not in (None, "") else None
    except ValueError:
        return None


def read_3mf(path: Path) -> dict:
    """Devuelve ``{"sliced": bool, "plates": [...]}``.

    Cada placa: ``index, gcode, thumbnail, prediction_s, weight_g, filaments``
    y cada filamento: ``id`` (1-based, posición en el proyecto), ``type``,
    ``color`` (#RRGGBB), ``used_g``.
    """
    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        raise InvalidFile("No es un archivo 3MF válido") from e

    with zf:
        names = set(zf.namelist())
        gcodes = sorted(
            (int(m[1]) for n in names if (m := re.fullmatch(r"Metadata/plate_(\d+)\.gcode", n))),
        )
        info: dict[int, dict] = {}
        if "Metadata/slice_info.config" in names:
            try:
                root = ET.fromstring(zf.read("Metadata/slice_info.config"))
            except ET.ParseError:
                root = None
            for plate in root.findall("plate") if root is not None else []:
                meta = _meta(plate)
                idx = int(meta.get("index", "0") or 0)
                filaments = []
                for f in plate.findall("filament"):
                    color = (f.get("color") or "").upper()
                    filaments.append(
                        {
                            "id": int(f.get("id", "0") or 0),
                            "type": f.get("type") or "PLA",
                            "color": color[:7] if color.startswith("#") else None,
                            "used_g": _float(f.get("used_g")),
                        }
                    )
                info[idx] = {
                    "prediction_s": int(_float(meta.get("prediction")) or 0) or None,
                    "weight_g": _float(meta.get("weight")),
                    "filaments": sorted(filaments, key=lambda x: x["id"]),
                }

        plates = []
        for idx in gcodes:
            extra = info.get(idx, {})
            plates.append(
                {
                    "index": idx,
                    "gcode": f"Metadata/plate_{idx}.gcode",
                    "thumbnail": f"Metadata/plate_{idx}.png" in names,
                    "prediction_s": extra.get("prediction_s"),
                    "weight_g": extra.get("weight_g"),
                    "filaments": extra.get("filaments", []),
                }
            )
        return {"sliced": bool(plates), "plates": plates}


def read_thumbnail(path: Path, plate: int) -> bytes | None:
    try:
        with zipfile.ZipFile(path) as zf:
            for name in (f"Metadata/plate_{plate}.png", f"Metadata/plate_{plate}_small.png"):
                try:
                    return zf.read(name)
                except KeyError:
                    continue
    except zipfile.BadZipFile:
        return None
    return None


def read_plate_objects(path: Path, plate: int) -> list[dict]:
    """Objetos de una placa según ``Metadata/plate_N.json`` (id = identify_id para omitirlos)."""
    import json

    try:
        with zipfile.ZipFile(path) as zf:
            data = json.loads(zf.read(f"Metadata/plate_{plate}.json"))
    except (KeyError, ValueError, zipfile.BadZipFile, OSError):
        return []
    out = []
    for o in data.get("bbox_objects") or []:
        try:
            bbox = [round(float(v), 1) for v in o.get("bbox", [])[:4]]
        except (TypeError, ValueError):
            bbox = []
        if "id" in o:
            out.append({"id": int(o["id"]), "name": o.get("name") or None, "bbox": bbox if len(bbox) == 4 else None})
    return out


def read_project(path: Path) -> dict:
    """Placas y filamentos de un proyecto .3mf sin laminar (Bambu Studio / OrcaSlicer).

    ``{"project_plates": [{index, name, thumbnail, objects}], "project_filaments": [{id, type, color}],
    "project_printer": str | None}``
    """
    import json

    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        raise InvalidFile("No es un archivo 3MF válido") from e
    with zf:
        names = set(zf.namelist())
        plates: list[dict] = []
        if "Metadata/model_settings.config" in names:
            try:
                root = ET.fromstring(zf.read("Metadata/model_settings.config"))
            except ET.ParseError:
                root = None
            for pl in root.findall("plate") if root is not None else []:
                meta = _meta(pl)
                try:
                    idx = int(meta.get("plater_id") or meta.get("index") or 0)
                except ValueError:
                    continue
                if idx <= 0:
                    continue
                plates.append({
                    "index": idx,
                    "name": meta.get("plater_name") or "",
                    "thumbnail": f"Metadata/plate_{idx}.png" in names,
                    "objects": len(pl.findall("model_instance")),
                })
        if not plates:
            idxs = sorted({int(m[1]) for n in names if (m := re.fullmatch(r"Metadata/plate_(\d+)\.png", n))})
            plates = [{"index": i, "name": "", "thumbnail": True, "objects": 0} for i in idxs] or \
                [{"index": 1, "name": "", "thumbnail": False, "objects": 0}]
        filaments, printer = [], None
        if "Metadata/project_settings.config" in names:
            try:
                cfg = json.loads(zf.read("Metadata/project_settings.config"))
            except ValueError:
                cfg = {}
            types = cfg.get("filament_type") or []
            colors = cfg.get("filament_colour") or []
            for i, t in enumerate(types):
                c = (colors[i] if i < len(colors) else "") or ""
                filaments.append({"id": i + 1, "type": t, "color": c[:7].upper() if c.startswith("#") else None})
            printer = cfg.get("printer_model") or None
    return {"project_plates": sorted(plates, key=lambda p: p["index"]), "project_filaments": filaments,
            "project_printer": printer}


def sanitize_project(src: Path, dest: Path, drop: set[str] | None = None) -> list[str]:
    """Copia el proyecto quitando ajustes que OrcaSlicer rechaza (valores de Bambu Studio fuera de rango).

    Devuelve las claves quitadas.
    """
    import json

    drop = set(drop or ())
    removed: list[str] = []
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            data = zin.read(info.filename)
            if info.filename == "Metadata/project_settings.config":
                try:
                    cfg = json.loads(data)
                except ValueError:
                    cfg = None
                if isinstance(cfg, dict):
                    for k in list(cfg):
                        v = cfg[k]
                        # En Bambu Studio -1 significa "automático"; OrcaSlicer no lo acepta en algunos campos
                        if k in drop or (k in NEGATIVE_AUTO and str(v).strip() in ("-1", "-1.0")):
                            cfg.pop(k)
                            removed.append(k)
                    data = json.dumps(cfg, indent=4).encode()
            zout.writestr(info, data)
    return removed


# Ajustes donde Bambu Studio guarda -1 como "automático"
NEGATIVE_AUTO = {"raft_first_layer_expansion"}
