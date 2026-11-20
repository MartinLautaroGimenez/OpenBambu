"""Vista previa del G-code: trayectorias de extrusión por capa.

Lee ``Metadata/plate_N.gcode`` de un .gcode.3mf (Bambu Studio / OrcaSlicer) y
devuelve, para cada capa, polilíneas agrupadas por tipo de línea (pared
exterior, relleno, soporte...) y filamento. Las coordenadas van en décimas de
milímetro (enteros) para que la respuesta sea liviana. Los arcos G2/G3 se
aproximan con segmentos.
"""

from __future__ import annotations

import json
import math
import re
import zipfile
from pathlib import Path

# Tipo de línea (comentario "; FEATURE:") → código corto
FEATURES = {
    "outer wall": "ow", "inner wall": "iw", "overhang wall": "ow",
    "sparse infill": "si", "internal solid infill": "ss", "solid infill": "ss",
    "top surface": "ts", "bottom surface": "bs", "bridge": "br", "gap infill": "gi",
    "support": "sp", "support interface": "sp", "support transition": "sp",
    "skirt": "sk", "brim": "sk", "prime tower": "pt", "ironing": "ir",
}
SKIP_LAYERS_LIMIT = 4000
MAX_POINTS = 900_000

_NUM = re.compile(r"([XYZEIJR])(-?\d*\.?\d+)")


class PreviewError(ValueError):
    pass


def _feature(comment: str) -> str:
    return FEATURES.get(comment.strip().lower(), "ot")


def parse_gcode(lines, max_points: int = MAX_POINTS) -> dict:
    layers: list[dict] = []
    cur: dict | None = None
    paths: dict[tuple[str, int], list[list[int]]] = {}
    x = y = 0.0
    z = 0.0
    absolute = True
    rel_e = True
    feature = "ot"
    tool = 0
    started = False
    total = 0
    min_x = min_y = 1e9
    max_x = max_y = -1e9
    open_poly: list[int] | None = None
    open_key: tuple[str, int] | None = None

    def close_layer():
        nonlocal paths, open_poly, open_key
        if cur is not None:
            cur["paths"] = [{"t": k[0], "f": k[1], "p": p} for k, polys in paths.items() for p in polys if len(p) >= 4]
            if cur["paths"]:
                layers.append(cur)
        paths = {}
        open_poly, open_key = None, None

    def new_layer(zh: float):
        nonlocal cur
        close_layer()
        cur = {"z": round(zh, 3)}

    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line[0] == ";":
            c = line[1:].strip()
            cu = c.upper()
            if cu.startswith("CHANGE_LAYER") or cu.startswith("LAYER_CHANGE"):
                started = True
                new_layer(z)
            elif cu.startswith("Z_HEIGHT:") or (cu.startswith("Z:") and cur is not None):
                try:
                    zv = float(c.split(":", 1)[1])
                    if cur is not None:
                        cur["z"] = round(zv, 3)
                    z = zv
                except ValueError:
                    pass
            elif cu.startswith("FEATURE:") or cu.startswith("TYPE:"):
                feature = _feature(c.split(":", 1)[1])
                open_poly = None
            continue
        code = line.split(";", 1)[0].strip()
        if not code:
            continue
        head = code.split(" ", 1)[0].upper()
        if head == "G90":
            absolute = True
        elif head == "G91":
            absolute = False
        elif head == "M82":
            rel_e = False
        elif head == "M83":
            rel_e = True
        elif head[0] == "T" and head[1:].isdigit():
            tool = int(head[1:])
            open_poly = None
        elif head in ("G0", "G1", "G2", "G3"):
            args = {k: float(v) for k, v in _NUM.findall(code[len(head):].upper())}
            nx = (args["X"] if absolute else x + args["X"]) if "X" in args else x
            ny = (args["Y"] if absolute else y + args["Y"]) if "Y" in args else y
            if "Z" in args:
                z = args["Z"] if absolute else z + args["Z"]
            e = args.get("E", 0.0)
            extruding = head != "G0" and e > 0 and rel_e and (nx != x or ny != y)
            if started and cur is not None and extruding and total < max_points:
                pts = [(nx, ny)]
                if head in ("G2", "G3") and ("I" in args or "J" in args):
                    pts = _arc(x, y, nx, ny, args.get("I", 0.0), args.get("J", 0.0), head == "G2")
                key = (feature, tool)
                if open_poly is None or open_key != key:
                    open_poly = [round(x * 10), round(y * 10)]
                    open_key = key
                    paths.setdefault(key, []).append(open_poly)
                frame = feature not in ("ot", "pt")  # purga y torre no definen el encuadre
                for px, py in pts:
                    open_poly += [round(px * 10), round(py * 10)]
                    if frame:
                        min_x, max_x = min(min_x, px), max(max_x, px)
                        min_y, max_y = min(min_y, py), max(max_y, py)
                total += len(pts)
            elif nx != x or ny != y:
                open_poly = None  # desplazamiento sin extruir: corta la polilínea
            x, y = nx, ny
        if len(layers) > SKIP_LAYERS_LIMIT:
            break
    close_layer()
    if not layers:
        raise PreviewError("El G-code no tiene capas reconocibles")
    if min_x > max_x:  # solo había líneas de purga
        min_x, min_y, max_x, max_y = 0, 0, 1, 1
    return {
        "layers": layers,
        "bbox": [round(min_x, 1), round(min_y, 1), round(max_x, 1), round(max_y, 1)],
        "points": total,
        "truncated": total >= max_points,
    }


def _arc(x0, y0, x1, y1, i, j, clockwise) -> list[tuple[float, float]]:
    cx, cy = x0 + i, y0 + j
    r = math.hypot(i, j)
    a0 = math.atan2(y0 - cy, x0 - cx)
    a1 = math.atan2(y1 - cy, x1 - cx)
    sweep = a1 - a0
    if clockwise and sweep >= 0:
        sweep -= 2 * math.pi
    elif not clockwise and sweep <= 0:
        sweep += 2 * math.pi
    n = max(2, min(24, int(abs(sweep) * r / 1.0)))  # ~1 mm por segmento
    return [(cx + r * math.cos(a0 + sweep * k / n), cy + r * math.sin(a0 + sweep * k / n)) for k in range(1, n)] + [
        (x1, y1)]


def build_preview(threemf: Path, plate: int, cache_dir: Path) -> bytes:
    """Devuelve el JSON de la vista previa (cacheado en disco)."""
    cache = cache_dir / f"{threemf.parent.name}_{plate}.json"
    if cache.exists() and cache.stat().st_mtime >= threemf.stat().st_mtime:
        return cache.read_bytes()
    try:
        with zipfile.ZipFile(threemf) as z, z.open(f"Metadata/plate_{plate}.gcode") as f:
            data = parse_gcode(line.decode("utf-8", "replace") for line in f)
    except KeyError as e:
        raise PreviewError(f"El archivo no tiene G-code para la placa {plate}") from e
    except zipfile.BadZipFile as e:
        raise PreviewError("Archivo inválido") from e
    body = json.dumps(data, separators=(",", ":")).encode()
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_bytes(body)
    return body
