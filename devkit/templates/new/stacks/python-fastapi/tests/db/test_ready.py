"""The db tier: a real Postgres from devkit/bin/throwaway_pg.sh (make ci-db sets the URL)."""

import os

from fastapi.testclient import TestClient

from server.config import Settings
from server.main import create_app


def test_ready_is_200_against_postgres() -> None:
    url = os.environ.get("TEST_DATABASE_URL")
    assert url, "TEST_DATABASE_URL is unset; run this tier with `make ci-db`"
    with TestClient(create_app(Settings(database_url=url, app_version="test"))) as c:
        response = c.get("/health/ready")
    assert response.status_code == 200
    assert response.json()["checks"]["database"] == {"status": "up"}
