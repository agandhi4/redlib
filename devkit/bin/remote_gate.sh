#!/usr/bin/env bash
# Run this repo's PR gate on the gate host over ssh, with local_gate.sh's output contract
# unchanged: the host's GATE/VERDICT lines stream to this stdout, its stderr to this stderr, and
# its exit code is this exit code. The host posts the `local-gate` status itself (it has gh).
# Normally reached through gate.sh (`make gate PR=<n>`), which decides remote vs local.
#
# Usage: devkit/bin/remote_gate.sh <pr> [--no-post] [--expect-head <sha>]   (both forwarded)
#
# Settings (environment, else ${XDG_CONFIG_HOME:-$HOME/.config}/devkit/gate.env; env wins):
#   GATE_REMOTE_HOST      [user@]host to ssh to (required here)
#   GATE_REMOTE_ROOT      where the host keeps one gate checkout per repo; default ~/gates, so
#                         finplat's is ~/gates/finplat. `~` is expanded ON THE HOST.
#   GATE_REMOTE_SSH_OPTS  extra ssh options, word-split (e.g. `-p 2222 -o ConnectTimeout=10`);
#                         they come first, so they override the defaults below.
# Nothing else crosses ssh: the host's own environment and gate.env set GATE_SLOTS etc., so a
# laptop's GATE_SLOTS=4 never loosens the host's one-gate-at-a-time lock.
#
# On the host (remote_main below), under a per-checkout flock:
#   1. clone GATE_SLUG (read from this checkout's plan) with `gh repo clone` if absent; refuse a
#      checkout whose origin is another repo;
#   2. fetch origin main, force the checkout onto it and remove untracked files: local_gate.sh
#      reads the plan from the checkout it runs from, so a stale or dirty one would gate with
#      the wrong policy;
#   3. run devkit/bin/local_gate.sh <pr> [--no-post] [--expect-head <sha>] there, which fetches the PR ref itself
#      (with its fork guard and missing-pull-ref fallback). The checkout is main's, so its gate
#      can predate a flag this wrapper forwards: the devkit-sync PR that brings --expect-head is
#      gated by main's older local_gate.sh, which exits 2 on it (Codex on closet #406). So the
#      flag goes only when that gate's --help usage line lists it; otherwise a GATE note says it
#      was dropped and the gate runs as main's always did, without the head wait.
# Remote gates keep their state in $GATE_REMOTE_ROOT/.state (logs: .state/<GATE_STATE_NAME>/
# logs/<pr>/), not the host's default: the host's merge queue gates the same repo from its own
# checkout with the same worktree names, and a worktree left by a killed run in one checkout
# would make `worktree add` fail in the other. The machine-wide lock is still shared.
#
# The ledger comes back: after the host's gate exits (any code but ssh's own 255 and an
# interrupt), a second short ssh call (remote_ledger) prints the host's runs.tsv rows of this PR
# and its logs/<pr>/gate.json, and `gate_record.py import` merges them into this machine's
# state dir (${XDG_STATE_HOME:-~/.local/state}/<GATE_STATE_NAME>), deduped by pr + head +
# finished, so a rerun copies nothing twice. Without it a remote run's record stayed on the
# host: gate_bite.py read no gates for a repo that gates remotely (locus), and pr_merge.sh fell
# back to the status text for the gated main. A failed copy is one stderr line and never
# changes the exit code.
#
# Interrupts: ssh's stdin is a pipe this script holds open and never writes. When this side
# goes away (Ctrl-C, a killed agent, a closed connection) the host sees EOF and sends TERM to
# local_gate.sh, whose EXIT trap stops the job, posts `error` and removes the worktree. Without
# it a gate whose client vanished kept running and held the host's lock to the end.
#
# Exit: the remote gate's (0 pass, 1 fail, 2 usage or environment, 130 interrupted); 2 when ssh
# itself fails (255), with no VERDICT line, like local_gate.sh's environment errors.
#
# ssh failures: ssh's stderr is teed to a file (it still streams), and on 255 its last line says
# which hint to print (ssh_failure_hint): unreachable (timeout, no route, DNS, refused) names the
# host and the networks it is reachable from; `Permission denied` asks about the key; anything
# else repeats ssh's own error. One key hint for every 255 sent three lanes chasing keys when
# the host was simply off-LAN (2026-10-16).
set -uo pipefail

