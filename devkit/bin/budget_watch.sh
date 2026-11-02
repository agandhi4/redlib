#!/usr/bin/env bash
# The nightly budget watch: time budgets report but never fail a PR's gate (owner 2026-10-29:
# 87 of 181 failed gates 2026-10-22..29 failed on load alone, 27.5 machine-hours), so a real
# slowdown is caught here instead, on the repo's main, on an idle box, with every budget enforced.
# Run by bin/dependency_merge.sh, which already visits every repo each night, on its worktree of
# origin/main after its merges (watch_budgets).
#
# Usage: bin/budget_watch.sh --slug <owner/repo> --root <main worktree> --state-dir <dir> [--dry-run]
#
# Jobs: every job the repo's gate plan (scripts/ci/gate_plan.sh) declares for a change touching
#   every path (the plan sourced with stub helpers: `changed` is true, `job` collects, nothing
#   runs), each run as the gate runs it, `make -C <root> <target> [VAR=val...]`, admitted to the
#   machine-wide pool for its cost (bin/_slot_lib.sh), with TIER_BUDGET_ENFORCE=1 so a tier's own
#   budget is held. Per job, one verdict:
#     ok         passed within its tier budget and GATE_JOB_BUDGET_MINUTES (default 5)
#     over       a `TIER <tier> OVERBUDGET` line, or past the job budget (tests passed or not)
#     fail       the job failed for another reason: on main, which the watch names but does not
#                judge (the next gate will)
#     contended  the 1-minute load, less this job's own, was over the box's capacity at its start
#                or end (bin/_load_lib.sh), or a tier in it ran on a stretched budget (its line
#                says `×<n>`): no timing verdict; the night was not idle
#   A job runs at most 3x its job budget (SAFETY_SECS, an hour when GATE_JOB_BUDGET_MINUTES=0
#   disables the job budget), then its whole process group is stopped and it counts as over. A
#   shifted tier's OVERBUDGET is tier_guard's report-only one (its unshifted twin holds the budget)
#   and never counts. The plan's gate_cleanup (images, containers) runs after the last job, and on
#   any exit, bounded as local_gate.sh bounds it.
# Ledger: one tab-separated row per job, appended to <state-dir>/<owner>__<repo>.tsv:
#   `<utc> <main sha> <job> <seconds> <budget seconds> <verdict>`.
# Issue: one per repo, marked `<!-- devkit-budget-watch -->`, labelled `performance`, opened
#   while any job is over, its table rewritten when it changes, closed with a comment once a run
#   has none. A night with any job contended or failed leaves an open issue as it is (its jobs were
#   not all timed to the end, so neither a recovery nor a new table is shown); it may still open
#   one for a job over. On a night with every job timed, their sum is held to the whole-gate
#   budget local_gate.sh computes (GATE_BUDGET_MINUTES raised by the jobs' typical seconds), as
#   a `total` row.
#   --dry-run runs the jobs and writes no ledger row and no issue.
# Output: exactly one line on stdout for the nightly's log,
#   `budgets: <slug> <n> jobs: <k> over (<job> <s>s > <b>s, ...)[, <c> contended][, <f> failed]`,
#   or `budgets: <slug> unmeasured (<why>)`. Job output goes to <state-dir>/logs/<repo>/<job>.log.
# Exit 0 when it printed its line, 2 on usage.
# shellcheck disable=SC2329,SC2317  # the plan stubs in plan_jobs are called by the sourced plan
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_load_lib.sh
. "$HERE/_load_lib.sh"
# shellcheck source=bin/_slot_lib.sh
. "$HERE/_slot_lib.sh"
# shellcheck source=bin/_timeout_lib.sh
. "$HERE/_timeout_lib.sh"
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"
# shellcheck source=/dev/null  # bin/toolchain_path.sh: toolchain_path, the gate's and the hooks'
. "$HERE/toolchain_path.sh"

