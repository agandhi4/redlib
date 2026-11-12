#!/usr/bin/env bash
# Every check of one commit: the jobs its scripts/ci/gate_plan.sh declares for a change touching
# every tracked path, on a clean detached worktree of <sha>, natively on this host, one log each,
# one verdict. publish.sh runs it on the commit it is about to publish (there is no pre-merge gate,
# devkit decisions 2026-11-02): this is where main is proven.
#
# Usage: devkit/bin/check_tree.sh <sha> [--repo <checkout>] [--base <commit>] [--log-dir <dir>]
#   <sha>       any commit of the repo; never the working tree (uncommitted edits never run)
#   --base      what change-aware checks compare against (default <sha>'s first parent; publish.sh
#               passes the deployed commit): exported as MIGRATION_BASE, so migration_check.py
#               judges <base>..<sha>, not origin/main against itself (an empty diff on main)
#   --repo      the checkout holding it (default: the one the current directory is in)
#   --log-dir   where each job's log goes (default <repo>/build/check/<sha7>; *.log cleared first)
#
# The plan contract is the one bin/_paths_lib.sh documents (gate_plan(), gate_cleanup(),
# GATE_JOBS_<GROUP>, GATE_DOCKER_GROUPS) with the same helpers (job, skip, note, changed,
# pr_has_label, require_docker, nothing_to_run), so no repo's plan changes. Here: $PR is
# check-<pid>, $WT and $ROOT the worktree, $CHANGED every tracked path, $HEAD_SHA and $MAIN_SHA
# both <sha>, and pr_has_label <label> is true when a PR merged in <base>..<sha> (first parent;
# <sha> alone with no base) carries it, so an approved `api-breaking` or `migration-contract`
# merge is checked as its PR would have been. Fail closed: a gh error or no GATE_SLUG means no
# label (one line on stderr), and the check runs strict.
#
# What fails the check, and what only reports (owner 2026-11-02: "ratchets should file issues,
# not block deploys"):
#   - A failed job is run once more. Passing on the retry, it counts as a pass and files one
#     `flaky` issue titled `flaky: <job>: <first failing test line of the first run>`.
#   - The plan's GATE_JOBS_METRICS jobs (the ratchet) never fail it: a failure prints REPORTED
#     and files one `ratchet` issue per job. They run with METRICS_BETTER_OK=1, as on any main.
#   - Time budgets never fail it (tier_guard.sh reports OVERBUDGET; TIER_BUDGET_ENFORCE is
#     unset here). A hung job does: each run of a job is stopped after CHECK_JOB_SECONDS (default
#     1800, whole seconds), with every process under it, and is a FAIL naming it, not retried (devkit
#     decisions 2026-11-02).
#   - The box, not the commit: a job failing its run and its retry with a cause in ENV_CAUSES
#     (no disk, no network, no docker daemon, a build script's host tool such as cmake) stops the check with exit 2 and no verdict, as a
#     plan's require_docker does before its first Docker job, so publish.sh never calls it red.
#   Issues go to the plan's GATE_SLUG through _issue_lib.sh (deduplicated by title); a gh error
#   is a `CHECK note:` and never changes the verdict.
# Capacity: each job (its run and its retry) is first admitted to the box's pool (bin/_slot_lib.sh,
# GATE_CAPACITY from the environment or gate.env) for its cost, holder `<repo>:<job>`, so two
# repos' checks, or a check beside a lane's tiers, queue instead of overlapping; a tier inside
# the job runs on its units. Waiting prints `CHECK waiting for capacity: …`. Inside a holder
# (DEVKIT_SLOT_HOLDER live) it asks for nothing.
#
# Output contract (an API: publish.sh keeps it as the main-red issue's evidence):
#   CHECK <job> PASS (<n>s)
#   CHECK <job> PASS on retry (<n>s; first run's log: <path>)     then the flaky issue's line
#   CHECK <job> FAIL ([[retry ]timed out after <n>s; ]<n>s; log: <path>)  then its last 15 lines
#   CHECK <job> REPORTED (<n>s; log: <path>)                      a ratchet job's failure
#   CHECK plan FAIL (<why>)                                       the commit's plan is broken
#   CHECK toolchain FAIL (<why>)    the commit's own toolchain pin is invalid (toolchain_path's 3)
#   CHECK <job> SKIPPED (<reason>), CHECK note: <text>, CHECK areas: <areas>
#   CHECK docker|toolchain ERROR (<why>)   the box, not the commit: exit 2, no verdict, so
#                                           publish.sh never calls the commit red for it
#   CHECK <job> ERROR (<cause>, the box, not the commit; log: <path>)  likewise, ENV_CAUSES
#   CHECK VERDICT PASS|FAIL head=<sha>[ failed=<job>,<job>]
# Job seconds go to $WT/build/metrics/gate.json (`gate.<job>.seconds`), rewritten after every
# job, for a plan's `job:<name>` metrics collector (bin/metrics_collect.sh).
# Exit: 0 pass, 1 fail (a job, or the commit's plan: none, no gate_plan(), a bad job name:
# `CHECK plan FAIL (<why>)`; or its toolchain pin: `CHECK toolchain FAIL (<why>)`), 2 usage or environment (no such commit, a missing tool, no Docker
# for a plan that needs it, a toolchain the box cannot provide, an ENV_CAUSES failure).
# shellcheck disable=SC2329,SC2317  # helpers are called by the sourced plan and the EXIT trap
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/toolchain_path.sh  # toolchain_path; brings devkit_preflight
. "$HERE/toolchain_path.sh"
# shellcheck source=bin/_paths_lib.sh  # devkit_gate_areas, devkit_default_gate_plan for the plan
. "$HERE/_paths_lib.sh"
# shellcheck source=bin/_timeout_lib.sh  # devkit_docker_ensure, devkit_with_timeout, devkit_timeout_stop
. "$HERE/_timeout_lib.sh"
# shellcheck source=bin/_load_lib.sh  # devkit_now
. "$HERE/_load_lib.sh"
# shellcheck source=bin/_gate_env.sh  # gate_plan_literal
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_issue_lib.sh  # devkit_issue_file
. "$HERE/_issue_lib.sh"
# shellcheck source=bin/_slot_lib.sh  # slot_pool_init, slot_cost, slot_acquire, slot_release
. "$HERE/_slot_lib.sh"

