"""Escena editable de una placa: lectura de modelos y escritura de proyectos 3MF.

* Lee STL, OBJ y 3MF (Bambu Studio / OrcaSlicer / MakerWorld): objetos, piezas
  (con su filamento y la pintura de colores/soportes), instancias y placas.
* Genera mallas livianas para mostrar en el editor 3D (la malla original se
  conserva para laminar).
* Escribe un proyecto 3MF estilo Bambu con las posiciones que dejó el editor,
  las placas y el filamento de cada pieza, listo para OrcaSlicer.

Las transformaciones usan la convención 3MF: 12 números ``m00 m01 m02 m10 m11
m12 m20 m21 m22 m30 m31 m32`` (vector fila: ``p' = p · M``; la traslación es la
última fila). En la escena se guardan relativas a la placa (0,0 = esquina de la
cama); al escribir se suma el origen de cada placa como hace Bambu Studio.
"""

from __future__ import annotations

import base64
import io
import json
import math
import re
import struct
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

UNITS = {"micron": 0.001, "millimeter": 1.0, "centimeter": 10.0, "inch": 25.4, "foot": 304.8, "meter": 1000.0}
PLATE_GAP = 1.0 / 5.0  # LOGICAL_PART_PLATE_GAP de Bambu Studio / OrcaSlicer
DISPLAY_TRIANGLES = 60_000  # por pieza, para el editor
PAINT_ATTRS = ("paint_color", "paint_supports", "paint_seam", "face_property")
IDENTITY = [1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0, 0, 0, 0]


class SceneError(ValueError):
    pass


@dataclass
class Part:
    vertices: np.ndarray  # (N, 3) float32, coordenadas del objeto (antes de la transformación de la pieza)
    triangles: np.ndarray  # (M, 3) int32
    transform: list[float] = field(default_factory=lambda: list(IDENTITY))
    extruder: int | None = None
    name: str = ""
    subtype: str = "normal_part"
    paint: dict[str, list[str]] | None = None  # atributo -> valor por triángulo ("" = sin pintar)


@dataclass
class SceneObject:
    key: str
    name: str
    parts: list[Part]
    extruder: int = 1


@dataclass
class Placement:
    key: str
    plate: int
    matrix: list[float]
    extruder: int | None = None


@dataclass
class Scene:
    objects: dict[str, SceneObject]
    items: list[Placement]
    plates: list[dict]
    filaments: list[dict]
    bed: tuple[float, float]
    settings: bytes | None = None  # Metadata/project_settings.config del proyecto original


# ---- matrices ------------------------------------------------------------------------------
def to_mat(m: list[float]) -> np.ndarray:
    a = np.eye(4)
    a[0, :3], a[1, :3], a[2, :3], a[3, :3] = m[0:3], m[3:6], m[6:9], m[9:12]
    return a


def from_mat(a: np.ndarray) -> list[float]:
    return [float(x) for x in (*a[0, :3], *a[1, :3], *a[2, :3], *a[3, :3])]


def parse_transform(s: str | None) -> list[float]:
    if not s:
        return list(IDENTITY)
    vals = [float(x) for x in s.split()]
    if len(vals) != 12:
        raise SceneError("Transformación 3MF inválida")
    return vals


def fmt_transform(m: list[float]) -> str:
    return " ".join(f"{x:.9g}" for x in m)


def apply(v: np.ndarray, m: list[float]) -> np.ndarray:
    a = to_mat(m)
    return v.astype(np.float64) @ a[:3, :3] + a[3, :3]


def plate_columns(count: int) -> int:
    value = math.sqrt(count)
    r = round(value)
    return int(r + 1 if value > r else r)


def plate_origin(index: int, count: int, bed: tuple[float, float]) -> tuple[float, float]:
    """Origen de la placa ``index`` (1-based) en el espacio del proyecto."""
    cols = plate_columns(max(count, 1))
    row, col = divmod(index - 1, cols)
    return col * bed[0] * (1 + PLATE_GAP), -row * bed[1] * (1 + PLATE_GAP)


