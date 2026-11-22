"""Tipos comunes del catálogo de modelos."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path

import httpx

USER_AGENT = "Mozilla/5.0 (X11; Linux aarch64) OpenBambu/0.1"


class CatalogError(RuntimeError):
    pass


class AuthRequired(CatalogError):
    """La fuente necesita un token configurado para esta operación."""


@dataclass
class CatalogItem:
    source: str
    id: str
    title: str
    image: str | None
    author: str | None = None
    likes: int = 0
    downloads: int = 0
    url: str | None = None
    # Solo MakerWorld: perfiles de impresión listos para Bambu
    bambu_ready: bool = False

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class CatalogFile:
    id: str
    name: str
    kind: str  # "stl" | "3mf" | "profile" (3mf con perfil de impresión de MakerWorld)
    size: int | None = None
    printer: str | None = None
    prediction_s: int | None = None
    weight_g: float | None = None
    filaments: list[dict] = field(default_factory=list)
    image: str | None = None
    # Perfiles de MakerWorld: placas con miniatura, tiempo, peso y filamentos
    plates: list[dict] = field(default_factory=list)
    pictures: list[str] = field(default_factory=list)
    description: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class CatalogDetail:
    item: CatalogItem
    description: str
    images: list[str]
    files: list[CatalogFile]
    license: str | None = None
    downloadable: bool = True
    note: str | None = None

    def to_dict(self) -> dict:
        return {
            **self.item.to_dict(),
            "description": self.description,
            "images": self.images,
            "files": [f.to_dict() for f in self.files],
            "license": self.license,
            "downloadable": self.downloadable,
            "note": self.note,
        }


class Provider:
    name = ""
    label = ""

    def __init__(self, client: httpx.AsyncClient):
        self.client = client

    @property
    def enabled(self) -> bool:
        return True

    async def search(self, query: str, page: int, limit: int) -> list[CatalogItem]:
        raise NotImplementedError

    async def popular(self, page: int, limit: int) -> list[CatalogItem]:
        raise NotImplementedError

    async def detail(self, item_id: str) -> CatalogDetail:
        raise NotImplementedError

    async def download(self, item_id: str, file: CatalogFile, dest: Path) -> Path:
        """Descarga el archivo a ``dest`` (carpeta) y devuelve la ruta final."""
        raise NotImplementedError

    async def _fetch_to(self, url: str, dest: Path, headers: dict | None = None,
                        max_bytes: int = 512 * 1024 * 1024) -> None:
        size = 0
        async with self.client.stream("GET", url, headers=headers, follow_redirects=True, timeout=120) as r:
            if r.status_code in (401, 403):
                raise AuthRequired(f"{self.label} rechazó la descarga ({r.status_code})")
            r.raise_for_status()
            with open(dest, "wb") as f:
                async for chunk in r.aiter_bytes(64 * 1024):
                    size += len(chunk)
                    if size > max_bytes:
                        raise CatalogError("Archivo demasiado grande")
                    f.write(chunk)
