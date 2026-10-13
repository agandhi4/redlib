#!/usr/bin/env bash
# The shared PR gate skeleton (agandhi4/devkit). Runs a repo's heavy checks on this machine
# against PR <pr>'s head MERGED INTO the current origin/main (the tree a squash-merge would
# produce) and posts the result as the `local-gate` commit status on the PR head. GitHub
# Actions runs only a cheap quick-check per PR (owner CI policy, 2026-09-28); this script
# decides whether a PR is mergeable.
#
# Usage: devkit/bin/local_gate.sh <pr> [--no-post]      (or: make gate PR=<pr>)
#   --no-post  run everything, post no commit status
#
# What is shared vs per-repo:
#   This file owns the mechanics: Node from .nvmrc (node_toolchain.sh), Rust from rust-toolchain.toml (rust_toolchain.sh), lock, fetch (with the missing-pull-ref fallback), worktree,
#   merge, job runner with per-job logs, status posting with retries, cleanup, verdict.
#   The repo owns WHICH jobs run for WHICH changed paths, in scripts/ci/gate_plan.sh,
#   sourced from the invoking checkout. Plan contract:
#     GATE_SLUG=owner/repo                   required
#     GATE_STATE_NAME=<name>                 required; state in $XDG_STATE_HOME/<name>
#     GATE_WORKTREE_PREFIX=wt-               optional; worktree dir is <prefix><pr>
#     GATE_ALLOW_FORKS=0|1                   optional; default 0: a fork PR is refused before fetch
#     gate_plan()                            required; called with the merged worktree ready
#     gate_cleanup()                         optional; runs in the EXIT trap (containers, images)
#   Available to the plan: $PR $WT $ROOT $CHANGED $HEAD_SHA $MAIN_SHA $LOGDIR and the helpers
#     job <name> <make target> [VAR=val...]    run `make -C $WT <target>`; GATE <name> PASS|FAIL
#     skip <name> <reason>                     GATE <name> SKIPPED (<reason>)
#     note <text>                              GATE note: <text>
#     changed <ERE>                            true if any changed path matches (anchor it)
#     pr_has_label <label>                     true only if gh confirms the label (fails closed)
#     nothing_to_run <reason>                  early VERDICT PASS when no job applies
#   Every job must be a Makefile target the CI workflows also call: parity is structural.
#   Change a check in the Makefile, never in the plan.
#
# Watchdog: a job whose log has not grown for GATE_SILENT_MINUTES (default 15; decimals allowed;
#   0 disables) is hung, not slow. OrbStack paused its VM mid-update and a pytest waited on
#   Postgres with no timeout for an hour, holding the machine-wide lock (2026-10-13). The job's
#   process group gets TERM (KILL after 10s), the status is `error`, the EXIT trap cleans up, and
#   the run stops with GATE <job> WATCHDOG, VERDICT FAIL and exit 2: the box failed, not the code.
#
# Output contract, parsed by the merge queues and worker.py — keep it:
#   GATE <job> PASS|FAIL|SKIPPED [(...)]            one line per job
#   GATE <job> WATCHDOG (silent for <n> min; log: <path>)   then the run stops
#   VERDICT PASS|FAIL head=<pr-head-sha> main=<origin/main-sha>
# A queue merges only when both SHAs are still current, so the squash-merged tree is exactly
# the tree gated here.
#
# Portability: macOS bash 3.2 and GNU bash. `${a[@]+"${a[@]}"}` is the bash 3.2 empty-array
# form under `set -u`. `flock` is required (brew install flock on macOS): a silent no-lock let
# overlapping Mac gates fail timing tests in suites the PR never touched (work-loop 2026-10-05).
#
# Exit: 0 pass, 1 fail, 2 usage or environment (a watchdog stop included).
# shellcheck disable=SC2329,SC2317  # helpers are called by the sourced plan and the EXIT trap (2317 is the pre-0.10 code)
set -uo pipefail

readonly STATUS_CONTEXT=local-gate
# Machine-wide, shared with every repo's gate on this box (closet's included): parallel full
# suites on one machine cause load-induced test timeouts, so only one gate runs at a time.
readonly LOCK=${GATE_LOCK:-/tmp/linux-box-local-gate.lock}

usage() { echo "usage: $0 <pr-number> [--no-post]"; }

