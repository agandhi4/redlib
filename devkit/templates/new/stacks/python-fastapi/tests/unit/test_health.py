"""Hermetic: no database. The unreachable DSN makes readiness fail fast, which is the point."""

from fastapi.testclient import TestClient

from server.config import Settings
from server.main import create_app

UNREACHABLE_DB = "postgresql+asyncpg://nobody@127.0.0.1:1/nothing"


def client() -> TestClient:
    return TestClient(create_app(Settings(database_url=UNREACHABLE_DB, app_version="test")))


def test_live_reports_the_version() -> None:
    with client() as c:
        response = c.get("/health/live")
    assert response.status_code == 200
    assert response.json() == {"status": "up", "version": "test"}


def test_ready_is_503_without_a_database() -> None:
    with client() as c:
        response = c.get("/health/ready")
    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "down"
    assert body["checks"]["database"] == {"status": "down"}
