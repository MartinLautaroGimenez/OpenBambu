"""MakerWorld (Bambu Lab).

Buscar y ver modelos funciona sin cuenta. Para **descargar** MakerWorld exige
una sesión: se configura el token de la cuenta (cookie ``token`` del navegador)
en ``catalog.makerworld_token``. Los "perfiles de impresión" son .3mf con
placas y ajustes ya preparados para impresoras Bambu.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from .base import AuthRequired, CatalogDetail, CatalogError, CatalogFile, CatalogItem, Provider

API = "https://makerworld.com/api/v1"


class MakerWorld(Provider):
    name = "makerworld"
    label = "MakerWorld"

    def __init__(self, client, token: str = ""):
        super().__init__(client)
        self.token = token.strip()

    @property
    def auth_headers(self) -> dict:
        return {"Authorization": f"Bearer {self.token}", "Cookie": f"token={self.token}"} if self.token else {}

    async def _get(self, path: str, params: dict | None = None, auth: bool = False) -> dict:
        r = await self.client.get(f"{API}{path}", params=params, timeout=20,
                                  headers=self.auth_headers if auth else None)
        if r.status_code in (401, 403):
            raise AuthRequired("MakerWorld requiere iniciar sesión para esto")
        r.raise_for_status()
        return r.json()

    def _item(self, h: dict) -> CatalogItem:
        return CatalogItem(
            source=self.name,
            id=str(h["id"]),
            title=h.get("titleTranslated") or h.get("title") or "",
            image=h.get("cover") or h.get("coverUrl"),
            author=(h.get("designCreator") or {}).get("name"),
            likes=int(h.get("likeCount") or 0),
            downloads=int(h.get("downloadCount") or 0),
            url=f"https://makerworld.com/models/{h['id']}",
            bambu_ready=bool(h.get("is_printable", True)),
        )

    async def search(self, query: str, page: int, limit: int) -> list[CatalogItem]:
        d = await self._get("/search-service/select/design2",
                            {"keyword": query, "limit": limit, "offset": page * limit})
        return [self._item(h) for h in d.get("hits") or [] if not h.get("nsfw")]

    async def popular(self, page: int, limit: int) -> list[CatalogItem]:
        d = await self._get("/search-service/recommend/design", {"limit": limit, "offset": page * limit})
        return [self._item(h) for h in d.get("hits") or [] if not h.get("nsfw")]

    async def detail(self, item_id: str) -> CatalogDetail:
        d = await self._get(f"/design-service/design/{int(item_id)}")
        files = []
        for inst in d.get("instances") or []:
            try:
                fil = json.loads(inst.get("instanceFilaments") or "[]") if isinstance(
                    inst.get("instanceFilaments"), str) else inst.get("instanceFilaments") or []
            except ValueError:
                fil = []
            title = inst.get("titleTranslated") or inst.get("title") or f"Perfil {inst.get('id')}"
            files.append(CatalogFile(
                id=str(inst["id"]),
                name=title,
                kind="profile",
                printer=_printer_from_title(title),
                prediction_s=_int(inst.get("prediction")),
                weight_g=_float(inst.get("weight")),
                filaments=[{"type": f.get("type"), "color": f.get("color"), "used_g": _float(f.get("usedG"))}
                           for f in fil],
                image=inst.get("cover"),
            ))
        pics = [p.get("url") for p in (d.get("designExtension") or {}).get("design_pictures") or [] if p.get("url")]
        return CatalogDetail(
            item=self._item({**d, "cover": d.get("coverUrl")}),
            description=d.get("summaryTranslated") or d.get("summary") or "",
            images=pics or ([d["coverUrl"]] if d.get("coverUrl") else []),
            files=files,
            license=d.get("license"),
            downloadable=bool(self.token),
            note=None if self.token else
            "Para descargar de MakerWorld configurá tu token de MakerWorld en el servidor (ver docs).",
        )

    async def download(self, item_id: str, file: CatalogFile, dest: Path) -> Path:
        if not self.token:
            raise AuthRequired("Configurá catalog.makerworld_token para descargar de MakerWorld")
        info = await self._get(f"/design-service/instance/{int(file.id)}/f3mf", {"type": "download"}, auth=True)
        url = info.get("url")
        if not url:
            raise CatalogError("MakerWorld no devolvió el enlace de descarga")
        name = info.get("name") or f"makerworld_{file.id}.3mf"
        if not name.lower().endswith(".3mf"):
            name += ".3mf"
        path = dest / re.sub(r"[^\w.\- ()]", "_", name)
        await self._fetch_to(url, path)
        return path


PRINTERS = ["A1 mini", "A1", "P1S", "P1P", "X1E", "X1 Carbon", "X1C", "H2D", "H2S", "P2S"]


def _printer_from_title(title: str) -> str | None:
    for p in PRINTERS:
        if re.search(rf"\b{re.escape(p)}\b", title, re.IGNORECASE):
            return p
    return None


def _int(v) -> int | None:
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def _float(v) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None
