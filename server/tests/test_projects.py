"""Calificación, proyectos, mantenimiento, energía y etiquetas QR."""

import io
import time

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from openbambu.config import PrinterConfig, Settings
from openbambu.library.labels import parse_code, spool_code
from openbambu.main import create_app
from tests.test_queue import make_3mf, wait

H = {"Authorization": "Bearer t"}


@pytest.fixture
def client(tmp_path):
    settings = Settings(api_token="t", data_dir=str(tmp_path),
                        printers=[PrinterConfig(id="sim", name="Sim", model="A1", mode="simulator")])
    with TestClient(create_app(settings)) as c:
        c.app.state.manager.printers["sim"].auto_demo = False
        time.sleep(0.8)
        yield c


def _run_print(client, name="Externo", finish="FINISH"):
    sim = client.app.state.manager.printers["sim"]
    sim._start_job(name)
    sim.p.update(gcode_state="RUNNING", stg_cur=0)
    client.portal.call(sim._emit)
    assert wait(lambda: (h := client.get("/api/history", headers=H).json()) and h[0]["status"] == "printing")
    time.sleep(0.2)
    sim._finish(finish)
    client.portal.call(sim._emit)
    assert wait(lambda: client.get("/api/history", headers=H).json()[0]["status"] != "printing")
    return client.get("/api/history", headers=H).json()[0]


def test_rating_changes_success_rate(client):
    rec = _run_print(client)
    st = client.get("/api/history/stats", headers=H).json()
    assert st["success_rate"] == 100 and st["unrated"] == 1
    assert client.get("/api/history?unrated=true", headers=H).json()[0]["id"] == rec["id"]
    r = client.post(f"/api/history/{rec['id']}/rating", json={"rating": "bad", "reason": "adhesion"}, headers=H)
    assert r.json()["rating"] == "bad" and r.json()["rating_reason"] == "adhesion"
    st = client.get("/api/history/stats", headers=H).json()
    assert st["success_rate"] == 0 and st["rated_bad"] == 1 and st["unrated"] == 0
    assert st["issues"] == [{"reason": "Se despegó de la cama", "count": 1}]
    assert client.get("/api/history?unrated=true", headers=H).json() == []
    client.post(f"/api/history/{rec['id']}/rating", json={"rating": "good"}, headers=H)
    assert client.get("/api/history/stats", headers=H).json()["success_rate"] == 100
    assert client.post(f"/api/history/{rec['id']}/rating", json={"rating": "meh"}, headers=H).status_code == 422
    assert len(client.get("/api/history/reject-reasons", headers=H).json()) >= 5


def test_projects_from_queue_and_manual(client):
    proj = client.post("/api/projects", json={"name": "Organizador", "color": "#2EC27E", "target": 2},
                       headers=H).json()
    assert proj["prints"] == 0 and proj["progress"] == 0
    item = client.put("/api/library?filename=Caja.gcode.3mf", content=make_3mf(), headers=H).json()
    mapping = [{"filament_id": 1, "tray": 2}, {"filament_id": 3, "tray": 254}]
    r = client.post("/api/printers/sim/queue", json={"library_id": item["id"], "mapping": mapping,
                                                     "project_id": 999}, headers=H)
    assert r.status_code == 422
    client.post("/api/printers/sim/queue", json={"library_id": item["id"], "mapping": mapping, "start_now": True,
                                                 "project_id": proj["id"]}, headers=H)
    assert wait(lambda: (h := client.get("/api/history", headers=H).json()) and h[0]["project_id"] == proj["id"])
    sim = client.app.state.manager.printers["sim"]
    sim.p.update(gcode_state="RUNNING", stg_cur=0)
    client.portal.call(sim._emit)
    time.sleep(0.3)
    sim._finish("FINISH")
    client.portal.call(sim._emit)
    assert wait(lambda: client.get(f"/api/projects/{proj['id']}", headers=H).json()["ok"] == 1)
    p = client.get(f"/api/projects/{proj['id']}", headers=H).json()
    assert p["progress"] == 50 and p["grams"] == 21.5

    other = _run_print(client, "Tapa")
    assert other["project_id"] is None
    client.patch(f"/api/history/{other['id']}", json={"project_id": proj["id"]}, headers=H)
    assert client.get(f"/api/projects/{proj['id']}", headers=H).json()["progress"] == 100
    assert len(client.get(f"/api/history?project_id={proj['id']}", headers=H).json()) == 2
    client.patch(f"/api/projects/{proj['id']}", json={"archived": True}, headers=H)
    assert client.get("/api/projects", headers=H).json() == []
    client.delete(f"/api/projects/{proj['id']}", headers=H)
    assert client.get(f"/api/history/{other['id']}", headers=H).status_code in (404, 405)
    assert all(h["project_id"] is None for h in client.get("/api/history", headers=H).json())