PR=""
POST=1
for arg in "$@"; do
  case "$arg" in
    --no-post) POST=0 ;;
    -h|--help) usage; exit 0 ;;
    ''|*[!0-9]*) usage >&2; exit 2 ;;
    *) PR=$arg ;;
  esac
done
[ -n "$PR" ] || { usage >&2; exit 2; }
readonly SILENT_MINUTES=${GATE_SILENT_MINUTES:-15}
[[ "$SILENT_MINUTES" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || { echo "local_gate: GATE_SILENT_MINUTES must be a number of minutes (got '$SILENT_MINUTES')" >&2; exit 2; }
SILENT_SECS=$(awk -v m="$SILENT_MINUTES" 'BEGIN { s = int(m * 60 + 0.5); print (m > 0 && s < 1) ? 1 : s }')
readonly SILENT_SECS
command -v flock >/dev/null || { echo "local_gate: flock not found (macOS: brew install flock)" >&2; exit 2; }

ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel) || exit 2
PLAN=${GATE_PLAN:-$ROOT/scripts/ci/gate_plan.sh}
[ -f "$PLAN" ] || { echo "local_gate: no plan at $PLAN" >&2; exit 2; }
GATE_WORKTREE_PREFIX=wt-
GATE_ALLOW_FORKS=0   # set here, not read from the environment: only the plan may opt in
# shellcheck source=/dev/null  # the repo's plan; its contract is in the header
. "$PLAN"
for required in GATE_SLUG GATE_STATE_NAME; do
  [ -n "${!required:-}" ] || { echo "local_gate: $PLAN must set $required" >&2; exit 2; }
done
declare -F gate_plan >/dev/null || { echo "local_gate: $PLAN must define gate_plan()" >&2; exit 2; }
declare -F gate_cleanup >/dev/null || gate_cleanup() { :; }

readonly SLUG=$GATE_SLUG
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/$GATE_STATE_NAME"
WT="$STATE/$GATE_WORKTREE_PREFIX$PR"
LOGDIR="$STATE/logs/$PR"
GATE_REF="refs/gate/pr-$PR"

# The fetch below runs pull/<n>/head for any PR. On a public repo that would execute a
# stranger's code on this box, so a fork PR is refused unless the plan opts in. Fails closed:
# a gh error or empty answer counts as a fork. No status is posted: there is no trusted head.
# (The missing-pull-ref fallback asks isCrossRepository again for a different reason: whether
# the branch tip can stand in for the pull ref even when forks are allowed.)
if [ "$GATE_ALLOW_FORKS" != 1 ] \
    && [ "$(gh pr view "$PR" --repo "$SLUG" --json isCrossRepository --jq .isCrossRepository 2>/dev/null)" != false ]; then
  echo "GATE fork FAIL (PR #$PR is from a fork; set GATE_ALLOW_FORKS=1 in the plan to gate forks deliberately)"
  echo "VERDICT FAIL head= main="
  exit 1
fi

# The jobs must run as they would from a clean shell (or an Actions runner): `make gate`
# would otherwise leak its command-line variables into every nested make via MAKEFLAGS.
unset MAKEFLAGS MFLAGS MAKELEVEL

exec 9>"$LOCK"
if ! flock -n 9; then echo "GATE waiting for another repo's gate to finish"; flock 9; fi

HEAD_SHA=""
MAIN_SHA=""
CHANGED=""
STATUS_OPEN=0   # a `pending` status is on the PR head and still needs a final state
FAILED=0
FAILED_JOBS=""
JOB_PGID=""     # the running job's process group; the watchdog and cleanup signal all of it

post_status() { # <state> <description>; three attempts, a GitHub timeout used to turn a PASS into a queue FAIL
  [ "$POST" = 1 ] || return 0
  local attempt
  for attempt in 1 2 3; do
    gh api "repos/$SLUG/statuses/$HEAD_SHA" \
      -f state="$1" -f context="$STATUS_CONTEXT" -f description="$2" >/dev/null 2>&1 && return 0
    sleep $((attempt * 5))
  done
  echo "local_gate: could not post $STATUS_CONTEXT=$1 on $HEAD_SHA after 3 attempts" >&2
}

# TERM the running job's whole process group (make, the test runner, its workers), KILL
# whatever is left after 10s, then reap the leader quietly.
stop_job() {
  [ -n "$JOB_PGID" ] || return 0
  local waited=0
  kill -TERM -- "-$JOB_PGID" 2>/dev/null
  while kill -0 -- "-$JOB_PGID" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -KILL -- "-$JOB_PGID" 2>/dev/null
  wait "$JOB_PGID" 2>/dev/null
  JOB_PGID=""
}

# True once the job's log has not grown for SILENT_SECS while it still runs; false when it ends.
# `kill -0` turns false when bash reaps the finished leader (it reaps on SIGCHLD).
job_went_silent() { # <log>
  local size last=-1 since=$SECONDS
  while kill -0 "$JOB_PGID" 2>/dev/null; do
    size=$(wc -c <"$1")
    if [ "$size" != "$last" ]; then
      last=$size
      since=$SECONDS
    elif [ "$SILENT_SECS" -gt 0 ] && [ $((SECONDS - since)) -ge "$SILENT_SECS" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup() {
  # An interrupted gate must not leave a job running in the worktree it is about to remove.
  stop_job
  # An interrupted gate must not leave the PR showing `pending` forever.
  if [ "$STATUS_OPEN" = 1 ]; then post_status error "Local gate interrupted before a verdict"; fi
  gate_cleanup >/dev/null 2>&1
  git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$ROOT" update-ref -d "$GATE_REF" >/dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT TERM

verdict() { # <PASS|FAIL> <status description>; ends the run
  local result=$1 description=$2
  if [ "$result" = PASS ]; then post_status success "$description"; else post_status failure "$description"; fi
  STATUS_OPEN=0
  echo "VERDICT $result head=$HEAD_SHA main=$MAIN_SHA"
  if [ "$result" = PASS ]; then exit 0; else exit 1; fi
}

# ---- helpers for gate_plan ---------------------------------------------------------------
job() { # <name> <make target> [VAR=val...]
  local name=$1 t0=$SECONDS log=$LOGDIR/$1.log rc
  shift
  # Backgrounded under `set -m` so the job leads its own process group: the watchdog can stop
  # everything under make, and a TERM to the gate runs its trap now instead of after the job.
  set -m
  make -C "$WT" --no-print-directory "$@" </dev/null >"$log" 2>&1 &
  JOB_PGID=$!
  set +m
  if job_went_silent "$log"; then
    stop_job
    echo "GATE $name WATCHDOG (silent for $SILENT_MINUTES min; log: $log)"
    post_status error "Job $name silent for $SILENT_MINUTES min; stopped by the watchdog"
    STATUS_OPEN=0
    echo "VERDICT FAIL head=$HEAD_SHA main=$MAIN_SHA"
    exit 2
  fi
  wait "$JOB_PGID"
  rc=$?
  JOB_PGID=""
  if [ "$rc" = 0 ]; then
    echo "GATE $name PASS ($((SECONDS - t0))s)"
  else
    echo "GATE $name FAIL (log: $LOGDIR/$name.log)"
    FAILED=1
    FAILED_JOBS="${FAILED_JOBS:+"$FAILED_JOBS, "}$name"
  fi
}
skip() { echo "GATE $1 SKIPPED ($2)"; }
note() { echo "GATE note: $*"; }
changed() { grep -qE "$1" <<< "$CHANGED"; }
pr_has_label() { # fail closed: a gh error means "no label", so label-relaxed checks stay strict
  gh pr view "$PR" --repo "$SLUG" --json labels --jq '.labels[].name' 2>/dev/null | grep -qx "$1"
}
nothing_to_run() { echo "GATE all SKIPPED ($1)"; verdict PASS "$1; nothing to run"; }

# ---- fetch, worktree, merge ----------------------------------------------------------------
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"

# `+` because a force-pushed PR head is not a fast-forward of a ref a killed run left behind.
if ! git -C "$ROOT" fetch -q origin main "+pull/$PR/head:$GATE_REF"; then
  # GitHub sometimes never creates refs/pull/<n>/head (finplat #527). A same-repo PR's head is
  # still the branch tip, but only gate it if that tip IS the PR's headRefOid: never gate
  # another commit.
  PR_INFO=$(gh pr view "$PR" --repo "$SLUG" --json headRefName,headRefOid,isCrossRepository \
    --jq '[.isCrossRepository, .headRefName, .headRefOid] | @tsv' 2>/dev/null)
  IFS=$'\t' read -r PR_CROSS PR_BRANCH PR_OID <<<"$PR_INFO"
  if [ "$PR_CROSS" != false ] || [ -z "$PR_BRANCH" ] || [ -z "$PR_OID" ] \
      || ! git -C "$ROOT" fetch -q origin main "+refs/heads/$PR_BRANCH:$GATE_REF" \
      || [ "$(git -C "$ROOT" rev-parse "$GATE_REF")" != "$PR_OID" ]; then
    echo "GATE fetch FAIL"
    echo "VERDICT FAIL head= main="
    exit 1
  fi
  note "pull/$PR/head missing; fetched branch $PR_BRANCH @ $PR_OID"
fi
HEAD_SHA=$(git -C "$ROOT" rev-parse "$GATE_REF")
MAIN_SHA=$(git -C "$ROOT" rev-parse origin/main)
echo "GATE pr=$PR head=$HEAD_SHA main=$MAIN_SHA"
post_status pending "Local gate running on main ${MAIN_SHA:0:7}"
STATUS_OPEN=1

git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1
if ! git -C "$ROOT" worktree add -q --detach "$WT" "$MAIN_SHA" >"$LOGDIR/worktree.log" 2>&1; then
  echo "GATE worktree FAIL (log: $LOGDIR/worktree.log)"
  verdict FAIL "Local gate could not create its worktree"
fi
if ! git -C "$WT" -c user.name=gate -c user.email=gate@local \
    merge -q --no-edit "$HEAD_SHA" >"$LOGDIR/merge.log" 2>&1; then
  echo "GATE merge FAIL (conflicts with main; log: $LOGDIR/merge.log)"
  verdict FAIL "Conflicts with main ${MAIN_SHA:0:7}"
fi

# Toolchains come from the MERGED tree, not the invoking checkout: the declaration (.nvmrc,
# rust-toolchain.toml) describes the code under test, so a PR that bumps it is gated on its own
# version. (Gate policy, by contrast, is read from $ROOT: see the plan contract.) The Mac's Node
# 25 failed every vitest suite CI passed on 22; node_toolchain.sh/rust_toolchain.sh cache
# checksum-verified installs. An environment the gate cannot provide is a FAIL verdict, never a
# silent fallback (and never a dangling `pending` status).
TOOLCHAIN_NOTES=""
if [ -f "$WT/.nvmrc" ]; then
  if ! NODE_BIN=$("$(dirname "${BASH_SOURCE[0]}")/node_toolchain.sh" "$WT"); then
    echo "GATE toolchain FAIL (cannot provide node $(tr -d '[:space:]' < "$WT/.nvmrc") declared in .nvmrc)"
    verdict FAIL "Gate box cannot provide the declared Node"
  fi
  [ -n "$NODE_BIN" ] && export PATH="$NODE_BIN:$PATH"
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0   # a corepack prompt would hang an unattended gate
  TOOLCHAIN_NOTES="node $(node --version) from .nvmrc"
fi
RUST_DECL=""
for f in rust-toolchain.toml rust-toolchain; do [ -f "$WT/$f" ] && { RUST_DECL=$f; break; }; done
if [ -n "$RUST_DECL" ]; then
  if ! RUST_BIN=$("$(dirname "${BASH_SOURCE[0]}")/rust_toolchain.sh" "$WT"); then
    echo "GATE toolchain FAIL (cannot provide the rust toolchain declared in $RUST_DECL)"
    verdict FAIL "Gate box cannot provide the declared Rust toolchain"
  fi
  [ -n "$RUST_BIN" ] && export PATH="$RUST_BIN:$PATH"
  TOOLCHAIN_NOTES="${TOOLCHAIN_NOTES:+$TOOLCHAIN_NOTES; }rust $( (cd "$WT" && cargo --version) | awk '{print $2}') from $RUST_DECL"
fi
[ -n "$TOOLCHAIN_NOTES" ] && note "$TOOLCHAIN_NOTES"

CHANGED=$(git -C "$WT" diff --name-only "$MAIN_SHA" HEAD)

# ---- the repo decides what runs --------------------------------------------------------------
gate_plan

if [ "$FAILED" = 0 ]; then
  verdict PASS "Passed on main ${MAIN_SHA:0:7}"
else
  verdict FAIL "Failed: ${FAILED_JOBS}. Logs: $LOGDIR"
fi
