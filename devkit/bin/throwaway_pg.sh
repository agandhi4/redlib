#!/usr/bin/env bash
# A throwaway Postgres container for test suites, smoke boots and e2e runs. Replaces the
# near-copies that lived in finplat (scripts/ci/test_pg.sh), orbit (Makefile test-db and
# e2e/run.sh) and locus (scripts/ci/smoke_image.sh).
#
# Usage: devkit/bin/throwaway_pg.sh up|down|url|name|port <name>
#   up    replace any leftover <name>, start it, wait until it accepts TCP connections, and
#         print exactly one stdout line: PG_PORT=<host port>. A <name> still RUNNING for another
#         checkout is refused (exit 1), never removed: see "Lanes" below.
#   url   print postgresql://<user>:<password>@127.0.0.1:<port>/<db> for a running <name>
#   down  remove <name>; a no-op when it is absent
#   name  print <name>-<lane>, this checkout's own container name for the base <name>; no docker
#   port  print this checkout's own host port for the base <name>: PORT_BASE + the CRC of
#         <name>-<lane> mod PORT_SPAN, 20000-29999; no docker. For a Makefile that builds its
#         URL from a port at parse time (finplat's TEST_DB_PORT); a recipe that reads the URL
#         back with `url` leaves PG_PORT empty instead, and Docker picks a free port.
#   Exit 0 ok, 1 runtime failure (docker failed, container died, not ready, not running, held by
#   another checkout), 2 usage.
#
# Lanes (2026-10-19): concurrent agent lanes each ran `make test-db` in their own worktree of
# one repo, every one with the Makefile's fixed name (finplat-test-pg). Each `up` removed the
# running container of the lane before it, and that lane's per-worker databases (<db>_gw0 ...)
# vanished mid-suite. The lane id is GATE_LANE_ID when set ([a-z0-9-], at most 32), else `w`
# plus the 8-hex CRC of the checkout's top-level path (`git rev-parse --show-toplevel`, else the
# working directory): stable for one worktree, distinct across worktrees. `up` labels the
# container with it (devkit.lane), and refuses a running same-named container labelled with
# another lane. A repo names its container with `name` and, when several lanes share one
# server (TEST_DATABASE_URL at a long-lived Postgres), puts the lane id into its per-worker
# database names too (README "Architecture", the throwaway_pg.sh row). A fixed host port is
# the same collision one layer down: two lanes' `up` on 55460 fail "port is already
# allocated", so a repo that fixes the port derives it with `port` (devkit-check warns on a
# literal name or port in the Makefile). The range sits below every OS's ephemeral ports
# (Linux 32768+, macOS 49152+) and clear of the fleet's fixed and per-PR ports (18000-19999,
# 55000+). Two lanes share a port with odds ~1/10000 per pair, and then `up` fails loudly.
#
# Env (all optional; `url` must see the same PG_USER/PG_PASSWORD/PG_DB as `up`):
#   PG_IMAGE=postgres:18  PG_USER=ci  PG_PASSWORD=ci  PG_DB=ci
#   PG_PORT            host port; empty lets Docker pick a free one (read back with `docker port`)
#   PG_NETWORK         also join this network, where the container answers as <name>:5432
#   PG_TMPFS=1         keep the data directory in RAM; 0 disables
#   PG_ARGS            server args after the image, word-split on purpose (-c autovacuum=off)
#   PG_READY_TIMEOUT=60  seconds to wait for readiness
#
# Why the flags are what they are:
# - The tmpfs mounts /var/lib/postgresql, the PARENT, never /var/lib/postgresql/data.
#   postgres:18 moved PGDATA to /var/lib/postgresql/18/docker and its declared VOLUME up to
#   the parent, so a tmpfs on the old path sits unused while docker creates an anonymous
#   volume that `run --rm` does not always reclaim (one orphan per run cost a gate box 18 GB).
#   On the parent the entrypoint creates PGDATA itself with the 0700 initdb wants; the old
#   path failed on orbit's CI runner, plausibly because a bare tmpfs is root-owned 1777.
#   RAM is also faster and guarantees an empty database. PG_TMPFS=0 falls back to the volume.
# - The container runs WITHOUT --rm so a database that dies mid-suite stays inspectable with
#   `docker logs` until `down`; `up` removes a same-named leftover first. Removal is always
#   `rm -fv`: -v reclaims the anonymous volume when tmpfs is off, -f makes a stale container
#   from a killed run harmless instead of a name clash.
# - Readiness is probed over TCP (-h 127.0.0.1) inside the container, never the unix socket:
#   the image's init phase runs a temporary server with listen_addresses='' and then restarts
#   it, so a socket probe can report ready on the server that is about to go away.
# - Ports bind to 127.0.0.1 only. A throwaway database with password "ci" must never be
#   reachable from the LAN.
# - Not `set -e`: the wait loop expects failing probes and handles every failure explicitly.
set -uo pipefail

