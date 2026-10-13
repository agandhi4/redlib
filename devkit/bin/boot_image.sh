#!/usr/bin/env bash
# Boot a built app image (optionally against a throwaway Postgres) and wait until it answers
# its health endpoint. The shared boot half of locus scripts/ci/smoke_image.sh, finplat
# scripts/ci/browser_smoke.sh, orbit e2e/run.sh and closet scripts/smoke-image.sh. What each
# repo asserts once the app is up (SPA HTML, healthcheck.py, seed + Playwright, migration log,
# SIGTERM exit code) stays in that repo; it calls `down` from its own EXIT trap. The shared
# observability-contract assertions (health shape, request ids, JSON logs, /metrics) are
# contract_probe.sh, run on the BASE this prints.
#
# Usage: devkit/bin/boot_image.sh up|down <name>
#   up    replace any leftovers, create network <name>-net, boot Postgres <name>-pg on it when
#         BOOT_WITH_PG=1, run <name>-app, wait for health, print exactly one stdout line:
#         BASE=http://127.0.0.1:<host port>. On failure: logs to stderr, everything removed.
#   down  remove <name>-app, <name>-pg and <name>-net; quiet, idempotent, always exit 0
#   Exit 0 ok, 1 runtime failure (docker failed, app died, health timeout), 2 usage/bad env.
#
# Env for `up`:
#   BOOT_IMAGE          required; the image to boot
#   BOOT_PORT           required; the port the app listens on inside the container
#   BOOT_HEALTH_PATH    required; e.g. /health/ready
#   BOOT_HOST_PORT      loopback host port; empty lets Docker pick a free one
#   BOOT_HEALTH_STATUS  exact HTTP code to accept (e.g. 204); empty accepts any 2xx
#   BOOT_TIMEOUT=120    seconds to wait for health
#   BOOT_ENV_FILE       passed as --env-file
#   BOOT_ENV            newline-separated KEY=VALUE lines, each passed as -e
#   BOOT_WITH_PG=0      1 boots <name>-pg via throwaway_pg.sh first; PG_* env passes through
#                       (PG_NETWORK is forced to <name>-net). Nothing is exported: the caller's
#                       env puts host <name>-pg, port 5432 in its DSN.
#   BOOT_LOG_TAIL=80    log lines dumped per container on failure
#   BOOT_RUN_ARGS       extra `docker run` args before the image, word-split on purpose
#   BOOT_EXPECT_VERSION when set, after health passes, BOOT_HEALTH_PATH must return JSON whose
#                       `version` equals it (the image's APP_VERSION); a mismatch fails the boot
#
# Why it is shaped this way (lessons from the four originals):
# - A private network per <name>, with the database reached by container name: a
#   host-published Postgres port is NOT reachable from the default bridge on a box whose
#   firewall drops bridge-to-host traffic (linux-box, finplat), and host networking would pin
#   the app to whatever port its entrypoint hard-codes. Unique names also keep concurrent runs
#   and a developer's own containers from colliding.
# - `up` runs `down` first: a container left by an interrupted run would hold the port, and
#   the suite would test yesterday's build (orbit).
# - The app runs WITHOUT --rm so its log survives a crash; `down` removes it with `rm -fv`.
# - The health poll exits early when the container stops running. Most boot failures (a
#   migration that fails from zero, a settings validator rejecting the env, an import only a
#   dev dependency satisfied) kill the container in seconds; waiting out the deadline hides
#   that behind a timeout message.
# - Status via `curl -w %{http_code}`, not `curl -f`: an exact code can be required (closet
#   answers /healthz with 204) and the last code seen goes into the failure message.
# - Default log tail is 80 (locus); the originals used 40-200. A migration traceback needs
#   ~50 lines; raise BOOT_LOG_TAIL for chattier apps.
# - The env lives in the caller's BOOT_ENV_FILE / BOOT_ENV, and should mirror production's
#   posture (production settings validator on). A NEW REQUIRED SETTING MUST BE ADDED THERE
#   TOO, or every smoke boot (and so every publish gated on it) fails (locus).
# - Ports bind to 127.0.0.1 only: a smoke app with a throwaway secret is never LAN-reachable.
# - BOOT_EXPECT_VERSION proves the build arg reached the running app (ARG -> ENV -> health
#   `version`), the release-identity contract that release_check.sh checks statically. It is
#   read with jq, else python3, else sed: the gate box, Actions and slim images differ in tools.
# - Not `set -e`: the poll loop expects failing probes and handles every failure explicitly.
set -uo pipefail

