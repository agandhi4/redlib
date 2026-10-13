#!/usr/bin/env bash
# Boot a built __NAME__ image and prove it serves.
# Usage: scripts/ci/smoke_image.sh <image> <version>
#        (or: make ci-smoke CI_IMAGE=<image> CI_BUILD_VERSION=<version>)
#   <version> is the APP_VERSION the image was built with; /health/ready must report it.
#
# Catches what the source-tree suites cannot: a binary that does not run on the release
# stage's libc, a missing COPY, a crash on the production env. publish.yml runs it before
# pushing; the PR gate's `image` job runs it on every image-affecting PR.
#
# The boot (private network, health poll with early exit, log dump on a failed boot) is
# devkit/bin/boot_image.sh; this script owns the env and the assertions. When the service
# gains a database, set BOOT_WITH_PG=1 and put the <name>-pg DSN in BOOT_ENV.
set -euo pipefail

IMAGE=${1:?usage: smoke_image.sh <image> <version>}
VERSION=${2:?usage: smoke_image.sh <image> <version>}
# Unique per run, so concurrent smokes and a developer's own containers never collide.
NAME="__NAME__-smoke-$$-$RANDOM"
BOOT="$(cd "$(dirname "$0")/../.." && pwd)/devkit/bin/boot_image.sh"
trap '"$BOOT" down "$NAME"' EXIT

# The production env. A NEW REQUIRED SETTING MUST BE ADDED HERE TOO, or every publish fails.
BOOT_ENV="PORT=8080"

BASE_LINE=$(
  BOOT_IMAGE="$IMAGE" BOOT_PORT=8080 BOOT_HEALTH_PATH=/health/ready BOOT_TIMEOUT=60 \
  BOOT_ENV="$BOOT_ENV" BOOT_EXPECT_VERSION="$VERSION" "$BOOT" up "$NAME"
)
BASE=${BASE_LINE#BASE=}
echo "smoke: $BASE/health/ready 2xx, version $VERSION"

# The image's own HEALTHCHECK command, run the way Docker runs it.
docker exec "$NAME-app" wget -q -O /dev/null http://127.0.0.1:8080/health/ready
echo "smoke: HEALTHCHECK command ok"
