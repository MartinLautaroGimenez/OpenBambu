"""Vista previa del G-code."""

import io
import json
import zipfile

from openbambu.library.preview import parse_gcode

GCODE = """
; HEADER_BLOCK_START
G28 ; start gcode, no cuenta
G1 X10 Y10 E5 F1000
; MACHINE_START_GCODE_END
M83
G90
; CHANGE_LAYER
; Z_HEIGHT: 0.2
; LAYER_HEIGHT: 0.2
; FEATURE: Outer wall
G1 X0 Y0 F3000
G1 X10 Y0 E0.5
G1 X10 Y10 E0.5
G1 X0 Y10 E0.5
G1 X0 Y0 E0.5
; FEATURE: Sparse infill
G1 X5 Y5
G1 X8 Y8 E0.2
G0 X1 Y1
G1 X2 Y1 E0.1
; CHANGE_LAYER
; Z_HEIGHT: 0.4
T1
; FEATURE: Inner wall
G1 X0 Y0
G2 X10 Y0 I5 J0 E1.0
; CHANGE_LAYER
; Z_HEIGHT: 0.6
; FEATURE: Outer wall
G1 X3 Y3
G1 X3 Y3 E0.5 ; retracción/extrusión sin movimiento: no dibuja
"""


def test_parse_layers_features_and_arcs():
    d = parse_gcode(GCODE.splitlines())
    assert [layer["z"] for layer in d["layers"]] == [0.2, 0.4]  # la capa vacía no se incluye
    l0 = {(p["t"], p["f"]): p["p"] for p in d["layers"][0]["paths"]}
    assert l0[("ow", 0)] == [0, 0, 100, 0, 100, 100, 0, 100, 0, 0]
    infill = [p["p"] for p in d["layers"][0]["paths"] if p["t"] == "si"]
    assert infill == [[50, 50, 80, 80], [10, 10, 20, 10]]  # el G0 corta la polilínea
    arc = d["layers"][1]["paths"][0]
    assert arc["t"] == "iw" and arc["f"] == 1 and arc["p"][-2:] == [100, 0] and len(arc["p"]) > 6
    ys = arc["p"][1::2]
    assert max(ys) >= 45 and min(ys) >= 0  # G2 (horario) de (0,0) a (10,0) con centro (5,0) pasa por arriba (y≈5)
    assert d["bbox"][0] == 0 and d["bbox"][2] == 10


def test_preview_api(tmp_path):
    import time

    from fastapi.testclient import TestClient

    from openbambu.config import PrinterConfig, Settings
    from openbambu.main import create_app

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("Metadata/plate_1.gcode", GCODE)
        z.writestr("Metadata/slice_info.config", '<config><plate><metadata key="index" value="1"/></plate></config>')
    settings = Settings(api_token="t", data_dir=str(tmp_path),
                        printers=[PrinterConfig(id="sim", model="A1", mode="simulator")])
    H = {"Authorization": "Bearer t", "Accept-Encoding": "gzip"}
    with TestClient(create_app(settings)) as c:
        time.sleep(0.3)
        item = c.put("/api/library?filename=p.gcode.3mf", content=buf.getvalue(), headers=H).json()
        r = c.get(f"/api/library/{item['id']}/plates/1/preview", headers=H)
        assert r.status_code == 200 and len(json.loads(r.content)["layers"]) == 2
        assert c.get(f"/api/library/{item['id']}/plates/2/preview", headers=H).status_code == 422
        assert list((tmp_path / "cache" / "preview").glob("*.json"))
