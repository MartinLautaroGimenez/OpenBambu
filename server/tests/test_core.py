import json

import pytest

from openbambu.notify.events import CANCELLED_ERROR, EventDetector
from openbambu.printer import commands as C
from openbambu.printer.state import PrinterState, deep_merge, hms_code

# Fragmento real (recortado) de un reporte de una A1 con AMS lite
A1_FULL = {
    "print": {
        "gcode_state": "RUNNING",
        "stg_cur": 0,
        "mc_percent": 37,
        "mc_remaining_time": 64,
        "layer_num": 41,
        "total_layer_num": 210,
        "subtask_name": "Benchy",
        "nozzle_temper": 219.8,
        "nozzle_target_temper": 220,
        "bed_temper": 64.9,
        "bed_target_temper": 65,
        "cooling_fan_speed": "15",
        "big_fan1_speed": "0",
        "heatbreak_fan_speed": "15",
        "spd_lvl": 2,
        "spd_mag": 100,
        "lights_report": [{"node": "chamber_light", "mode": "on"}],
        "hms": [{"attr": 0x07008000, "code": 0x00020001}],
        "ams": {
            "ams": [
                {
                    "id": "0",
                    "humidity": "5",
                    "temp": "0.0",
                    "tray": [
                        {"id": "0", "tray_type": "PLA", "tray_color": "FF6A13FF", "remain": 80},
                        {"id": "1"},
                    ],
                }
            ],
            "tray_now": "0",
        },
        "vt_tray": {"id": "254", "tray_type": "PETG", "tray_color": "000000FF"},
    }
}


def test_deep_merge_keeps_unchanged_fields():
    base = {"print": {"a": 1, "b": {"c": 2, "d": 3}}}
    deep_merge(base, {"print": {"b": {"c": 9}}})
    assert base == {"print": {"a": 1, "b": {"c": 9, "d": 3}}}


def test_normalize_a1_report_and_delta():
    st = PrinterState("A1")
    st.connected = True
    st.apply(json.loads(json.dumps(A1_FULL)))
    s = st.snapshot()
    assert s["state"] == "RUNNING"
    assert s["job"]["progress"] == 37 and s["job"]["total_layers"] == 210
    assert s["temps"]["nozzle"] == 219.8
    assert s["fans"]["part"] == 100
    assert s["fans"]["aux"] is None  # la A1 no tiene ventilador auxiliar
    assert s["light"] is True
    tray0, tray1 = s["ams"]["units"][0]["trays"]
    assert tray0["color"] == "#FF6A13" and tray0["active"] and tray0["remain"] == 80
    assert not tray1["loaded"]
    assert s["ams"]["external"]["global_id"] == 254
    assert s["hms"][0]["code"] == "0700_8000_0002_0001"
    assert s["hms"][0]["severity"] == "serious"

    # delta parcial: solo cambia el progreso
    st.apply({"print": {"mc_percent": 38}})
    s2 = st.snapshot()
    assert s2["job"]["progress"] == 38 and s2["temps"]["bed"] == 64.9


def test_offline_state():
    st = PrinterState("A1")
    st.apply(A1_FULL)
    assert st.snapshot()["state"] == "OFFLINE"


def test_hms_code_format():
    assert hms_code(0x0300_1200, 0x0002_0001) == "0300_1200_0002_0001"


def test_commands():
    assert C.set_temperature("A1", "nozzle", 220)["print"]["param"] == "M104 S220\n"
    assert C.set_temperature("A1", "bed", 60)["print"]["param"] == "M140 S60\n"
    with pytest.raises(C.CommandError):
        C.set_temperature("A1", "bed", 110)  # la cama de la A1 llega a 100 °C
    assert C.set_fan("A1", "part", 50)["print"]["param"] == "M106 P1 S128\n"
    with pytest.raises(C.CommandError):
        C.set_fan("A1", "chamber", 50)
    assert C.light(False)["system"]["led_mode"] == "off"
    assert C.ams_load(2)["print"]["target"] == 2
    assert C.ams_load(254)["print"]["ams_id"] == 255
    f = C.ams_filament_setting(1, "petg", "#00ff00")["print"]
    assert f["tray_color"] == "00FF00FF" and f["tray_info_idx"] == "GFG99" and f["tray_id"] == 1
    assert "G1 Z-10.0 F600" in C.move("z", -10)["print"]["param"]
    with pytest.raises(C.CommandError):
        C.print_speed(5)


