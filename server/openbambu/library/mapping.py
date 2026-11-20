"""Asignación automática de filamentos del archivo a bandejas del AMS."""

from __future__ import annotations

EXTERNAL = 254
# El AMS lite no admite filamentos flexibles: van por el carrete externo
EXTERNAL_ONLY = {"TPU", "TPU-AMS", "PEBA"}


def _rgb(hex_: str | None) -> tuple[int, int, int] | None:
    if not hex_ or len(hex_) < 7:
        return None
    try:
        return int(hex_[1:3], 16), int(hex_[3:5], 16), int(hex_[5:7], 16)
    except ValueError:
        return None


def color_distance(a: str | None, b: str | None) -> float:
    ra, rb = _rgb(a), _rgb(b)
    if ra is None or rb is None:
        return 500.0
    # distancia "redmean", barata y razonable para colores percibidos
    rm = (ra[0] + rb[0]) / 2
    dr, dg, db = ra[0] - rb[0], ra[1] - rb[1], ra[2] - rb[2]
    return ((2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db) ** 0.5


def _family(t: str | None) -> str:
    return (t or "").upper().split("-")[0].split(" ")[0]


def available_trays(status: dict) -> list[dict]:
    trays = [t for u in status["ams"]["units"] for t in u["trays"] if t["loaded"]]
    ext = status["ams"].get("external")
    if ext and ext.get("loaded"):
        trays.append(ext)
    return trays


def suggest_mapping(filaments: list[dict], status: dict) -> list[dict]:
    """Para cada filamento del archivo sugiere una bandeja.

    Devuelve ``[{"filament_id", "tray", "reason"}]``; ``tray`` es el id global
    (0-15 AMS, 254 externo) o ``None`` si no hay una bandeja compatible.
    """
    trays = available_trays(status)
    out = []
    for f in filaments:
        ftype = _family(f.get("type"))
        if ftype in EXTERNAL_ONLY:
            out.append({"filament_id": f["id"], "tray": EXTERNAL,
                        "reason": f"{ftype} va por el carrete externo"})
            continue
        candidates = [t for t in trays if _family(t.get("type")) == ftype]
        if not candidates:
            out.append({"filament_id": f["id"], "tray": None,
                        "reason": f"No hay {ftype} cargado"})
            continue
        best = min(candidates, key=lambda t: (color_distance(f.get("color"), t.get("color")), t["global_id"]))
        out.append({"filament_id": f["id"], "tray": best["global_id"], "reason": "ok"})
    return out


def build_ams_payload(filaments: list[dict], mapping: dict[int, int]) -> tuple[list[int], list[dict], bool]:
    """Convierte {filament_id: tray} en los campos del comando ``project_file``.

    ``ams_mapping`` es un array indexado por (filament_id - 1) con el id global
    de la bandeja (-1 si el filamento no se usa). ``use_ams`` es False cuando
    todo va por el carrete externo.
    """
    if not filaments:
        return [], [], False
    size = max(f["id"] for f in filaments)
    ams_mapping = [-1] * size
    ams_mapping2 = [{"ams_id": 255, "slot_id": 255} for _ in range(size)]
    for f in filaments:
        tray = mapping.get(f["id"])
        if tray is None:
            continue
        ams_mapping[f["id"] - 1] = tray
        ams_mapping2[f["id"] - 1] = (
            {"ams_id": 255, "slot_id": 0} if tray == EXTERNAL else {"ams_id": tray // 4, "slot_id": tray % 4}
        )
    used = [t for t in ams_mapping if t >= 0]
    use_ams = any(t != EXTERNAL for t in used)
    return ams_mapping, ams_mapping2, use_ams
