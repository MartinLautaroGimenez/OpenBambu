"""Biblioteca, mapeo de AMS y cola de impresión (con la impresora simulada)."""

import io
import time
import zipfile

import pytest
from fastapi.testclient import TestClient

from openbambu.config import PrinterConfig, Settings
from openbambu.library.mapping import build_ams_payload, suggest_mapping
from openbambu.library.threemf import read_3mf
from openbambu.main import create_app

TOKEN = "t"
H = {"Authorization": f"Bearer {TOKEN}"}

SLICE_INFO = """<?xml version="1.0" encoding="UTF-8"?>
<config>
  <plate>
    <metadata key="index" value="1"/>
    <metadata key="prediction" value="3720"/>
    <metadata key="weight" value="21.5"/>
    <filament id="1" type="PLA" color="#FF0000" used_m="5.1" used_g="15.2"/>
    <filament id="3" type="TPU" color="#000000" used_m="2.0" used_g="6.3"/>
  </plate>
</config>"""


def make_3mf(plates=(1,)) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("3D/3dmodel.model", "<model/>")
        for p in plates:
            z.writestr(f"Metadata/plate_{p}.gcode", "G28\n")
            z.writestr(f"Metadata/plate_{p}.png", b"\x89PNG fake")
        z.writestr("Metadata/slice_info.config", SLICE_INFO)
    return buf.getvalue()


def test_read_3mf(tmp_path):
    f = tmp_path / "x.gcode.3mf"
    f.write_bytes(make_3mf((1, 2)))
    meta = read_3mf(f)
    assert meta["sliced"] and [p["index"] for p in meta["plates"]] == [1, 2]
    p1 = meta["plates"][0]
    assert p1["prediction_s"] == 3720 and p1["weight_g"] == 21.5 and p1["thumbnail"]
    assert [(x["id"], x["type"], x["color"]) for x in p1["filaments"]] == [(1, "PLA", "#FF0000"), (3, "TPU", "#000000")]


STATUS = {
    "ams": {
        "units": [{"trays": [
            {"global_id": 0, "loaded": True, "type": "PLA", "color": "#FFFFFF"},
            {"global_id": 1, "loaded": True, "type": "PLA", "color": "#E4002B"},
            {"global_id": 2, "loaded": True, "type": "PETG", "color": "#FF0000"},
            {"global_id": 3, "loaded": False, "type": None, "color": None},
        ]}],
        "external": {"global_id": 254, "loaded": True, "type": "TPU", "color": "#000000"},
    }
}


def test_suggest_mapping_prefers_type_then_color():
    fil = [{"id": 1, "type": "PLA", "color": "#FF0000"}, {"id": 3, "type": "TPU", "color": "#000000"},
           {"id": 4, "type": "ABS", "color": "#FFFFFF"}]
    m = suggest_mapping(fil, STATUS)
    assert [x["tray"] for x in m] == [1, 254, None]  # rojo PLA → A2 (no el PETG rojo); TPU → externo


def test_build_ams_payload():
    fil = [{"id": 1}, {"id": 3}]
    ams, ams2, use_ams = build_ams_payload(fil, {1: 1, 3: 254})
    assert ams == [1, -1, 254]
    assert ams2[0] == {"ams_id": 0, "slot_id": 1} and ams2[2] == {"ams_id": 255, "slot_id": 0}
    assert use_ams
    assert build_ams_payload([{"id": 1}], {1: 254})[2] is False  # todo externo → sin AMS


@pytest.fixture
def client(tmp_path):
    settings = Settings(api_token=TOKEN, data_dir=str(tmp_path),
                        printers=[PrinterConfig(id="sim", name="Sim", model="A1", mode="simulator")])
    with TestClient(create_app(settings)) as c:
        sim = c.app.state.manager.printers["sim"]
        sim.auto_demo = False
        time.sleep(0.8)
        yield c


def wait(cond, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.2)
    return False


