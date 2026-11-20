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
