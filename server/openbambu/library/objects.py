"""Omitir objetos durante la impresión.

Los objetos de la placa se identifican con el ``identify_id`` que guarda el
laminador (``Metadata/plate_N.json`` y marcas en el G-code). La impresora
recibe ``skip_objects`` con esos ids y reporta los ya omitidos en ``s_obj``.
"""

from __future__ import annotations

import asyncio
import json
import posixpath
import re
from pathlib import Path

from .ingest import ingest, safe_name
from .preview import PreviewError, build_preview
from .threemf import read_plate_objects

LIB_FILE = re.compile(r"ob_([0-9a-f]{16})\.gcode\.3mf$")


class ObjectsError(ValueError):
    pass


class ObjectsService:
    def __init__(self, mgr):
        self.mgr = mgr
        # archivo de la SD ya importado para la impresión en curso: pid -> (archivo, library_id)
        self._sd_cache: dict[str, tuple[str, str]] = {}

    async def _current_file(self, pid: str, snap: dict) -> tuple[str, int]:
        store = self.mgr.store
        rec = store.open_print(pid)
        if rec and rec["library_id"] and store.get_file(rec["library_id"]):
            return rec["library_id"], rec["plate"] or 1
        job = store.active_job(pid)
        if job and store.get_file(job["library_id"]):
            return job["library_id"], job["plate"]
        file = snap["job"]["file"] or ""
        if (m := LIB_FILE.search(file)) and store.get_file(m[1]):
            return m[1], 1
        if not file.lower().endswith(".3mf"):
            raise ObjectsError("No se puede identificar el archivo que se está imprimiendo")
        cached = self._sd_cache.get(pid)
        if cached and cached[0] == file and store.get_file(cached[1]):
            return cached[1], 1
        # Impresión iniciada desde otro lado: traer el archivo de la SD
        remote = file[len("/sdcard"):] if file.startswith("/sdcard") else file
        remote = "/" + remote.lstrip("/")
        lid, folder = store.new_file_dir()
        filename = safe_name(posixpath.basename(remote))
        try:
            await self.mgr.printers[pid].files.adownload(remote, folder / filename)
            item = ingest(store, lid, folder, filename, f"printer:{pid}")
        except Exception as e:  # noqa: BLE001
            raise ObjectsError(f"No se pudo leer el archivo de la impresora: {e}") from e
        self._sd_cache[pid] = (file, item["id"])
        return item["id"], 1

    async def objects(self, pid: str) -> dict:
        p = self.mgr.printers[pid]
        snap = p.state.snapshot()
        if snap["state"] not in ("RUNNING", "PAUSE", "PREPARE"):
            raise ObjectsError("No hay una impresión en curso")
        lid, plate = await self._current_file(pid, snap)
        item = self.mgr.store.get_file(lid)
        path = self.mgr.store.file_path(item)

        objs = {o["id"]: o for o in read_plate_objects(path, plate)}
        try:
            prev = json.loads(await asyncio.to_thread(
                build_preview, path, plate, Path(self.mgr.settings.data_dir) / "cache" / "preview"))
            for o in prev.get("objects", []):
                base = objs.setdefault(o["id"], {"id": o["id"], "name": None, "bbox": None})
                base["bbox"] = base["bbox"] or o["bbox"]
                base["name"] = base["name"] or o.get("name")
        except PreviewError:
            pass
        skipped = set(snap.get("skipped_objects") or [])
        out = []
        for i, o in enumerate(sorted(objs.values(), key=lambda x: x["id"]), 1):
            out.append({**o, "name": o["name"] or f"Objeto {i}", "skipped": o["id"] in skipped})
        return {"library_id": lid, "plate": plate, "objects": out, "bed": list(p.caps.bed_size[:2])}

    async def skip(self, pid: str, ids: list[int]) -> dict:
        from ..printer import commands as C

        info = await self.objects(pid)
        known = {o["id"] for o in info["objects"]}
        if not info["objects"]:
            raise ObjectsError("Este archivo no tiene objetos identificables (laminalo con 'Excluir objetos' activado)")
        ids = sorted(set(ids))
        if not ids or not set(ids) <= known:
            raise ObjectsError("Objetos inválidos")
        remaining = [o for o in info["objects"] if not o["skipped"] and o["id"] not in ids]
        if not remaining:
            raise ObjectsError("No se pueden omitir todos los objetos: detené la impresión")
        skipped = sorted({o["id"] for o in info["objects"] if o["skipped"]} | set(ids))
        res = await self.mgr.printers[pid].send(C.skip_objects(skipped))
        if res.get("result") == "failed":
            raise ObjectsError("La impresora rechazó la orden")
        return res
