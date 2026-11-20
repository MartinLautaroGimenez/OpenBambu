"""Catálogo con respuestas HTTP simuladas (sin internet)."""

import asyncio
import json

import httpx
import pytest

from openbambu.catalog.base import AuthRequired
from openbambu.catalog.service import CatalogService
from openbambu.config import CatalogConfig
from openbambu.library.store import Store

STL = b"solid cubo\nendsolid cubo\n"


def handler(request: httpx.Request) -> httpx.Response:
    url = str(request.url)
    if "api.printables.com" in url:
        q = json.loads(request.content)["query"]
        if "searchPrints2" in q:
            return httpx.Response(200, json={"data": {"searchPrints2": {"items": [
                {"id": "1", "name": "Cubo", "slug": "cubo", "likesCount": 5, "downloadCount": 9,
                 "image": {"filePath": "media/a.jpg"}, "user": {"publicUsername": "ana"}},
                {"id": "2", "name": "Gancho", "slug": "gancho", "likesCount": 1, "downloadCount": 2,
                 "image": None, "user": None}]}}})
        if "getDownloadLink" in q:
            return httpx.Response(200, json={"data": {"getDownloadLink": {
                "ok": True, "errors": None, "output": {"link": "https://files.printables.com/cubo.stl"}}}})
        if "print(id" in q:
            return httpx.Response(200, json={"data": {"print": {
                "id": "1", "name": "Cubo", "slug": "cubo", "likesCount": 5, "downloadCount": 9,
                "image": {"filePath": "media/a.jpg"}, "user": {"publicUsername": "ana"},
                "summary": "Un cubo", "description": "<p>Cubo</p>", "license": {"name": "CC BY"},
                "images": [{"filePath": "media/a.jpg"}, {"filePath": "media/b.jpg"}],
                "stls": [{"id": "10", "name": "cubo.stl", "fileSize": 25}, {"id": "11", "name": "leeme.pdf"}]}}})
    if "files.printables.com" in url:
        return httpx.Response(200, content=STL)
    if "makerworld.com/api/v1/search-service" in url:
        return httpx.Response(200, json={"hits": [
            {"id": 77, "title": "Benchy", "cover": "https://mw/c.jpg", "likeCount": 3, "downloadCount": 4,
             "designCreator": {"name": "Bambu Lab"}},
            {"id": 78, "title": "NSFW", "nsfw": True}]})
    if "makerworld.com/api/v1/design-service/design/77" in url:
        return httpx.Response(200, json={
            "id": 77, "title": "Benchy", "coverUrl": "https://mw/c.jpg", "summary": "Barco",
            "designExtension": {"design_pictures": [{"url": "https://mw/1.jpg"}]},
            "instances": [{"id": 500, "title": "15min, PLA, A1", "prediction": "900", "weight": "12",
                           "instanceFilaments": '[{"type": "PLA", "color": "#FFFFFF", "usedG": "12"}]'}]})
    if "makerworld.com/api/v1/design-service/instance/500/f3mf" in url:
        if "token=secreto" not in request.headers.get("cookie", ""):
            return httpx.Response(403)
        return httpx.Response(200, json={"name": "benchy.3mf", "url": "https://mw-cdn/benchy.3mf"})
    if "mw-cdn" in url:
        return httpx.Response(200, content=b"no es un zip")
    return httpx.Response(404)


@pytest.fixture
def service(tmp_path):
    def make(**cfg):
        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        return CatalogService(CatalogConfig(**cfg), Store(tmp_path), client)
    return make


def run(coro):
    return asyncio.run(coro)


def test_browse_interleaves_sources_and_skips_disabled(service):
    s = service()
    res = run(s.browse("", None, 0, 12))
    assert [(i["source"], i["title"]) for i in res["items"]] == [
        ("makerworld", "Benchy"), ("printables", "Cubo"), ("printables", "Gancho")]  # sin NSFW
    assert res["items"][1]["image"] == "https://media.printables.com/media/a.jpg"
    assert [x["id"] for x in s.sources() if x["enabled"]] == ["makerworld", "printables"]  # Thingiverse sin token


