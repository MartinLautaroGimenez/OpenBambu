"""Historial, consumo de filamento por carrete y estadísticas."""

import time

import pytest
from fastapi.testclient import TestClient

from openbambu.config import PrinterConfig, Settings
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


def test_spool_crud_and_single_tray(client):
    a = client.post("/api/spools", json={"brand": "Bambu", "material": "pla", "color": "#FF0000",
                                         "price": 20000, "tray": 2}, headers=H).json()
    assert a["material"] == "PLA" and a["remaining_g"] == 1000 and a["printer_id"] == "sim" and a["tray"] == 2
    b = client.post("/api/spools", json={"material": "PETG", "tray": 2}, headers=H).json()
    spools = {s["id"]: s for s in client.get("/api/spools", headers=H).json()}
    assert spools[a["id"]]["tray"] is None and spools[b["id"]]["tray"] == 2  # una bandeja, un carrete
    client.patch(f"/api/spools/{b['id']}", json={"unassign": True, "remaining_g": 300}, headers=H)
    assert client.get("/api/spools", headers=H).json()[0]["tray"] is None
    client.patch(f"/api/spools/{a['id']}", json={"archived": True}, headers=H)
    assert [s["id"] for s in client.get("/api/spools", headers=H).json()] == [b["id"]]
    assert client.post("/api/spools", json={"material": "PLA", "color": "rojo"}, headers=H).status_code == 422


def test_print_history_consumes_spools(client):
    item = client.put("/api/library?filename=Soporte.gcode.3mf", content=make_3mf(), headers=H).json()
    pla = client.post("/api/spools", json={"brand": "Bambu", "material": "PLA", "price": 20000,
                                           "weight_g": 1000, "tray": 2}, headers=H).json()
    tpu = client.post("/api/spools", json={"material": "TPU", "price": 30000, "weight_g": 500,
                                           "remaining_g": 100, "tray": 254}, headers=H).json()
    mapping = [{"filament_id": 1, "tray": 2}, {"filament_id": 3, "tray": 254}]
    client.post("/api/printers/sim/queue", json={"library_id": item["id"], "mapping": mapping,
                                                 "start_now": True}, headers=H)
    assert wait(lambda: client.get("/api/history", headers=H).json()[:1]
                and client.get("/api/history", headers=H).json()[0]["status"] == "printing")
    rec = client.get("/api/history", headers=H).json()[0]
    assert rec["name"] == "Soporte" and rec["library_id"] == item["id"] and rec["weight_g"] == 21.5
    assert [(f["filament_id"], f["tray"]) for f in rec["filaments"]] == [(1, 2), (3, 254)]

    sim = client.app.state.manager.printers["sim"]
    sim.p.update(gcode_state="RUNNING", stg_cur=0)
    sim._emit()
    time.sleep(0.3)
    sim._finish("FINISH")
    sim._emit()
    assert wait(lambda: client.get("/api/history", headers=H).json()[0]["status"] == "done")
    rec = client.get("/api/history", headers=H).json()[0]
    assert rec["weight_g"] == 21.5 and rec["reprintable"]
    assert rec["cost"] == pytest.approx(15.2 * 20 + 6.3 * 60, abs=0.01)  # $/g = precio / peso del carrete
    spools = {s["id"]: s for s in client.get("/api/spools", headers=H).json()}
    assert spools[pla["id"]]["remaining_g"] == pytest.approx(1000 - 15.2)
    assert spools[tpu["id"]]["remaining_g"] == pytest.approx(100 - 6.3)

    stats = client.get("/api/history/stats", headers=H).json()
    assert stats["total"] == 1 and stats["done"] == 1 and stats["success_rate"] == 100
    assert stats["grams"] == 21.5 and stats["materials"] == {"PLA": 15.2, "TPU": 6.3}
    assert len(stats["months"]) == 6 and stats["months"][-1]["prints"] == 1


def test_cancelled_print_counts_partial(client):
    sim = client.app.state.manager.printers["sim"]
    pla = client.post("/api/spools", json={"material": "PLA", "price": 10000, "tray": 0}, headers=H).json()
    # Impresión iniciada fuera de OpenBambu (sin datos del laminador)
    sim._start_job("Externo")
    sim.p.update(gcode_state="RUNNING", stg_cur=0, mc_percent=40)
    sim._emit()
    assert wait(lambda: client.get("/api/history", headers=H).json())
    client.post("/api/printers/sim/print/stop", headers=H)
    assert wait(lambda: client.get("/api/history", headers=H).json()[0]["status"] == "cancelled")
    rec = client.get("/api/history", headers=H).json()[0]
    assert rec["progress"] == 40 and rec["cost"] is None and not rec["reprintable"]
    assert client.get("/api/spools", headers=H).json()[0]["remaining_g"] == pla["remaining_g"]  # sin datos: no descuenta
