"""Health contract (~/.claude/conventions/observability.md, Health Contract).

/health/live checks nothing and answers 200 while the process serves. /health/ready checks
every dependency the app cannot serve without and answers 503 when one is down. The body
names what is down, never why: the endpoint is unauthenticated, so the detail goes to the log.
"""

import asyncio
import logging

from fastapi import APIRouter, Request, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

router = APIRouter(prefix="/health")
log = logging.getLogger("__NAME__.health")

# A readiness probe must answer before the container healthcheck's own timeout (5 s).
DB_TIMEOUT_S = 3


@router.get("/live")
async def live(request: Request) -> dict:
    return {"status": "up", "version": request.app.state.settings.app_version}


@router.get("/ready")
async def ready(request: Request, response: Response) -> dict:
    checks = {"database": await _check_database(request.app.state.engine)}
    status = "up" if all(check["status"] == "up" for check in checks.values()) else "down"
    if status == "down":
        response.status_code = 503
    return {
        "status": status,
        "version": request.app.state.settings.app_version,
        "checks": checks,
    }


async def _check_database(engine: AsyncEngine) -> dict:
    try:
        async with asyncio.timeout(DB_TIMEOUT_S):
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
    except Exception:
        log.warning("health: database check failed", exc_info=True)
        return {"status": "down"}
    return {"status": "up"}