def shift(m: list[float], dx: float, dy: float) -> list[float]:
    out = list(m)
    out[9] += dx
    out[10] += dy
    return out


# ---- lectura de mallas sueltas -----------------------------------------------------------------
def read_stl(data: bytes) -> tuple[np.ndarray, np.ndarray]:
    if len(data) >= 84:
        n = struct.unpack_from("<I", data, 80)[0]
        if 84 + n * 50 == len(data):
            rec = np.frombuffer(data, dtype=np.dtype([("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")]),
                                count=n, offset=84)
            return _weld(rec["v"].reshape(-1, 3))
    text = data.decode("utf-8", errors="replace")
    nums = re.findall(r"vertex\s+([-+\deE.]+)\s+([-+\deE.]+)\s+([-+\deE.]+)", text)
    if not nums or len(nums) % 3:
        raise SceneError("STL inválido")
    return _weld(np.array(nums, dtype=np.float32))


def read_obj(data: bytes) -> tuple[np.ndarray, np.ndarray]:
    verts, tris = [], []
    for line in data.decode("utf-8", errors="replace").splitlines():
        if line.startswith("v "):
            verts.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("f "):
            idx = []
            for tok in line.split()[1:]:
                i = int(tok.split("/")[0])
                idx.append(i - 1 if i > 0 else len(verts) + i)
            for k in range(1, len(idx) - 1):  # triangular polígonos
                tris.append([idx[0], idx[k], idx[k + 1]])
    if not verts or not tris:
        raise SceneError("OBJ inválido")
    return np.array(verts, dtype=np.float32), np.array(tris, dtype=np.int32)