usage() { echo "usage: $0 <pr-number> [--no-post] [--expect-head <sha>]"; }

PR=""
FORWARD=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-post) FORWARD+=(--no-post) ;;
    --expect-head)
      # Validated here too: the value travels inside the single-quoted remote command.
      [[ "${2:-}" =~ ^[0-9a-f]{40}$ ]] \
        || { echo "remote_gate: --expect-head needs a full 40-hex commit SHA (got '${2:-}')" >&2; exit 2; }
      FORWARD+=(--expect-head "$2")
      shift ;;
    -h|--help) usage; exit 0 ;;
    ''|*[!0-9]*) usage >&2; exit 2 ;;
    *) PR=$1 ;;
  esac
  shift
done
[ -n "$PR" ] || { usage >&2; exit 2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"
gate_env_load remote_gate "$GATE_REMOTE_KEYS" "$GATE_LOCAL_KEYS"
gate_remote_settings_check
HOST=${GATE_REMOTE_HOST:-}
[ -n "$HOST" ] || { echo "remote_gate: GATE_REMOTE_HOST is not set (environment or gate.env)" >&2; exit 2; }
REMOTE_ROOT=${GATE_REMOTE_ROOT:-"~/gates"}
command -v ssh >/dev/null || { echo "remote_gate: ssh not found" >&2; exit 2; }

ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 2
PLAN=$ROOT/scripts/ci/gate_plan.sh
[ -f "$PLAN" ] || { echo "remote_gate: no plan at $PLAN" >&2; exit 2; }
SLUG=$(gate_plan_literal "$PLAN" GATE_SLUG)
[[ "$SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || { echo "remote_gate: $PLAN needs a literal GATE_SLUG=owner/repo line (read here, not sourced)" >&2; exit 2; }

# Runs on the host as `bash -c <this function> remote_gate <pr> <slug> <root> [--no-post]`.
# It travels inside single quotes, so it must contain none (checked below); `declare -f` ships
# exactly the code shellcheck linted here.
# shellcheck disable=SC2329  # invoked on the host, shipped via `declare -f`
remote_main() {
  local pr=$1 slug=$2 root dir repo url gate gate_pid watch_pid rc
  root=$(remote_root_dir "$3")
  shift 3
  repo=${slug#*/}
  dir=$root/$repo
  for tool in git gh flock make; do
    command -v "$tool" >/dev/null || { echo "remote_gate: $tool not found on $(hostname)" >&2; exit 2; }
  done
  mkdir -p "$root" || exit 2

  # Two Macs (or two agents) gating the same repo must not fetch and reset one checkout at once.
  exec 8>"$root/.$repo.lock"
  flock 8
  if [ ! -e "$dir/.git" ]; then
    echo "remote_gate: no checkout of $slug at $dir on $(hostname); cloning" >&2
    gh repo clone "$slug" "$dir" -- -q \
      || { echo "remote_gate: gh repo clone $slug failed on $(hostname) (gh auth status?)" >&2; exit 2; }
  fi
  url=$(git -C "$dir" remote get-url origin) || exit 2
  case "$url" in
    */"$slug" | */"$slug".git | *:"$slug" | *:"$slug".git) ;;
    *) echo "remote_gate: $dir on $(hostname) has origin $url, not $slug" >&2; exit 2 ;;
  esac
  git -C "$dir" fetch -q origin main \
    || { echo "remote_gate: git fetch origin main failed in $dir on $(hostname)" >&2; exit 2; }
  if ! git -C "$dir" checkout -q -f -B main origin/main || ! git -C "$dir" clean -q -ffd; then
    echo "remote_gate: could not reset $dir to origin/main on $(hostname)" >&2
    exit 2
  fi
  exec 8>&-

  gate=$dir/devkit/bin/local_gate.sh
  [ -x "$gate" ] || { echo "remote_gate: $gate missing on $(hostname); is devkit vendored on main?" >&2; exit 2; }
  echo "GATE note: remote $(hostname) $dir main $(git -C "$dir" rev-parse --short HEAD)"
  local usage_line arg
  local args=()
  usage_line=$("$gate" --help 2>/dev/null)
  while [ $# -gt 0 ]; do
    arg=$1
    shift
    if [ "$arg" = --expect-head ]; then
      case "$usage_line" in
        *--expect-head*) args+=(--expect-head "$1") ;;
        *) echo "GATE note: the local_gate.sh on main takes no --expect-head (a devkit-sync PR brings it); gating without the head wait" ;;
      esac
      shift
      continue
    fi
    args+=("$arg")
  done

  export XDG_STATE_HOME=$root/.state
  # Background jobs of a non-interactive shell read /dev/null, so keep ssh's stdin on fd 3 for
  # the watcher. The watcher's own output goes nowhere: sshd waits for every holder of the
  # session's stdout/stderr before it reports the exit status.
  exec 3<&0
  "$gate" "$pr" ${args[@]+"${args[@]}"} </dev/null 3<&- &
  gate_pid=$!
  ( cat <&3 >/dev/null; kill -TERM "$gate_pid" ) >/dev/null 2>&1 &
  watch_pid=$!
  exec 3<&-
  wait "$gate_pid"
  rc=$?
  kill "$watch_pid" 2>/dev/null
  exit "$rc"
}

# remote_root_dir <root>: GATE_REMOTE_ROOT with a leading `~` expanded on the host.
# shellcheck disable=SC2329  # invoked on the host, shipped via `declare -f`
remote_root_dir() {
  case "$1" in
    \~) echo "$HOME" ;;
    \~/*) echo "$HOME/${1#\~/}" ;;
    *) echo "$1" ;;
  esac
}

# Runs on the host as `bash -c <this function> remote_gate <pr> <root> <state name>`: the
# ledger gate_record.py import reads (its LEDGER_SEPARATOR is the `--- gate.json` line).
# shellcheck disable=SC2329  # invoked on the host, shipped via `declare -f`
remote_ledger() {
  local pr=$1 state
  state=$(remote_root_dir "$2")/.state/$3
  if [ -f "$state/runs.tsv" ]; then awk -F "\t" -v pr="$pr" "\$2 == pr" "$state/runs.tsv"; fi
  echo "--- gate.json"
  if [ -f "$state/logs/$pr/gate.json" ]; then cat "$state/logs/$pr/gate.json"; fi
}

SHARED_SCRIPT=$(declare -f remote_root_dir)
REMOTE_SCRIPT="$SHARED_SCRIPT; $(declare -f remote_main); remote_main \"\$@\""
LEDGER_SCRIPT="$SHARED_SCRIPT; $(declare -f remote_ledger); remote_ledger \"\$@\""
case "$REMOTE_SCRIPT$LEDGER_SCRIPT$REMOTE_ROOT" in
  *"'"*) echo "remote_gate: the remote command must not contain a single quote" >&2; exit 2 ;;
esac
REMOTE_CMD="bash -c '$REMOTE_SCRIPT' remote_gate $PR $SLUG '$REMOTE_ROOT' ${FORWARD[*]+"${FORWARD[*]}"}"

read -r -a USER_SSH_OPTS <<<"${GATE_REMOTE_SSH_OPTS:-}"
# BatchMode: an unattended gate must fail on a missing key, never prompt. ServerAlive: a dead
# link ends this side within ~2 min instead of hanging an agent.
SSH_OPTS=(${USER_SSH_OPTS[@]+"${USER_SSH_OPTS[@]}"} -T -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=4)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/remote_gate.XXXXXX") || exit 2
mkfifo "$TMP/stdin" || exit 2
mkfifo "$TMP/stderr" || exit 2
KEEPER=""
SSH_PID=""
TEE_PID=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  [ -n "$KEEPER" ] && kill "$KEEPER" 2>/dev/null
  [ -n "$SSH_PID" ] && kill "$SSH_PID" 2>/dev/null
  [ -n "$TEE_PID" ] && kill "$TEE_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
# First INT/TERM: close the host's stdin (it stops the gate cleanly) and wait for its cleanup
# output. A second one leaves without waiting.
# shellcheck disable=SC2329  # invoked by the trap below
interrupted() {
  trap 'exit 130' INT TERM
  echo "remote_gate: interrupted; stopping the gate on $HOST (again to leave without waiting)" >&2
  [ -n "$KEEPER" ] && kill "$KEEPER" 2>/dev/null
  KEEPER=""
  [ -n "$SSH_PID" ] && wait "$SSH_PID"
  SSH_PID=""
  exit 130
}
trap interrupted INT TERM

# The keeper holds the fifo's write end open and never writes: ssh's stdin stays open (no EOF)
# exactly as long as this script lives, whatever stdin `make gate` itself was given.
sleep 2147483647 >"$TMP/stdin" &
KEEPER=$!
# The host's stderr (and ssh's own) still streams to this stderr; the copy is for the hint below.
# A fifo and a waited-for tee, not `2> >(tee ...)`: bash 3.2 cannot wait for a process
# substitution, so the copy could be read before ssh's last line reached it.
tee "$TMP/stderr.log" <"$TMP/stderr" >&2 &
TEE_PID=$!

# ssh_failure_hint <host> <ssh's last stderr line>: what an exit 255 most likely means. Only the
# last line: ssh prints its own error last, and the host's gate output above it may well
# contain "Connection refused" from a test.
ssh_failure_hint() {
  case "$2" in
    *"Connection timed out"* | *"No route to host"* | *"Could not resolve"* | *"Connection refused"* \
      | *"Network is unreachable"* | *"Operation timed out"*)
      echo "remote_gate: cannot reach the gate host $1 ($2)."
      echo "remote_gate: it is reachable only from its LAN, a VPN that routes its subnet (check split tunnelling), or Tailscale; or gate here with GATE_REMOTE=0."
      ;;
    *"Permission denied"*)
      echo "remote_gate: $1 refused this machine's key ($2); is it in ~/.ssh/authorized_keys there? (BatchMode never prompts; GATE_REMOTE_SSH_OPTS=-i <key> picks one)"
      ;;
    *)
      echo "remote_gate: ssh to $1 failed (exit 255): ${2:-no error output}"
      ;;
  esac
}

echo "remote_gate: gating $SLUG#$PR on $HOST" >&2
# Backgrounded so a signal reaches the trap now, not after ssh returns.
# shellcheck disable=SC2029  # REMOTE_CMD is built here on purpose; the host sees it verbatim
ssh "${SSH_OPTS[@]}" "$HOST" "$REMOTE_CMD" <"$TMP/stdin" 2>"$TMP/stderr" &
SSH_PID=$!
wait "$SSH_PID"
rc=$?
SSH_PID=""
wait "$TEE_PID"
TEE_PID=""
if [ "$rc" = 255 ]; then
  last=$(sed '/^[[:space:]]*$/d' "$TMP/stderr.log" | tail -n 1 | tr -d '\r')
  ssh_failure_hint "$HOST" "$last" >&2
  exit 2
fi

# copy_ledger: the host's record of this PR into this machine's state dir (header: The ledger
# comes back). Every failure is a warning: the verdict above stands.
copy_ledger() {
  local state_name state
  state_name=$(gate_plan_literal "$PLAN" GATE_STATE_NAME)
  if [ -z "$state_name" ]; then
    echo "remote_gate: WARNING: ledger not copied: $PLAN has no literal GATE_STATE_NAME= line" >&2
    return
  fi
  state=${XDG_STATE_HOME:-$HOME/.local/state}/$state_name
  # shellcheck disable=SC2029  # built here on purpose, as REMOTE_CMD
  if ! ssh "${SSH_OPTS[@]}" "$HOST" "bash -c '$LEDGER_SCRIPT' remote_gate $PR '$REMOTE_ROOT' $state_name" \
    </dev/null >"$TMP/ledger" 2>"$TMP/ledger.err"; then
    echo "remote_gate: WARNING: ledger not copied from $HOST: $(tail -n 1 "$TMP/ledger.err")" >&2
    return
  fi
  python3 -I "$HERE/gate_record.py" import --pr "$PR" --runs "$state/runs.tsv" \
    --logdir "$state/logs/$PR" <"$TMP/ledger" >&2 \
    || echo "remote_gate: WARNING: ledger from $HOST not merged into $state (above)" >&2
}
copy_ledger
exit "$rc"
