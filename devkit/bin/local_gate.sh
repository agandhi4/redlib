#!/usr/bin/env bash
# The shared PR gate skeleton (agandhi4/devkit). Runs a repo's heavy checks on this machine
# against PR <pr>'s head MERGED INTO the current origin/main (the tree a squash-merge would
# produce) and posts the result as the `local-gate` commit status on the PR head. GitHub
# Actions runs only a cheap quick-check per PR (owner CI policy, 2026-09-28); this script
# decides whether a PR is mergeable.
#
# Usage: devkit/bin/local_gate.sh <pr> [--no-post] [--expect-head <sha>]   (or: make gate PR=<pr>)
#   --no-post            run everything, post no commit status
#   --expect-head <sha>  the full SHA the caller means to gate; gate.sh passes this checkout's
#                        tip when it is on the PR's branch ("Expected head" below)
#
# What is shared vs per-repo:
#   This file owns the mechanics: Node and Rust from their pin files (toolchain_path.sh), lock,
#   fetch (with the missing-pull-ref fallback), worktree, merge, job runner with per-job logs,
#   status posting with retries, cleanup, verdict.
#   The repo owns WHICH jobs run for WHICH changed paths, in scripts/ci/gate_plan.sh,
#   sourced from the invoking checkout. Plan contract:
#     GATE_SLUG=owner/repo                   required
#     GATE_STATE_NAME=<name>                 required; state in $XDG_STATE_HOME/<name>
#     GATE_WORKTREE_PREFIX=wt-               optional; worktree dir is <prefix><pr>
#     GATE_ALLOW_FORKS=0|1                   optional; default 0: a fork PR is refused before fetch
#     GATE_JOB_COSTS="<job>=<units> ..."     optional; a job's admission cost where the default
#                                            table guesses wrong ("Concurrency")
#     gate_plan()                            required; called with the merged worktree ready
#     gate_cleanup()                         optional; runs in the EXIT trap (containers, images)
#   Available to the plan: $PR $WT $ROOT $CHANGED $HEAD_SHA $MAIN_SHA $LOGDIR, the areas the
#   changed paths fall in (bin/_paths_lib.sh, the table the hooks use too; printed as
#   `GATE areas: <areas>|none` just before gate_plan runs):
#     GATE_AREAS="docs tooling"              space-separated, from docs backend frontend native tooling other
#     GATE_HAS_DOCS|BACKEND|FRONTEND|NATIVE|TOOLING|OTHER=0|1
#     GATE_ONLY_TOOLING_OR_DOCS=1            docs/tooling paths and no backend, frontend or other
#     devkit_default_gate_plan               the default plan body: the plan declares
#                                            GATE_JOBS_<GROUP> and calls it (_paths_lib.sh)
#   and the helpers
#     job <name> <make target> [VAR=val...]    run `make -C $WT <target>`; GATE <name> PASS|FAIL
#     skip <name> <reason>                     GATE <name> SKIPPED (<reason>)
#     note <text>                              GATE note: <text>
#     changed <ERE>                            true if any changed path matches (anchor it)
#     pr_has_label <label>                     true only if gh confirms the label (fails closed)
#     nothing_to_run <reason>                  early VERDICT PASS when no job applies
#   Every job must be a Makefile target the CI workflows also call: parity is structural.
#   Change a check in the Makefile, never in the plan.
#
# Watchdog: a job whose log has not grown for GATE_SILENCE_SECONDS (default 300; whole seconds;
#   0 disables) is hung, not slow. OrbStack paused its VM mid-update and a pytest waited on
#   Postgres with no timeout for an hour, holding the machine-wide lock (2026-10-13); a bats shard
#   then hung twice in one night and each time parked its lane for the old 15 minutes
#   (2026-10-19). A job that legitimately works quietly for minutes prints progress instead (devkit's
#   own tests/shards.sh does). The job's process group gets TERM (KILL after 10s), the status is
#   `error`, the outcome record gives the job verdict `error` and rule `silence:<job>`, the EXIT
#   trap cleans up, and the run stops with GATE <job> WATCHDOG, VERDICT FAIL and exit 2: the box
#   failed, not the code.
#   The watchdog sees only jobs; the plan's gate_cleanup (EXIT trap) is bounded by
#   GATE_CLEANUP_SECONDS (default 120) instead, and the docker scripts a job runs
#   (throwaway_pg.sh, boot_image.sh) probe the daemon and bound every docker call themselves
#   (bin/_timeout_lib.sh), so a hung daemon fails in seconds with one line, not 15 minutes.
#
# Budgets (owner directive 2026-10-13: whole gate <= 10 min, no job > 5 min): GATE_JOB_BUDGET_MINUTES
#   (default 5) per job and GATE_BUDGET_MINUTES (default 10) for the whole gate, counted from the
#   moment the PR's run lock is held, less every second a job queued for capacity ("Concurrency":
#   waiting is the box's cost, not the PR's). Decimals allowed; 0 disables.
#   An over-budget job still runs to completion (budgets never kill real work; the watchdog
#   handles hangs) and then prints GATE <job> OVERBUDGET (<n>s > <budget>s); the whole gate prints
#   GATE total OVERBUDGET (...). Either makes the verdict FAIL, with the job named in the status
#   description, unless GATE_BUDGET_ENFORCE=0 (default 1), which keeps the lines and the verdict
#   PASS: for a queue adopting budgets before its suites fit.
#   Under load a JOB's budget stretches (bin/_load_lib.sh: min(max(1-minute load / cores, gate
#   slots held), 2), sampled when the job starts and when it ends, the larger kept, only above
#   1.0), and its PASS|FAIL and OVERBUDGET lines then carry `; budget 300 s ×1.6 (load 2.0 at
#   start, 13.1 at end on 8 cpus) → 480 s` inside their parentheses (`; 2 gate slots held` before
#   its `)` when more than one was: the load lags a neighbour gate's bursts). closet's db
#   tier ran 61-65 s alone and failed 110 s twice at load ~13 on 8 cores (closet #410). The
#   whole-gate budget is not scaled by load: it is the owner's wall-clock promise, load or not.
#   It scales with what the plan ran (devkit decisions 2026-10-26): GATE_BUDGET_MINUTES is the
#   floor, raised to the sum, over the jobs that ran, of twice each one's typical seconds (the
#   median of its newest 10 passing records in this repo's run logs, bin/gate_record.py
#   typical), capped at the job budget, or the job budget itself for a job with fewer than 3.
#   locus #155 ran build-ios and unit-ios beside its usual 12 jobs, every one passing, and
#   failed 600 s at 623-798 s. A total over the floor reads the raised budget and prints
#   `GATE note: whole-gate budget <b>s for <n> jobs ...`; one over that names the same figure.
#   The job's start-sample factor reaches its make as DEVKIT_LOAD_SCALE ("1" unscaled), and
#   tier_guard.sh re-exports its own: lint/vitest.base.mjs multiplies vitest's testTimeout and
#   hookTimeout by it (finplat #689's frontend-unit timed out at load 169 on 10 cores).
#
# Job seconds: after each job the gate writes $WT/build/metrics/gate.json, flat keys
#   gate.<job>.seconds, plus gate.total.seconds once the jobs are done (docs/metrics-keys.md,
#   domain `gate`, direction lower). Rewritten after every job, so a metrics job the plan runs
#   last can merge the earlier jobs' seconds. Job names are therefore [A-Za-z0-9_-]+ and never
#   `total` (exit 2 otherwise).
#
# Run logs: each run keeps its own dir, $STATE/logs/<pr>/<head7>-<n>/ (nohead-<n> when the fetch
#   failed before a head was known), n counting up per PR. logs/<pr>/latest names the newest and
#   logs/<pr>/gate.json is a symlink to latest/gate.json, the path every reader already uses.
#   A run that opens removes all but the newest 5 dirs of its PR (KEEP_RUNS). Why
#   (2026-10-20): the gate used to clear logs/<pr>/ each run, so a failure's logs were gone once
#   the next run passed, and a triage of 40 failures found the cause of several only in runs.tsv.
#
# Outcome record: once a run has a log dir, its EXIT trap (every exit, an interrupt included)
#   hands each job's verdict to bin/gate_record.py, which writes $LOGDIR/gate.json (the seconds
#   above plus pr, head, main, started, finished, the run's verdict and per job its verdict and
#   failing rules, parsed from the job logs) and appends one row to $STATE/runs.tsv. Schema:
#   README "Gate record". A fork refusal ends before the log dir and leaves no record. The
#   recorder never changes the verdict or exit code; a failure to write is one stderr line.
#
# Concurrency (devkit decisions 2026-10-26): every job is admitted to the machine-wide pool
#   (bin/_slot_lib.sh, a fixed path every vendored copy and the nightly job share) for its cost
#   before it runs and gives the units back when it ends; the gate holds nothing between jobs.
#   GATE_CAPACITY (an integer >= 1; default max(4, ceil(cores / 2))) is the pool's size. A job's
#   cost is its GATE_JOB_COSTS entry, else the heaviest word of its make target: 1 for lint,
#   docs, deps and metrics, 3 for Docker (db, image, smoke, e2e), 4 for native (ios, swift), 2
#   for anything else (a test tier). Waiters queue in order of their gate's start, so a running
#   gate's next job goes ahead of a newer gate's first; while it waits a job prints, at once and
#   every 30 s,
#     GATE waiting for capacity: <repo>#<pr> <job> needs <c> of <cap>, <u> in use (<holder> <c>,
#       ...)[; queued behind <repo>#<pr> <job>, ...]
#   and its PASS|FAIL line then carries `; queued <n>s` inside the parentheses. A holder whose pid
#   died is reclaimed by the next look at the pool. A tier run by hand outside a gate is admitted
#   too (holder `<repo>:<tier>`); a job's make gets DEVKIT_SLOT_HOLDER=<the gate's pid>, so a tier
#   inside it runs on the job's units instead of asking again. 1 gate at a time was the
#   2026-10-05 rule, GATE_SLOTS equal slots per whole gate the 2026-10-20 one (gate.env may still
#   hold it for older vendored copies; this file ignores it).
#   Two gates of ONE PR never overlap: before its first job a gate locks
#   $STATE/pr-<pr>.lock, printing `GATE waiting for another gate of PR #<pr> (pid <pid> since
#   <utc>)` at once and every 30 s, since both would share refs/gate/pr-<pr>, the worktree and the
#   run numbers under logs/<pr>/ (2026-10-21).
#
# Load: GATE_LOAD_MAX (default unset: no check; a number, decimals allowed). Before its run
#   lock, the gate waits while EITHER the 1- or 5-minute load average exceeds it, printing one
#   `GATE waiting: load 1m=<x> 5m=<y> > <max>` line per minute. After GATE_LOAD_WAIT_MINUTES
#   (default 30; decimals allowed) it proceeds anyway with a `GATE note:`; load alone never
#   fails a gate, and an unreadable load is a note too. Both minutes count: closet's db tier
#   failed twice at a 5-minute load of ~30 that had just dipped under 12 on the 1-minute figure
#   (another repo's Xcode builds, 2026-10-16). The wait is before the budget clock.
#   Load is `sysctl -n vm.loadavg` (macOS) or /proc/loadavg (Linux), read by _load_lib.sh. Test
#   hooks, environment only: DEVKIT_LOADAVG_CMD (a command printing "<1m> <5m> ..."),
#   DEVKIT_NCPU and GATE_LOAD_POLL_SECONDS (default 60).
#
# Expected head: GitHub moves refs/pull/<n>/head a few seconds after a push, so a gate started
#   right after `git push` gated the previous head and posted its verdict there (Orbit #80,
#   finplat #657). With --expect-head, before its run lock the gate reads the pull ref
#   (`git ls-remote`, read-only) and, while it names another commit, prints one
#   `GATE waiting: ...` line and re-polls every GATE_HEAD_POLL_SECONDS (default 5) for up to
#   GATE_HEAD_WAIT_SECONDS (default 60). After the fetch a head that is still not the expected
#   one is `GATE head FAIL` with no status posted: a verdict on a commit the caller did not mean
#   is worse than none. Both settings are environment-only test hooks.
#
# Sleep: on macOS the gate holds a caffeinate assertion for its own lifetime (bin/_awake_lib.sh),
#   since its budgets and watchdog read wall time; DEVKIT_CAFFEINATE=0 turns it off. With the lid
#   closed on battery, which no assertion survives, it refuses at once with exit 2 (one line;
#   DEVKIT_ALLOW_BATTERY=1 overrides).
#
# Per-machine defaults: ${XDG_CONFIG_HOME:-$HOME/.config}/devkit/gate.env, if present, holds
#   GATE_CAPACITY, GATE_SILENCE_SECONDS, GATE_CLEANUP_SECONDS, GATE_JOB_BUDGET_MINUTES, GATE_BUDGET_MINUTES,
#   GATE_BUDGET_ENFORCE, GATE_LOAD_MAX and GATE_LOAD_WAIT_MINUTES `KEY=value` lines (blank lines and full-line `#` comments
#   allowed; GATE_REMOTE* lines are gate.sh's and skipped). It is parsed, never sourced: any other
#   key, quoting, `export` or other shell syntax is a usage error (exit 2) naming the line. An explicit environment variable wins over the
#   file, so `GATE_CAPACITY=1 make gate` still runs one job at a time. Asking every agent to set
#   GATE_SLOTS did not stick (eight lanes queued >1 h serially, 2026-10-13); a file does. The
#   merge queues and linux-box never create it, so they keep the defaults.
#
# Output contract, parsed by the merge queues and worker.py — keep it (the informational
# `GATE slot|areas|note|scope|waiting ...` lines are never job lines):
#   GATE <job> PASS|FAIL|SKIPPED [(...)]            one line per job
#   GATE <job> WATCHDOG (silent for <n>s; log: <path>)      then the run stops
#   GATE <job>|total OVERBUDGET (<n>s > <budget>s)  after the job's PASS|FAIL line / before VERDICT
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

