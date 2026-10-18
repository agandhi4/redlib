#!/usr/bin/env bash
# One docker call from a Makefile recipe, behind the daemon probe and per-call bound that
# throwaway_pg.sh and boot_image.sh use (bin/_timeout_lib.sh). A recipe cannot source that lib
# itself: make runs recipes under /bin/sh (dash on a Linux gate box), and the lib is bash.
# devkit-check warns on a recipe line that runs docker directly (makefile_raw_docker).
#
#   devkit/bin/docker_bounded.sh <docker args...>
#     e.g. DOCKER_CALL_TIMEOUT=900 devkit/bin/docker_bounded.sh build -t "$(CI_IMAGE)" .
#
# DOCKER_CALL_TIMEOUT (180 s) bounds the call, so a cold `docker build` sets more;
# DOCKER_PROBE_TIMEOUT (15 s) bounds the probe. Exit: docker's code, 124 when the bound stopped
# it (one line says so), 1 for a hung or unreachable daemon, 2 a bad call.
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: docker_bounded.sh <docker args...>" >&2; exit 2; }
# shellcheck source=bin/_timeout_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_timeout_lib.sh"
devkit_docker_guard docker_bounded.sh
rc=0
docker "$@" || rc=$?
[ "$rc" != 124 ] \
  || echo "docker_bounded.sh: docker $1 did not finish within ${DOCKER_CALL_TIMEOUT:-180}s (DOCKER_CALL_TIMEOUT); stopped" >&2
exit "$rc"
