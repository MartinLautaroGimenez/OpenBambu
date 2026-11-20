"""Thingiverse: API oficial; necesita un token de app (catalog.thingiverse_token).

Se crea gratis en https://www.thingiverse.com/developers (App → "Desktop app").
"""

from __future__ import annotations

from pathlib import Path

from .base import AuthRequired, CatalogDetail, CatalogError, CatalogFile, CatalogItem, Provider

API = "https://api.thingiverse.com"
MODEL_EXT = (".stl", ".3mf", ".obj", ".step", ".stp")


class Thingiverse(Provider):
    name = "thingiverse"
    label = "Thingiverse"

    def __init__(self, client, token: str = ""):
        super().__init__(client)
        self.token = token.strip()

    @property
    def enabled(self) -> bool:
        return bool(self.token)

    async def _get(self, path: str, params: dict | None = None):
        if not self.token:
            raise AuthRequired("Thingiverse necesita un token (catalog.thingiverse_token)")
        r = await self.client.get(f"{API}{path}", params=params, timeout=20,
                                  headers={"Authorization": f"Bearer {self.token}"})
        if r.status_code in (401, 403):
            raise AuthRequired("Thingiverse rechazó el token")
        r.raise_for_status()
        return r.json()

    def _item(self, t: dict) -> CatalogItem:
        return CatalogItem(
            source=self.name,
            id=str(t["id"]),
            title=t.get("name") or "",
            image=t.get("preview_image") or t.get("thumbnail"),
            author=(t.get("creator") or {}).get("name"),
            likes=int(t.get("like_count") or 0),
            downloads=int(t.get("download_count") or 0),
            url=t.get("public_url") or f"https://www.thingiverse.com/thing:{t['id']}",
        )

    async def search(self, query: str, page: int, limit: int) -> list[CatalogItem]:
        d = await self._get(f"/search/{query}", {"type": "things", "per_page": limit, "page": page + 1})
        return [self._item(t) for t in (d.get("hits") if isinstance(d, dict) else d) or []]

    async def popular(self, page: int, limit: int) -> list[CatalogItem]:
        d = await self._get("/popular", {"per_page": limit, "page": page + 1})
        return [self._item(t) for t in (d if isinstance(d, list) else d.get("hits") or [])]

    async def detail(self, item_id: str) -> CatalogDetail:
        t = await self._get(f"/things/{int(item_id)}")
        files = await self._get(f"/things/{int(item_id)}/files")
        images = await self._get(f"/things/{int(item_id)}/images")
        out = [
            CatalogFile(id=str(f["id"]), name=f["name"], kind="3mf" if f["name"].lower().endswith(".3mf") else "stl",
                        size=f.get("size"))
            for f in files if str(f.get("name", "")).lower().endswith(MODEL_EXT)
        ]
        pics = []
        for img in images or []:
            sizes = {s.get("size"): s.get("url") for s in img.get("sizes") or [] if s.get("type") == "display"}
            if url := sizes.get("large") or sizes.get("medium"):
                pics.append(url)
        return CatalogDetail(item=self._item(t), description=t.get("description_html") or t.get("description") or "",
                             images=pics, files=out, license=t.get("license"))

    async def download(self, item_id: str, file: CatalogFile, dest: Path) -> Path:
        info = await self._get(f"/files/{int(file.id)}")
        url = info.get("direct_url") or info.get("download_url")
        if not url:
            raise CatalogError("Thingiverse no devolvió el enlace de descarga")
        path = dest / file.name
        await self._fetch_to(url, path, headers={"Authorization": f"Bearer {self.token}"})
        return path
