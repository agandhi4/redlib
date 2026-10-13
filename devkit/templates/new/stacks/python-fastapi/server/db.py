"""The async engine. Used by: server.main (lifespan), server.health (readiness)."""

from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine


def make_engine(url: str) -> AsyncEngine:
    # pool_pre_ping: a connection Postgres closed (restart, idle timeout) is replaced instead
    # of surfacing as the first query's error after the outage.
    return create_async_engine(url, pool_pre_ping=True)
