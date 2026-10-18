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
#                                         one line naming the hang. Bad values are exit 2.

# Safe under `set -e` (docker_bounded.sh): every status this reads is captured with `||`, so
# a failed command, or the killed watcher's 137, never aborts the caller mid-cleanup.
devkit_with_timeout() {
  local secs=$1 pid watcher rc=0 watcher_rc=0
  shift
  "$@" &
  pid=$!
  ( sleep "$secs"; pkill -TERM -P "$pid"; kill -TERM "$pid"; exit 124 ) </dev/null >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" 2>/dev/null || rc=$?  # 2>: the shell's own "Terminated" notice, not cmd's stderr
  # Stand the watcher down with signals it cannot defer or trap: bash 3.2 lost a TERM sent to
  # a trapping subshell about one time in 40, which then slept its full term and fired on a
  # command that had finished. STOP freezes it before its sleep can end, KILL its sleep, then it.
  kill -STOP "$watcher" 2>/dev/null || :
  pkill -KILL -P "$watcher" 2>/dev/null || :
  kill -KILL "$watcher" 2>/dev/null || :
  wait "$watcher" 2>/dev/null || watcher_rc=$?
  [ "$watcher_rc" -ne 124 ] || rc=124
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
  devkit_with_timeout "${DOCKER_PROBE_TIMEOUT:-15}" command docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || rc=$?
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