usage() { echo "usage: $0 <sha> [--repo <checkout>] [--base <commit>] [--log-dir <dir>]"; }
die() { echo "check_tree: $*" >&2; exit 2; }
SHA_ARG='' REPO=. LOGDIR='' BASE_ARG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--log-dir|--base)
      [ $# -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }
      case "$1" in --repo) REPO=$2 ;; --base) BASE_ARG=$2 ;; *) LOGDIR=$2 ;; esac
      shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$SHA_ARG" ] || { usage >&2; exit 2; }; SHA_ARG=$1 ;;
  esac
  shift
done
[ -n "$SHA_ARG" ] || { usage >&2; exit 2; }
REPO=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || die "$REPO is not a git checkout"
HEAD_SHA=$(git -C "$REPO" rev-parse --verify -q "$SHA_ARG^{commit}") || die "$SHA_ARG is no commit of $REPO"
# A root commit has no parent: MIGRATION_BASE stays unset and migration_check.py says so.
if [ -n "$BASE_ARG" ]; then
  MIGRATION_BASE=$(git -C "$REPO" rev-parse --verify -q "$BASE_ARG^{commit}") || die "--base $BASE_ARG is no commit of $REPO"
  export MIGRATION_BASE
elif MIGRATION_BASE=$(git -C "$REPO" rev-parse --verify -q "$HEAD_SHA^1"); then
  export MIGRATION_BASE
else
  unset MIGRATION_BASE