def test_printables_detail_and_download(service):
    s = service()
    d = run(s.detail("printables", "1"))
    assert [f["name"] for f in d["files"]] == ["cubo.stl"] and len(d["images"]) == 2
    items = run(s.download("printables", "1", ["10"]))
    assert items[0]["name"] == "Cubo" and items[0]["meta"]["format"] == "stl"
    assert items[0]["meta"]["catalog"]["image"] == "https://media.printables.com/media/a.jpg"
    assert s.store.file_path(items[0]).read_bytes() == STL


def test_makerworld_profiles_and_auth(service):
    s = service()
    d = run(s.detail("makerworld", "77"))
    f = d["files"][0]
    assert f["kind"] == "profile" and f["printer"] == "A1" and f["prediction_s"] == 900 and f["weight_g"] == 12
    assert d["downloadable"] is False and d["note"]
    with pytest.raises(AuthRequired):
        run(s.download("makerworld", "77", ["500"]))
    # Con token descarga, pero el archivo no es un 3MF válido → error y no queda basura en la biblioteca
    s2 = service(makerworld_token="secreto")
    with pytest.raises(Exception):
        run(s2.download("makerworld", "77", ["500"]))
    assert s2.store.list_files() == []


def test_image_proxy_allowlist_and_resize(service, tmp_path):
    import io

    from PIL import Image

    from openbambu.catalog.service import fetch_thumbnail, image_allowed

    assert image_allowed("https://media.printables.com/media/a.jpg")
    assert image_allowed("https://makerworld.bblmw.com/x.png")
    assert not image_allowed("http://media.printables.com/a.jpg")  # solo https
    assert not image_allowed("https://169.254.169.254/latest/meta-data")
    assert not image_allowed("https://evilmedia.printables.com.attacker.net/a.jpg")

    buf = io.BytesIO()
    Image.new("RGB", (2000, 1000), (200, 10, 10)).save(buf, "PNG")
    png = buf.getvalue()

    def img_handler(request):
        return httpx.Response(200, content=png)

    s = CatalogService(CatalogConfig(), Store(tmp_path), httpx.AsyncClient(transport=httpx.MockTransport(img_handler)))
    data = run(fetch_thumbnail(s, "https://media.printables.com/big.png", 400, tmp_path / "cache"))
    assert Image.open(io.BytesIO(data)).size == (400, 200)
    assert len(list((tmp_path / "cache").rglob("*.jpg"))) == 1


def test_makerworld_login_flow(tmp_path):
    from fastapi.testclient import TestClient

    from openbambu.config import PrinterConfig, Settings
    from openbambu.main import create_app

    calls = []

    def bambu(request):
        body = json.loads(request.content)
        calls.append((request.url.path, body))
        if request.url.path.endswith("/user/login"):
            if body.get("code") == "123456":
                return httpx.Response(200, json={"accessToken": "tok-nuevo"})
            return httpx.Response(200, json={"accessToken": "", "loginType": "verifyCode"})
        return httpx.Response(200, json={})

    settings = Settings(api_token="t", data_dir=str(tmp_path),
                        printers=[PrinterConfig(id="sim", model="A1", mode="simulator")])
    with TestClient(create_app(settings)) as c:
        mgr = c.app.state.manager
        mgr.catalog.client = httpx.AsyncClient(transport=httpx.MockTransport(bambu))
        H = {"Authorization": "Bearer t"}
        r = c.post("/api/catalog/makerworld/login", json={"email": "a@b.c", "password": "x"}, headers=H).json()
        assert r["needs_code"] and calls[-1][0].endswith("/sendemail/code")
        r = c.post("/api/catalog/makerworld/login", json={"email": "a@b.c", "code": "123456"}, headers=H).json()
        assert r == {"ok": True}
        assert mgr.catalog.providers["makerworld"].token == "tok-nuevo"
        assert next(s for s in c.get("/api/catalog/sources", headers=H).json() if s["id"] == "makerworld")["can_download"]
        assert "tok-nuevo" not in c.get("/api/catalog/sources", headers=H).text  # el token no se expone
        c.delete("/api/catalog/makerworld/login", headers=H)
        assert mgr.catalog.providers["makerworld"].token == ""