readonly MARKER='<!-- devkit-budget-watch -->'
usage() { echo "usage: budget_watch.sh --slug <owner/repo> --root <main worktree> --state-dir <dir> [--dry-run]" >&2; exit 2; }

SLUG="" ROOT="" STATE_DIR="" DRY_RUN=0
parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --slug) SLUG=${2:-}; shift ;;
      --root) ROOT=${2:-}; shift ;;
      --state-dir) STATE_DIR=${2:-}; shift ;;
      --dry-run) DRY_RUN=1 ;;
      *) usage ;;
    esac
    shift
  done
  [[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [ -d "$ROOT" ] && [ -n "$STATE_DIR" ] || usage
}

unmeasured() { echo "budgets: $SLUG unmeasured ($1)"; exit 0; }

# minutes_secs <VAR> <default minutes>: whole seconds, or 1 on a value that is no number.
minutes_secs() {
  awk -v m="${!1:-$2}" 'BEGIN { if (m !~ /^[0-9]+(\.[0-9]+)?$/) exit 1; print int(m * 60 + 0.5) }'
}

# load_settings: the budgets (gate.env's, as the gate reads them), the safety bound, the pool and
# main's toolchain, as the gate runs its jobs: pins first on PATH, no make variables leaking in.
load_settings() {
  gate_env_load budget_watch "GATE_CAPACITY|GATE_JOB_BUDGET_MINUTES|GATE_BUDGET_MINUTES" "$GATE_LOCAL_KEYS|$GATE_REMOTE_KEYS"
  GATE_BUDGET_SECS=$(minutes_secs GATE_BUDGET_MINUTES 10) || unmeasured "GATE_BUDGET_MINUTES must be a number of minutes"
  JOB_BUDGET_SECS=$(minutes_secs GATE_JOB_BUDGET_MINUTES 5) || unmeasured "GATE_JOB_BUDGET_MINUTES must be a number of minutes"
  SAFETY_SECS=$((3 * JOB_BUDGET_SECS))
  [ "$JOB_BUDGET_SECS" -gt 0 ] || SAFETY_SECS=3600
  readonly GATE_BUDGET_SECS JOB_BUDGET_SECS SAFETY_SECS
  [ -f "$ROOT/scripts/ci/gate_plan.sh" ] || unmeasured "no scripts/ci/gate_plan.sh on main"
  slot_pool_init budget_watch
  toolchain_path "$ROOT" >/dev/null 2>&1 || unmeasured "main's declared toolchain: ${TOOLCHAIN_ERROR:-unavailable}"
  unset MAKEFLAGS MFLAGS MAKELEVEL
}

# plan_jobs: one `<name> <target> [VAR=val...]` line per job the plan runs for a change touching
# every tracked path, then `costs <GATE_JOB_COSTS>`. In a subshell: the plan's own variables and
# functions stay there.
plan_jobs() (
  # shellcheck disable=SC2034  # read by the sourced plan and _paths_lib.sh
  PR=0 WT=$ROOT HEAD_SHA="" MAIN_SHA="" LOGDIR=""
  CHANGED=$(git -C "$ROOT" ls-files) || exit 1
  job() { echo "$*"; }
  skip() { :; }
  note() { :; }
  changed() { return 0; }
  pr_has_label() { return 1; }
  nothing_to_run() { exit 0; }
  # shellcheck source=bin/_paths_lib.sh
  . "$HERE/_paths_lib.sh"
  devkit_gate_areas "$CHANGED"
  # shellcheck source=/dev/null  # the repo's plan
  GATE_JOB_COSTS=""
  . "$ROOT/scripts/ci/gate_plan.sh" || exit 1
  gate_plan
  echo "costs ${GATE_JOB_COSTS:-}"
  echo "state ${GATE_STATE_NAME:-}"
)

# idle_now: true while the 1-minute load, less <own> running units, is within the box's capacity.
idle_now() { # <own>
  local l1 cap
  read -r l1 _ <<<"$(devkit_loadavg)"
  cap=$(devkit_cpu_capacity)
  [ -n "$l1" ] && [ -n "$cap" ] || return 0
  awk -v l="$l1" -v o="$1" -v c="$cap" 'BEGIN { exit !(l - o <= c) }'
}

# stop_group <pgid>: TERM the job's whole process group, KILL what is left after 10 s. Stopping
# make and its direct children alone left deeper test workers running outside the pool (Codex,
# devkit #278).
stop_group() {
  local deadline=$((SECONDS + 10))
  kill -TERM -- "-$1" 2>/dev/null
  while kill -0 -- "-$1" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  kill -KILL -- "-$1" 2>/dev/null
}

# tier_over <log>: true when a tier in <log> went over its enforced budget. A shifted tier's
# OVERBUDGET line is followed by its `not enforced (shifted…)` line, and is not one.
tier_over() {
  awk '/^TIER [^ ]+ OVERBUDGET / { over[$2] = 1 }
       /^TIER [^ ]+: over budget, not enforced \(shifted/ { t = $2; sub(/:$/, "", t); delete over[t] }
       END { for (t in over) found = 1; exit !found }' "$1"
}

# run_job <name> <target> [VAR=val...]: sets SECS and VERDICT (header, Jobs).
run_job() {
  local name=$1 cost t0 rc idle=1 log pid timed_out=0
  shift
  log=$LOGS/$name.log
  cost=$(slot_cost "$name" "$1")
  slot_acquire "budgets:" "${SLUG#*/}:budget-watch $name" "$cost" >/dev/null
  idle_now 0 || idle=0
  t0=$SECONDS
  # Its own process group (set -m), so a timeout stops every descendant before the units go back.
  set -m
  DEVKIT_SLOT_HOLDER=$$ TIER_BUDGET_ENFORCE=1 make -C "$ROOT" --no-print-directory "$@" </dev/null >"$log" 2>&1 &
  pid=$!
  set +m
  JOB_PGID=$pid
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - t0)) -ge "$SAFETY_SECS" ]; then
      stop_group "$pid"
      timed_out=1
      break
    fi
    sleep 0.2
  done
  wait "$pid"
  rc=$?
  JOB_PGID=""
  SECS=$((SECONDS - t0))
  idle_now "$cost" || idle=0
  slot_release
  # A tier whose budget tier_guard stretched (its line says `×<n>`, the load or other holders) was
  # not judged against its own budget: no timing verdict, as on a busy box (Codex, #278).
  if [ "$idle" = 0 ] || grep -qE '^TIER [^ ]+(:| OVERBUDGET| FAIL).*×[0-9]' "$log"; then
    VERDICT=contended
  elif [ "$timed_out" = 1 ] || { [ "$JOB_BUDGET_SECS" -gt 0 ] && [ "$SECS" -gt "$JOB_BUDGET_SECS" ]; } || tier_over "$log"; then
    VERDICT=over
  elif [ "$rc" != 0 ]; then
    VERDICT=fail
  else
    VERDICT=ok
  fi
}

