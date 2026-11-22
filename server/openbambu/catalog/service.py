"""Catálogo unificado: busca en todas las fuentes y descarga a la biblioteca."""

from __future__ import annotations

import asyncio
import logging
import time
from itertools import zip_longest

import httpx

from ..config import CatalogConfig
from ..library.ingest import ingest, safe_name
from ..library.store import Store
from ..library.threemf import InvalidFile
from .base import USER_AGENT, AuthRequired, CatalogError, CatalogItem, Provider
from .makerworld import MakerWorld
from .printables import Printables
from .thingiverse import Thingiverse

log = logging.getLogger(__name__)
CACHE_TTL = 600


class CatalogService:
    def __init__(self, cfg: CatalogConfig, store: Store, client: httpx.AsyncClient | None = None):
        self.store = store
        self.client = client or httpx.AsyncClient(headers={"User-Agent": USER_AGENT}, follow_redirects=True)
        self.providers: dict[str, Provider] = {
            p.name: p for p in (
                MakerWorld(self.client, cfg.makerworld_token),
                Printables(self.client),
                Thingiverse(self.client, cfg.thingiverse_token),
            )
        }
        self._cache: dict[tuple, tuple[float, object]] = {}

    def set_makerworld_token(self, token: str) -> None:
        self.providers["makerworld"].token = token.strip()  # type: ignore[attr-defined]
        self._cache = {k: v for k, v in self._cache.items() if k[0] != "makerworld"}

    def sources(self) -> list[dict]:
        return [
            {"id": p.name, "label": p.label, "enabled": p.enabled,
             "can_download": p.enabled and (not isinstance(p, MakerWorld) or bool(p.token))}
            for p in self.providers.values()
        ]

    async def _cached(self, key: tuple, factory):
        hit = self._cache.get(key)
        if hit and time.time() - hit[0] < CACHE_TTL:
            return hit[1]
        value = await factory()
        self._cache[key] = (time.time(), value)
        if len(self._cache) > 300:
            for k in sorted(self._cache, key=lambda k: self._cache[k][0])[:100]:
                self._cache.pop(k, None)
        return value

    def _provider(self, name: str) -> Provider:
        p = self.providers.get(name)
        if not p:
            raise CatalogError(f"Fuente desconocida: {name}")
        return p

    async def browse(self, query: str, source: str | None, page: int, limit: int) -> dict:
        """Busca (o, sin texto, trae populares) en una fuente o en todas."""
        query = query.strip()
        targets = [self._provider(source)] if source else [p for p in self.providers.values() if p.enabled]
        per = limit if source else max(6, limit // max(1, len(targets)))

        async def one(p: Provider):
            key = (p.name, query, page, per)
            fn = (lambda: p.search(query, page, per)) if query else (lambda: p.popular(page, per))
            return await self._cached(key, fn)

        results = await asyncio.gather(*(one(p) for p in targets), return_exceptions=True)
        lists: list[list[CatalogItem]] = []
        errors = {}
        for p, r in zip(targets, results):
            if isinstance(r, Exception):
                log.warning("Catálogo %s: %s", p.name, r)
                errors[p.name] = str(r) or type(r).__name__
                lists.append([])
            else:
                lists.append(r)
        # Intercalar fuentes para que la portada sea variada
        items = [it for group in zip_longest(*lists) for it in group if it is not None]
        return {"items": [i.to_dict() for i in items], "errors": errors, "page": page}

    async def detail(self, source: str, item_id: str) -> dict:
        p = self._provider(source)
        d = await self._cached((source, "detail", item_id), lambda: p.detail(item_id))
        return d.to_dict()

    async def download(self, source: str, item_id: str, file_ids: list[str]) -> list[dict]:
        p = self._provider(source)
        detail = await self._cached((source, "detail", item_id), lambda: p.detail(item_id))
        wanted = [f for f in detail.files if f.id in set(file_ids)]
        if not wanted:
            raise CatalogError("Elegí al menos un archivo")
        items = []
        for f in wanted:
            lid, folder = self.store.new_file_dir()
            try:
                path = await p.download(item_id, f, folder)
                filename = safe_name(path.name)
                if filename != path.name:
                    path = path.rename(folder / filename)
                base = detail.item.title if len(wanted) == 1 or f.kind == "profile" else \
                    f"{detail.item.title} · {f.name.rsplit('.', 1)[0]}"
                if f.kind == "profile":
                    base = f"{detail.item.title} ({f.name})"
                items.append(ingest(self.store, lid, folder, filename, f"catalog:{source}", name=base[:120],
                                    extra_meta={"catalog": {"source": source, "id": item_id,
                                                            "url": detail.item.url, "image": detail.item.image,
                                                            "author": detail.item.author,
                                                            "profile": f.name if f.kind == "profile" else None,
                                                            "plates": f.plates}}))
            except (AuthRequired, CatalogError, InvalidFile, httpx.HTTPError):
                import shutil
                shutil.rmtree(folder, ignore_errors=True)
                raise
        return items


# ---- proxy de imágenes -------------------------------------------------------
IMAGE_HOSTS = (
    "makerworld.bblmw.com", "public-cdn.bblmw.com", "media.printables.com", "files.printables.com",
    "cdn.thingiverse.com", "thingiverse-production-new.s3.amazonaws.com",
)


def image_allowed(url: str) -> bool:
    from urllib.parse import urlparse

    u = urlparse(url)
    return u.scheme == "https" and any(u.hostname == h or (u.hostname or "").endswith("." + h) for h in IMAGE_HOSTS)


async def fetch_thumbnail(service: CatalogService, url: str, width: int, cache_dir) -> bytes:
    """Descarga una imagen del catálogo, la achica a ``width`` px (JPEG) y la cachea en disco."""
    import hashlib
    import io

    from PIL import Image

    if not image_allowed(url):
        raise CatalogError("Dominio de imagen no permitido")
    width = max(64, min(width, 1600))
    key = hashlib.sha1(f"{url}|{width}".encode()).hexdigest()
    path = cache_dir / key[:2] / f"{key}.jpg"
    if path.exists():
        return path.read_bytes()
    r = await service.client.get(url, timeout=20)
    r.raise_for_status()
    if len(r.content) > 20 * 1024 * 1024:
        raise CatalogError("Imagen demasiado grande")

    def resize() -> bytes:
        img = Image.open(io.BytesIO(r.content))
        img = img.convert("RGB")
        if img.width > width:
            img = img.resize((width, round(img.height * width / img.width)), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=82, optimize=True)
        return buf.getvalue()

    data = await asyncio.to_thread(resize)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return data
