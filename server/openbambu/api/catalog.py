"""API del catálogo de modelos."""

from __future__ import annotations

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from ..catalog.base import AuthRequired, CatalogError
from ..library.threemf import InvalidFile
from ..manager import PrinterManager
from .routes import auth, manager

router = APIRouter(prefix="/api/catalog", dependencies=[Depends(auth)])


def _err(e: Exception) -> HTTPException:
    if isinstance(e, AuthRequired):
        return HTTPException(403, str(e))
    if isinstance(e, httpx.HTTPStatusError) and e.response.status_code == 404:
        return HTTPException(404, "Modelo no encontrado")
    if isinstance(e, InvalidFile):
        return HTTPException(422, f"El archivo descargado no es válido: {e}")
    if isinstance(e, httpx.HTTPError):
        return HTTPException(502, "No se pudo contactar a la fuente del catálogo")
    return HTTPException(422, str(e))


@router.get("/sources")
async def sources(mgr: PrinterManager = Depends(manager)):
    return mgr.catalog.sources()


@router.get("")
async def browse(q: str = "", source: str | None = None, page: int = Query(0, ge=0, le=50),
                 limit: int = Query(24, ge=1, le=60), mgr: PrinterManager = Depends(manager)):
    try:
        return await mgr.catalog.browse(q, source, page, limit)
    except CatalogError as e:
        raise _err(e) from e


@router.get("/{source}/{item_id}")
async def detail(source: str, item_id: str, mgr: PrinterManager = Depends(manager)):
    try:
        return await mgr.catalog.detail(source, item_id)
    except (CatalogError, httpx.HTTPError) as e:
        raise _err(e) from e


class DownloadIn(BaseModel):
    file_ids: list[str]


@router.post("/{source}/{item_id}/download")
async def download(source: str, item_id: str, body: DownloadIn, mgr: PrinterManager = Depends(manager)):
    try:
        return await mgr.catalog.download(source, item_id, body.file_ids)
    except (CatalogError, InvalidFile, httpx.HTTPError) as e:
        raise _err(e) from e
