"""API del catálogo de modelos."""

from __future__ import annotations

import httpx
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import Response
from pydantic import BaseModel

from ..catalog.base import AuthRequired, CatalogError
from ..catalog.service import fetch_thumbnail
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


class MakerWorldLoginIn(BaseModel):
    email: str = ""
    password: str = ""
    code: str = ""
    token: str = ""  # alternativa: pegar el token a mano


@router.post("/makerworld/login")
async def makerworld_login(body: MakerWorldLoginIn, mgr: PrinterManager = Depends(manager)):
    from ..catalog.bambu_auth import LoginNeedsCode, login, save_secret

    token = body.token.strip()
    if not token:
        if not body.email:
            raise HTTPException(422, "Ingresá tu email o un token")
        try:
            token = await login(mgr.catalog.client, body.email, body.password, body.code)
        except LoginNeedsCode as e:
            return {"ok": False, "needs_code": True, "message": str(e)}
        except CatalogError as e:
            raise HTTPException(422, str(e)) from e
        except httpx.HTTPError as e:
            raise HTTPException(502, "No se pudo contactar a Bambu Lab") from e
    save_secret(mgr.settings.data_dir, "makerworld_token", token)
    mgr.catalog.set_makerworld_token(token)
    return {"ok": True}


@router.delete("/makerworld/login")
async def makerworld_logout(mgr: PrinterManager = Depends(manager)):
    from ..catalog.bambu_auth import save_secret

    save_secret(mgr.settings.data_dir, "makerworld_token", None)
    mgr.catalog.set_makerworld_token("")
    return {"ok": True}


@router.get("/image")
async def image(url: str, w: int = 480, mgr: PrinterManager = Depends(manager)):
    """Miniatura de una imagen del catálogo (achicada y cacheada en el servidor)."""
    try:
        data = await fetch_thumbnail(mgr.catalog, url, w, Path(mgr.settings.data_dir) / "cache" / "images")
    except CatalogError as e:
        raise HTTPException(422, str(e)) from e
    except (httpx.HTTPError, OSError) as e:
        raise HTTPException(502, "No se pudo obtener la imagen") from e
    return Response(data, media_type="image/jpeg", headers={"Cache-Control": "public, max-age=604800"})


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
