"""Laminador: perfiles, ajustes y flujo completo con un OrcaSlicer falso."""

import json
import stat
import sys
import textwrap
import time

import pytest
from fastapi.testclient import TestClient

from openbambu.config import PrinterConfig, Settings
from openbambu.main import create_app
from openbambu.slicer import profiles as P

TOKEN = "t"
H = {"Authorization": f"Bearer {TOKEN}"}
MACHINE = "Bambu Lab A1 0.4 nozzle"


def write(root, kind, name, data):
    d = root / kind
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{name}.json").write_text(json.dumps({"name": name, **data}))


@pytest.fixture
def profile_dir(tmp_path, monkeypatch):
    root = tmp_path / "BBL"
    write(root, "machine", "fdm_machine_common", {"type": "machine", "instantiation": "false", "nozzle_diameter": ["0.4"]})
    write(root, "machine", MACHINE, {"type": "machine", "inherits": "fdm_machine_common", "printer_model": "Bambu Lab A1"})
    write(root, "process", "fdm_process_common", {"type": "process", "instantiation": "false",
                                                   "layer_height": "0.2", "wall_loops": "2",
                                                   "sparse_infill_density": "15%", "enable_support": "0"})
    for lh, label in (("0.20", "Standard"), ("0.12", "Fine"), ("0.28", "Extra Draft")):
        write(root, "process", f"{lh}mm {label} @BBL A1", {"type": "process", "inherits": "fdm_process_common",
                                                           "layer_height": lh, "compatible_printers": [MACHINE]})
    write(root, "process", "0.20mm Standard @BBL X1C", {"type": "process", "inherits": "fdm_process_common",
                                                        "compatible_printers": ["Bambu Lab X1 Carbon 0.4 nozzle"]})
    write(root, "filament", "fdm_filament_common", {"type": "filament", "instantiation": "false"})
    for n, t, v in (("Bambu PLA Basic @BBL A1", "PLA", "Bambu Lab"), ("Generic PETG @BBL A1", "PETG", "Generic"),
                    ("Generic TPU @BBL A1", "TPU", "Generic")):
        write(root, "filament", n, {"type": "filament", "inherits": "fdm_filament_common", "filament_type": [t],
                                    "filament_vendor": [v], "compatible_printers": [MACHINE]})
    monkeypatch.setenv("OB_ORCA_PROFILES", str(root))
    P.get_library.cache_clear()
    yield root
    P.get_library.cache_clear()


def test_profiles_listing_and_resolution(profile_dir):
    lib = P.get_library()
    procs = lib.processes(MACHINE)
    assert [p["label"] for p in procs] == ["0.12mm Fine", "0.20mm Standard", "0.28mm Extra Draft"]  # sin X1C
    resolved = lib.resolve("0.12mm Fine @BBL A1")
    assert resolved["wall_loops"] == "2" and resolved["layer_height"] == "0.12" and "inherits" not in resolved
    assert lib.default_filament(MACHINE, "pla") == "Bambu PLA Basic @BBL A1"
    assert lib.default_filament(MACHINE, "TPU") == "Generic TPU @BBL A1"
    assert lib.default_filament(MACHINE, "ABS") is None


def test_profiles_from_opc_zip(profile_dir, tmp_path, monkeypatch):
    """OrcaSlicer 2.5 empaqueta los perfiles en BBL.opc (zip)."""
    import zipfile

    opc = tmp_path / "profiles" / "BBL.opc"
    opc.parent.mkdir()
    with zipfile.ZipFile(opc, "w") as z:
        for f in profile_dir.rglob("*.json"):
            z.write(f, "BBL/" + f.relative_to(profile_dir).as_posix())
    monkeypatch.setenv("OB_ORCA_PROFILES", str(opc))
    P.get_library.cache_clear()
    lib = P.get_library()
    assert lib is not None and lib.root == opc
    assert [p["label"] for p in lib.processes(MACHINE)][0] == "0.12mm Fine"
    assert lib.resolve(MACHINE)["nozzle_diameter"] == ["0.4"]


def test_overrides():
    p = P.apply_overrides({"layer_height": "0.2"}, {"layer_height": 0.16, "infill": 30, "walls": 4,
                                                    "supports": "tree", "brim": False, "infill_pattern": "gyroid"})
    assert p == {"layer_height": "0.16", "sparse_infill_density": "30%", "wall_loops": "4", "enable_support": "1",
                 "support_type": "tree(auto)", "brim_type": "no_brim", "sparse_infill_pattern": "gyroid"}
    with pytest.raises(P.ProfileError):
        P.apply_overrides({}, {"layer_height": 1})
    with pytest.raises(P.ProfileError):
        P.apply_overrides({}, {"supports": "magic"})