def test_maintenance_due_and_done(client):
    m = client.get("/api/printers/sim/maintenance", headers=H).json()
    assert m["hours"] == 0 and len(m["tasks"]) >= 4 and m["due"] == 0
    t = client.post("/api/printers/sim/maintenance", json={"name": "Prueba", "interval_h": 0.000001},
                    headers=H).json()
    task = next(x for x in t["tasks"] if x["name"] == "Prueba")
    events = []
    client.app.state.manager.bus.listeners.append(events.append)
    _run_print(client)
    assert wait(lambda: any(e.type == "maintenance" for e in events))
    m = client.get("/api/printers/sim/maintenance", headers=H).json()
    task = next(x for x in m["tasks"] if x["id"] == task["id"])
    assert task["due"] and task["notified"] and m["due"] >= 1
    m = client.post(f"/api/printers/sim/maintenance/{task['id']}/done", json={"notes": "listo"}, headers=H).json()
    task = next(x for x in m["tasks"] if x["id"] == task["id"])
    assert not task["due"] and not task["notified"] and m["log"][0]["notes"] == "listo"
    m = client.patch(f"/api/printers/sim/maintenance/{task['id']}", json={"interval_h": 50}, headers=H).json()
    assert next(x for x in m["tasks"] if x["id"] == task["id"])["interval_h"] == 50
    m = client.delete(f"/api/printers/sim/maintenance/{task['id']}", headers=H).json()
    assert all(x["id"] != task["id"] for x in m["tasks"])
    assert len(client.get("/api/maintenance", headers=H).json()) == 1


def test_energy_from_kwh_sensor(client):
    mgr = client.app.state.manager
    readings = iter([("energy", 10.0), ("energy", 10.35)])

    async def fake_reading(pid):
        return next(readings, ("energy", 10.35))

    mgr.power.energy_reading = fake_reading
    mgr.power.cfg.price_kwh = 100
    rec = _run_print(client)
    assert wait(lambda: client.get("/api/history", headers=H).json()[0]["energy_kwh"] is not None)
    rec = client.get("/api/history", headers=H).json()[0]
    assert rec["energy_kwh"] == pytest.approx(0.35) and rec["energy_cost"] == pytest.approx(35)
    st = client.get("/api/history/stats", headers=H).json()
    assert st["energy_kwh"] == pytest.approx(0.35) and st["energy_cost"] == pytest.approx(35)


async def test_energy_from_power_sensor(tmp_path):
    from openbambu.library.history import HistoryRecorder
    from openbambu.library.store import Store

    class P:
        cfg = type("C", (), {"price_kwh": 0})()

        async def energy_reading(self, pid):
            return ("power", 3.6e7)

    store = Store(tmp_path)
    h = HistoryRecorder(store, {}, tmp_path)
    h.power = P()
    pid = store.add_print(printer_id="x", name="n", status="printing", filaments=[])
    await h._energy_start("x", pid)
    import asyncio
    h._meters[pid].cancel()
    h._meters[pid] = asyncio.get_running_loop().create_task(h._integrate("x", pid, 3.6e7, every=0.05))
    await asyncio.sleep(0.3)
    await h._energy_finish("x", store.get_print(pid))
    kwh = store.get_print(pid)["energy_kwh"]
    assert 1.5 < kwh < 3.5  # 36 MW simulados durante ~0.25 s = 2.5 kWh


def test_spool_label_and_code(client):
    sp = client.post("/api/spools", json={"brand": "Bambu", "material": "PLA", "color": "#FF0000",
                                          "color_name": "Rojo"}, headers=H).json()
    r = client.get(f"/api/spools/{sp['id']}/label.png", headers=H)
    assert r.status_code == 200 and r.headers["content-type"] == "image/png"
    assert Image.open(io.BytesIO(r.content)).size == (696, 300)
    assert parse_code(spool_code(sp["id"])) == sp["id"] and parse_code("hola") is None
    assert client.get(f"/api/spools/by-code?code={spool_code(sp['id'])}", headers=H).json()["id"] == sp["id"]
    assert client.get("/api/spools/by-code?code=openbambu:spool:999", headers=H).status_code == 404