def test_library_and_queue_flow(client):
    r = client.put("/api/library?filename=Soporte%20celular.gcode.3mf", content=make_3mf(), headers=H)
    assert r.status_code == 200, r.text
    item = r.json()
    assert item["name"] == "Soporte celular" and item["meta"]["plates"][0]["filaments"][1]["type"] == "TPU"
    assert client.get(f"/api/library/{item['id']}/plates/1/thumbnail.png", headers=H).content.startswith(b"\x89PNG")

    sugg = client.get(f"/api/library/{item['id']}/mapping?printer_id=sim&plate=1", headers=H).json()
    assert sugg[1]["tray"] == 254  # TPU → carrete externo

    # Sin asignar todos los filamentos se rechaza
    bad = client.post("/api/printers/sim/queue", json={"library_id": item["id"], "mapping": []}, headers=H)
    assert bad.status_code == 422

    mapping = [{"filament_id": 1, "tray": 2}, {"filament_id": 3, "tray": 254}]
    q = client.post("/api/printers/sim/queue",
                    json={"library_id": item["id"], "mapping": mapping, "copies": 2}, headers=H).json()
    assert [j["name"] for j in q["jobs"]] == ["Soporte celular · copia 1/2", "Soporte celular · copia 2/2"]

    # La cola espera confirmación de cama libre
    assert wait(lambda: client.get("/api/printers/sim/queue", headers=H).json()["waiting_bed_clear"])
    events = [e["type"] for e in client.get("/api/events", headers=H).json()]
    assert "queue_bed_clear" in events

    client.post("/api/printers/sim/queue/bed-clear", headers=H)
    assert wait(lambda: client.get("/api/printers/sim/status", headers=H).json()["state"] in ("PREPARE", "RUNNING"))
    st = client.get("/api/printers/sim/status", headers=H).json()
    assert st["job"]["name"] == "Soporte celular · copia 1/2"
    files = client.get("/api/printers/sim/files", headers=H).json()
    assert any(f["name"] == f"ob_{item['id']}.gcode.3mf" and f["printable"] for f in files)

    # Terminar la impresión: el trabajo queda hecho y la 2ª copia espera cama libre
    sim = client.app.state.manager.printers["sim"]
    sim.p.update(gcode_state="RUNNING", stg_cur=0)
    sim._emit()
    assert wait(lambda: client.get("/api/printers/sim/queue", headers=H).json()["jobs"][0]["status"] == "printing")
    sim._progress = 100
    sim._finish("FINISH")
    sim._emit()

    def second_waiting():
        q = client.get("/api/printers/sim/queue", headers=H).json()
        return q["waiting_bed_clear"] and [j["status"] for j in q["jobs"]] == ["queued", "done"]

    assert wait(second_waiting)

    # No se puede borrar un archivo con trabajos pendientes
    assert client.delete(f"/api/library/{item['id']}", headers=H).status_code == 409


def test_start_now_and_sd(client):
    item = client.put("/api/library?filename=a.gcode.3mf", content=make_3mf(), headers=H).json()
    mapping = [{"filament_id": 1, "tray": 0}, {"filament_id": 3, "tray": 254}]
    client.post("/api/printers/sim/queue",
                json={"library_id": item["id"], "mapping": mapping, "start_now": True}, headers=H)
    assert wait(lambda: client.get("/api/printers/sim/status", headers=H).json()["state"] in ("PREPARE", "RUNNING"))

    # importar desde la SD y borrar
    path = f"/ob_{item['id']}.gcode.3mf"
    imported = client.post("/api/printers/sim/files/import", json={"path": path}, headers=H).json()
    assert imported["meta"]["sliced"] and imported["source"] == "printer:sim"
    # "/../etc" se normaliza a "/etc" dentro de la SD (no existe): nunca sale de la raíz
    assert client.get("/api/printers/sim/files?path=/../etc", headers=H).status_code == 503


def test_rejects_non_3mf(client):
    r = client.put("/api/library?filename=x.exe", content=b"MZ", headers=H)
    assert r.status_code == 422
    # Un STL se acepta como modelo sin laminar
    r = client.put("/api/library?filename=cubo.stl", content=b"solid cubo", headers=H)
    assert r.status_code == 200 and r.json()["meta"] == {"sliced": False, "plates": [], "format": "stl"}
    r = client.put("/api/library?filename=x.3mf", content=b"not a zip", headers=H)
    assert r.status_code == 422


def test_scheduled_job_waits_until_time(client):
    item = client.put("/api/library?filename=noche.gcode.3mf", content=make_3mf(), headers=H).json()
    mapping = [{"filament_id": 1, "tray": 0}, {"filament_id": 3, "tray": 254}]
    at = time.time() + 3
    q = client.post("/api/printers/sim/queue", json={"library_id": item["id"], "mapping": mapping,
                                                     "start_after": at, "bed_clear": True}, headers=H).json()
    assert q["jobs"][0]["start_after"] == at and q["next_scheduled"] == at
    assert not q["waiting_bed_clear"]  # todavía no es la hora
    time.sleep(1.5)
    assert client.get("/api/printers/sim/status", headers=H).json()["state"] == "IDLE"
    assert wait(lambda: client.get("/api/printers/sim/status", headers=H).json()["state"] in ("PREPARE", "RUNNING"),
                timeout=12)
    # validaciones
    bad = {"library_id": item["id"], "mapping": mapping, "start_after": time.time() - 3600}
    assert client.post("/api/printers/sim/queue", json=bad, headers=H).status_code == 422
    bad = {**bad, "start_after": time.time() + 60, "start_now": True}
    assert client.post("/api/printers/sim/queue", json=bad, headers=H).status_code == 422
