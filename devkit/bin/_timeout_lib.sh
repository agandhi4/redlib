# shellcheck shell=bash
# Bounded commands, and guards for a hung Docker daemon and a hung git remote. Sourced; defines
# functions and runs nothing. Used by: throwaway_pg.sh, boot_image.sh, docker_bounded.sh and
# publish.sh (devkit_docker_guard), check_tree.sh (devkit_docker_ensure in its require_docker,
# devkit_with_timeout around each job and the plan's gate_cleanup), and the jobs that fetch every
# checkout, dependency_merge.sh and main_check.sh (devkit_git_guard).
#
# Why (2026-10-17): the OrbStack daemon wedged and every `docker rm -fv`, `docker ps` and
# `docker inspect` hung for 12+ minutes. Inside a job only the 15-minute silence watchdog
# caught it; in gate_cleanup (the EXIT trap) nothing did, so two gates held both machine-wide
# slots while every other lane queued behind them. macOS has no `timeout(1)`, hence the shell
# version.
#
#   devkit_with_timeout <secs> <cmd...>   run cmd (a function too, in a subshell); after <secs>
#                                         stop it and everything it started (_devkit_stop_tree:
#                                         TERM, then KILL DEVKIT_TIMEOUT_GRACE s later, default
#                                         10). Returns cmd's exit code, or 124 (GNU timeout's)
#                                         when it was stopped. While it runs,
#                                         DEVKIT_TIMEOUT_PID names cmd for devkit_timeout_stop.
#   devkit_timeout_stop                   from the caller's EXIT trap: stop the running cmd's
#                                         tree the same way; nothing when none runs.
#   devkit_docker_guard <who>             from here on every `docker` call in the sourcing script
#                                         is bounded by DOCKER_CALL_TIMEOUT (default 180 s: a
#                                         first `docker run` may pull an image), and the daemon
#                                         must answer `docker version` within
#                                         DOCKER_PROBE_TIMEOUT (default 15 s), else exit 1 with
#                                         one line naming the hang. Bad values are exit 2. It
#                                         holds the machine awake for the caller's lifetime, and
#                                         on macOS a probe that times out gets one user-activity
#                                         wake and one re-probe (bin/_awake_lib.sh).
#   devkit_git_guard <who>                from here on every network `git` call (fetch, push, pull,
#                                         ls-remote, clone) in the sourcing script is bounded by
#                                         DEVKIT_GIT_TIMEOUT (default 120 s:
#                                         an incremental fetch or a push), one stderr line
#                                         naming a stop; and git is non-interactive:
#                                         GIT_TERMINAL_PROMPT=0 (exported to children too), and
#                                         unless GIT_SSH_COMMAND or GIT_SSH is set, the repo's
#                                         ssh command in BatchMode with a ConnectTimeout. Bad
#                                         values are exit 2.
#   devkit_docker_check <who>             the same checks and probe without the exit: 0 when the
#                                         daemon answers, else 1 with DEVKIT_DOCKER_ERROR (one
#                                         line, no <who> prefix). Bad values are still exit 2.
#   devkit_docker_ensure <who>            devkit_docker_check, and on macOS with OrbStack
#                                         `Stopped` (orbctl status) one `orbctl start`, then the
#                                         probe again, 1 s apart, up to
#                                         DEVKIT_ORBSTACK_START_PROBES times (default 60); sets
#                                         DEVKIT_DOCKER_NOTE ("" or what it started). Never
#                                         `orbctl stop` or restart: that kills every container.

# shellcheck source=bin/_awake_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_awake_lib.sh"