usage() { echo "usage: $0 up|down|url|name|port <name>" >&2; exit 2; }
die() { echo "throwaway_pg: $*" >&2; exit 1; }

[ $# -eq 2 ] || usage
VERB=$1
NAME=$2
case "$VERB" in up|down|url|name|port) ;; *) usage ;; esac
# Docker's own name grammar; also keeps the name safe to splice into messages and URLs.
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "throwaway_pg: invalid container name '$NAME'" >&2; exit 2; }

# lane_id: header, "Lanes". Lowercase alphanumerics and `-` only: a valid docker name part, and
# a Postgres database name part (quoted, as the fleet's per-worker CREATE DATABASE already is).
lane_id() {
  if [ -n "${GATE_LANE_ID:-}" ]; then
    [[ "$GATE_LANE_ID" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] \
      || { echo "throwaway_pg: GATE_LANE_ID must be [a-z0-9-], at most 32, no leading or trailing '-' (got '$GATE_LANE_ID')" >&2; exit 2; }
    echo "$GATE_LANE_ID"
    return
  fi
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
  printf 'w%08x\n' "$(printf '%s' "$top" | cksum | cut -d' ' -f1)"
}
readonly PORT_BASE=20000 PORT_SPAN=10000
case "$VERB" in
  name|port)
    lane=$(lane_id) || exit 2
    if [ "$VERB" = name ]; then
      echo "$NAME-$lane"
    else
      echo $((PORT_BASE + $(printf '%s' "$NAME-$lane" | cksum | cut -d' ' -f1) % PORT_SPAN))
    fi
    exit 0 ;;
esac

PG_IMAGE=${PG_IMAGE:-postgres:18}
PG_USER=${PG_USER:-ci}
PG_PASSWORD=${PG_PASSWORD:-ci}
PG_DB=${PG_DB:-ci}
PG_PORT=${PG_PORT:-}
PG_NETWORK=${PG_NETWORK:-}
PG_TMPFS=${PG_TMPFS:-1}
PG_ARGS=${PG_ARGS:-}
PG_READY_TIMEOUT=${PG_READY_TIMEOUT:-60}

# Every docker call below is bounded; a hung daemon is one line and exit 1 (bin/_timeout_lib.sh).
# shellcheck source=bin/_timeout_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_timeout_lib.sh"
devkit_docker_guard throwaway_pg

remove() { docker rm -fv "$NAME" >/dev/null 2>&1 || true; }
is_running() { [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ]; }
# The lane a running <name> was started for, or nothing (absent, stopped, or unlabelled: a
# container from before the label, or a hand-run one, is this checkout's to replace as before).
running_lane() {
  local state
  state=$(docker inspect -f '{{.State.Running}} {{index .Config.Labels "devkit.lane"}}' "$NAME" 2>/dev/null) || return 0
  case "$state" in "true "?*) echo "${state#true }" ;; esac
}

# Host port published for 5432/tcp; empty when there is none. `docker port` may list an IPv4
# and an IPv6 binding; both carry the same port, so the first line is enough.
host_port() {
  local binding
  binding=$(docker port "$NAME" 5432/tcp 2>/dev/null | head -n 1)
  binding=${binding##*:}
  case "$binding" in ''|*[!0-9]*) return 1 ;; esac
  echo "$binding"
}