# issue_sync <body|""> <contended>: the one open marked issue made to say <body>, or closed when it
# is empty; with any job contended an open issue is left as it is (header, Issue).
issue_sync() {
  local number current
  number=$(gh issue list --repo "$SLUG" --state open --search "\"devkit-budget-watch\" in:body" \
    --json number,body --jq "[.[] | select(.body | contains(\"$MARKER\"))][0].number // empty") || return 1
  # Not every job timed: an open issue keeps what the last fully timed night said.
  [ -z "$number" ] || [ "$2" = 0 ] || return 0
  if [ -z "$1" ]; then
    [ -z "$number" ] || gh issue close "$number" --repo "$SLUG" \
      --comment "Every job is within its budget on main $(git -C "$ROOT" rev-parse --short HEAD) (nightly budget watch)." >/dev/null
    return
  fi
  if [ -z "$number" ]; then
    gh label create performance --repo "$SLUG" --color FBCA04 --description "A time budget the nightly watch saw exceeded" >/dev/null 2>&1
    gh issue create --repo "$SLUG" --title "Over its time budget on an idle box (nightly budget watch)" \
      --label performance --body "$1" >/dev/null
    return
  fi
  current=$(gh issue view "$number" --repo "$SLUG" --json body --jq .body) || return 1
  [ "$current" = "$1" ] || gh issue edit "$number" --repo "$SLUG" --body "$1" >/dev/null
}

