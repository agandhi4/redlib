"""App factory. Used by: uvicorn (Dockerfile CMD: server.main:app), tests/."""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from server.config import Settings
from server.db import make_engine
from server.health import router as health_router

log = logging.getLogger("__NAME__")


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        logging.basicConfig(level=settings.log_level)
        app.state.engine = make_engine(settings.database_url)
        # The boot line states what is enforced; never the DSN itself.
        log.info("__NAME__ starting version=%s", settings.app_version)
        yield
        await app.state.engine.dispose()

    app = FastAPI(title="__NAME__", lifespan=lifespan)
    app.state.settings = settings
    app.include_router(health_router)
    return app


app = create_app()
