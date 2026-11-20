"""Enchufe vía Home Assistant (simulado): config, on/off, auto-apagado y auto-encendido por la cola."""

import time

import httpx
import pytest
from fastapi.testclient import TestClient

from openbambu.config import PrinterConfig, Settings
from openbambu.main import create_app
from tests.test_queue import make_3mf, wait

H = {"Authorization": "Bearer t"}


class FakeHA:
    def __init__(self):
        self.state = "on"
        self.calls = []
        self.on_turn_on = None

    def handler(self, request: httpx.Request) -> httpx.Response:
        if request.headers.get("authorization") != "Bearer ha-token":
            return httpx.Response(401)
        path = request.url.path
        self.calls.append((request.method, path))
        if path == "/api/states":
            return httpx.Response(200, json=[
                {"entity_id": "sensor.temp", "state": "21"},
                {"entity_id": "switch.enchufe_a1", "state": self.state, "attributes": {"friendly_name": "Enchufe A1"}},
                {"entity_id": "light.living", "state": "off", "attributes": {"friendly_name": "Living"}},
            ])
        if path == "/api/states/switch.enchufe_a1":
            return httpx.Response(200, json={"state": self.state})
        if path == "/api/services/switch/turn_on":
            self.state = "on"
            if self.on_turn_on:
                self.on_turn_on()
            return httpx.Response(200, json=[])
        if path == "/api/services/switch/turn_off":
            self.state = "off"
            return httpx.Response(200, json=[])
        return httpx.Response(404)


@pytest.fixture
def env(tmp_path):
    settings = Settings(api_token="t", data_dir=str(tmp_path),
                        printers=[PrinterConfig(id="sim", name="Sim", model="A1", mode="simulator")])
    ha = FakeHA()
    with TestClient(create_app(settings)) as c:
        mgr = c.app.state.manager
        mgr.printers["sim"].auto_demo = False
        mgr.power.ha.client = httpx.AsyncClient(transport=httpx.MockTransport(ha.handler))
        time.sleep(0.8)
        yield c, mgr, ha


def configure(c, **extra):
    body = {"url": "homeassistant.local:8123", "token": "ha-token", "entities": {"sim": "switch.enchufe_a1"}, **extra}
    return c.put("/api/power/config", json=body, headers=H).json()


def test_config_entities_and_toggle(env):
    c, mgr, ha = env
    cfg = configure(c)
    assert cfg["url"] == "http://homeassistant.local:8123" and cfg["token"] == "" and cfg["has_token"]
    # Guardar sin token mantiene el anterior
    assert c.put("/api/power/config", json={"auto_off_delay_min": 0}, headers=H).json()["has_token"]
    ents = c.get("/api/power/entities", headers=H).json()
    assert [e["entity_id"] for e in ents] == ["switch.enchufe_a1", "light.living"]

    assert c.get("/api/printers/sim/power", headers=H).json()["state"] == "on"
    r = c.post("/api/printers/sim/power", json={"on": False}, headers=H).json()
    assert r["state"] == "off" and mgr.power.recently_powered_off("sim")

    # No apagar mientras imprime (salvo force)
    sim = mgr.printers["sim"]
    sim._start_job("X")
    sim.p.update(gcode_state="RUNNING")
    sim._emit()
    assert c.post("/api/printers/sim/power", json={"on": False}, headers=H).status_code == 409


def test_auto_off_after_cooldown(env):
    c, mgr, ha = env
    configure(c, auto_off_delay_min=0, auto_off_max_nozzle=60)
    sim = mgr.printers["sim"]
    sim._start_job("Pieza")
    sim.p.update(gcode_state="RUNNING")
    c.portal.call(sim._emit)
    time.sleep(0.2)
    sim._finish("FINISH")
    sim.p["nozzle_temper"] = 35  # ya se enfrió
    c.portal.call(sim._emit)  # dentro del event loop del servidor, como en producción
    assert wait(lambda: ha.state == "off", timeout=15)
    events = [e["type"] for e in c.get("/api/events", headers=H).json()]
    assert "power_off" in events


def test_queue_turns_printer_on(env):
    c, mgr, ha = env
    configure(c)
    sim = mgr.printers["sim"]
    ha.state = "off"
    sim.state.connected = False
    sim._emit()

    def boot():
        sim.state.connected = True

    ha.on_turn_on = boot
    item = c.put("/api/library?filename=a.gcode.3mf", content=make_3mf(), headers=H).json()
    mapping = [{"filament_id": 1, "tray": 0}, {"filament_id": 3, "tray": 254}]
    c.post("/api/printers/sim/queue", json={"library_id": item["id"], "mapping": mapping, "bed_clear": True}, headers=H)
    assert wait(lambda: ("POST", "/api/services/switch/turn_on") in ha.calls, timeout=15)
    assert wait(lambda: c.get("/api/printers/sim/status", headers=H).json()["state"] in ("PREPARE", "RUNNING"),
                timeout=15)
    assert "power_on" in [e["type"] for e in c.get("/api/events", headers=H).json()]