# plan_cleanup: the plan's gate_cleanup, if it defines one, with the plan sourced as in plan_jobs,
# bounded as local_gate.sh bounds it (a hung docker daemon). Its output is the cleanup's own log.
plan_cleanup() {
  # shellcheck disable=SC2016  # expanded by the inner bash, from its own arguments
  devkit_with_timeout 120 bash -c '
    PR=0 WT=$1 HEAD_SHA="" MAIN_SHA="" LOGDIR=""
    job() { :; }; skip() { :; }; note() { :; }; changed() { return 0; }; pr_has_label() { return 1; }
    nothing_to_run() { :; }
    . "$2/_paths_lib.sh" && . "$1/scripts/ci/gate_plan.sh" || exit 0
    if declare -F gate_cleanup >/dev/null; then gate_cleanup; fi
  ' plan_cleanup "$ROOT" "$HERE" >>"$LOGS/cleanup.log" 2>&1
}

# on_exit: stop a running job's group, give its units back, then the plan's cleanup.
JOB_PGID=""
on_exit() {
  [ -z "$JOB_PGID" ] || stop_group "$JOB_PGID"
  slot_release
  [ -z "${LOGS:-}" ] || plan_cleanup
}

# load_jobs: JOBS, the plan's GATE_JOB_COSTS and the costs this repo's gates measured
# (SLOT_MEASURED_COSTS, as local_gate.sh reads them, so a wide job is admitted at its width), the
# log dir, main's sha and the ledger.
load_jobs() {
  JOBS=$(plan_jobs) || unmeasured "the gate plan did not load (stderr above)"
  GATE_JOB_COSTS=$(sed -n 's/^costs //p' <<<"$JOBS" | tail -n 1)
  STATE_NAME=$(sed -n 's/^state //p' <<<"$JOBS" | tail -n 1)
  slot_costs_check budget_watch
  [ -z "$STATE_NAME" ] || slot_measured_costs budget_watch "${XDG_STATE_HOME:-$HOME/.local/state}/$STATE_NAME/job-costs"
  JOBS=$(grep -vE '^(costs|state) ' <<<"$JOBS")
  [ -n "$JOBS" ] || unmeasured "the gate plan runs no job"
  LOGS=$STATE_DIR/logs/${SLUG#*/}
  mkdir -p "$LOGS" || unmeasured "cannot create $LOGS"
  MAIN=$(git -C "$ROOT" rev-parse HEAD) || unmeasured "no HEAD in $ROOT"
  LEDGER=$STATE_DIR/${SLUG%%/*}__${SLUG#*/}.tsv
}

# whole_budget_secs <job>...: the whole-gate budget local_gate.sh's whole_budget gives these jobs:
# GATE_BUDGET_MINUTES as the floor, raised to the sum of twice each job's typical seconds (capped
# at the job budget; the job budget itself with no typical yet), from this repo's gate records on
# this box. The floor alone when the records cannot be read.
whole_budget_secs() {
  local sum=0 name typ c typicals
  typicals=$("$DEVKIT_PYTHON" -I "$HERE/gate_record.py" typical \
    --logs "${XDG_STATE_HOME:-$HOME/.local/state}/$STATE_NAME/logs" "$@" 2>/dev/null) || { echo "$GATE_BUDGET_SECS"; return; }
  while read -r name typ; do
    [ -n "$name" ] || continue
    if [ "$typ" = - ]; then c=$JOB_BUDGET_SECS; else c=$((2 * typ)); fi
    [ "$JOB_BUDGET_SECS" = 0 ] || [ "$c" -le "$JOB_BUDGET_SECS" ] || c=$JOB_BUDGET_SECS
    sum=$((sum + c))
  done <<<"$typicals"
  if [ "$sum" -gt "$GATE_BUDGET_SECS" ]; then echo "$sum"; else echo "$GATE_BUDGET_SECS"; fi
}

# ledger_row <job> <seconds> <budget> <verdict>: one ledger line (header, Ledger), none on a dry run.
ledger_row() {
  [ "$DRY_RUN" = 1 ] || printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MAIN" "$@" >>"$LEDGER"
}

# run_jobs: each job of JOBS, counted into n, total, names, over_n/over/rows, contended, failed.
n=0 over="" over_n=0 contended=0 failed=0 rows="" total=0 names=""
run_jobs() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086  # a job line is the plan's words: <name> <target> [VAR=val...]
    set -- $line
    run_job "$@"
    n=$((n + 1)) total=$((total + SECS)) names="$names $1"
    case $VERDICT in
      over) over_n=$((over_n + 1)); over="${over:+$over, }$1 ${SECS}s > ${JOB_BUDGET_SECS}s"
        rows="$rows| \`$1\` | ${SECS} s | $LOGS/$1.log |"$'\n' ;;
      contended) contended=$((contended + 1)) ;;
      fail) failed=$((failed + 1)) ;;
    esac
    ledger_row "$1" "$SECS" "$JOB_BUDGET_SECS" "$VERDICT"
  done <<<"$JOBS"
}

