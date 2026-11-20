"""Alta/edición/baja de impresoras desde la API, persistencia y descubrimiento."""

import json
import time

from fastapi.testclient import TestClient

from openbambu.config import PrinterConfig, Settings
from openbambu.main import create_app
from openbambu.printer.discovery import parse_notify

H = {"Authorization": "Bearer t"}


def app(tmp_path, printers=()):
    return create_app(Settings(api_token="t", data_dir=str(tmp_path), printers=list(printers)))


def test_add_edit_delete_and_persist(tmp_path):
    with TestClient(app(tmp_path)) as c:
        assert c.get("/api/admin/printers", headers=H).json() == []
        # Validaciones
        bad = {"name": "Mi A1", "model": "A1", "host": "", "serial": "03919A3B1234567", "access_code": "12345678"}
        assert c.post("/api/admin/printers", json=bad, headers=H).status_code == 422
        bad = {**bad, "host": "192.168.1.50", "access_code": ""}
        assert c.post("/api/admin/printers", json=bad, headers=H).status_code == 422

        a1 = c.post("/api/admin/printers", json={**bad, "access_code": "12345678"}, headers=H).json()
        assert a1["id"] == "mi-a1" and a1["has_access_code"] and a1["editable"] and "access_code" not in a1
        sim = c.post("/api/admin/printers", json={"name": "Mi A1", "mode": "simulator"}, headers=H).json()
        assert sim["id"] == "mi-a1-2"
        # misma impresora (serie) dos veces → 409
        assert c.post("/api/admin/printers", json={**bad, "access_code": "x1234567"}, headers=H).status_code == 409

        # ya aparece en la API principal y la WS avisa al cambiar
        assert {p["id"] for p in c.get("/api/printers", headers=H).json()} == {"mi-a1", "mi-a1-2"}
        time.sleep(0.8)
        assert c.get("/api/printers/mi-a1-2/status", headers=H).json()["connected"]

        # editar sin código mantiene el anterior
        r = c.put("/api/admin/printers/mi-a1", json={"name": "Taller", "model": "A1MINI", "host": "192.168.1.51",
                                                      "serial": "03919a3b1234567"}, headers=H).json()
        assert r["name"] == "Taller" and r["model"] == "A1MINI" and r["serial"] == "03919A3B1234567"
        saved = json.loads((tmp_path / "printers.json").read_text())
        assert {p["id"]: p["access_code"] for p in saved}["mi-a1"] == "12345678"

        assert c.delete("/api/admin/printers/mi-a1-2", headers=H).json() == {"ok": True}
        assert c.delete("/api/admin/printers/nope", headers=H).status_code == 404

    # Al reiniciar el servidor se cargan las impresoras guardadas
    with TestClient(app(tmp_path)) as c:
        ps = c.get("/api/admin/printers", headers=H).json()
        assert [(p["id"], p["name"], p["host"]) for p in ps] == [("mi-a1", "Taller", "192.168.1.51")]


def test_config_yaml_printers_are_read_only(tmp_path):
    with TestClient(app(tmp_path, [PrinterConfig(id="yaml", name="Desde YAML", mode="simulator")])) as c:
        p = c.get("/api/admin/printers", headers=H).json()[0]
        assert p["id"] == "yaml" and not p["editable"]
        assert c.delete("/api/admin/printers/yaml", headers=H).status_code == 403
        r = c.put("/api/admin/printers/yaml", json={"name": "X", "mode": "simulator"}, headers=H)
        assert r.status_code == 403


def test_queue_works_for_printer_added_later(tmp_path):
    from tests.test_queue import make_3mf, wait

    with TestClient(app(tmp_path)) as c:
        c.post("/api/admin/printers", json={"name": "Sim", "mode": "simulator"}, headers=H)
        c.app.state.manager.printers["sim"].auto_demo = False
        time.sleep(0.8)
        item = c.put("/api/library?filename=a.gcode.3mf", content=make_3mf(), headers=H).json()
        mapping = [{"filament_id": 1, "tray": 0}, {"filament_id": 3, "tray": 254}]
        c.post("/api/printers/sim/queue", json={"library_id": item["id"], "mapping": mapping, "start_now": True},
               headers=H)
        assert wait(lambda: c.get("/api/printers/sim/status", headers=H).json()["state"] in ("PREPARE", "RUNNING"))


def test_test_connection_unreachable(tmp_path):
    with TestClient(app(tmp_path)) as c:
        r = c.post("/api/admin/printers/test", json={"host": "127.0.0.1", "serial": "SER123", "access_code": "x"},
                   headers=H).json()
        assert r["ok"] is False and "conectar" in r["message"].lower()
        assert c.post("/api/admin/printers/test", json={"host": "", "serial": "S"}, headers=H).status_code == 422
        d = c.get("/api/admin/discovery", headers=H).json()
        assert d["printers"] == []


def test_parse_ssdp_notify():
    msg = (
        "NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nServer: UPnP/1.0\r\nLocation: 192.168.1.50\r\n"
        "NT: urn:bambulab-com:device:3dprinter:1\r\nUSN: 03919A3B1234567\r\nCache-Control: max-age=1800\r\n"
        "DevModel.bambu.com: N2S\r\nDevName.bambu.com: Mi A1\r\nDevSignal.bambu.com: -45\r\n"
        "DevConnect.bambu.com: lan\r\nDevBind.bambu.com: free\r\n\r\n"
    ).encode()
    d = parse_notify(msg, "192.168.1.50")
    assert (d["serial"], d["host"], d["model"], d["name"], d["connection"]) == (
        "03919A3B1234567", "192.168.1.50", "A1", "Mi A1", "lan")
    assert parse_notify(b"NOTIFY * HTTP/1.1\r\nUSN: x\r\n\r\n", "1.2.3.4") is None  # no es Bambu
