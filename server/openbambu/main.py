"""Punto de entrada del servidor OpenBambu."""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware

from . import __version__
from .api.catalog import router as catalog_router
from .api.files import router as files_router
from .api.history import router as history_router
from .api.maintenance import router as maintenance_router
from .api.power import router as power_router
from .api.printers_admin import router as admin_router
from .api.routes import router
from .api.slicer import router as slicer_router
from .config import Settings, load_settings
from .manager import PrinterManager


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        mgr = PrinterManager(settings)
        app.state.manager = mgr
        await mgr.start()
        yield
        await mgr.stop()

    app = FastAPI(title="OpenBambu", version=__version__, lifespan=lifespan)
    app.add_middleware(GZipMiddleware, minimum_size=2048)
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
    app.include_router(router)
    app.include_router(files_router)
    app.include_router(slicer_router)
    app.include_router(catalog_router)
    app.include_router(history_router)
    app.include_router(power_router)
    app.include_router(admin_router)
    app.include_router(maintenance_router)
    _mount_web(app)
    return app


def _mount_web(app: FastAPI) -> None:
    """Dashboard web: la app Flutter compilada para web, servida en la raíz."""
    from pathlib import Path

    from fastapi.responses import RedirectResponse
    from fastapi.staticfiles import StaticFiles

    web = Path(os.getenv("OB_WEB_DIR", "/opt/openbambu-web"))
    if not (web / "index.html").exists():
        @app.get("/", include_in_schema=False)
        async def no_web():
            return RedirectResponse("/docs")
        return

    class WebFiles(StaticFiles):
        async def get_response(self, path, scope):
            resp = await super().get_response(path, scope)
            # index.html y el service worker siempre frescos; el resto se cachea
            if path in ("", ".", "index.html", "flutter_service_worker.js", "version.json"):
                resp.headers["Cache-Control"] = "no-cache"
            return resp

    app.mount("/", WebFiles(directory=web, html=True), name="web")


def run() -> None:
    import uvicorn

    logging.basicConfig(
        level=os.getenv("OB_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )
    uvicorn.run(create_app(), host="0.0.0.0", port=int(os.getenv("OB_PORT", "8787")), log_level="info")


if __name__ == "__main__":
    run()