# Safe under `set -e` (docker_bounded.sh): every status this reads is captured with `||`, so
# a failed command, or the killed watcher's 137, never aborts the caller mid-cleanup.
# Whether the bound fired is a file the watcher writes before it signals, not its exit code:
# once its TERM lands the command can exit (a script whose `sleep` child was killed exits 0)
# and the stand-down below KILLs the watcher before its `exit 124`, which read as success
# under load (throwaway_pg's hung-daemon case, devkit #215's gate, 2026-10-22). With no file
# (no mktemp, a full disk) the bound still TERMs the tree but cannot say so: never 124, and the
# stand-down may cut its KILL short.
# Why the whole tree (devkit #311, Codex on #301): TERM to cmd and its direct children reached
# make alone, which passes it to its recipes' shells only, so a timed-out job's test runner, or a
# recipe that traps TERM, ran on into the next job and under the worktree being removed. The
# tree stays in the caller's process group, so a supervisor's group or cgroup kill still takes
# it all, and the watcher, a process of its own, still stops it if the caller is SIGKILLed.
devkit_with_timeout() {
  local secs=$1 grace=${DEVKIT_TIMEOUT_GRACE:-10} pid watcher rc=0 fired
  shift
  [[ "$grace" =~ ^[0-9]+$ ]] || { echo "devkit_with_timeout: DEVKIT_TIMEOUT_GRACE must be a whole number of seconds (got '$grace')" >&2; exit 2; }
  fired=$(mktemp "${TMPDIR:-/tmp}/devkit_timeout.XXXXXX" 2>/dev/null) || fired=/dev/null
  "$@" &
  pid=$!
  ( sleep "$secs"; echo fired >"$fired"; _devkit_stop_tree "$pid" "$grace" ) </dev/null >/dev/null 2>&1 &
  watcher=$!
  DEVKIT_TIMEOUT_PID=$pid DEVKIT_TIMEOUT_WATCHER=$watcher DEVKIT_TIMEOUT_GRACE_SECS=$grace
  wait "$pid" 2>/dev/null || rc=$?  # 2>: the shell's own "Terminated" notice, not cmd's stderr
  DEVKIT_TIMEOUT_PID=''  # reaped: its pid may be reused, so devkit_timeout_stop leaves it be
  # Fired: the watcher owns the stop until its KILL, so it is waited for (at most the grace),
  # never stood down mid-stop, by this or by devkit_timeout_stop.
  if [ -s "$fired" ]; then wait "$watcher" 2>/dev/null || :; else _devkit_watcher_down "$watcher"; fi
  DEVKIT_TIMEOUT_WATCHER=''
  [ ! -s "$fired" ] || rc=124
  [ "$fired" = /dev/null ] || rm -f "$fired"
  return "$rc"
}

# Stand a watcher down with signals it cannot defer or trap: bash 3.2 lost a TERM sent to a
# trapping subshell about one time in 40, which then slept its full term and fired on a command
# that had finished. STOP freezes it before its sleep can end, KILL its sleep, then it.
_devkit_watcher_down() {
  kill -STOP "$1" 2>/dev/null || :
  pkill -KILL -P "$1" 2>/dev/null || :
  kill -KILL "$1" 2>/dev/null || :
  wait "$1" 2>/dev/null || :
}

# A TERM or Ctrl-C to the caller alone (a hand-run check_tree) leaves cmd running; the watcher
# goes first, so it never signals the tree's pids after they are reused.
devkit_timeout_stop() {
  local pid=${DEVKIT_TIMEOUT_PID:-}
  [ -n "$pid" ] || return 0
  [ -z "${DEVKIT_TIMEOUT_WATCHER:-}" ] || _devkit_watcher_down "$DEVKIT_TIMEOUT_WATCHER"
  DEVKIT_TIMEOUT_PID='' DEVKIT_TIMEOUT_WATCHER=''
  _devkit_stop_tree "$pid" "$DEVKIT_TIMEOUT_GRACE_SECS"
  wait "$pid" 2>/dev/null || :
}

# _devkit_stop_tree <pid> <grace>: STOP <pid> and every descendant, walking again until a walk
# finds none new (a stopped process cannot fork, and none exits mid-walk to orphan its children
# out of reach), then TERM and CONT them all, and KILL whichever is still the same process after
# <grace> s: each is kept as `<pid> <start time>`, so a pid that exited and was reused meanwhile
# is never signalled (#375).
_devkit_stop_tree() {
  local root=$1 all='' pids found p start deadline=$((SECONDS + $2)) _
  for _ in 1 2 3 4 5 6 7 8; do
    pids=$(cut -d ' ' -f 1 <<<"$all")
    found=$(_devkit_tree "$root" | grep -vxF -e "${pids:-x}" -e x) || :
    [ -n "$found" ] || break
    for p in $found; do
      kill -STOP "$p" 2>/dev/null || continue
      all=$(printf '%s\n%s %s' "$all" "$p" "$(_devkit_start "$p")" | grep .)
    done
  done
  [ -n "$all" ] || return 0
  pids=$(cut -d ' ' -f 1 <<<"$all")
  for p in $pids; do kill -TERM "$p" 2>/dev/null || :; done
  for p in $pids; do kill -CONT "$p" 2>/dev/null || :; done
  while [ "$SECONDS" -lt "$deadline" ] && _devkit_any_alive "$pids"; do sleep 0.2; done
  while read -r p start; do
    [ "$(_devkit_start "$p")" != "$start" ] || kill -KILL "$p" 2>/dev/null || :
  done <<<"$all"
}