usage() { echo "usage: $0 <pr-number> [--no-post] [--expect-head <sha>]"; }

PR=""
POST=1
EXPECT_HEAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-post) POST=0 ;;
    --expect-head)
      [[ "${2:-}" =~ ^[0-9a-f]{40}$ ]] \
        || { echo "local_gate: --expect-head needs a full 40-hex commit SHA (got '${2:-}')" >&2; exit 2; }
      EXPECT_HEAD=$2
      shift ;;
    -h|--help) usage; exit 0 ;;
    ''|*[!0-9]*) usage >&2; exit 2 ;;
    *) PR=$1 ;;
  esac
  shift
done
[ -n "$PR" ] || { usage >&2; exit 2; }
GATE_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
readonly GATE_STARTED
# Awake from here to exit, the capacity waits included: a sleeping box stalls every queued gate too
# (bin/_awake_lib.sh; Linux: run the gate under systemd-inhibit, as that file says). A Mac that
# no assertion keeps awake (lid closed on battery) is refused first, before any lock or a status.
# shellcheck source=bin/_awake_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_awake_lib.sh"
! devkit_sleep_forced || { echo "local_gate: $DEVKIT_SLEEP_REASON (DEVKIT_ALLOW_BATTERY=1 overrides)" >&2; exit 2; }
devkit_stay_awake

