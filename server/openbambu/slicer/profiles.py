"""Perfiles de laminado de OrcaSlicer (carpeta ``resources/profiles/BBL``).

Los perfiles del sistema heredan unos de otros (``inherits``). Para pasarlos
al CLI se "aplanan": se resuelve la cadena de herencia y se escribe un JSON
completo, sobre el que además se aplican los ajustes elegidos en la app.
"""

from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path

# Nombre del perfil de máquina de Orca para cada modelo (boquilla 0.4)
MACHINE_FOR_MODEL = {
    "A1": "Bambu Lab A1 0.4 nozzle",
    "A1MINI": "Bambu Lab A1 mini 0.4 nozzle",
    "P1P": "Bambu Lab P1P 0.4 nozzle",
    "P1S": "Bambu Lab P1S 0.4 nozzle",
    "X1C": "Bambu Lab X1 Carbon 0.4 nozzle",
    "X1E": "Bambu Lab X1E 0.4 nozzle",
}

DEFAULT_PROFILE_DIRS = [
    "/opt/orca/resources/profiles/BBL",
    "/opt/orca/squashfs-root/resources/profiles/BBL",
]


class ProfileError(ValueError):
    pass


def profiles_dir() -> Path | None:
    candidates = [os.getenv("OB_ORCA_PROFILES", "")] + DEFAULT_PROFILE_DIRS
    for c in candidates:
        if c and (Path(c) / "machine").is_dir():
            return Path(c)
    # La ubicación dentro del AppImage cambia entre versiones: buscarla
    orca = Path("/opt/orca")
    if orca.is_dir() and not os.getenv("OB_ORCA_PROFILES"):
        for pattern in ("*/profiles/BBL", "*/*/profiles/BBL", "*/*/*/profiles/BBL", "*/*/*/*/profiles/BBL"):
            for found in sorted(orca.glob(pattern)):
                if (found / "machine").is_dir():
                    return found
    return None


class ProfileLibrary:
    """Índice de perfiles por nombre dentro de un directorio de vendor."""

    def __init__(self, root: Path):
        self.root = root
        self.by_name: dict[str, tuple[str, Path]] = {}
        self._raw: dict[str, dict] = {}
        self._resolved: dict[str, dict] = {}
        for kind in ("machine", "process", "filament"):
            for f in (root / kind).rglob("*.json"):
                try:
                    data = json.loads(f.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue
                if isinstance(data, dict) and data.get("name"):
                    self.by_name[data["name"]] = (kind, f)
                    self._raw[data["name"]] = data

    def raw(self, name: str) -> dict:
        if name not in self._raw:
            raise ProfileError(f"Perfil no encontrado: {name}")
        return self._raw[name]

    def resolve(self, name: str, _depth: int = 0) -> dict:
        """Devuelve el perfil con toda su herencia aplicada."""
        if name in self._resolved:
            return dict(self._resolved[name])
        if _depth > 20:
            raise ProfileError(f"Herencia demasiado profunda en {name}")
        data = self.raw(name)
        parent = data.get("inherits")
        base = self.resolve(parent, _depth + 1) if parent else {}
        merged = {**base, **data}
        merged.pop("inherits", None)
        self._resolved[name] = merged
        return dict(merged)

    def kind(self, name: str) -> str:
        return self.by_name[name][0]

    def _listed(self, kind: str, machine: str) -> list[dict]:
        out = []
        for name, (k, _) in self.by_name.items():
            if k != kind:
                continue
            raw = self.raw(name)
            if str(raw.get("instantiation", "true")).lower() != "true":
                continue
            try:
                p = self.resolve(name)
            except ProfileError:
                continue
            compat = p.get("compatible_printers") or []
            if compat and machine not in compat:
                continue
            out.append(p)
        return out

    def processes(self, machine: str) -> list[dict]:
        items = [
            {
                "name": p["name"],
                "layer_height": _num(p.get("layer_height")),
                "label": p["name"].split(" @")[0],
            }
            for p in self._listed("process", machine)
        ]
        return sorted(items, key=lambda x: (x["layer_height"] or 0, x["name"]))

    def filaments(self, machine: str) -> list[dict]:
        items = []
        for p in self._listed("filament", machine):
            ftype = _first(p.get("filament_type")) or "PLA"
            items.append(
                {
                    "name": p["name"],
                    "type": ftype,
                    "vendor": _first(p.get("filament_vendor")) or "",
                    "label": p["name"].split(" @")[0],
                }
            )
        return sorted(items, key=lambda x: (x["vendor"] != "Bambu Lab", x["type"], x["name"]))

    def default_filament(self, machine: str, ftype: str) -> str | None:
        """Elige un perfil de filamento razonable para un tipo (PLA, PETG, TPU...)."""
        ftype = ftype.upper()
        options = [f for f in self.filaments(machine) if f["type"].upper() == ftype]
        for pref in (f"Bambu {ftype} Basic", f"Generic {ftype}", "Bambu"):
            for f in options:
                if f["name"].startswith(pref):
                    return f["name"]
        return options[0]["name"] if options else None


def _first(v):
    if isinstance(v, list):
        return v[0] if v else None
    return v


def _num(v) -> float | None:
    try:
        return float(_first(v))
    except (TypeError, ValueError):
        return None


@lru_cache(maxsize=1)
def get_library() -> ProfileLibrary | None:
    d = profiles_dir()
    return ProfileLibrary(d) if d else None


# ---- ajustes que se pueden cambiar desde la app ---------------------------------
SUPPORT_TYPES = {"none": None, "normal": "normal(auto)", "tree": "tree(auto)"}
INFILL_PATTERNS = {"grid", "gyroid", "honeycomb", "cubic", "line", "rectilinear", "adaptivecubic", "lightning"}


def apply_overrides(process: dict, o: dict) -> dict:
    """Aplica los ajustes de la app al perfil de proceso aplanado."""
    p = dict(process)
    if (lh := o.get("layer_height")) is not None:
        if not 0.04 <= float(lh) <= 0.4:
            raise ProfileError("Altura de capa fuera de rango (0.04-0.4 mm)")
        p["layer_height"] = f"{float(lh):.2f}"
    if (inf := o.get("infill")) is not None:
        if not 0 <= int(inf) <= 100:
            raise ProfileError("Relleno fuera de rango (0-100 %)")
        p["sparse_infill_density"] = f"{int(inf)}%"
    if (pat := o.get("infill_pattern")) is not None:
        if pat not in INFILL_PATTERNS:
            raise ProfileError("Patrón de relleno inválido")
        p["sparse_infill_pattern"] = pat
    if (walls := o.get("walls")) is not None:
        if not 1 <= int(walls) <= 10:
            raise ProfileError("Cantidad de paredes inválida (1-10)")
        p["wall_loops"] = str(int(walls))
    if (sup := o.get("supports")) is not None:
        if sup not in SUPPORT_TYPES:
            raise ProfileError("Tipo de soporte inválido")
        p["enable_support"] = "0" if sup == "none" else "1"
        if SUPPORT_TYPES[sup]:
            p["support_type"] = SUPPORT_TYPES[sup]
    if (brim := o.get("brim")) is not None:
        p["brim_type"] = "auto_brim" if brim else "no_brim"
    return p


def write_profile(data: dict, path: Path, name_suffix: str = "") -> Path:
    data = dict(data)
    data["from"] = "User"
    if name_suffix:
        data["name"] = f"{data['name']}{name_suffix}"
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    return path