# _devkit_start <pid>: its start time, which a reused pid does not share (_slot_lib.sh's way).
_devkit_start() { TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

# _devkit_tree <pid>: <pid> and its descendants, one per line, from one ps snapshot.
_devkit_tree() {
  ps -A -o pid= -o ppid= | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END { q = root; while (q != "") { n = split(q, a, " "); q = ""; for (i = 1; i <= n; i++) { print a[i]; q = q kids[a[i]] } } }'
}

# A zombie is gone: from an EXIT trap the root is the caller's own unreaped child, and `kill -0`
# on it held every stop for the full grace.
_devkit_any_alive() {
  local p
  for p in $1; do
    case "$(ps -o stat= -p "$p" 2>/dev/null | tr -d ' ')" in '' | Z*) ;; *) return 0 ;; esac
  done
  return 1
}

devkit_docker_guard() {
  local who=$1
  [[ "${DOCKER_CALL_TIMEOUT:-180}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$who: DOCKER_CALL_TIMEOUT must be a whole number of seconds >= 1 (got '$DOCKER_CALL_TIMEOUT')" >&2; exit 2; }
  devkit_docker_check "$who" || { echo "$who: $DEVKIT_DOCKER_ERROR" >&2; exit 1; }
  # shellcheck disable=SC2329  # shadows the CLI for every later call in the sourcing script
  docker() { devkit_with_timeout "${DOCKER_CALL_TIMEOUT:-180}" command docker "$@"; }
}

# shellcheck disable=SC2034  # DEVKIT_DOCKER_ERROR is this function's output, read by its callers
devkit_docker_check() {
  local who=$1 rc=0
  DEVKIT_DOCKER_ERROR=""
  [[ "${DOCKER_PROBE_TIMEOUT:-15}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$who: DOCKER_PROBE_TIMEOUT must be a whole number of seconds >= 1 (got '$DOCKER_PROBE_TIMEOUT')" >&2; exit 2; }
  command -v docker >/dev/null || { DEVKIT_DOCKER_ERROR="docker not found on PATH"; return 1; }
  # devkit_with_timeout stops the command's children and its own sleep with pkill. Without it
  # both survive silently: a watcher slept out its full bound (180 s) holding the caller's file
  # descriptors, which kept a bats file waiting past its last test (2026-10-18).
  command -v pkill >/dev/null || { DEVKIT_DOCKER_ERROR="pkill not found on PATH (procps: apt install procps)"; return 1; }
  # Held before the probe: lanes idle between Docker calls, and a Mac asleep then is how the
  # OrbStack VM stays asleep through DarkWake (2026-10-22).
  devkit_stay_awake
  _devkit_docker_probe || rc=$?
  if [ "$rc" = 124 ] && devkit_wake_user; then
    echo "$who: the docker daemon did not answer within ${DOCKER_PROBE_TIMEOUT:-15}s; woke the Mac (caffeinate -u -t 2), probing once more" >&2
    rc=0
    _devkit_docker_probe || rc=$?
    [ "$rc" != 124 ] || { DEVKIT_DOCKER_ERROR=$(_devkit_orbstack_asleep_hint); return 1; }
  fi
  if [ "$rc" = 124 ]; then
    DEVKIT_DOCKER_ERROR="the docker daemon did not answer within ${DOCKER_PROBE_TIMEOUT:-15}s (hung; restart Docker, then rerun)"
    return 1
  elif [ "$rc" != 0 ]; then
    DEVKIT_DOCKER_ERROR="the docker daemon is not reachable (docker version exit $rc; is Docker running?)"
    return 1
  fi
}

# Why (redlib #67, 2026-11-01): OrbStack was stopped, and the gate ran quick and unit for ~135 s
# before its image job found no daemon; the PR needed a full rerun. A stopped OrbStack is the one
# state safe to fix unasked: it runs no containers to lose. A hung or asleep VM is left to
# devkit_docker_check's wake and hint, never restarted here.
# shellcheck disable=SC2034  # DEVKIT_DOCKER_NOTE is this function's output, read by its callers
devkit_docker_ensure() {
  local who=$1 probes=${DEVKIT_ORBSTACK_START_PROBES:-60} n=1 state
  DEVKIT_DOCKER_NOTE=""
  [[ "$probes" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$who: DEVKIT_ORBSTACK_START_PROBES must be a whole number >= 1 (got '$probes')" >&2; exit 2; }
  devkit_docker_check "$who" && return 0
  _devkit_on_macos && command -v orbctl >/dev/null || return 1
  state=$(devkit_with_timeout "${DOCKER_PROBE_TIMEOUT:-15}" orbctl status 2>/dev/null) || :
  [ "$state" = Stopped ] || return 1
  echo "$who: OrbStack is stopped; starting it (orbctl start), then up to $probes probes 1 s apart" >&2
  devkit_with_timeout "$probes" orbctl start </dev/null >/dev/null 2>&1 || :
  # Counted probes, not elapsed seconds: the test steps the loop by its probe count, and a wait
  # between probes only, so one probe (DEVKIT_ORBSTACK_START_PROBES=1) never sleeps.
  until _devkit_docker_probe; do
    if [ "$n" -ge "$probes" ]; then
      DEVKIT_DOCKER_ERROR="OrbStack was stopped; orbctl start ran, but the docker daemon did not answer in $probes probe(s) 1 s apart (open OrbStack, then rerun)"
      return 1
    fi
    n=$((n + 1))
    sleep 1
  done
  DEVKIT_DOCKER_NOTE="OrbStack was stopped; started it (orbctl start), docker answered on probe $n"
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

# Why (devkit #366, 2026-11-02): the nightly dependency merge and the Mac's apple check fetch
# every checkout under the parents, unrelated ones too, and one remote waiting on a credential
# prompt, an SSH host key prompt or a dead network stalled the whole run. A prompt now fails at
# once; a silent remote is stopped. BatchMode is added per call to the repo's own ssh command
# (core.sshCommand, say a deploy key's `ssh -i`, else ssh), never exported over it, and never
# when the caller set GIT_SSH_COMMAND or GIT_SSH: the environment beats the config, so an
# exported one would drop every per-repo key.
devkit_git_guard() {
  local who=$1
  [[ "${DEVKIT_GIT_TIMEOUT:-120}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "$who: DEVKIT_GIT_TIMEOUT must be a whole number of seconds >= 1 (got '$DEVKIT_GIT_TIMEOUT')" >&2; exit 2; }
  command -v pkill >/dev/null || { echo "$who: pkill not found on PATH (procps: apt install procps)" >&2; exit 2; }
  export GIT_TERMINAL_PROMPT=0
  # shellcheck disable=SC2329  # shadows the CLI for every later call in the sourcing script
  git() {
    local a sub='' skip=0 rc=0 ssh pre=()
    # The subcommand is the first word that is not a global option or its value (-C <dir>).
    for a in "$@"; do
      if [ "$skip" = 1 ]; then skip=0; pre+=("$a"); continue; fi
      case "$a" in
        -C|-c|--git-dir|--work-tree|--namespace) skip=1 ;;
        -*) ;;
        *) sub=$a; break ;;
      esac
      pre+=("$a")
    done
    case "$sub" in
      fetch|push|pull|ls-remote|clone) ;;
      *) command git "$@"; return ;;
    esac
    if [ -n "${GIT_SSH_COMMAND:-}${GIT_SSH:-}" ]; then
      devkit_with_timeout "${DEVKIT_GIT_TIMEOUT:-120}" command git "$@" || rc=$?
    else
      ssh=$(command git ${pre[@]+"${pre[@]}"} config --get core.sshCommand) || ssh=ssh
      devkit_with_timeout "${DEVKIT_GIT_TIMEOUT:-120}" \
        env GIT_SSH_COMMAND="$ssh -o BatchMode=yes -o ConnectTimeout=30" git "$@" || rc=$?
    fi
    # Never worded as a transient failure: a remote that hung once hangs again, and a retry
    # (dependency_merge.sh's net) would only spend another bound on it.
    [ "$rc" != 124 ] || echo "git $sub: no answer within ${DEVKIT_GIT_TIMEOUT:-120}s; stopped" >&2
    return "$rc"
  }
}