# Percent-encode a URL userinfo component byte by byte (bash 3.2 has no builtin for it).
url_encode() {
  local LC_ALL=C s=$1 out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [A-Za-z0-9._~-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  echo "$out"
}

dump_logs() {
  echo "throwaway_pg: last 40 log lines of $NAME:" >&2
  docker logs --tail 40 "$NAME" >&2 || echo "throwaway_pg: (no logs; container already removed)" >&2
}

up() {
  case "$PG_PORT" in *[!0-9]*) echo "throwaway_pg: PG_PORT must be a port number (got '$PG_PORT')" >&2; exit 2 ;; esac
  case "$PG_TMPFS" in 0|1) ;; *) echo "throwaway_pg: PG_TMPFS must be 0 or 1 (got '$PG_TMPFS')" >&2; exit 2 ;; esac
  case "$PG_READY_TIMEOUT" in ''|*[!0-9]*) echo "throwaway_pg: PG_READY_TIMEOUT must be whole seconds (got '$PG_READY_TIMEOUT')" >&2; exit 2 ;; esac

  # No --rm: a database that dies mid-suite must stay inspectable (`docker logs`) until `down`;
  # `up` removes a same-named leftover first, so nothing accumulates (Orbit backend/AGENTS.md).
  local lane
  lane=$(lane_id) || exit 2
  local args=(run -d --name "$NAME" --label "devkit.lane=$lane"
    -e "POSTGRES_USER=$PG_USER" -e "POSTGRES_PASSWORD=$PG_PASSWORD" -e "POSTGRES_DB=$PG_DB"
    -p "127.0.0.1:$PG_PORT:5432")
  [ "$PG_TMPFS" = 1 ] && args+=(--tmpfs /var/lib/postgresql:rw)
  [ -n "$PG_NETWORK" ] && args+=(--network "$PG_NETWORK")
  args+=("$PG_IMAGE")
  local server_args=()
  # shellcheck disable=SC2206  # PG_ARGS is a word list by contract (-c key=value pairs)
  [ -n "$PG_ARGS" ] && server_args=($PG_ARGS)

  local holder
  holder=$(running_lane)
  if [ -n "$holder" ] && [ "$holder" != "$lane" ]; then
    die "$NAME is running for another checkout (lane $holder; this is $lane): removing it would drop that lane's databases mid-suite; name yours with \`$0 name <base>\`"
  fi
  remove
  echo "throwaway_pg: starting $NAME ($PG_IMAGE, port ${PG_PORT:-auto}${PG_NETWORK:+, network $PG_NETWORK})" >&2
  docker "${args[@]}" ${server_args[@]+"${server_args[@]}"} >/dev/null || { remove; die "docker run failed for $NAME"; }

  local start=$SECONDS
  while :; do
    if ! is_running; then
      dump_logs
      remove
      die "$NAME exited before accepting connections"
    fi
    if docker exec "$NAME" pg_isready -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB" -q >/dev/null 2>&1; then
      break
    fi
    if [ $((SECONDS - start)) -ge "$PG_READY_TIMEOUT" ]; then
      dump_logs
      remove
      die "$NAME not ready after ${PG_READY_TIMEOUT}s"
    fi
    sleep 1
  done

  local port
  port=$(host_port) || { remove; die "$NAME publishes no host port for 5432/tcp"; }
  echo "throwaway_pg: $NAME ready on 127.0.0.1:$port after $((SECONDS - start))s" >&2
  echo "PG_PORT=$port"
}

url() {
  is_running || die "$NAME is not running"
  local port
  port=$(host_port) || die "$NAME publishes no host port for 5432/tcp"
  echo "postgresql://$(url_encode "$PG_USER"):$(url_encode "$PG_PASSWORD")@127.0.0.1:$port/$(url_encode "$PG_DB")"
}

case "$VERB" in
  up) up ;;
  url) url ;;
  down) remove ;;
esac