FAKE_ORCA = textwrap.dedent('''\
    #!{python}
    import json, sys, zipfile, pathlib
    args = sys.argv[1:]
    def opt(name): return args[args.index(name) + 1]
    out = pathlib.Path(opt("--outputdir"))
    settings = [json.loads(pathlib.Path(f).read_text()) for f in opt("--load-settings").split(";")]
    fils = opt("--load-filaments").split(";")
    flags = {{"--slice", "--arrange", "--load-settings", "--load-filaments", "--outputdir", "--export-3mf"}}
    inputs = [a for i, a in enumerate(args) if not a.startswith("--") and args[i - 1] not in flags]
    import os
    pathlib.Path(os.environ["FAKE_ORCA_ARGS"]).write_text(
        json.dumps({{"settings": settings, "fils": len(fils), "inputs": inputs}}))
    if "FALLA" in inputs[0]:
        (out / "result.json").write_text(json.dumps({{"return_code": -50, "error_string": "Objeto fuera de la cama"}}))
        sys.exit(1)
    print("Slicing plate 1 ...", flush=True)
    with zipfile.ZipFile(out / opt("--export-3mf"), "w") as z:
        z.writestr("Metadata/plate_1.gcode", "G28\\n")
        z.writestr("Metadata/slice_info.config",
                   '<config><plate><metadata key="index" value="1"/><metadata key="prediction" value="600"/>'
                   '<filament id="1" type="PLA" color="#FFFFFF" used_g="3.2"/></plate></config>')
''')


@pytest.fixture
def client(tmp_path, profile_dir, monkeypatch):
    fake = tmp_path / "orca"
    fake.write_text(FAKE_ORCA.format(python=sys.executable))
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("OB_ORCA_BIN", str(fake))
    monkeypatch.setenv("DISPLAY", ":99")  # no usar xvfb-run en los tests
    monkeypatch.setenv("FAKE_ORCA_ARGS", str(tmp_path / "args.json"))
    settings = Settings(api_token=TOKEN, data_dir=str(tmp_path / "data"),
                        printers=[PrinterConfig(id="sim", name="Sim", model="A1", mode="simulator")])
    with TestClient(create_app(settings)) as c:
        c.app.state.manager.printers["sim"].auto_demo = False
        time.sleep(0.8)
        yield c


def wait_job(client, jid, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        j = client.get(f"/api/slicer/jobs/{jid}", headers=H).json()
        if j["status"] in ("done", "failed"):
            return j
        time.sleep(0.2)
    raise AssertionError("el laminado no terminó")


def test_slice_flow(client, tmp_path):
    assert client.get("/api/slicer", headers=H).json()["available"] is True
    prof = client.get("/api/slicer/profiles?printer_id=sim", headers=H).json()
    assert prof["machine"] == MACHINE and prof["default_process"] == "0.20mm Standard @BBL A1"
    # El simulador tiene PLA, PLA, PETG, PLA cargados
    assert {t["profile"] for t in prof["tray_filaments"]} == {"Bambu PLA Basic @BBL A1", "Generic PETG @BBL A1"}

    item = client.put("/api/library?filename=Engranaje.stl", content=b"solid x", headers=H).json()
    body = {"printer_id": "sim", "process": "0.20mm Standard @BBL A1", "filaments": ["Bambu PLA Basic @BBL A1"],
            "overrides": {"layer_height": 0.16, "infill": 25, "supports": "tree", "brim": True}, "copies": 3}
    job = client.post(f"/api/library/{item['id']}/slice", json=body, headers=H).json()
    done = wait_job(client, job["id"])
    assert done["status"] == "done", done
    assert any("Slicing plate" in line for line in done["log_tail"])

    result = client.get(f"/api/library/{done['result_id']}", headers=H).json()
    assert result["name"] == "Engranaje ×3" and result["meta"]["sliced"]
    assert result["meta"]["slice_settings"]["overrides"]["infill"] == 25

    # Lo que recibió OrcaSlicer: perfiles aplanados con los ajustes y 3 copias del modelo
    args = json.loads((tmp_path / "args.json").read_text())
    machine, process = args["settings"]
    assert machine["name"] == MACHINE and "inherits" not in machine and machine["nozzle_diameter"] == ["0.4"]
    assert process["layer_height"] == "0.16" and process["sparse_infill_density"] == "25%"
    assert process["support_type"] == "tree(auto)" and process["brim_type"] == "auto_brim"
    assert process["wall_loops"] == "2"  # heredado del perfil base
    assert len(args["inputs"]) == 3 and args["fils"] == 1


def test_slice_errors(client):
    item = client.put("/api/library?filename=FALLA.stl", content=b"solid x", headers=H).json()
    body = {"printer_id": "sim", "process": "0.20mm Standard @BBL A1", "filaments": ["Bambu PLA Basic @BBL A1"]}
    job = client.post(f"/api/library/{item['id']}/slice", json=body, headers=H).json()
    done = wait_job(client, job["id"])
    assert done["status"] == "failed" and done["error"] == "Objeto fuera de la cama"

    bad = dict(body, process="No existe")
    assert client.post(f"/api/library/{item['id']}/slice", json=bad, headers=H).status_code == 422
    bad = dict(body, overrides={"layer_height": 2})
    assert client.post(f"/api/library/{item['id']}/slice", json=bad, headers=H).status_code == 422
