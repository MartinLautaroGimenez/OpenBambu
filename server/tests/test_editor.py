"""Editor de placas: lectura de modelos, escena y guardado como proyecto 3MF."""

import struct
import time
import zipfile

import numpy as np
import pytest
from fastapi.testclient import TestClient

from openbambu.config import PrinterConfig, Settings
from openbambu.library.scene import (
    Placement,
    decimate,
    plate_origin,
    read_3mf_scene,
    read_stl,
    write_project,
)
from openbambu.library.threemf import read_project
from openbambu.main import create_app
from tests.test_slicer import make_project

H = {"Authorization": "Bearer t"}


def cube_stl(size=20.0) -> bytes:
    s = size
    v = [(0, 0, 0), (s, 0, 0), (s, s, 0), (0, s, 0), (0, 0, s), (s, 0, s), (s, s, s), (0, s, s)]
    faces = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
             (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]
    data = bytearray(b"x".ljust(80, b"\0")) + struct.pack("<I", len(faces))
    for f in faces:
        data += struct.pack("<3f", 0, 0, 0) + b"".join(struct.pack("<3f", *v[i]) for i in f) + b"\0\0"
    return bytes(data)


@pytest.fixture
def client(tmp_path):
    settings = Settings(api_token="t", data_dir=str(tmp_path),
                        printers=[PrinterConfig(id="sim", name="Sim", model="A1", mode="simulator")])
    with TestClient(create_app(settings)) as c:
        c.app.state.manager.printers["sim"].auto_demo = False
        time.sleep(0.5)
        yield c


def test_stl_and_decimate():
    v, t = read_stl(cube_stl())
    assert v.shape == (8, 3) and t.shape == (12, 3)
    # Esfera densa → menos triángulos
    u, w = np.meshgrid(np.linspace(0, np.pi, 120), np.linspace(0, 2 * np.pi, 240))
    pts = np.stack([np.sin(u) * np.cos(w), np.sin(u) * np.sin(w), np.cos(u)], -1).reshape(-1, 3) * 20
    idx = np.arange(len(pts)).reshape(240, 120)
    tris = np.concatenate([np.stack([idx[:-1, :-1], idx[1:, :-1], idx[:-1, 1:]], -1).reshape(-1, 3),
                           np.stack([idx[1:, :-1], idx[1:, 1:], idx[:-1, 1:]], -1).reshape(-1, 3)])
    dv, dt = decimate(pts.astype(np.float32), tris.astype(np.int32), 5000)
    assert 1000 < len(dt) <= 5000 and dt.max() < len(dv)


def test_plate_origin_matches_bambu():
    assert plate_origin(1, 3, (256, 256)) == (0, 0)
    assert plate_origin(2, 3, (256, 256)) == pytest.approx((307.2, 0))
    assert plate_origin(3, 3, (256, 256)) == pytest.approx((0, -307.2))


def test_scene_roundtrip_through_project(client, tmp_path):
    stl = client.put("/api/library?filename=Cubo.stl", content=cube_stl(), headers=H).json()
    scene = client.get(f"/api/library/{stl['id']}/scene?printer_id=sim", headers=H).json()
    assert scene["bed"] == {"w": 256, "d": 256} and len(scene["objects"]) == 1
    obj = scene["objects"][0]
    assert obj["bbox"] == [[0, 0, 0], [20, 20, 20]] and obj["triangles"] == 12
    it = scene["items"][0]
    assert it["matrix"][9:12] == [118, 118, 0]  # centrado en la cama
    mesh = client.get(obj["parts"][0]["mesh"], headers=H)
    nv, nt = struct.unpack_from("<II", mesh.content)
    assert (nv, nt) == (8, 12) and len(mesh.content) == 8 + nv * 12 + nt * 12

    # Dos copias en la placa 1 (una con filamento 2) y una en la placa 2
    m2 = list(it["matrix"]); m2[9] = 30
    m3 = list(it["matrix"]); m3[9] = 50
    body = {"name": "Cubos / editados", "printer_id": "sim",
            "plates": [{"index": 1, "name": "Uno"}, {"index": 2, "name": "Dos"}],
            "items": [it, {**it, "matrix": m2, "extruder": 2}, {**it, "matrix": m3, "plate": 2}],
            "thumbnails": {"1": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
                                "+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="}}
    saved = client.post(f"/api/library/{stl['id']}/scene", json=body, headers=H)
    assert saved.status_code == 200, saved.text
    new = saved.json()
    assert new["name"] == "Cubos / editados" and new["source"] == f"editor:{stl['id']}"
    assert [p["index"] for p in new["meta"]["project_plates"]] == [1, 2]
    assert new["meta"]["project_plates"][0]["name"] == "Uno" and new["meta"]["project_plates"][0]["thumbnail"]

    # Releer el proyecto: las posiciones vuelven a coordenadas de placa
    path = client.app.state.manager.store.file_path(new)
    sc = read_3mf_scene(path)
    pos = sorted((p.plate, round(p.matrix[9], 3), p.extruder or sc.objects[p.key].extruder) for p in sc.items)
    assert pos == [(1, 30, 2), (1, 118, 1), (2, 50, 1)]
    cfg = zipfile.ZipFile(path).read("Metadata/model_settings.config").decode()
    assert cfg.count("<plate>") == 2 and 'key="extruder" value="2"' in cfg

    # Reemplazar al volver a guardar un archivo del editor
    again = client.post(f"/api/library/{new['id']}/scene",
                        json={**body, "items": [it], "plates": [], "replace": True}, headers=H).json()
    assert again["id"] == new["id"] and len(again["meta"]["project_plates"]) == 1

    # Validaciones
    bad = {**body, "items": [{**it, "key": f"{stl['id']}:99"}]}
    assert client.post(f"/api/library/{stl['id']}/scene", json=bad, headers=H).status_code == 422
    far = list(it["matrix"]); far[9] = 99999
    bad = {**body, "items": [{**it, "matrix": far}]}
    assert client.post(f"/api/library/{stl['id']}/scene", json=bad, headers=H).status_code == 422


