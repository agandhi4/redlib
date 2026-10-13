#!/usr/bin/env bash
# Boot a built __NAME__ image against an EMPTY throwaway Postgres and prove it serves.
# Usage: scripts/ci/smoke_image.sh <image> <version>
#        (or: make ci-smoke CI_IMAGE=<image> CI_BUILD_VERSION=<version>)
#   <version> is the APP_VERSION the image was built with; /health/ready must report it.
#
# Catches what the source-tree suites cannot: a broken COPY, a runtime import only a dev
# dependency satisfied, a settings validator rejecting the production env. publish.yml runs
# it before pushing; the PR gate's `image` job runs it on every image-affecting PR.
#
# The boot (private network, throwaway Postgres, health poll with early exit, log dump on a
# failed boot) is devkit/bin/boot_image.sh; this script owns the env and the assertions.
set -euo pipefail

IMAGE=${1:?usage: smoke_image.sh <image> <version>}
VERSION=${2:?usage: smoke_image.sh <image> <version>}
# Unique per run, so concurrent smokes and a developer's own containers never collide.
NAME="__NAME__-smoke-$$-$RANDOM"
BOOT="$(cd "$(dirname "$0")/../.." && pwd)/devkit/bin/boot_image.sh"
trap '"$BOOT" down "$NAME"' EXIT

# The production env. A NEW REQUIRED SETTING MUST BE ADDED HERE TOO, or every publish fails.
BOOT_ENV="DATABASE_URL=postgresql+asyncpg://ci:ci@$NAME-pg:5432/ci"

BASE_LINE=$(
  BOOT_IMAGE="$IMAGE" BOOT_PORT=8000 BOOT_HEALTH_PATH=/health/ready BOOT_TIMEOUT=60 \
  BOOT_ENV="$BOOT_ENV" BOOT_WITH_PG=1 BOOT_EXPECT_VERSION="$VERSION" \
  PG_IMAGE=postgres:18 "$BOOT" up "$NAME"
)
BASE=${BASE_LINE#BASE=}
echo "smoke: $BASE/health/ready 2xx, version $VERSION"

# The image's own HEALTHCHECK script, run the way Docker runs it.
docker exec "$NAME-app" python /healthcheck.py
echo "smoke: healthcheck.py ok"
