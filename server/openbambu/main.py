"""Punto de entrada del servidor OpenBambu."""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from . import __version__
from .api.routes import router
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
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
    app.include_router(router)
    return app


def run() -> None:
    import uvicorn

    logging.basicConfig(
        level=os.getenv("OB_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )
    uvicorn.run(create_app(), host="0.0.0.0", port=int(os.getenv("OB_PORT", "8787")), log_level="info")


if __name__ == "__main__":
    run()
