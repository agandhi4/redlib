# --- Stage 0: dependencies (cached unless the lock changes) ---
FROM python:3.13-slim AS deps

# Pinned: :latest means two builds of the same commit can use different uv versions.
COPY --from=ghcr.io/astral-sh/uv:0.10.12 /uv /uvx /bin/

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# --- Stage 1: runtime ---
FROM python:3.13-slim

RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --create-home app

WORKDIR /app
COPY --from=deps /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"

COPY server/ server/
COPY healthcheck.py /healthcheck.py

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
  CMD ["python", "/healthcheck.py"]

# Release identity, last so a new version never invalidates a cached layer. The build passes
# it once (publish.yml: sha-<7>; Makefile: ci-<7> / gate-<n>); /health/ready reports it.
# devkit/bin/release_check.sh requires all three lines in this final stage.
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
LABEL org.opencontainers.image.version=$APP_VERSION

USER app
CMD ["uvicorn", "server.main:app", "--host", "0.0.0.0", "--port", "8000"]