def _snap(state="RUNNING", progress=0, layer=0, error=0, hms=(), stage=0, connected=True):
    st = PrinterState("A1")
    st.connected = connected
    st.apply({"print": {"gcode_state": state, "mc_percent": progress, "layer_num": layer,
                        "total_layer_num": 100, "subtask_name": "Cubo", "print_error": error,
                        "stg_cur": stage, "hms": list(hms)}})
    return st.snapshot()


def types(events):
    return [e.type for e in events]


def test_event_detector_lifecycle():
    d = EventDetector("a1", "A1", progress_step=25)
    assert d.feed(_snap("IDLE")) == []
    assert types(d.feed(_snap("PREPARE"))) == ["print_started"]
    d.feed(_snap("RUNNING", 1, 1))
    assert types(d.feed(_snap("RUNNING", 3, 2))) == ["first_layer"]
    assert types(d.feed(_snap("RUNNING", 26, 26))) == ["progress"]
    assert types(d.feed(_snap("RUNNING", 27, 27))) == []
    assert types(d.feed(_snap("PAUSE", 27, 27, stage=6))) == ["print_paused", "filament_runout"]
    assert types(d.feed(_snap("RUNNING", 27, 27))) == ["print_resumed"]
    assert types(d.feed(_snap("FINISH", 100, 100))) == ["print_finished"]


def test_event_detector_cancel_hms_offline():
    d = EventDetector("a1", "A1")
    d.feed(_snap("RUNNING", 10, 10))
    ev = d.feed(_snap("FAILED", 10, 10, error=CANCELLED_ERROR))
    assert types(ev) == ["print_cancelled"]
    ev = d.feed(_snap("IDLE", hms=[{"attr": 0x07008000, "code": 0x00020001}]))
    assert types(ev) == ["hms"] and ev[0].severity == "error"
    assert types(d.feed(_snap("IDLE", hms=[{"attr": 0x07008000, "code": 0x00020001}]))) == []
    assert types(d.feed(_snap("IDLE", connected=False))) == ["offline"]
    # al reconectar no se disparan transiciones espurias
    assert types(d.feed(_snap("RUNNING", 50, 50))) == []


def test_hms_descriptions_spanish_with_english_fallback():
    from openbambu.printer.hms_db import DB, HmsDatabase

    db = HmsDatabase()
    db.load_dict({"data": {"device_hms": {"es": [{"ecode": "0700800000020001", "intro": "Falla en el AMS lite"}]},
                           "device_error": {"es": [{"ecode": "0300400C", "intro": "Se canceló la impresión"}]}}}, "es")
    db.load_dict({"data": {"device_hms": {"en": [{"ecode": "0700800000020001", "intro": "AMS lite failure"},
                                                 {"ecode": "0300120000020001", "intro": "Only in English"}]}}}, "en")
    assert db.describe_hms("0700_8000_0002_0001") == "Falla en el AMS lite"  # español primero
    assert db.describe_hms("0300_1200_0002_0001") == "Only in English"      # respaldo
    assert db.describe_error(50348044) == "Se canceló la impresión"
    assert db.describe_error(0) is None

    # El estado normalizado incluye las descripciones
    DB.hms, DB.errors = db.hms, db.errors
    try:
        st = PrinterState("A1")
        st.connected = True
        st.apply({"print": {"gcode_state": "FAILED", "print_error": 50348044,
                            "hms": [{"attr": 0x07008000, "code": 0x00020001}]}})
        s = st.snapshot()
        assert s["hms"][0]["description"] == "Falla en el AMS lite"
        assert s["job"]["print_error_text"] == "Se canceló la impresión"
    finally:
        DB.hms, DB.errors = {}, {}
