"""Omitir objetos durante la impresión."""

import io
import json
import time
import zipfile

from fastapi.testclient import TestClient

from openbambu.config import PrinterConfig, Settings
from openbambu.library.preview import parse_gcode
from openbambu.main import create_app
from tests.test_queue import wait

H = {"Authorization": "Bearer t"}


def square(x, y, size=10):
    return [f"G1 X{x} Y{y}", f"G1 X{x + size} Y{y} E0.5", f"G1 X{x + size} Y{y + size} E0.5",
            f"G1 X{x} Y{y + size} E0.5", f"G1 X{x} Y{y} E0.5"]


def bambu_gcode(ids=(101, 202, 303)):
    lines = ["M83", "G90"]
    for layer in (1, 2):
        lines += ["; CHANGE_LAYER", f"; Z_HEIGHT: {layer * 0.2:.1f}", "; FEATURE: Outer wall"]
        for i, oid in enumerate(ids):
            lines += [f"; start printing object, unique label id: {oid}", *square(20 + i * 40, 30),
                      f"; stop printing object, unique label id: {oid}"]
    return "\n".join(lines)


def make_objects_3mf(with_json=True) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("Metadata/plate_1.gcode", bambu_gcode())
        z.writestr("Metadata/slice_info.config",
                   '<config><plate><metadata key="index" value="1"/>'
                   '<filament id="1" type="PLA" color="#FFFFFF" used_g="3"/></plate></config>')
        if with_json:
            z.writestr("Metadata/plate_1.json", json.dumps({"bbox_objects": [
                {"id": 101, "name": "Engranaje.stl", "bbox": [20, 30, 30, 40]},
                {"id": 202, "name": "Engranaje.stl", "bbox": [60, 30, 70, 40]},
                {"id": 303, "name": "Tapa.stl", "bbox": [100, 30, 110, 40]},
            ]}))
    return buf.getvalue()


def test_parser_objects_bambu_and_orca_markers():
    d = parse_gcode(bambu_gcode().splitlines())
    assert [(o["id"], o["bbox"]) for o in d["objects"]] == [
        (101, [20.0, 30.0, 30.0, 40.0]), (202, [60.0, 30.0, 70.0, 40.0]), (303, [100.0, 30.0, 110.0, 40.0])]
    assert {p.get("o") for p in d["layers"][0]["paths"]} == {101, 202, 303}

    orca = ["M83", "; CHANGE_LAYER", "; Z_HEIGHT: 0.2", "; FEATURE: Outer wall",
            "; printing object Cubo.stl id:0 copy 0", *square(10, 10), "; stop printing object Cubo.stl id:0 copy 0",
            "; printing object Cubo.stl id:1 copy 0", *square(50, 10), "; stop printing object Cubo.stl id:1 copy 0",
            "; FEATURE: Skirt", "G1 X0 Y0", "G1 X5 Y0 E0.2"]
    d = parse_gcode(orca)
    assert [(o["id"], o["name"]) for o in d["objects"]] == [(0, "Cubo.stl"), (1, "Cubo.stl")]
    skirt = [p for p in d["layers"][0]["paths"] if p["t"] == "sk"][0]
    assert "o" not in skirt  # lo que está fuera de un objeto no se asocia


def start_print(c, sim, content, name="Placa.gcode.3mf"):
    item = c.put(f"/api/library?filename={name}", content=content, headers=H).json()
    c.post("/api/printers/sim/queue", json={"library_id": item["id"], "mapping": [{"filament_id": 1, "tray": 0}],
                                            "start_now": True}, headers=H)
    assert wait(lambda: c.get("/api/printers/sim/status", headers=H).json()["state"] in ("PREPARE", "RUNNING"))
    return item


def client(tmp_path):
    return TestClient(create_app(Settings(api_token="t", data_dir=str(tmp_path),
                                          printers=[PrinterConfig(id="sim", model="A1", mode="simulator")])))