def test_bambu_project_with_components_and_paint(tmp_path):
    """3MF estilo Bambu: objetos en archivos aparte, piezas con filamento, pintura y 2 placas."""
    p = tmp_path / "mw.3mf"
    sub = ('<?xml version="1.0"?><model unit="millimeter"><resources>'
           '<object id="1" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/>'
           '<vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/></vertices><triangles>'
           '<triangle v1="0" v2="2" v3="1" paint_color="4"/><triangle v1="0" v2="1" v3="3"/>'
           '<triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/></triangles></mesh></object>'
           '<object id="2" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="5" y="0" z="0"/>'
           '<vertex x="0" y="5" z="0"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh>'
           '</object></resources></model>')
    root = ('<?xml version="1.0"?><model unit="millimeter" xmlns:p="http://x"><resources>'
            '<object id="3" type="model"><components>'
            '<component p:path="/3D/Objects/object_1.model" objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>'
            '<component p:path="/3D/Objects/object_1.model" objectid="2" transform="1 0 0 0 1 0 0 0 1 0 0 10"/>'
            '</components></object></resources><build>'
            '<item objectid="3" transform="1 0 0 0 1 0 0 0 1 90 90 0"/>'
            '<item objectid="3" transform="1 0 0 0 1 0 0 0 1 226 -126 0"/></build></model>')
    cfg = ('<config><object id="3"><metadata key="name" value="Raton"/><metadata key="extruder" value="1"/>'
           '<part id="1" subtype="normal_part"><metadata key="extruder" value="1"/></part>'
           '<part id="2" subtype="normal_part"><metadata key="extruder" value="3"/></part></object>'
           '<plate><metadata key="plater_id" value="1"/><model_instance><metadata key="object_id" value="3"/>'
           '<metadata key="instance_id" value="0"/></model_instance></plate>'
           '<plate><metadata key="plater_id" value="2"/><model_instance><metadata key="object_id" value="3"/>'
           '<metadata key="instance_id" value="1"/></model_instance></plate></config>')
    import json
    with zipfile.ZipFile(p, "w") as z:
        z.writestr("_rels/.rels", '<Relationships><Relationship Target="/3D/3dmodel.model"/></Relationships>')
        z.writestr("3D/3dmodel.model", root)
        z.writestr("3D/Objects/object_1.model", sub)
        z.writestr("Metadata/model_settings.config", cfg)
        z.writestr("Metadata/project_settings.config", json.dumps({
            "printable_area": ["0x0", "180x0", "180x180", "0x180"], "filament_type": ["PLA", "PLA", "PETG"],
            "filament_colour": ["#FFFFFF", "#000000", "#FF0000"]}))
    sc = read_3mf_scene(p)
    assert len(sc.objects) == 1 and sc.bed == (180, 180)
    obj = sc.objects["3"]
    assert obj.name == "Raton" and [pt.extruder for pt in obj.parts] == [1, 3]
    assert obj.parts[0].paint == {"paint_color": ["4", "", "", ""]} and obj.parts[1].transform[11] == 10
    # placa 2 de 2 en cama de 180: origen (216, 0) → (226-216, -126) = (10, -126)?? No: 2 placas → 2 columnas
    assert [(i.plate, i.matrix[9], i.matrix[10]) for i in sc.items] == [(1, 90, 90), (2, 10, -126)]
    assert [f["type"] for f in sc.filaments] == ["PLA", "PLA", "PETG"]

    out = tmp_path / "out.3mf"
    write_project(out, sc.objects, sc.items, sc.plates, (256, 256), sc.settings)
    again = read_3mf_scene(out)
    assert again.bed == (256, 256)
    assert [(i.plate, round(i.matrix[9], 3)) for i in again.items] == [(1, 90), (2, 10)]
    o2 = next(iter(again.objects.values()))
    assert [pt.extruder for pt in o2.parts] == [1, 3] and o2.parts[0].paint == {"paint_color": ["4", "", "", ""]}
    assert [pl["index"] for pl in read_project(out)["project_plates"]] == [1, 2]
