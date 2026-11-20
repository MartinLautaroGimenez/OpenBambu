"""Timelapse: una foto por capa y video al terminar (con el simulador)."""

import shutil
import time

import pytest
from fastapi.testclient import TestClient

from openbambu.config import PrinterConfig, Settings
from openbambu.main import create_app
from tests.test_queue import make_3mf, wait

H = {"Authorization": "Bearer t"}


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="ffmpeg no instalado")
def test_timelapse_video_after_print(tmp_path):
    settings = Settings(api_token="t", data_dir=str(tmp_path),
                        printers=[PrinterConfig(id="sim", model="A1", mode="simulator")])
    with TestClient(create_app(settings)) as c:
        mgr = c.app.state.manager
        sim = mgr.printers["sim"]
        sim.auto_demo = False
        sim.SPEED_FACTOR = {2: 12.0}  # imprimir rápido: muchas capas en pocos segundos
        assert c.get("/api/timelapse/config", headers=H).json()["enabled"]
        time.sleep(0.6)
        item = c.put("/api/library?filename=t.gcode.3mf", content=make_3mf(), headers=H).json()
        mapping = [{"filament_id": 1, "tray": 0}, {"filament_id": 3, "tray": 254}]
        c.post("/api/printers/sim/queue", json={"library_id": item["id"], "mapping": mapping, "start_now": True},
               headers=H)
        assert wait(lambda: c.get("/api/printers/sim/status", headers=H).json()["state"] == "RUNNING", timeout=30)
        # El simulador termina solo; mientras tanto se juntan fotos por capa
        assert wait(lambda: c.get("/api/printers/sim/status", headers=H).json()["state"] == "FINISH", timeout=40)
        assert wait(lambda: c.get("/api/history", headers=H).json()[0]["timelapse"], timeout=40)
        rec = c.get("/api/history", headers=H).json()[0]
        r = c.get(f"/api/history/{rec['id']}/timelapse.mp4", headers=H)
        assert r.status_code == 200 and r.headers["content-type"] == "video/mp4" and len(r.content) > 5000
        assert not (tmp_path / "timelapse" / str(rec["id"])).exists()  # las fotos se borran
        c.delete(f"/api/history/{rec['id']}", headers=H)
        assert not (tmp_path / "timelapse" / f"{rec['id']}.mp4").exists()


def test_timelapse_config(tmp_path):
    settings = Settings(api_token="t", data_dir=str(tmp_path), printers=[])
    with TestClient(create_app(settings)) as c:
        r = c.put("/api/timelapse/config", json={"enabled": False, "fps": 30}, headers=H).json()
        assert r["enabled"] is False and r["fps"] == 30
        assert c.put("/api/timelapse/config", json={"fps": 2}, headers=H).status_code == 422
