#!/usr/bin/env bash
# Run a built redlib image's binary offline and prove it reports the version it was built with.
# Usage: scripts/ci/smoke_image.sh <image> <version>
#        (or: make ci-smoke CI_IMAGE=<image> CI_BUILD_VERSION=<version>)
#
# Not devkit's boot_image.sh: the listener opens only after OAuth bootstrap against live Reddit
# (AGENTS.md "Startup order"), so no health path answers offline. Instead the image's own binary
# runs with no network and prints `redlib --version` (instance_info::app_version, which reads the
# APP_VERSION ENV the footer and /info read). That proves the binary executes on this platform
# (an arm64 image on the amd64 NAS was `exec format error`, instalite-relay 2026-10-18) and the
# build arg reached the app. The OCI label is what devkit/bin/publish.sh later reads back from
# `latest` as the deployed commit. publish.sh runs this before pushing; the gate's smoke job on
# every image-affecting PR.
set -euo pipefail

IMAGE=${1:?usage: smoke_image.sh <image> <version>}
VERSION=${2:?usage: smoke_image.sh <image> <version>}
DOCKER="$(cd "$(dirname "$0")/../.." && pwd)/devkit/bin/docker_bounded.sh"

reported=$(DOCKER_CALL_TIMEOUT=60 "$DOCKER" run --rm --network none "$IMAGE" redlib --version)
label=$("$DOCKER" image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")
if [ "$reported" = "Redlib $VERSION" ] && [ "$label" = "$VERSION" ]; then
  echo "smoke: redlib --version and the image.version label are $VERSION"
else
  echo "smoke: expected $VERSION, the binary reports '$reported' and the label is '$label'" >&2
  exit 1
fi