def _weld(soup: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Triángulos sueltos → vértices compartidos."""
    soup = soup.astype(np.float32)
    uniq, inverse = np.unique(soup, axis=0, return_inverse=True)
    return uniq, inverse.reshape(-1, 3).astype(np.int32)


# ---- lectura de 3MF --------------------------------------------------------------------------------
_OBJECT_RE = re.compile(r"<object\b([^>]*)>(.*?)</object>", re.S)
_ATTR_RE = re.compile(r'([\w:]+)="([^"]*)"')
_VERTEX_RE = re.compile(r'<vertex\s+x="([^"]+)"\s+y="([^"]+)"\s+z="([^"]+)"')
_TRI_RE = re.compile(r'<triangle\s+v1="(\d+)"\s+v2="(\d+)"\s+v3="(\d+)"([^>]*?)/?>')
_COMP_RE = re.compile(r"<component\b([^>]*)/?>")


def _attrs(s: str) -> dict[str, str]:
    return dict(_ATTR_RE.findall(s))


def _local(name: str) -> str:
    return name.split(":", 1)[-1]


class _ModelFile:
    def __init__(self, text: str):
        m = re.search(r'<model\b[^>]*\bunit="([^"]+)"', text)
        self.scale = UNITS.get(m[1], 1.0) if m else 1.0
        self.objects: dict[str, tuple[dict, str]] = {}
        for om in _OBJECT_RE.finditer(text):
            a = _attrs(om[1])
            self.objects[a.get("id", "")] = (a, om[2])
        bm = re.search(r"<build\b[^>]*>(.*?)</build>", text, re.S)
        self.items = [_attrs(x) for x in re.findall(r"<item\b([^>]*)/?>", bm[1])] if bm else []

    def mesh(self, oid: str) -> tuple[np.ndarray, np.ndarray, dict[str, list[str]] | None]:
        a, body = self.objects[oid]
        vs = _VERTEX_RE.findall(body)
        ts = _TRI_RE.findall(body)
        if not vs or not ts:
            raise SceneError(f"El objeto {oid} no tiene malla")
        v = np.array(vs, dtype=np.float32) * self.scale
        t = np.array([x[:3] for x in ts], dtype=np.int32)
        paint = None
        if any(x[3].strip() for x in ts):
            paint = {}
            for attr in PAINT_ATTRS:
                vals = [_attrs(x[3]).get(attr, "") for x in ts]
                if any(vals):
                    paint[attr] = vals
            paint = paint or None
        return v, t, paint


def read_3mf_scene(path: Path) -> Scene:
    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile as e:
        raise SceneError("No es un archivo 3MF válido") from e
    with zf:
        names = set(zf.namelist())
        root_name = "3D/3dmodel.model"
        if "_rels/.rels" in names:
            m = re.search(r'Target="/?([^"]+\.model)"', zf.read("_rels/.rels").decode(errors="replace"))
            if m and m[1] in names:
                root_name = m[1]
        if root_name not in names:
            raise SceneError("El 3MF no tiene modelo 3D")
        files: dict[str, _ModelFile] = {}

        def model(name: str) -> _ModelFile:
            name = name.lstrip("/")
            if name not in files:
                files[name] = _ModelFile(zf.read(name).decode("utf-8", errors="replace"))
            return files[name]

        root = model(root_name)

        # Ajustes de Bambu: nombres, filamento de objetos/piezas y placas
        obj_meta: dict[str, dict] = {}
        plates: list[dict] = []
        inst_plate: dict[tuple[str, int], int] = {}
        if "Metadata/model_settings.config" in names:
            try:
                cfg = ET.fromstring(zf.read("Metadata/model_settings.config"))
            except ET.ParseError:
                cfg = None
            for o in cfg.findall("object") if cfg is not None else []:
                md = {m.get("key"): m.get("value") for m in o.findall("metadata")}
                parts = {}
                for p in o.findall("part"):
                    pm = {m.get("key"): m.get("value") for m in p.findall("metadata")}
                    parts[p.get("id", "")] = {"name": pm.get("name") or "", "extruder": _int(pm.get("extruder")),
                                              "subtype": p.get("subtype") or "normal_part"}
                obj_meta[o.get("id", "")] = {"name": md.get("name") or "", "extruder": _int(md.get("extruder")),
                                             "parts": parts}
            for p in cfg.findall("plate") if cfg is not None else []:
                md = {m.get("key"): m.get("value") for m in p.findall("metadata")}
                idx = _int(md.get("plater_id")) or len(plates) + 1
                plates.append({"index": idx, "name": md.get("plater_name") or ""})
                for mi in p.findall("model_instance"):
                    mm = {m.get("key"): m.get("value") for m in mi.findall("metadata")}
                    inst_plate[(mm.get("object_id") or "", _int(mm.get("instance_id")) or 0)] = idx

        settings = zf.read("Metadata/project_settings.config") if "Metadata/project_settings.config" in names else None
        cfgj: dict = {}
        if settings:
            try:
                cfgj = json.loads(settings)
            except ValueError:
                cfgj = {}
        bed = _bed_from_config(cfgj) or (256.0, 256.0)
        filaments = []
        for i, t in enumerate(cfgj.get("filament_type") or []):
            colors = cfgj.get("filament_colour") or []
            c = colors[i] if i < len(colors) else ""
            filaments.append({"id": i + 1, "type": t, "color": c[:7].upper() if c.startswith("#") else None})

        # Objetos referenciados por el armado
        objects: dict[str, SceneObject] = {}
        for item in root.items:
            oid = item.get("objectid", "")
            if oid in objects or oid not in root.objects:
                continue
            meta = obj_meta.get(oid, {})
            a, body = root.objects[oid]
            parts: list[Part] = []
            comps = _COMP_RE.findall(body)
            if comps:
                for c in comps:
                    ca = _attrs(c)
                    path_ = next((v for k, v in ca.items() if _local(k) == "path"), None)
                    mf = model(path_) if path_ else root
                    cid = ca.get("objectid", "")
                    v, t, paint = mf.mesh(cid)
                    tr = parse_transform(ca.get("transform"))
                    tr[9:12] = [x * root.scale for x in tr[9:12]]
                    pm = meta.get("parts", {}).get(cid, {})
                    parts.append(Part(v, t, tr, pm.get("extruder"), pm.get("name", ""),
                                      pm.get("subtype", "normal_part"), paint))
            else:
                v, t, paint = root.mesh(oid)
                pm = next(iter(meta.get("parts", {}).values()), {}) if meta.get("parts") else {}
                parts.append(Part(v, t, list(IDENTITY), pm.get("extruder"), pm.get("name", ""),
                                  pm.get("subtype", "normal_part"), paint))
            objects[oid] = SceneObject(oid, meta.get("name") or a.get("name") or f"Objeto {oid}", parts,
                                       meta.get("extruder") or 1)

        count = len(plates) or 1
        if not plates:
            plates = [{"index": 1, "name": ""}]
        items: list[Placement] = []
        seen: dict[str, int] = {}
        for item in root.items:
            oid = item.get("objectid", "")
            if oid not in objects:
                continue
            inst = seen.get(oid, 0)
            seen[oid] = inst + 1
            m = parse_transform(item.get("transform"))
            m[9:12] = [x * root.scale for x in m[9:12]]
            plate = inst_plate.get((oid, inst), 1 if not inst_plate else None)
            if plate is None:
                plate = 1
            ox, oy = plate_origin(plate, count, bed) if inst_plate else (0.0, 0.0)
            items.append(Placement(oid, plate, shift(m, -ox, -oy)))
        if not items:
            raise SceneError("El 3MF no tiene piezas para editar")
        return Scene(objects, items, sorted(plates, key=lambda p: p["index"]), filaments, bed, settings)


def _bed_from_config(cfg: dict) -> tuple[float, float] | None:
    area = cfg.get("printable_area")
    try:
        pts = [tuple(float(c) for c in p.split("x")) for p in area]
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        return max(xs) - min(xs), max(ys) - min(ys)
    except (TypeError, ValueError, AttributeError):
        return None


def _int(v) -> int | None:
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def read_scene(path: Path, bed: tuple[float, float], name: str) -> Scene:
    low = path.name.lower()
    if low.endswith(".3mf"):
        return read_3mf_scene(path)
    if low.endswith(".stl"):
        v, t = read_stl(path.read_bytes())
    elif low.endswith(".obj"):
        v, t = read_obj(path.read_bytes())
    else:
        raise SceneError("Este formato no se puede editar (STEP): laminalo directamente")
    obj = SceneObject("1", name, [Part(v, t)])
    lo, hi = v.min(0), v.max(0)
    m = list(IDENTITY)
    m[9:12] = [float(bed[0] / 2 - (lo[0] + hi[0]) / 2), float(bed[1] / 2 - (lo[1] + hi[1]) / 2), -float(lo[2])]
    return Scene({"1": obj}, [Placement("1", 1, m)], [{"index": 1, "name": ""}], [], bed)


# ---- mallas para el editor ---------------------------------------------------------------------------
def decimate(v: np.ndarray, t: np.ndarray, target: int = DISPLAY_TRIANGLES) -> tuple[np.ndarray, np.ndarray]:
    """Simplifica por agrupamiento de vértices hasta quedar con ``target`` triángulos o menos."""
    if len(t) <= target:
        return v.astype(np.float32), t.astype(np.int32)
    lo, size = v.min(0), float((v.max(0) - v.min(0)).max()) or 1.0
    best = None
    a, b = 8, 2048
    while a <= b:
        res = (a + b) // 2
        q = np.floor((v - lo) / size * res).astype(np.int64)
        keys = (q[:, 0] * (res + 1) + q[:, 1]) * (res + 1) + q[:, 2]
        uniq, inv = np.unique(keys, return_inverse=True)
        nt = inv[t]
        ok = (nt[:, 0] != nt[:, 1]) & (nt[:, 1] != nt[:, 2]) & (nt[:, 0] != nt[:, 2])
        nt = nt[ok]
        if len(nt) <= target:
            best = (res, uniq, inv, nt)
            a = res + 1
        else:
            b = res - 1
    if best is None:
        return v.astype(np.float32), t[:target].astype(np.int32)
    _, uniq, inv, nt = best
    sums = np.zeros((len(uniq), 3))
    np.add.at(sums, inv, v)
    counts = np.bincount(inv, minlength=len(uniq))[:, None]
    nv = (sums / np.maximum(counts, 1)).astype(np.float32)
    return nv, nt.astype(np.int32)


def mesh_bin(v: np.ndarray, t: np.ndarray) -> bytes:
    """Formato del editor: ``uint32 nv, uint32 nt, float32[nv*3], uint32[nt*3]``."""
    return struct.pack("<II", len(v), len(t)) + v.astype("<f4").tobytes() + t.astype("<u4").tobytes()


def part_bbox(p: Part) -> tuple[np.ndarray, np.ndarray]:
    w = apply(p.vertices, p.transform)
    return w.min(0), w.max(0)


# ---- escritura del proyecto -----------------------------------------------------------------------------
CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
 <Default Extension="png" ContentType="image/png"/>
 <Default Extension="config" ContentType="text/xml"/>
</Types>"""
RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>"""
APPLICATION = "BambuStudio-02.04.00.00"


def write_project(
    dest: Path,
    objects: dict[str, SceneObject],
    items: list[Placement],
    plates: list[dict],
    bed: tuple[float, float],
    settings: bytes | None = None,
    thumbnails: dict[int, bytes] | None = None,
    title: str = "",
) -> None:
    """Escribe un proyecto 3MF con las piezas ubicadas en sus placas."""
    if not items:
        raise SceneError("La placa está vacía")
    plates = sorted(plates, key=lambda p: p["index"]) or [{"index": 1, "name": ""}]
    # Renumerar placas 1..N sin huecos (las placas vacías se descartan)
    used = sorted({it.plate for it in items})
    renum = {old: i + 1 for i, old in enumerate(used)}
    names = {p["index"]: p.get("name", "") for p in plates}
    count = len(used)

    out = io.StringIO()
    w = out.write
    w('<?xml version="1.0" encoding="UTF-8"?>\n')
    w('<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" '
      'xmlns:BambuStudio="http://schemas.bambulab.com/package/2021">\n')
    w(f' <metadata name="Application">{APPLICATION}</metadata>\n')
    w(' <metadata name="BambuStudio:3mfVersion">1</metadata>\n')
    if title:
        w(f' <metadata name="Title">{_xml(title)}</metadata>\n')
    w(" <resources>\n")
    next_id = 1
    obj_ids: dict[str, tuple[int, list[int]]] = {}
    used_keys = list(dict.fromkeys(it.key for it in items))
    for key in used_keys:
        obj = objects[key]
        part_ids = []
        for part in obj.parts:
            pid = next_id
            next_id += 1
            part_ids.append(pid)
            w(f'  <object id="{pid}" type="model">\n   <mesh>\n    <vertices>\n')
            w("".join(f'     <vertex x="{x:.6g}" y="{y:.6g}" z="{z:.6g}"/>\n' for x, y, z in part.vertices.tolist()))
            w("    </vertices>\n    <triangles>\n")
            paint = part.paint or {}
            for i, (a, b, c) in enumerate(part.triangles.tolist()):
                extra = "".join(f' {k}="{vals[i]}"' for k, vals in paint.items() if vals[i])
                w(f'     <triangle v1="{a}" v2="{b}" v3="{c}"{extra}/>\n')
            w("    </triangles>\n   </mesh>\n  </object>\n")
        cid = next_id
        next_id += 1
        obj_ids[key] = (cid, part_ids)
        w(f'  <object id="{cid}" type="model">\n   <components>\n')
        for pid, part in zip(part_ids, obj.parts):
            w(f'    <component objectid="{pid}" transform="{fmt_transform(part.transform)}"/>\n')
        w("   </components>\n  </object>\n")
    w(" </resources>\n <build>\n")
    instances: dict[str, int] = {}
    plate_instances: dict[int, list[tuple[int, int, int]]] = {}
    for n, it in enumerate(items):
        cid, _ = obj_ids[it.key]
        inst = instances.get(it.key, 0)
        instances[it.key] = inst + 1
        plate = renum[it.plate]
        ox, oy = plate_origin(plate, count, bed)
        w(f'  <item objectid="{cid}" transform="{fmt_transform(shift(it.matrix, ox, oy))}" printable="1"/>\n')
        plate_instances.setdefault(plate, []).append((cid, inst, n + 1))
    w(" </build>\n</model>\n")

    # Metadata/model_settings.config: nombres, filamentos y placas
    cfg = ['<?xml version="1.0" encoding="UTF-8"?>\n<config>\n']
    for key in used_keys:
        obj = objects[key]
        cid, part_ids = obj_ids[key]
        # El filamento de un objeto puede cambiar por instancia en el editor: se usa el de la primera
        ext = next((it.extruder for it in items if it.key == key and it.extruder), None) or obj.extruder or 1
        cfg.append(f'  <object id="{cid}">\n    <metadata key="name" value="{_xml(obj.name)}"/>\n'
                   f'    <metadata key="extruder" value="{ext}"/>\n')
        for pid, part in zip(part_ids, obj.parts):
            cfg.append(f'    <part id="{pid}" subtype="{_xml(part.subtype)}">\n'
                       f'      <metadata key="name" value="{_xml(part.name or obj.name)}"/>\n')
            if part.extruder and len(obj.parts) > 1:
                cfg.append(f'      <metadata key="extruder" value="{part.extruder}"/>\n')
            cfg.append("    </part>\n")
        cfg.append("  </object>\n")
    for old in used:
        plate = renum[old]
        cfg.append(f'  <plate>\n    <metadata key="plater_id" value="{plate}"/>\n'
                   f'    <metadata key="plater_name" value="{_xml(names.get(old, ""))}"/>\n'
                   '    <metadata key="locked" value="false"/>\n')
        if thumbnails and old in thumbnails:
            cfg.append(f'    <metadata key="thumbnail_file" value="Metadata/plate_{plate}.png"/>\n')
        for cid, inst, ident in plate_instances.get(plate, []):
            cfg.append('    <model_instance>\n'
                       f'      <metadata key="object_id" value="{cid}"/>\n'
                       f'      <metadata key="instance_id" value="{inst}"/>\n'
                       f'      <metadata key="identify_id" value="{ident}"/>\n'
                       '    </model_instance>\n')
        cfg.append("  </plate>\n")
    cfg.append("</config>\n")

    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("_rels/.rels", RELS)
        z.writestr("3D/3dmodel.model", out.getvalue())
        z.writestr("Metadata/model_settings.config", "".join(cfg))
        if settings:
            z.writestr("Metadata/project_settings.config", _fit_settings(settings, bed))
        for old, png in (thumbnails or {}).items():
            if old in renum:
                z.writestr(f"Metadata/plate_{renum[old]}.png", png)


def _fit_settings(settings: bytes, bed: tuple[float, float]) -> bytes:
    """Ajusta la cama del proyecto a la impresora de destino (las placas se ubican con ese tamaño)."""
    try:
        cfg = json.loads(settings)
    except ValueError:
        return settings
    cfg["printable_area"] = ["0x0", f"{bed[0]:g}x0", f"{bed[0]:g}x{bed[1]:g}", f"0x{bed[1]:g}"]
    return json.dumps(cfg, indent=4).encode()


def _xml(s: str) -> str:
    return (s or "").replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


def decode_png(data_url: str) -> bytes | None:
    if not data_url:
        return None
    b64 = data_url.split(",", 1)[-1]
    try:
        raw = base64.b64decode(b64, validate=True)
    except ValueError:
        return None
    return raw if raw.startswith(b"\x89PNG") and len(raw) < 4_000_000 else None
