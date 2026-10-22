# shellcheck shell=bash
# Bounded commands, and a guard for a hung Docker daemon. Sourced; defines functions and runs
# nothing. Used by: throwaway_pg.sh and boot_image.sh (devkit_docker_guard), local_gate.sh
# (devkit_with_timeout around the plan's gate_cleanup).
#
# Why (2026-10-17): the OrbStack daemon wedged and every `docker rm -fv`, `docker ps` and
# `docker inspect` hung for 12+ minutes. Inside a job only the 15-minute silence watchdog
# caught it; in gate_cleanup (the EXIT trap) nothing did, so two gates held both machine-wide
# slots while every other lane queued behind them. macOS has no `timeout(1)`, hence the shell
# version.
#
#   devkit_with_timeout <secs> <cmd...>   run cmd (a function too, in a subshell); TERM it and
#                                         its direct children after <secs>. Returns cmd's exit
#                                         code, or 124 (GNU timeout's) when it was stopped.
#   devkit_docker_guard <who>             from here on every `docker` call in the sourcing script
#                                         is bounded by DOCKER_CALL_TIMEOUT (default 180 s: a
#                                         first `docker run` may pull an image), and the daemon
#                                         must answer `docker version` within
#                                         DOCKER_PROBE_TIMEOUT (default 15 s), else exit 1 with
#                                         one line naming the hang. Bad values are exit 2. It
#                                         holds the machine awake for the caller's lifetime, and
#                                         on macOS a probe that times out gets one user-activity
#                                         wake and one re-probe (bin/_awake_lib.sh).

# shellcheck source=bin/_awake_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_awake_lib.sh"

# Safe under `set -e` (docker_bounded.sh): every status this reads is captured with `||`, so
# a failed command, or the killed watcher's 137, never aborts the caller mid-cleanup.
# Whether the bound fired is a file the watcher writes before it signals, not its exit code:
# once its TERM lands the command can exit (a script whose `sleep` child was killed exits 0)
# and the stand-down below KILLs the watcher before its `exit 124`, which read as success
# under load (throwaway_pg's hung-daemon case, devkit #215's gate, 2026-10-22). With no file
# (no mktemp, a full disk) the bound still stops the command but cannot say so: never 124.
devkit_with_timeout() {
  local secs=$1 pid watcher rc=0 fired
  shift
  fired=$(mktemp "${TMPDIR:-/tmp}/devkit_timeout.XXXXXX" 2>/dev/null) || fired=/dev/null
  "$@" &
  pid=$!
  ( sleep "$secs"; echo fired >"$fired"; pkill -TERM -P "$pid"; kill -TERM "$pid" ) </dev/null >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null || rc=$?  # 2>: the shell's own "Terminated" notice, not cmd's stderr
  # Stand the watcher down with signals it cannot defer or trap: bash 3.2 lost a TERM sent to
  # a trapping subshell about one time in 40, which then slept its full term and fired on a
  # command that had finished. STOP freezes it before its sleep can end, KILL its sleep, then it.
  kill -STOP "$watcher" 2>/dev/null || :
  pkill -KILL -P "$watcher" 2>/dev/null || :
  kill -KILL "$watcher" 2>/dev/null || :
  wait "$watcher" 2>/dev/null || :
  [ ! -s "$fired" ] || rc=124
  [ "$fired" = /dev/null ] || rm -f "$fired"
  return "$rc"
}

devkit_docker_guard() {
  local who=$1 rc=0
  [[ "${DOCKER_CALL_TIMEOUT:-180}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$who: DOCKER_CALL_TIMEOUT must be a whole number of seconds >= 1 (got '$DOCKER_CALL_TIMEOUT')" >&2; exit 2; }
  [[ "${DOCKER_PROBE_TIMEOUT:-15}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$who: DOCKER_PROBE_TIMEOUT must be a whole number of seconds >= 1 (got '$DOCKER_PROBE_TIMEOUT')" >&2; exit 2; }
  command -v docker >/dev/null || { echo "$who: docker not found on PATH" >&2; exit 1; }
  # devkit_with_timeout stops the command's children and its own sleep with pkill. Without it
  # both survive silently: a watcher slept out its full bound (180 s) holding the caller's file
  # descriptors, which kept a bats file waiting past its last test (2026-10-18).
  command -v pkill >/dev/null || { echo "$who: pkill not found on PATH (procps: apt install procps)" >&2; exit 1; }
  # Held before the probe: lanes idle between Docker calls, and a Mac asleep then is how the
  # OrbStack VM stays asleep through DarkWake (2026-10-22).
  devkit_stay_awake
  _devkit_docker_probe || rc=$?
  if [ "$rc" = 124 ] && devkit_wake_user; then
    echo "$who: the docker daemon did not answer within ${DOCKER_PROBE_TIMEOUT:-15}s; woke the Mac (caffeinate -u -t 2), probing once more" >&2
    rc=0
    _devkit_docker_probe || rc=$?
    [ "$rc" != 124 ] || { echo "$who: $(_devkit_orbstack_asleep_hint)" >&2; exit 1; }
  fi
  if [ "$rc" = 124 ]; then
    echo "$who: the docker daemon did not answer within ${DOCKER_PROBE_TIMEOUT:-15}s (hung; restart Docker, then rerun)" >&2
    exit 1
  elif [ "$rc" != 0 ]; then
    echo "$who: the docker daemon is not reachable (docker version exit $rc; is Docker running?)" >&2
    exit 1
  fi
  # shellcheck disable=SC2329  # shadows the CLI for every later call in the sourcing script
  docker() { devkit_with_timeout "${DOCKER_CALL_TIMEOUT:-180}" command docker "$@"; }
}

_devkit_docker_probe() {
  devkit_with_timeout "${DOCKER_PROBE_TIMEOUT:-15}" command docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# The macOS failure after a wake. Never restarts OrbStack itself: `orbctl stop` kills every
# lane's containers, so it is named only as the last resort, after another wake.
_devkit_orbstack_asleep_hint() {
  local log=${HOME:-}/.orbstack/log/vmgr.log last=""
  [ -r "$log" ] && last=$(tail -n 5000 "$log" | sed -nE 's/.*time="([^"]+)".*msg=(sleep|wake)$/\2 at \1/p' | tail -n 1)
  printf '%s' "the docker daemon still did not answer after a wake; likely the OrbStack VM asleep after system sleep"
  [ -z "$last" ] || printf ' (last vmgr event: %s)' "$last"
  printf '%s\n' ". Remedy in order: \`caffeinate -u -t 2\` and rerun; only as a last resort \`orbctl stop && orbctl start\`, which kills every container"
}