# judge_total: the whole gate, judged only on a night every job was timed to the end (none
# contended or failed): per-job budgets alone let four jobs each grow under 300 s past the 600 s
# total (Codex, #278).
judge_total() {
  local whole
  [ "$contended" = 0 ] && [ "$failed" = 0 ] && [ "$GATE_BUDGET_SECS" -gt 0 ] || return 0
  devkit_python 2>/dev/null || return 0
  # shellcheck disable=SC2086  # one argument per job name
  whole=$(whole_budget_secs $names)
  [ "$total" -gt "$whole" ] || return 0
  over_n=$((over_n + 1)) over="${over:+$over, }total ${total}s > ${whole}s"
  rows="$rows| whole gate | ${total} s (budget ${whole} s) | the jobs above |"$'\n'
  ledger_row total "$total" "$whole" over
}

# report: the one summary line, and the issue made to match (header, Issue).
report() {
  local summary body=""
  summary="budgets: $SLUG $n jobs: $over_n over${over:+ ($over)}"
  [ "$contended" = 0 ] || summary="$summary, $contended contended"
  [ "$failed" = 0 ] || summary="$summary, $failed failed"
  if [ "$DRY_RUN" = 1 ] || { [ $((contended + failed)) != 0 ] && [ "$over_n" = 0 ]; }; then
    echo "$summary"
    return
  fi
  [ "$over_n" = 0 ] || body="$MARKER
On an idle box, main $(git -C "$ROOT" rev-parse --short HEAD) ran these gate jobs past their time budget (a tier's own, or the ${JOB_BUDGET_SECS} s job budget). Gates report budgets and never fail on them (devkit decisions 2026-10-29), so this issue is where a real slowdown shows. Find the new cost and cut it, or move it down a tier.

| Job | Seconds | Log (on the nightly's host) |
|---|---|---|
$rows"
  # A failed job, like a contended one, was not timed to the end: neither is a recovery.
  issue_sync "$body" $((contended + failed)) || summary="$summary; the issue could not be updated (gh above)"
  echo "$summary"
}

parse_args "$@"
load_settings
load_jobs
trap on_exit EXIT
trap 'exit 130' INT TERM
run_jobs
judge_total
report