# Per-machine defaults (header). An allowlist, not GATE_*: GATE_LOCK or GATE_PLAN in a file would
# silently split this box's lock from the queues' or swap the plan, which is no per-machine
# default. The GATE_REMOTE* lines in the same file belong to gate.sh/remote_gate.sh and are
# skipped here, so one file configures both (one parser: _gate_env.sh).
# shellcheck source=bin/_gate_env.sh
. "$(dirname "${BASH_SOURCE[0]}")/_gate_env.sh"
gate_env_load local_gate "$GATE_LOCAL_KEYS" "$GATE_REMOTE_KEYS"
# shellcheck source=bin/_load_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_load_lib.sh"
# minutes_to_secs <VAR> <minutes>: whole seconds; a positive fraction never rounds to 0 (which
# means "off"). Junk is a usage error naming the variable.
minutes_to_secs() {
  [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
    || { echo "local_gate: $1 must be a number of minutes (got '$2')" >&2; return 2; }
  awk -v m="$2" 'BEGIN { s = int(m * 60 + 0.5); print (m > 0 && s < 1) ? 1 : s }'
}
readonly CLEANUP_SECS=${GATE_CLEANUP_SECONDS:-120}
[[ "$CLEANUP_SECS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "local_gate: GATE_CLEANUP_SECONDS must be a whole number of seconds >= 1 (got '$CLEANUP_SECS')" >&2; exit 2; }
# How often job_went_silent and stop_job look at a running job. A finished job is noticed within
# one poll, so a whole second cost every job up to 1 s: gate_contract.bats ran ~200 jobs, most of
# its 264 s wall at 58 s CPU (2026-10-19). Fractional sleep is BSD's and GNU's alike.
readonly WATCH_POLL_SECS=0.2
readonly SILENT_SECS=${GATE_SILENCE_SECONDS:-300}
[[ "$SILENT_SECS" =~ ^[0-9]+$ ]] \
  || { echo "local_gate: GATE_SILENCE_SECONDS must be a whole number of seconds, 0 to disable (got '$SILENT_SECS')" >&2; exit 2; }
JOB_BUDGET_SECS=$(minutes_to_secs GATE_JOB_BUDGET_MINUTES "${GATE_JOB_BUDGET_MINUTES:-5}") || exit 2
GATE_BUDGET_SECS=$(minutes_to_secs GATE_BUDGET_MINUTES "${GATE_BUDGET_MINUTES:-10}") || exit 2
readonly JOB_BUDGET_SECS GATE_BUDGET_SECS
readonly BUDGET_ENFORCE=${GATE_BUDGET_ENFORCE:-1}
[[ "$BUDGET_ENFORCE" =~ ^[01]$ ]] \
  || { echo "local_gate: GATE_BUDGET_ENFORCE must be 0 or 1 (got '$BUDGET_ENFORCE')" >&2; exit 2; }
# Machine-wide, shared with every repo's gate and hand-run tier on this box (closet's included):
# parallel full suites on one machine cause load-induced test timeouts (header, "Concurrency").
# shellcheck source=bin/_slot_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_slot_lib.sh"
slot_pool_init local_gate
readonly SLOT_DIR SLOT_CAPACITY
readonly LOAD_MAX=${GATE_LOAD_MAX:-}
[ -z "$LOAD_MAX" ] || [[ "$LOAD_MAX" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || { echo "local_gate: GATE_LOAD_MAX must be a number (got '$LOAD_MAX')" >&2; exit 2; }
readonly LOAD_WAIT_MINUTES=${GATE_LOAD_WAIT_MINUTES:-30}
LOAD_WAIT_SECS=$(minutes_to_secs GATE_LOAD_WAIT_MINUTES "$LOAD_WAIT_MINUTES") || exit 2
readonly LOAD_WAIT_SECS
readonly LOAD_POLL_SECS=${GATE_LOAD_POLL_SECONDS:-60}
[[ "$LOAD_POLL_SECS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "local_gate: GATE_LOAD_POLL_SECONDS must be an integer >= 1 (got '$LOAD_POLL_SECS')" >&2; exit 2; }
readonly HEAD_WAIT_SECS=${GATE_HEAD_WAIT_SECONDS:-60}
[[ "$HEAD_WAIT_SECS" =~ ^[0-9]+$ ]] \
  || { echo "local_gate: GATE_HEAD_WAIT_SECONDS must be an integer >= 0 (got '$HEAD_WAIT_SECS')" >&2; exit 2; }
readonly HEAD_POLL_SECS=${GATE_HEAD_POLL_SECONDS:-5}
[[ "$HEAD_POLL_SECS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "local_gate: GATE_HEAD_POLL_SECONDS must be an integer >= 1 (got '$HEAD_POLL_SECS')" >&2; exit 2; }

ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel) || exit 2
# Absolute: the EXIT trap runs it, after the plan, which may have changed directory.
GATE_RECORDER=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate_record.py || exit 2
readonly GATE_RECORDER
# shellcheck source=/dev/null  # bin/toolchain_path.sh: toolchain_path, shared with the hooks
. "$(dirname "${BASH_SOURCE[0]}")/toolchain_path.sh"
# Preflight, before a lock, a status or a worktree: the skeleton's tools, devkit's python3 (the
# outcome record and every vendored tool) and the tools this checkout declares (uv for a uv.lock).
# A box missing any is one error naming them all, not a FAIL per job (_toolchain_lib.sh).
devkit_preflight gh git make flock -- "$ROOT" || { echo "local_gate: $DEVKIT_PREFLIGHT_ERROR" >&2; exit 2; }
PLAN=${GATE_PLAN:-$ROOT/scripts/ci/gate_plan.sh}
[ -f "$PLAN" ] || { echo "local_gate: no plan at $PLAN" >&2; exit 2; }
GATE_WORKTREE_PREFIX=wt-
GATE_ALLOW_FORKS=0   # set here, not read from the environment: only the plan may opt in
# Before the plan, which may call devkit_default_gate_plan. The invoking checkout's copy, as
# for the skeleton: a PR cannot change how its own paths are classified.
# shellcheck source=bin/_paths_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_paths_lib.sh"
# shellcheck source=bin/_timeout_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_timeout_lib.sh"
GATE_CODE_PATHS=  # the plan's alone, never the environment's (_paths_lib.sh header)
GATE_JOB_COSTS=   # the plan's alone too: an exported one would re-cost every repo's jobs
# shellcheck source=/dev/null  # the repo's plan; its contract is in the header
. "$PLAN"
slot_costs_check local_gate
for required in GATE_SLUG GATE_STATE_NAME; do
  [ -n "${!required:-}" ] || { echo "local_gate: $PLAN must set $required" >&2; exit 2; }
done
declare -F gate_plan >/dev/null || { echo "local_gate: $PLAN must define gate_plan()" >&2; exit 2; }
declare -F gate_cleanup >/dev/null || gate_cleanup() { :; }

readonly SLUG=$GATE_SLUG
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/$GATE_STATE_NAME"
WT="$STATE/$GATE_WORKTREE_PREFIX$PR"
PRDIR="$STATE/logs/$PR"
LOGDIR=""   # this run's own dir under $PRDIR, once open_run names it (header, "Run logs")
readonly KEEP_RUNS=5
GATE_REF="refs/gate/pr-$PR"

JOB_OUTCOMES="" # "<name> <verdict> <seconds|->" lines, in run order, for the outcome record
OVER_NAMES=""   # jobs (and `total`) over an ENFORCED budget, space-separated, for the record
RECORD=0        # 1 once $LOGDIR exists: from then on every exit leaves an outcome record
RUN_VERDICT=error   # pass|fail once verdict() or a FAIL step decides; error if neither does

# record_job <name> <pass|fail|skip|budget|error> <seconds|->: the job's line for the outcome record;
# a job the plan runs again replaces its earlier line, as in JOB_SECONDS.
record_job() {
  JOB_OUTCOMES=$(awk -v n="$1 " 'index($0, n) != 1' <<<"$JOB_OUTCOMES"; echo "$1 $2 $3")
}
# fail_step <name> [<detail>]: a gate step (not a plan job) failed: its GATE line and its record.
fail_step() {
  echo "GATE $1 FAIL${2:+ ($2)}"
  record_job "$1" fail -
}
# fail_unposted <name> [<detail>]: a step failed before there is a head to post a status on.
fail_unposted() {
  fail_step "$@"
  RUN_VERDICT=fail
  echo "VERDICT FAIL head= main="
  exit 1
}

# The fetch below runs pull/<n>/head for any PR. On a public repo that would execute a
# stranger's code on this box, so a fork PR is refused unless the plan opts in. Fails closed:
# a gh error or empty answer counts as a fork. No status is posted: there is no trusted head.
# (The missing-pull-ref fallback asks isCrossRepository again for a different reason: whether
# the branch tip can stand in for the pull ref even when forks are allowed.)
if [ "$GATE_ALLOW_FORKS" != 1 ] \
    && [ "$(gh pr view "$PR" --repo "$SLUG" --json isCrossRepository --jq .isCrossRepository 2>/dev/null)" != false ]; then
  fail_unposted fork "PR #$PR is from a fork; set GATE_ALLOW_FORKS=1 in the plan to gate forks deliberately"
fi

# The jobs must run as they would from a clean shell (or an Actions runner): `make gate`
# would otherwise leak its command-line variables into every nested make via MAKEFLAGS.
unset MAKEFLAGS MFLAGS MAKELEVEL

# wait_for_load: header, "Load". Returns once both averages are <= LOAD_MAX, or after
# LOAD_WAIT_SECS, or at once when the load cannot be read; never fails the gate.
wait_for_load() {
  [ -n "$LOAD_MAX" ] || return 0
  local t0=$SECONDS l1 l5
  while :; do
    read -r l1 l5 <<<"$(devkit_loadavg)"
    if [ -z "$l1" ]; then
      echo "GATE note: cannot read the load average; GATE_LOAD_MAX=$LOAD_MAX not applied"
      return 0
    fi
    awk -v a="$l1" -v b="$l5" -v m="$LOAD_MAX" 'BEGIN { exit !(a > m || b > m) }' || return 0
    if [ $((SECONDS - t0)) -ge "$LOAD_WAIT_SECS" ]; then
      echo "GATE note: load 1m=$l1 5m=$l5 still > $LOAD_MAX after $LOAD_WAIT_MINUTES min (GATE_LOAD_WAIT_MINUTES); proceeding anyway"
      return 0
    fi
    echo "GATE waiting: load 1m=$l1 5m=$l5 > $LOAD_MAX"
    sleep "$LOAD_POLL_SECS"
  done
}
# wait_for_head: header, "Expected head". Returns once the pull ref names EXPECT_HEAD, or
# after HEAD_WAIT_SECS, or at once when there is no pull ref to read (the missing-pull-ref
# fallback below asks gh instead); the comparison after the fetch is what fails the gate.
wait_for_head() {
  [ -n "$EXPECT_HEAD" ] || return 0
  local t0=$SECONDS seen said=0
  while :; do
    seen=$(git -C "$ROOT" ls-remote origin "refs/pull/$PR/head" 2>/dev/null | cut -f1)
    [ -n "$seen" ] && [ "$seen" != "$EXPECT_HEAD" ] || return 0
    [ $((SECONDS - t0)) -lt "$HEAD_WAIT_SECS" ] || return 0
    if [ "$said" = 0 ]; then
      echo "GATE waiting: GitHub has PR #$PR at ${seen:0:12}, expected ${EXPECT_HEAD:0:12}; re-polling for up to ${HEAD_WAIT_SECS}s"
      said=1
    fi
    sleep "$HEAD_POLL_SECS"
  done
}
wait_for_head
wait_for_load

# Two gates of one PR share $GATE_REF, $WT and the run-number pick in $PRDIR: one would remove
# the other's worktree and both could open the same log dir. Nothing else keeps them apart, so
# the second waits here for the first, before its jobs queue for capacity.
mkdir -p "$STATE" || { echo "local_gate: cannot create $STATE" >&2; exit 2; }
run_lock_acquire GATE "$STATE/pr-$PR.lock" "another gate of PR #$PR"
echo "GATE slot capacity $SLOT_CAPACITY"
readonly GATE_T0=$SECONDS   # the whole-gate budget starts once the PR is this run's
GATE_ORDER=$(date +%s)      # this gate's place in the capacity queue, for every job (header)
readonly GATE_ORDER
QUEUED_SECS=0               # seconds this gate's jobs waited for capacity, off every budget

HEAD_SHA=""
MAIN_SHA=""
CHANGED=""
STATUS_OPEN=0   # a `pending` status is on the PR head and still needs a final state
FAILED=0
FAILED_JOBS=""
JOB_PGID=""     # the running job's process group; the watchdog and cleanup signal all of it
OVERBUDGET=""   # "<name> (<n>s > <b>s)" entries, comma-separated, for the status description
JOB_SECONDS=""  # "<name> <seconds>" lines, in run order, for gate.json

post_status() { # <state> <description>; three attempts, a GitHub timeout used to turn a PASS into a queue FAIL
  [ "$POST" = 1 ] || return 0
  local attempt
  for attempt in 1 2 3; do
    gh api "repos/$SLUG/statuses/$HEAD_SHA" \
      -f state="$1" -f context="$STATUS_CONTEXT" -f description="$2" >/dev/null 2>&1 && return 0
    # Backoff between attempts only (5 s, 10 s); GATE_STATUS_BACKOFF_SECONDS is a test hook.
    [ "$attempt" = 3 ] || sleep $((attempt * ${GATE_STATUS_BACKOFF_SECONDS:-5}))
  done
  echo "local_gate: could not post $STATUS_CONTEXT=$1 on $HEAD_SHA after 3 attempts" >&2
}

# TERM the running job's whole process group (make, the test runner, its workers), KILL
# whatever is left after 10s, then reap the leader quietly.
stop_job() {
  [ -n "$JOB_PGID" ] || return 0
  local deadline=$((SECONDS + 10))
  kill -TERM -- "-$JOB_PGID" 2>/dev/null
  while kill -0 -- "-$JOB_PGID" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    sleep "$WATCH_POLL_SECS"
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
    sleep "$WATCH_POLL_SECS"
  done
  return 1
}

# record_outcome: the outcome record (header, "Outcome record"), once, from the EXIT trap.
record_outcome() {
  [ "$RECORD" = 1 ] || return 0
  local name over=() total=${TOTAL_SECS:-}
  for name in $OVER_NAMES; do over+=(--over "$name"); done
  printf '%s\n' "$JOB_OUTCOMES" | "$DEVKIT_PYTHON" -I "$GATE_RECORDER" --logdir "$LOGDIR" --runs "$STATE/runs.tsv" \
    --pr "$PR" --head "$HEAD_SHA" --main "$MAIN_SHA" --started "$GATE_STARTED" \
    --verdict "$RUN_VERDICT" --seconds "${total:-$((SECONDS - GATE_T0 - QUEUED_SECS))}" \
    ${total:+--total-seconds "$total"} ${over[@]+"${over[@]}"} \
    || echo "local_gate: the outcome record for this run was not written (gate_record.py above)" >&2
}

cleanup() {
  # An interrupted gate must not leave a job running in the worktree it is about to remove.
  stop_job
  slot_release
  # An interrupted gate must not leave the PR showing `pending` forever.
  if [ "$STATUS_OPEN" = 1 ]; then post_status error "Local gate interrupted before a verdict"; fi
  record_outcome
  # Bounded: a hung docker daemon made a plan's `docker rm -fv` block this trap for 12+ min
  # while the gate held its machine-wide slot (2026-10-17); here it still holds the PR's run lock.
  devkit_with_timeout "$CLEANUP_SECS" gate_cleanup >/dev/null 2>&1
  [ $? -ne 124 ] || echo "local_gate: gate_cleanup stopped after ${CLEANUP_SECS}s (a hung docker daemon?); containers may be left: docker ps" >&2
  git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$ROOT" update-ref -d "$GATE_REF" >/dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT TERM

verdict() { # <PASS|FAIL> <status description>; ends the run
  local result=$1 description=$2
  RUN_VERDICT=$(tr '[:upper:]' '[:lower:]' <<<"$result")
  if [ "$result" = PASS ]; then post_status success "$description"; else post_status failure "$description"; fi
  STATUS_OPEN=0
  echo "VERDICT $result head=$HEAD_SHA main=$MAIN_SHA"
  if [ "$result" = PASS ]; then exit 0; else exit 1; fi
}

# check_budget <name> <seconds> <budget-seconds> [<load note>]: the OVERBUDGET line; a FAIL unless
# enforcement is off. The note (devkit_load_scale's LOAD_NOTE) explains a stretched budget.
check_budget() {
  [ "$3" -gt 0 ] && [ "$2" -gt "$3" ] || return 0
  echo "GATE $1 OVERBUDGET (${2}s > ${3}s${4:+; $4})"
  OVERBUDGET="${OVERBUDGET:+"$OVERBUDGET, "}$1 (${2}s > ${3}s)"
  [ "$BUDGET_ENFORCE" = 0 ] && return 0
  FAILED=1
  OVER_NAMES="$OVER_NAMES $1"
}
over_budget() { case " $OVER_NAMES " in *" $1 "*) return 0 ;; esac; return 1; }

# write_gate_metrics [<total-seconds>]: gate.json in the worktree, for the plan's metrics job (the
# record in $LOGDIR is gate_record.py's). Names were validated by job(), so no JSON escaping applies.
write_gate_metrics() {
  local dir=$WT/build/metrics name secs sep="" body=""
  while read -r name secs; do
    [ -n "$name" ] || continue
    body="$body$sep  \"gate.$name.seconds\": $secs"
    sep=$',\n'
  done <<<"$JOB_SECONDS"
  [ -z "${1:-}" ] || body="$body$sep  \"gate.total.seconds\": $1"
  mkdir -p "$dir" && printf '{\n%s\n}\n' "$body" >"$dir/gate.json"
}

# whole_budget: WHOLE_BUDGET_SECS for the jobs this run ran (header, Budgets) and, when it is above
# the floor, WHOLE_BUDGET_NOTE saying how, also printed as a note. Read only for a total over the
# floor, which the derived budget never goes below: the records' read costs a python start, and
# gate_contract.bats runs ~200 gates. The floor alone when the typical seconds cannot be read
# (one stderr line): a recorder failure never fails a gate.
whole_budget() {
  local name typ c sum=0 n=0 names typicals
  WHOLE_BUDGET_SECS=$GATE_BUDGET_SECS WHOLE_BUDGET_NOTE=""
  [ "$GATE_BUDGET_SECS" -gt 0 ] && [ "$TOTAL_SECS" -gt "$GATE_BUDGET_SECS" ] || return 0
  names=$(awk '{ print $1 }' <<<"$JOB_SECONDS")
  [ -n "$names" ] || return 0
  # shellcheck disable=SC2086  # one argument per job name; names are [A-Za-z0-9_-]+ (job)
  typicals=$("$DEVKIT_PYTHON" -I "$GATE_RECORDER" typical --logs "$STATE/logs" --exclude "$LOGDIR" $names) || {
    echo "local_gate: could not read the jobs' typical seconds (gate_record.py above); whole-gate budget ${GATE_BUDGET_SECS}s" >&2
    return 0
  }
  while read -r name typ; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ "$typ" = - ]; then
      c=$JOB_BUDGET_SECS
    else
      c=$((2 * typ))
      [ "$JOB_BUDGET_SECS" = 0 ] || [ "$c" -le "$JOB_BUDGET_SECS" ] || c=$JOB_BUDGET_SECS
    fi
    sum=$((sum + c))
  done <<<"$typicals"
  [ "$sum" -gt "$GATE_BUDGET_SECS" ] || return 0
  WHOLE_BUDGET_SECS=$sum
  WHOLE_BUDGET_NOTE="whole-gate budget ${sum}s for $n jobs: twice each one's typical seconds, or its budget with under 3 passing runs; floor ${GATE_BUDGET_SECS}s"
  note "$WHOLE_BUDGET_NOTE"
}

# ---- helpers for gate_plan ---------------------------------------------------------------
job() { # <name> <make target> [VAR=val...]
  local name=$1 t0 log=$LOGDIR/$1.log rc secs queued
  local budget load_note
  shift
  if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]] || [ "$name" = total ]; then
    echo "local_gate: job name '$name' must match [A-Za-z0-9_-]+ and not be 'total' (it becomes the key gate.<name>.seconds)" >&2
    exit 2
  fi
  slot_acquire GATE "${GATE_STATE_NAME%-gate}#$PR $name" "$(slot_cost "$name" "$1")" "$GATE_ORDER"
  QUEUED_SECS=$((QUEUED_SECS + SLOT_QUEUED))
  queued=$SLOT_QUEUED
  t0=$SECONDS   # the job's budget starts once it is admitted
  devkit_load_scale "$JOB_BUDGET_SECS" "$(slot_held_count)"
  # Backgrounded under `set -m` so the job leads its own process group: the watchdog can stop
  # everything under make, and a TERM to the gate runs its trap now instead of after the job.
  set -m
  # The child opens $log after it is forked; create it first so the watchdog's first size read
  # never races a missing file (it printed a `wc` error line before the job's redirect ran).
  : >"$log"
  # 7>&-: the PR lock stays with this process. A job's descendant that outlives the gate (a dev
  # server) would otherwise hold it, and the PR's next gate would wait forever. A tier inside the
  # job finds the job's units through DEVKIT_SLOT_HOLDER.
  DEVKIT_SLOT_HOLDER=$$ DEVKIT_LOAD_SCALE=$LOAD_SCALE make -C "$WT" --no-print-directory "$@" </dev/null >"$log" 2>&1 7>&- &
  JOB_PGID=$!
  set +m
  if job_went_silent "$log"; then
    stop_job
    echo "GATE $name WATCHDOG (silent for ${SILENT_SECS}s; log: $log)"
    record_job "$name" error $((SECONDS - t0))
    post_status error "Job $name silent for ${SILENT_SECS}s; stopped by the watchdog"
    STATUS_OPEN=0
    echo "VERDICT FAIL head=$HEAD_SHA main=$MAIN_SHA"
    exit 2
  fi
  wait "$JOB_PGID"
  rc=$?
  JOB_PGID=""
  secs=$((SECONDS - t0))
  devkit_load_rescale "$(slot_held_count)"
  slot_release
  budget=$LOAD_BUDGET load_note=$LOAD_NOTE
  [ "$queued" = 0 ] || load_note="${load_note:+$load_note; }queued ${queued}s"
  local verdict=fail
  if [ "$rc" = 0 ]; then
    verdict=pass
    echo "GATE $name PASS (${secs}s${load_note:+; $load_note})"
  else
    echo "GATE $name FAIL (log: $LOGDIR/$name.log${load_note:+; $load_note})"
    FAILED=1
    FAILED_JOBS="${FAILED_JOBS:+"$FAILED_JOBS, "}$name"
  fi
  check_budget "$name" "$secs" "$budget" "$load_note"
  if [ "$verdict" = pass ] && over_budget "$name"; then verdict=budget; fi
  record_job "$name" "$verdict" "$secs"
  JOB_SECONDS=$(grep -v "^$name " <<<"$JOB_SECONDS"; echo "$name $secs")
  write_gate_metrics
}
skip() { echo "GATE $1 SKIPPED ($2)"; record_job "$1" skip -; }
note() { echo "GATE note: $*"; }
changed() { grep -qE "$1" <<< "$CHANGED"; }
pr_has_label() { # fail closed: a gh error means "no label", so label-relaxed checks stay strict
  gh pr view "$PR" --repo "$SLUG" --json labels --jq '.labels[].name' 2>/dev/null | grep -qx "$1"
}
# The description names main, as every verdict does: pr_merge.sh reads `on main <sha>` from it
# when the gate ran on another host.
nothing_to_run() { echo "GATE all SKIPPED ($1)"; verdict PASS "$1; nothing to run on main ${MAIN_SHA:0:7}"; }

# ---- run logs (header, "Run logs") --------------------------------------------------------------
# run_numbers: "<n> <dir>" for each run dir under $PRDIR, any order.
run_numbers() {
  local d n
  for d in "$PRDIR"/*-*; do
    n=${d##*-}
    [ -d "$d" ] && [ ! -L "$d" ] && [[ "$n" =~ ^[0-9]+$ ]] && echo "$n $d"
  done
}
# open_run <head7|nohead>: create this run's dir, point latest (and gate.json) at it, prune the
# oldest past KEEP_RUNS, and from now on leave an outcome record.
open_run() {
  local n d
  mkdir -p "$PRDIR" || { echo "local_gate: cannot create $PRDIR" >&2; exit 2; }
  # The old layout kept one run's files straight in $PRDIR; a new run replaces them, as it did.
  for d in "$PRDIR"/*; do
    if [ -f "$d" ] && [ ! -L "$d" ]; then rm -f "$d"; fi
  done
  n=$(run_numbers | sort -n | tail -1 | cut -d' ' -f1)
  LOGDIR=$PRDIR/$1-$(( ${n:-0} + 1 ))
  mkdir -p "$LOGDIR" || { echo "local_gate: cannot create $LOGDIR" >&2; exit 2; }
  ln -sfn "${LOGDIR##*/}" "$PRDIR/latest"
  ln -sfn latest/gate.json "$PRDIR/gate.json"
  run_numbers | sort -rn | tail -n +$((KEEP_RUNS + 1)) | while read -r _ d; do rm -rf "$d"; done
  RECORD=1
}

# ---- fetch, worktree, merge ----------------------------------------------------------------

# `+` because a force-pushed PR head is not a fast-forward of a ref a killed run left behind.
if ! fetch_main "$ROOT" "+pull/$PR/head:$GATE_REF"; then
  # GitHub sometimes never creates refs/pull/<n>/head (finplat #527). A same-repo PR's head is
  # still the branch tip, but only gate it if that tip IS the PR's headRefOid: never gate
  # another commit.
  PR_INFO=$(gh pr view "$PR" --repo "$SLUG" --json headRefName,headRefOid,isCrossRepository \
    --jq '[.isCrossRepository, .headRefName, .headRefOid] | @tsv' 2>/dev/null)
  IFS=$'\t' read -r PR_CROSS PR_BRANCH PR_OID <<<"$PR_INFO"
  if [ "$PR_CROSS" != false ] || [ -z "$PR_BRANCH" ] || [ -z "$PR_OID" ] \
      || ! fetch_main "$ROOT" "+refs/heads/$PR_BRANCH:$GATE_REF" \
      || [ "$(git -C "$ROOT" rev-parse "$GATE_REF")" != "$PR_OID" ]; then
    open_run nohead
    fail_unposted fetch
  fi
  note "pull/$PR/head missing; fetched branch $PR_BRANCH @ $PR_OID"
fi
HEAD_SHA=$(git -C "$ROOT" rev-parse "$GATE_REF")
open_run "${HEAD_SHA:0:7}"
if [ -n "$EXPECT_HEAD" ] && [ "$HEAD_SHA" != "$EXPECT_HEAD" ]; then
  fail_unposted head "GitHub head $HEAD_SHA ≠ local $EXPECT_HEAD after ${HEAD_WAIT_SECS}s; push or wait"
fi
MAIN_SHA=$(git -C "$ROOT" rev-parse origin/main)
echo "GATE pr=$PR head=$HEAD_SHA main=$MAIN_SHA"
post_status pending "Local gate running on main ${MAIN_SHA:0:7}"
STATUS_OPEN=1

git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1
if ! git -C "$ROOT" worktree add -q --detach "$WT" "$MAIN_SHA" >"$LOGDIR/worktree.log" 2>&1; then
  fail_step worktree "log: $LOGDIR/worktree.log"
  verdict FAIL "Local gate could not create its worktree"
fi
if ! git -C "$WT" -c user.name=gate -c user.email=gate@local \
    merge -q --no-edit "$HEAD_SHA" >"$LOGDIR/merge.log" 2>&1; then
  fail_step merge "conflicts with main; log: $LOGDIR/merge.log"
  verdict FAIL "Conflicts with main ${MAIN_SHA:0:7}"
fi

# Toolchains come from the MERGED tree, not the invoking checkout: the declaration (.nvmrc,
# rust-toolchain.toml) describes the code under test, so a PR that bumps it is gated on its own
# version. (Gate policy, by contrast, is read from $ROOT: see the plan contract.) The Mac's Node
# 25 failed every vitest suite CI passed on 22. toolchain_path.sh, shared with the hooks, puts
# the cached, checksum-verified node_toolchain.sh/rust_toolchain.sh installs first on PATH. An
# environment the gate cannot provide is a FAIL verdict, never a silent fallback (and never a
# dangling `pending` status).
if ! toolchain_path "$WT"; then
  fail_step toolchain "$TOOLCHAIN_ERROR"
  verdict FAIL "Gate box cannot provide the declared $TOOLCHAIN_FAILED"
fi
# A tool the merged tree declares is required here too (a PR's first uv.lock): the preflight read
# $ROOT's, and toolchain_path never requires one, since hooks and CI run without uv.
if ! devkit_preflight -- "$WT"; then
  fail_step toolchain "$DEVKIT_PREFLIGHT_ERROR"
  verdict FAIL "Gate box cannot provide a tool the merged tree declares"
fi
[ -n "$TOOLCHAIN_NOTES" ] && note "$TOOLCHAIN_NOTES"

CHANGED=$(git -C "$WT" diff --name-only "$MAIN_SHA" HEAD)
devkit_gate_areas "$CHANGED"
echo "GATE areas: ${GATE_AREAS:-none}"

# ---- the repo decides what runs --------------------------------------------------------------
gate_plan

TOTAL_SECS=$((SECONDS - GATE_T0 - QUEUED_SECS))
[ "$QUEUED_SECS" = 0 ] || note "jobs queued ${QUEUED_SECS}s for capacity in all; not counted in any budget"
whole_budget
check_budget total "$TOTAL_SECS" "$WHOLE_BUDGET_SECS" "$WHOLE_BUDGET_NOTE"
write_gate_metrics "$TOTAL_SECS"
if [ -n "$OVERBUDGET" ] && [ "$BUDGET_ENFORCE" = 0 ]; then
  note "over budget, not enforced (GATE_BUDGET_ENFORCE=0): $OVERBUDGET"
fi

if [ "$FAILED" = 0 ]; then
  verdict PASS "Passed on main ${MAIN_SHA:0:7}"
fi
DESCRIPTION=""
[ -z "$FAILED_JOBS" ] || DESCRIPTION="Failed: $FAILED_JOBS. "
[ -z "$OVERBUDGET" ] || [ "$BUDGET_ENFORCE" = 0 ] || DESCRIPTION="${DESCRIPTION}Over budget: $OVERBUDGET. "
verdict FAIL "${DESCRIPTION}Logs: $LOGDIR"