fi
LOGDIR=${LOGDIR:-$REPO/build/check/${HEAD_SHA:0:7}}
case "$LOGDIR" in /*) ;; *) LOGDIR=$PWD/$LOGDIR ;; esac
readonly CLEANUP_SECS=${GATE_CLEANUP_SECONDS:-120} JOB_SECS=${CHECK_JOB_SECONDS:-1800}
[[ "$CLEANUP_SECS" =~ ^[1-9][0-9]*$ ]] || die "GATE_CLEANUP_SECONDS must be a whole number >= 1 (got '$CLEANUP_SECS')"
[[ "$JOB_SECS" =~ ^[1-9][0-9]*$ ]] || die "CHECK_JOB_SECONDS must be a whole number >= 1 (got '$JOB_SECS')"
mkdir -p "$LOGDIR" || die "cannot create $LOGDIR"
rm -f "$LOGDIR"/*.log
# The jobs run as from a clean shell: a caller's make would leak its variables through MAKEFLAGS.
unset MAKEFLAGS MFLAGS MAKELEVEL TIER_BUDGET_ENFORCE GATE_BUDGET_ENFORCE

# A clean tree: the worktree's own dir, never the checkout (its edits, its build/ outputs).
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/check_tree.XXXXXX") || die "mktemp failed"
WT=$SCRATCH/tree
remove_tree() {
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$SCRATCH"
  git -C "$REPO" worktree prune >/dev/null 2>&1
}
trap remove_tree EXIT
git -C "$REPO" worktree add -q --detach "$WT" "$HEAD_SHA" 2>"$SCRATCH/wt.err" \
  || die "git worktree add at ${HEAD_SHA:0:7} failed: $(tr '\n' ' ' <"$SCRATCH/wt.err")"
# The tree's declared tools too (uv for a uv.lock): a box missing one is exit 2, never a red commit.
devkit_preflight git make gh pkill -- "$WT" || die "$DEVKIT_PREFLIGHT_ERROR"

verdict() { # <PASS|FAIL>; ends the run
  echo "CHECK VERDICT $1 head=$HEAD_SHA${FAILED_JOBS:+ failed=$FAILED_JOBS}"
  if [ "$1" = PASS ]; then exit 0; else exit 1; fi
}
# The commit broke its own plan: red like a failing job, never exit 2 (that is the box's).
bad_plan() { echo "CHECK plan FAIL ($*)"; FAILED_JOBS=plan; verdict FAIL; }
PLAN=$WT/scripts/ci/gate_plan.sh
[ -f "$PLAN" ] || bad_plan "${HEAD_SHA:0:7} has no scripts/ci/gate_plan.sh"
SLUG=$(gate_plan_literal "$PLAN" GATE_SLUG)

# shellcheck disable=SC2034  # $PR, $ROOT, $MAIN_SHA and $CHANGED are the plan's (header)
PR=check-$$ ROOT=$WT MAIN_SHA=$HEAD_SHA
CHANGED=$(git -C "$WT" ls-files) || exit 2
FAILED_JOBS='' JOB_SECONDS='' REPORT_ONLY=''
export METRICS_BETTER_OK=1

write_gate_metrics() { # names were validated by job(), so no JSON escaping applies
  local name secs sep='' body=''
  while read -r name secs; do
    [ -n "$name" ] || continue
    body="$body$sep  \"gate.$name.seconds\": $secs"
    sep=$',\n'
  done <<<"$JOB_SECONDS"
  mkdir -p "$WT/build/metrics" && printf '{\n%s\n}\n' "$body" >"$WT/build/metrics/gate.json"
}

file_issue() { # <label> <title> <body>
  local said
  if [ -z "$SLUG" ]; then note "no literal GATE_SLUG in the plan; no $1 issue filed: $2"; return; fi
  said=$(devkit_issue_file "$SLUG" "$1" "$2" "$3") || said="gh failed (above); not filed: $2"
  note "$1 issue: $said"
}

# run_make <log> <target> [VAR=val...]: one attempt, 124 when stopped at JOB_SECS: make and every
# process under it, so nothing of it runs on into the next job or the worktree's removal (#311). 7>&-: publish.sh's lock stays with it, so a job's
# leftover descendant never holds the next publish.
_make_once() { local log=$1; shift; make -C "$WT" --no-print-directory "$@" </dev/null >"$log" 2>&1 7>&-; }
run_make() { devkit_with_timeout "$JOB_SECS" _make_once "$@"; }

# The one list of failures that are the box's, not the commit's: "<cause>: <ERE>" per line,
# matched against the retry's log. Gotcha: a test that asserts one of these messages and fails
# reads as the box too; the check then stays exit 2 run after run, which the publisher's
# dead-man (publisher_deadman.sh) reports within hours, so keep each ERE an OS or daemon message,
# or a build script's own report that the box lacks a host program or library (cmake-rs, cc-rs,
# clang-sys, pkg-config-rs; uv's hint when an sdist's C build lacks a header): never a shell's
# `command not found`, which a recipe's typo also prints.
# uv wraps its hint at 80 columns, so its ERE is the hint's first words only. Gotcha: uv hints the
# same for a repo's own C extension (`<name>@<version>` either way), so a header missing from the
# repo's source reads as the box too; no fleet repo builds one (2026-11-05, devkit #403).
# shellcheck disable=SC2016  # the backticks are cmake-rs's literal text, not a substitution
readonly ENV_CAUSES='disk full: No space left on device|Disk quota exceeded
a host build tool missing: [Ii]s `[^`]+` (not )?installed\?|[Ff]ailed to find tool|Unable to find libclang|The pkg-config command could not be found|This error likely indicates that you need to install
docker unreachable: Cannot connect to the Docker daemon|error during connect:|docker daemon is not reachable|docker daemon did not answer
no network: Could not resolve host|Temporary failure in name resolution|Network is unreachable|getaddrinfo (ENOTFOUND|EAI_AGAIN)'
env_cause() { # <log>: prints the cause and exits 0 when the log shows one
  local cause ere
  while IFS= read -r cause; do
    ere=${cause#*: }
    grep -qE -- "$ere" "$1" && { echo "${cause%%: *}"; return 0; }
  done <<<"$ENV_CAUSES"
  return 1
}

# The first line of a log that names a failed test (bats, pytest, cargo, vitest, go), else "".
first_failure() {
  grep -m 1 -E '^(not ok [0-9]+ |FAILED |FAIL |--- FAIL|test .* \.\.\. FAILED| *(×|✗) )' "$1" \
    | sed -e 's/[[:space:]]*$//' | cut -c1-150
}

# ---- helpers for gate_plan ---------------------------------------------------------------
job() { # <name> <make target> [VAR=val...]
  local name=$1 t0 log=$LOGDIR/$1.log test cause rc=0
  shift
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] && [ "$name" != total ] \
    || bad_plan "job name '$name' must match [A-Za-z0-9_-]+ and not be 'total' (it becomes the key gate.<name>.seconds)"
  admit "$name" "$1"
  t0=$(devkit_now)
  run_make "$log" "$@" || rc=$?
  if [ "$rc" = 0 ]; then
    echo "CHECK $name PASS ($(($(devkit_now) - t0))s)"
  elif [ "$rc" = 124 ]; then
    # Before REPORT_ONLY: a hung ratchet is a hang, not a metric (devkit #355). Not retried: a
    # second hang would hold the publisher another JOB_SECS.
    job_failed "$name" "$t0" "$log" "timed out after ${JOB_SECS}s; "
  elif case " $REPORT_ONLY " in *" $name "*) true ;; *) false ;; esac; then
    # A ratchet is not retried: a metric does not flake, and the issue is the whole outcome.
    echo "CHECK $name REPORTED ($(($(devkit_now) - t0))s; log: $log)"
    file_issue ratchet "ratchet: $name fails on main" "check_tree.sh at ${HEAD_SHA:0:7}: \`make $*\` failed. A ratchet reports on main and never blocks a deploy (devkit decisions 2026-11-02); fix the regression or rebaseline.

\`\`\`
$(tail -n 30 "$log")
\`\`\`"
  else
    mv "$log" "$LOGDIR/$name.first.log"
    rc=0
    run_make "$log" "$@" || rc=$?
    if [ "$rc" = 0 ]; then
      test=$(first_failure "$LOGDIR/$name.first.log")
      echo "CHECK $name PASS on retry ($(($(devkit_now) - t0))s; first run's log: $LOGDIR/$name.first.log)"
      file_issue flaky "flaky: $name: ${test:-no test named in its log}" "check_tree.sh at ${HEAD_SHA:0:7}: \`make $*\` failed, then passed when rerun; counted as a pass.

\`\`\`
$(tail -n 30 "$LOGDIR/$name.first.log")
\`\`\`"
    elif [ "$rc" != 124 ] && cause=$(env_cause "$log"); then
      echo "CHECK $name ERROR ($cause, the box, not the commit; log: $log)"
      tail -n 15 "$log" | sed 's/^/    /'
      exit 2
    else
      job_failed "$name" "$t0" "$log" "$([ "$rc" != 124 ] || echo "retry timed out after ${JOB_SECS}s; ")"
    fi
  fi
  slot_release
  JOB_SECONDS=$(grep -v "^$name " <<<"$JOB_SECONDS"; echo "$name $(($(devkit_now) - t0))")
  write_gate_metrics
}
# admit <name> <target>: the job's units, before its clock starts (header, Capacity).
admit() {
  [ "$IN_HOLDER" = 0 ] || return 0
  slot_acquire CHECK "${SLUG#*/}:$1" "$(slot_cost "$1" "$2")" || exit 2
  # The holder for a tier the job runs (it asks for nothing again).
  export DEVKIT_SLOT_HOLDER=$$
}
job_failed() { # <name> <t0> <log> <why prefix>
  echo "CHECK $1 FAIL ($4$(($(devkit_now) - $2))s; log: $3)"
  tail -n 15 "$3" | sed 's/^/    /'
  FAILED_JOBS="${FAILED_JOBS:+$FAILED_JOBS,}$1"
}
skip() { echo "CHECK $1 SKIPPED ($2)"; }
note() { echo "CHECK note: $*"; }
changed() { grep -qE "$1" <<<"$CHANGED"; }
# Called inside $(...) too (_devkit_quick_jobs), so it prints nothing on stdout.
pr_has_label() { # <label>
  local c labels range=("$HEAD_SHA" --max-count=1)
  [ -n "$SLUG" ] || return 1
  [ -z "${MIGRATION_BASE:-}" ] || range=("$MIGRATION_BASE..$HEAD_SHA")
  for c in $(git -C "$REPO" rev-list --first-parent "${range[@]}"); do
    labels=$(gh api "repos/$SLUG/commits/$c/pulls" \
      --jq ".[] | select(.merge_commit_sha == \"$c\") | .labels[].name") \
      || { echo "check_tree: cannot read the PR labels of ${c:0:7} (gh above); no $1 label" >&2; return 1; }
    ! grep -qxF -- "$1" <<<"$labels" || return 0
  done
  return 1
}
nothing_to_run() { echo "CHECK all SKIPPED ($1)"; verdict PASS; }
require_docker() {
  if devkit_docker_ensure check_tree; then
    [ -z "$DEVKIT_DOCKER_NOTE" ] || note "$DEVKIT_DOCKER_NOTE"
    return 0
  fi
  echo "CHECK docker ERROR (needed by $1: $DEVKIT_DOCKER_ERROR)"
  exit 2
}

