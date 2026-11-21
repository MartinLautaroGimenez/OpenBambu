"""Pruebas de la API usando la impresora simulada."""

import time

import pytest
from fastapi.testclient import TestClient

from openbambu.config import PrinterConfig, Settings
from openbambu.main import create_app

TOKEN = "test-token"
H = {"Authorization": f"Bearer {TOKEN}"}


@pytest.fixture
def client(tmp_path):
    settings = Settings(
        api_token=TOKEN,
        data_dir=str(tmp_path),
        printers=[PrinterConfig(id="sim", name="Sim A1", model="A1", mode="simulator")],
    )
    with TestClient(create_app(settings)) as c:
        time.sleep(0.8)  # dejar que el simulador "conecte"
        yield c


def test_auth_required(client):
    assert client.get("/api/health").status_code == 200
    assert client.get("/api/printers").status_code == 401
    assert client.get("/api/printers?token=wrong").status_code == 401
    assert client.get(f"/api/printers?token={TOKEN}").status_code == 200


def test_status_and_controls(client):
    printers = client.get("/api/printers", headers=H).json()
    assert printers[0]["id"] == "sim" and printers[0]["capabilities"]["max_bed_temp"] == 100
    assert printers[0]["status"]["connected"]

    assert client.post("/api/printers/sim/light", json={"on": False}, headers=H).json()["result"] == "success"
    assert client.get("/api/printers/sim/status", headers=H).json()["light"] is False

    client.post("/api/printers/sim/temperature", json={"target": "nozzle", "value": 200}, headers=H)
    assert client.get("/api/printers/sim/status", headers=H).json()["temps"]["nozzle_target"] == 200

    r = client.post("/api/printers/sim/temperature", json={"target": "bed", "value": 120}, headers=H)
    assert r.status_code == 422

    r = client.post("/api/printers/sim/fan", json={"fan": "chamber", "percent": 50}, headers=H)
    assert r.status_code == 422

    client.post("/api/printers/sim/ams/filament", json={"tray": 1, "type": "PETG", "color": "#00FF00"}, headers=H)
    tray = client.get("/api/printers/sim/status", headers=H).json()["ams"]["units"][0]["trays"][1]
    assert tray["type"] == "PETG" and tray["color"] == "#00FF00"

    assert client.get("/api/printers/nope/status", headers=H).status_code == 404


def test_print_lifecycle_and_events(client):
    sim = client.app.state.manager.printers["sim"]
    sim._start_job()
    sim.p.update(gcode_state="RUNNING", stg_cur=0)
    sim._emit()
    assert client.post("/api/printers/sim/home", headers=H).status_code == 409  # bloqueado imprimiendo
    client.post("/api/printers/sim/print/pause", headers=H)
    assert client.get("/api/printers/sim/status", headers=H).json()["state"] == "PAUSE"
    client.post("/api/printers/sim/print/stop", headers=H)
    events = client.get("/api/events", headers=H).json()
    assert [e["type"] for e in events][-2:] == ["print_paused", "print_cancelled"]
    last = events[-1]["id"]
    assert client.get(f"/api/events?after={last}", headers=H).json() == []


def test_camera_snapshot(client):
    r = client.get("/api/printers/sim/camera/snapshot.jpg", headers=H)
    assert r.status_code == 200 and r.content[:2] == b"\xff\xd8"


def test_websocket(client):
    with client.websocket_connect(f"/api/ws?token={TOKEN}") as ws:
        msg = ws.receive_json()
        assert msg["type"] == "status" and msg["printer_id"] == "sim"
        ws.send_text("ping")
        types = {ws.receive_json()["type"] for _ in range(3)}
        assert "pong" in types or "status" in types


def test_serves_web_dashboard(tmp_path, monkeypatch):
    web = tmp_path / "web"
    web.mkdir()
    (web / "index.html").write_text("<html>OpenBambu web</html>")
    (web / "main.dart.js").write_text("console.log(1)")
    monkeypatch.setenv("OB_WEB_DIR", str(web))
    settings = Settings(api_token=TOKEN, data_dir=str(tmp_path / "d"), printers=[])
    with TestClient(create_app(settings)) as c:
        r = c.get("/")
        assert r.status_code == 200 and "OpenBambu web" in r.text and r.headers["cache-control"] == "no-cache"
        assert c.get("/main.dart.js").status_code == 200
        assert c.get("/api/health").json()["name"] == "OpenBambu"  # la API sigue funcionando
        assert c.get("/api/printers").status_code == 401


def test_root_without_web_redirects_to_docs(tmp_path, monkeypatch):
    monkeypatch.setenv("OB_WEB_DIR", str(tmp_path / "nada"))
    settings = Settings(api_token=TOKEN, data_dir=str(tmp_path / "d"), printers=[])
    with TestClient(create_app(settings)) as c:
        assert c.get("/", follow_redirects=False).headers["location"] == "/docs"