usage() { echo "usage: $0 up|down <name>" >&2; exit 2; }
bad_env() { echo "boot_image: $*" >&2; exit 2; }

[ $# -eq 2 ] || usage
VERB=$1
NAME=$2
case "$VERB" in up|down) ;; *) usage ;; esac
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || bad_env "invalid name '$NAME'"

NET="$NAME-net"
APP="$NAME-app"
PG="$NAME-pg"
THROWAWAY_PG="$(dirname "$0")/throwaway_pg.sh"

command -v docker >/dev/null || { echo "boot_image: docker not found on PATH" >&2; exit 1; }

# Order matters: the network cannot be removed while a container is still attached.
teardown() {
  docker rm -fv "$APP" >/dev/null 2>&1 || true
  "$THROWAWAY_PG" down "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}

dump_logs() {
  echo "--- $APP logs (last $BOOT_LOG_TAIL lines) ---" >&2
  docker logs --tail "$BOOT_LOG_TAIL" "$APP" >&2 2>&1 || echo "boot_image: (no logs for $APP)" >&2
  if [ "$BOOT_WITH_PG" = 1 ]; then
    echo "--- $PG logs (last $BOOT_LOG_TAIL lines) ---" >&2
    docker logs --tail "$BOOT_LOG_TAIL" "$PG" >&2 2>&1 || echo "boot_image: (no logs for $PG)" >&2
  fi
}

abort() {
  echo "boot_image: $*" >&2
  dump_logs
  teardown
  exit 1
}

# stdin: a JSON body; prints its top-level string `version`, or nothing.
json_version() {
  if command -v jq >/dev/null; then
    jq -r 'if type == "object" and (.version | type) == "string" then .version else empty end' 2>/dev/null
  elif command -v python3 >/dev/null; then
    python3 -c 'import json, sys
try:
    v = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
if isinstance(v, dict) and isinstance(v.get("version"), str):
    print(v["version"])' 2>/dev/null
  else
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
  fi
}

is_running() { [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" = true ]; }

health_ok() {
  if [ -n "$BOOT_HEALTH_STATUS" ]; then
    [ "$1" = "$BOOT_HEALTH_STATUS" ]
  else
    case "$1" in 2[0-9][0-9]) return 0 ;; *) return 1 ;; esac
  fi
}

up() {
  [ -n "${BOOT_IMAGE:-}" ] || bad_env "BOOT_IMAGE is required"
  [ -n "${BOOT_PORT:-}" ] || bad_env "BOOT_PORT is required"
  [ -n "${BOOT_HEALTH_PATH:-}" ] || bad_env "BOOT_HEALTH_PATH is required"
  BOOT_HOST_PORT=${BOOT_HOST_PORT:-}
  BOOT_HEALTH_STATUS=${BOOT_HEALTH_STATUS:-}
  BOOT_TIMEOUT=${BOOT_TIMEOUT:-120}
  BOOT_ENV_FILE=${BOOT_ENV_FILE:-}
  BOOT_ENV=${BOOT_ENV:-}
  BOOT_WITH_PG=${BOOT_WITH_PG:-0}
  BOOT_LOG_TAIL=${BOOT_LOG_TAIL:-80}
  BOOT_RUN_ARGS=${BOOT_RUN_ARGS:-}
  BOOT_EXPECT_VERSION=${BOOT_EXPECT_VERSION:-}

  case "$BOOT_PORT" in *[!0-9]*) bad_env "BOOT_PORT must be a port number (got '$BOOT_PORT')" ;; esac
  case "$BOOT_HOST_PORT" in *[!0-9]*) bad_env "BOOT_HOST_PORT must be a port number (got '$BOOT_HOST_PORT')" ;; esac
  case "$BOOT_HEALTH_PATH" in /*) ;; *) bad_env "BOOT_HEALTH_PATH must start with / (got '$BOOT_HEALTH_PATH')" ;; esac
  case "$BOOT_HEALTH_STATUS" in ''|[1-5][0-9][0-9]) ;; *) bad_env "BOOT_HEALTH_STATUS must be an HTTP code (got '$BOOT_HEALTH_STATUS')" ;; esac
  case "$BOOT_TIMEOUT" in ''|*[!0-9]*) bad_env "BOOT_TIMEOUT must be whole seconds (got '$BOOT_TIMEOUT')" ;; esac
  case "$BOOT_LOG_TAIL" in ''|*[!0-9]*) bad_env "BOOT_LOG_TAIL must be a line count (got '$BOOT_LOG_TAIL')" ;; esac
  case "$BOOT_WITH_PG" in 0|1) ;; *) bad_env "BOOT_WITH_PG must be 0 or 1 (got '$BOOT_WITH_PG')" ;; esac
  [ -z "$BOOT_ENV_FILE" ] || [ -r "$BOOT_ENV_FILE" ] || bad_env "BOOT_ENV_FILE '$BOOT_ENV_FILE' is not a readable file"
  command -v curl >/dev/null || { echo "boot_image: curl not found on PATH" >&2; exit 1; }

  local args=(run -d --name "$APP" --network "$NET" -p "127.0.0.1:$BOOT_HOST_PORT:$BOOT_PORT")
  [ -n "$BOOT_ENV_FILE" ] && args+=(--env-file "$BOOT_ENV_FILE")
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(-e "$line")
  done <<< "$BOOT_ENV"
  local extra=()
  # shellcheck disable=SC2206  # BOOT_RUN_ARGS is a word list by contract
  [ -n "$BOOT_RUN_ARGS" ] && extra=($BOOT_RUN_ARGS)

  teardown
  # An interrupted `up` must not leave containers behind for the caller to find.
  trap 'echo "boot_image: interrupted" >&2; teardown; exit 1' INT TERM

  docker network create "$NET" >/dev/null || { teardown; echo "boot_image: docker network create $NET failed" >&2; exit 1; }

  if [ "$BOOT_WITH_PG" = 1 ]; then
    # throwaway_pg's PG_PORT line goes to stderr: BASE must stay the only stdout line.
    PG_NETWORK="$NET" "$THROWAWAY_PG" up "$PG" >&2 || { teardown; echo "boot_image: Postgres $PG did not come up" >&2; exit 1; }
  fi

  echo "boot_image: starting $APP ($BOOT_IMAGE, port $BOOT_PORT on 127.0.0.1:${BOOT_HOST_PORT:-auto})" >&2
  docker "${args[@]}" ${extra[@]+"${extra[@]}"} "$BOOT_IMAGE" >/dev/null || abort "docker run failed for $APP"

  local host_port=$BOOT_HOST_PORT
  if [ -z "$host_port" ]; then
    # `docker port` may list IPv4 and IPv6 bindings; both carry the same port.
    host_port=$(docker port "$APP" "$BOOT_PORT/tcp" 2>/dev/null | head -n 1)
    host_port=${host_port##*:}
    case "$host_port" in ''|*[!0-9]*) abort "$APP publishes no host port for $BOOT_PORT/tcp" ;; esac
  fi
  local base="http://127.0.0.1:$host_port"

  local start=$SECONDS code
  while :; do
    # curl prints 000 (and exits non-zero) while nothing listens; only the printed code matters.
    code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "$base$BOOT_HEALTH_PATH" 2>/dev/null)
    health_ok "$code" && break
    is_running || abort "$APP exited before $BOOT_HEALTH_PATH answered ${BOOT_HEALTH_STATUS:-2xx} (last: $code)"
    [ $((SECONDS - start)) -lt "$BOOT_TIMEOUT" ] \
      || abort "$BOOT_HEALTH_PATH did not answer ${BOOT_HEALTH_STATUS:-2xx} within ${BOOT_TIMEOUT}s (last: $code)"
    sleep 1
  done

  if [ -n "$BOOT_EXPECT_VERSION" ]; then
    local body version
    body=$(curl -s --max-time 5 "$base$BOOT_HEALTH_PATH" 2>/dev/null)
    version=$(printf '%s' "$body" | json_version)
    [ "$version" = "$BOOT_EXPECT_VERSION" ] \
      || abort "$BOOT_HEALTH_PATH reports version '${version:-<none>}', expected '$BOOT_EXPECT_VERSION' (body: ${body:0:200})"
    echo "boot_image: $APP reports version $version" >&2
  fi

  trap - INT TERM
  echo "boot_image: $APP healthy ($BOOT_HEALTH_PATH $code) after $((SECONDS - start))s" >&2
  echo "BASE=$base"
}

case "$VERB" in
  up) up ;;
  down) teardown ;;
esac