# The tree's pins first on PATH. A pin the commit got wrong is red like its plan (devkit #321):
# exit 2 would record nothing, so the publisher would stall on it every window instead of filing
# main-red and walking past it.
provide_toolchain() {
  local rc=0
  toolchain_path "$WT" || rc=$?
  case $rc in
    0) ;;
    3) echo "CHECK toolchain FAIL ($TOOLCHAIN_ERROR)"; FAILED_JOBS=toolchain; verdict FAIL ;;
    *) echo "CHECK toolchain ERROR ($TOOLCHAIN_ERROR)"; exit 2 ;;
  esac
  [ -z "$TOOLCHAIN_NOTES" ] || note "$TOOLCHAIN_NOTES"
}

# ---- the tree's toolchain, then the plan decides what runs ----------------------------------
provide_toolchain
# shellcheck disable=SC2034  # read by _paths_lib.sh; the plan's alone, never the environment's
GATE_CODE_PATHS=
unset GATE_DOCKER_GROUPS GATE_JOBS_METRICS
# shellcheck source=/dev/null  # the commit's plan; its contract is in the header
. "$PLAN"
declare -F gate_plan >/dev/null || bad_plan "scripts/ci/gate_plan.sh must define gate_plan()"
declare -F gate_cleanup >/dev/null || gate_cleanup() { :; }
# The ratchet's job names, before the default plan appends METRICS_REBASELINE (never, here).
REPORT_ONLY=$(tr '|' '\n' <<<"${GATE_JOBS_METRICS:-}" | awk 'NF { print $1 }' | paste -sd ' ' -)
cleanup() {
  # A TERM to this process alone (not its group) leaves the running job: stop it first.
  devkit_timeout_stop
  slot_release
  # Bounded: a hung docker daemon made a plan's `docker rm -fv` block an EXIT trap for 12+ min
  # (2026-10-17).
  devkit_with_timeout "$CLEANUP_SECS" gate_cleanup >/dev/null 2>&1
  [ $? -ne 124 ] || echo "check_tree: gate_cleanup stopped after ${CLEANUP_SECS}s (a hung docker daemon?); containers may be left: docker ps" >&2
  remove_tree
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# After the plan is sourced: slot_cost reads its GATE_JOB_COSTS. Only GATE_CAPACITY is applied.
gate_env_load check_tree GATE_CAPACITY "$GATE_LOCAL_KEYS|$GATE_REMOTE_KEYS"
slot_pool_init check_tree
IN_HOLDER=0
! slot_held_above || IN_HOLDER=1
devkit_gate_areas "$CHANGED"
echo "CHECK areas: ${GATE_AREAS:-none}"
echo "CHECK tree: ${HEAD_SHA:0:12} of ${SLUG:-$REPO}; logs: $LOGDIR"
gate_plan
if [ -z "$FAILED_JOBS" ]; then verdict PASS; else verdict FAIL; fi