def test_skip_objects_flow(tmp_path):
    with client(tmp_path) as c:
        sim = c.app.state.manager.printers["sim"]
        sim.auto_demo = False
        time.sleep(0.6)
        assert c.get("/api/printers/sim/objects", headers=H).status_code == 409  # sin impresión
        start_print(c, sim, make_objects_3mf())
        info = c.get("/api/printers/sim/objects", headers=H).json()
        assert [(o["id"], o["name"], o["skipped"]) for o in info["objects"]] == [
            (101, "Engranaje.stl", False), (202, "Engranaje.stl", False), (303, "Tapa.stl", False)]
        assert info["bed"] == [256, 256] and info["plate"] == 1

        r = c.post("/api/printers/sim/objects/skip", json={"ids": [202]}, headers=H).json()
        assert [o["id"] for o in r["objects"] if o["skipped"]] == [202]
        assert c.get("/api/printers/sim/status", headers=H).json()["skipped_objects"] == [202]
        # se envía la lista completa de omitidos
        c.post("/api/printers/sim/objects/skip", json={"ids": [303]}, headers=H)
        assert sim.p["s_obj"] == [202, 303]
        # no se pueden omitir todos ni ids desconocidos
        assert c.post("/api/printers/sim/objects/skip", json={"ids": [101]}, headers=H).status_code == 422
        assert c.post("/api/printers/sim/objects/skip", json={"ids": [999]}, headers=H).status_code == 422


def test_objects_from_gcode_only_and_sd_file(tmp_path):
    """Archivo sin plate_N.json, iniciado fuera de OpenBambu (desde la SD)."""
    with client(tmp_path) as c:
        sim = c.app.state.manager.printers["sim"]
        sim.auto_demo = False
        time.sleep(0.6)
        (sim.files.root / "externo.gcode.3mf").write_bytes(make_objects_3mf(with_json=False))
        sim._start_job("Externo", "/sdcard/externo.gcode.3mf")
        sim._emit()
        info = c.get("/api/printers/sim/objects", headers=H).json()
        assert [(o["id"], o["name"], o["bbox"]) for o in info["objects"]] == [
            (101, "Objeto 1", [20.0, 30.0, 30.0, 40.0]), (202, "Objeto 2", [60.0, 30.0, 70.0, 40.0]),
            (303, "Objeto 3", [100.0, 30.0, 110.0, 40.0])]
        lib = c.get(f"/api/library/{info['library_id']}", headers=H).json()
        assert lib["source"] == "printer:sim"
        # la segunda vez no vuelve a descargar
        assert c.get("/api/printers/sim/objects", headers=H).json()["library_id"] == info["library_id"]
        assert len(c.get("/api/library", headers=H).json()) == 1


def test_merge_orca_ids_differ_between_json_and_gcode():
    """OrcaSlicer: plate_1.json (103, 104) y el G-code (88, 69) usan ids distintos."""
    from openbambu.library.objects import merge_objects

    plate = [{"id": 103, "name": "cubo.stl", "bbox": [104.8, 80.2, 124.8, 99.8]},
             {"id": 104, "name": "cubo.stl", "bbox": [126.4, 80.2, 146.4, 99.8]}]
    gcode = [{"id": 88, "name": None, "bbox": [105.0, 80.5, 124.5, 99.5]},
             {"id": 69, "name": None, "bbox": [126.6, 80.5, 146.1, 99.5]}]
    m = merge_objects(plate, gcode)
    assert [(o["id"], o["aliases"], o["name"]) for o in m] == [(88, [88, 103], "cubo.stl"), (69, [69, 104], "cubo.stl")]
    # Sin plate_1.json: solo los del G-code
    assert [o["aliases"] for o in merge_objects([], gcode)] == [[88], [69]]
    # Sin marcas en el G-code: solo los de plate_1.json
    assert [o["id"] for o in merge_objects(plate, [])] == [103, 104]


def test_skip_sends_all_aliases(tmp_path):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("Metadata/plate_1.gcode", bambu_gcode(ids=(88, 69)))
        z.writestr("Metadata/plate_1.json", json.dumps({"bbox_objects": [
            {"id": 103, "name": "A.stl", "bbox": [20, 30, 30, 40]}, {"id": 104, "name": "B.stl", "bbox": [60, 30, 70, 40]}]}))
        z.writestr("Metadata/slice_info.config", '<config><plate><metadata key="index" value="1"/>'
                   '<filament id="1" type="PLA" color="#FFFFFF" used_g="3"/></plate></config>')
    with client(tmp_path) as c:
        sim = c.app.state.manager.printers["sim"]
        sim.auto_demo = False
        time.sleep(0.6)
        start_print(c, sim, buf.getvalue())
        objs = c.get("/api/printers/sim/objects", headers=H).json()["objects"]
        assert [(o["id"], o["name"]) for o in objs] == [(88, "A.stl"), (69, "B.stl")]
        r = c.post("/api/printers/sim/objects/skip", json={"ids": [69]}, headers=H).json()
        assert sim.p["s_obj"] == [69, 104]
        assert [o["skipped"] for o in r["objects"]] == [False, True]
