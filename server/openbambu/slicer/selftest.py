"""Autotest del laminador: lamina un cubo de 20 mm con los perfiles de la A1.

    docker compose exec openbambu python3 -m openbambu.slicer.selftest
"""

from __future__ import annotations

import asyncio
import struct
import sys
import tempfile
import time
import zipfile
from pathlib import Path

from ..library.threemf import read_3mf
from .orca import orca_binary, orca_version, run_orca
from .profiles import MACHINE_FOR_MODEL, get_library


def cube_stl(path: Path, size: float = 20.0) -> None:
    s = size
    v = [(0, 0, 0), (s, 0, 0), (s, s, 0), (0, s, 0), (0, 0, s), (s, 0, s), (s, s, s), (0, s, s)]
    faces = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
             (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]
    data = bytearray(b"OpenBambu selftest".ljust(80, b"\0"))
    data += struct.pack("<I", len(faces))
    for a, b, c in faces:
        data += struct.pack("<3f", 0, 0, 0)
        for i in (a, b, c):
            data += struct.pack("<3f", *v[i])
        data += b"\0\0"
    path.write_bytes(bytes(data))


async def main(model: str = "A1") -> int:
    print(f"OrcaSlicer: {orca_binary()} (versión {orca_version()})")
    lib = get_library()
    if not lib or not orca_binary():
        print("ERROR: OrcaSlicer o sus perfiles no están instalados")
        for d in sorted(Path("/opt/orca").glob("**/profiles"))[:5]:
            print("  carpeta de perfiles encontrada:", d)
            entries = sorted(d.iterdir())
            print("   ", len(entries), "entradas:", [e.name for e in entries[:40]])
            for e in entries:
                if e.name.upper().startswith("BBL"):
                    if e.is_dir():
                        print("   ", e.name, "->", [x.name for x in sorted(e.iterdir())[:20]])
                    elif zipfile.is_zipfile(e):
                        with zipfile.ZipFile(e) as z:
                            print("   ", e.name, "(zip) ->", z.namelist()[:15])
        return 1
    machine = MACHINE_FOR_MODEL[model]
    procs = lib.processes(machine)
    print(f"Perfiles para {machine}: {len(procs)} de proceso, {len(lib.filaments(machine))} de filamento")
    process = next(p["name"] for p in procs if p["name"].startswith("0.20mm Standard"))
    filament = lib.default_filament(machine, "PLA")
    print(f"Usando: {process} + {filament}")
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        stl = work / "cubo.stl"
        cube_stl(stl)
        t0 = time.time()
        result = await run_orca([stl, stl], lib.resolve(machine), lib.resolve(process), [lib.resolve(filament)],
                                work / "job", on_line=lambda line: print("  orca:", line))
        meta = read_3mf(result)
        plate = meta["plates"][0]
        print(f"OK en {time.time() - t0:.0f} s: {result.stat().st_size // 1024} KB, "
              f"{len(meta['plates'])} placa(s), tiempo estimado {plate['prediction_s']} s, "
              f"{plate['weight_g']} g, miniatura: {plate['thumbnail']}, filamentos: {plate['filaments']}")
        return 0 if meta["sliced"] else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main(*sys.argv[1:])))
