"""Printables (Prusa): API GraphQL pública, sin cuenta para buscar ni descargar."""

from __future__ import annotations

from pathlib import Path

from .base import CatalogDetail, CatalogError, CatalogFile, CatalogItem, Provider

API = "https://api.printables.com/graphql/"
MEDIA = "https://media.printables.com/"

ITEM_FIELDS = "id name slug likesCount downloadCount image { filePath } user { publicUsername }"


class Printables(Provider):
    name = "printables"
    label = "Printables"

    async def _gql(self, query: str, variables: dict | None = None) -> dict:
        r = await self.client.post(API, json={"query": query, "variables": variables or {}}, timeout=20)
        r.raise_for_status()
        data = r.json()
        if data.get("errors"):
            raise CatalogError(f"Printables: {data['errors'][0].get('message')}")
        return data["data"]

    def _item(self, p: dict) -> CatalogItem:
        img = (p.get("image") or {}).get("filePath")
        return CatalogItem(
            source=self.name,
            id=str(p["id"]),
            title=p.get("name") or "",
            image=MEDIA + img if img else None,
            author=(p.get("user") or {}).get("publicUsername"),
            likes=int(p.get("likesCount") or 0),
            downloads=int(p.get("downloadCount") or 0),
            url=f"https://www.printables.com/model/{p['id']}-{p.get('slug', '')}",
        )

    async def _search(self, query: str, ordering: str, page: int, limit: int) -> list[CatalogItem]:
        q = (
            "query($q: String!, $limit: Int!, $offset: Int!) {"
            f" searchPrints2(query: $q, limit: $limit, offset: $offset, ordering: {ordering})"
            f" {{ items {{ {ITEM_FIELDS} }} }} }}"
        )
        data = await self._gql(q, {"q": query, "limit": limit, "offset": page * limit})
        return [self._item(p) for p in data["searchPrints2"]["items"]]

    async def search(self, query: str, page: int, limit: int) -> list[CatalogItem]:
        return await self._search(query, "best_match", page, limit)

    async def popular(self, page: int, limit: int) -> list[CatalogItem]:
        return await self._search("", "popular", page, limit)

    async def detail(self, item_id: str) -> CatalogDetail:
        q = (
            "query($id: ID!) { print(id: $id) {"
            f" {ITEM_FIELDS} summary description license {{ name }}"
            " images { filePath } stls { id name fileSize } } }"
        )
        p = (await self._gql(q, {"id": item_id}))["print"]
        if not p:
            raise CatalogError("Modelo no encontrado en Printables")
        files = []
        for f in p.get("stls") or []:
            name = f.get("name") or "modelo.stl"
            kind = "3mf" if name.lower().endswith(".3mf") else "stl"
            if name.lower().endswith((".stl", ".3mf", ".obj", ".step", ".stp")):
                files.append(CatalogFile(id=str(f["id"]), name=name, kind=kind, size=f.get("fileSize")))
        return CatalogDetail(
            item=self._item(p),
            description=p.get("description") or p.get("summary") or "",
            images=[MEDIA + i["filePath"] for i in p.get("images") or [] if i.get("filePath")],
            files=files,
            license=(p.get("license") or {}).get("name"),
        )

    async def download(self, item_id: str, file: CatalogFile, dest: Path) -> Path:
        q = (
            "mutation($id: ID!, $printId: ID!) { getDownloadLink(id: $id, printId: $printId,"
            " fileType: stl, source: model_detail) { ok errors { messages } output { link } } }"
        )
        data = (await self._gql(q, {"id": file.id, "printId": item_id}))["getDownloadLink"]
        if not data.get("ok") or not (data.get("output") or {}).get("link"):
            raise CatalogError("Printables no devolvió el enlace de descarga")
        path = dest / file.name
        await self._fetch_to(data["output"]["link"], path)
        return path
