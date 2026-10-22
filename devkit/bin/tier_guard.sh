#!/usr/bin/env bash
# One test tier under a wall-clock budget and per-runner floors on the number of tests it ran.
# The test-value standard made executable (owner directive 2026-10-13: a fast, lean, useful
# suite): a tier that outgrows its budget fails even when every test passed, and a tier that
# silently stopped running part of its suite fails even when what is left is green.
#
# Usage: devkit/bin/tier_guard.sh <tier> --budget <seconds> [--floor <runner>=<min>]... -- <command...>
#   <tier>     [A-Za-z0-9_-]+, the metrics key's scope (unit, db, e2e, ...)
#   --budget   whole seconds of WALL time for the whole command: dependency syncs, container
#              start-up and migrations inside it count, so keep one-time setup (browser
#              installs, image builds) outside the guarded command
#   --floor    a runner whose summary the command prints, and the fewest tests it may report
#              as run; repeat for a command that runs several runners (pytest then vitest)
#
# Output (an API, like local_gate's GATE lines). The command's own output streams through
# unchanged (stderr merged into stdout); a copy is kept only to read the summaries. Then:
#   TIER <tier> FAIL (exit <rc>, <s>s)                   the command failed: exits <rc>
#   TIER <tier> FLOOR <runner> <n> < <min>               ran fewer tests than the floor: exit 1
#   TIER <tier> FLOOR <runner> no summary line (floor <min>)                           exit 1
#   TIER <tier> OVERBUDGET <s>s (budget <b>s)            exit 1, unless TIER_BUDGET_ENFORCE=0
#   TIER <tier>: <s>s (budget <b>s) <runner>=<n>...      every check held: exit 0
# Under load the budget stretches (bin/_load_lib.sh: min(1-minute load / cores, 2), sampled when
# the command starts and when it ends, the larger stretch kept, only above 1.0) and both budget
# lines then read `(budget 110 s ×1.6 (load 2.0 at start, 13.1 at end on 8 cpus) → 176 s)`;
# unloaded at both, they are exactly as above. The command runs with DEVKIT_LOAD_SCALE set to the
# start sample's factor ("1" unscaled), so its runner can stretch its own per-test timeouts
# by the factor its budget got (lint/vitest.base.mjs does, for vitest).
# Slot: outside a gate the tier takes one of the machine-wide gate slots first (bin/_slot_lib.sh,
# GATE_SLOTS from the environment or gate.env, as the gate reads it), holder `<repo>:<tier>`, so
# `make ci-unit` by hand in four worktrees queues instead of piling onto the gates' load
# (2026-10-21). While every slot is held it prints, at once and every 30 s,
#   TIER <tier> waiting for a gate slot (<n> running: <repo>#<pr>, <repo>:<tier>, ...)
# then `TIER <tier> slot <n>/<slots>`. The wait is before the budget clock. Inside a gate (or
# another tier) DEVKIT_SLOT_HOLDER names a live holder and the tier runs on that slot, silently;
# TIER_SLOT=0 (default 1) skips the slot for a deliberately quick single test.
# A bad invocation exits 2 before the command runs. TIER_BUDGET_ENFORCE=0 (default 1) keeps
# the OVERBUDGET line but not the failure, for a repo or box adopting budgets, exactly as
# GATE_BUDGET_ENFORCE does for local_gate's job budgets. Floors have no such switch: a count
# is deterministic, so a floor that fails is a real loss.
#
# Counted = tests that RAN: passed + failed (+ pytest xfailed/xpassed/error, vitest "expected
# fail", Playwright flaky). Skipped, todo and deselected tests do not count, so a tier whose
# tests all skip (finplat's db tier without TEST_DATABASE_URL) fails its floor. Each runner's
# summary lines are summed, so a command may run a runner more than once. The parser table is
# tier_count() below, one rule per runner, each pinned by a real captured summary in
# tests/fixtures/tier_guard/.
#
# Metrics (docs/metrics-keys.md): after a command that passed, <repo root>/build/metrics/
# tier-<tier>.json gets `tier.<tier>.seconds` and `tests.<tier>.<runner>` per floored runner.
# The root is git's top level (the working directory outside a repo), so a tier run from a
# subdirectory (`cd backend && ../devkit/bin/tier_guard.sh ...`) lands where the gate's and the
# ratchet's other collectors do. One file per tier, so ci-unit and ci-db in the
# same gate worktree never overwrite each other and `metrics_ratchet.py merge` sees no clash.
#
# Budgets are set from GATE timings with headroom and only ever go down; floors are the current
# counts and move only in the PR that removes tests, saying why in docs/decisions.md.
set -uo pipefail
# shellcheck source=bin/_load_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_load_lib.sh"
# shellcheck source=bin/_awake_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_awake_lib.sh"
# shellcheck source=bin/_gate_env.sh
. "$(dirname "${BASH_SOURCE[0]}")/_gate_env.sh"
# shellcheck source=bin/_slot_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_slot_lib.sh"

RUNNERS="pytest vitest playwright cargo bats"

usage() {
  echo "usage: $0 <tier> --budget <seconds> [--floor <runner>=<min>]... -- <command...>" >&2
  echo "       runners: $RUNNERS" >&2
  exit 2
}
die() { echo "tier_guard: $*" >&2; exit 2; }

# tier_count <runner>: stdin is the command's ANSI-stripped output; prints the summed count of
# tests that ran, or nothing when no summary line for that runner appeared. The patterns are
# anchored so one runner's summary never matches another's (locus runs pytest then vitest in
# one command): pytest's ends in " in <n>s", vitest's starts with "Tests", Playwright's is
# indented exactly two spaces, cargo's starts with "test result:". bats has no summary in its
# TAP output (what it prints when stdout is no terminal, as here): its plan line `1..<n>` marks
# a run and every `ok`/`not ok` line without `# skip` is a test that ran; its pretty formatter's
# "<n> tests, <f> failures, <s> skipped" line is read too.
tier_count() {
  awk -v runner="$1" '
    { sub(/\r$/, "") }
    runner == "pytest" && /^=* *([0-9]+ [a-z]+|no tests ran).* in [0-9.]+s( \([0-9:]+\))? *=*$/ {
      # "==== 1 failed, 2 passed, 1 skipped, 1 xfailed, 1 xpassed, 1 error in 0.01s ===="
      seen = 1
      line = $0
      gsub(/[=,]/, " ", line)
      n = split(line, w, " ")
      for (i = 1; i < n; i++)
        if (w[i] ~ /^[0-9]+$/ && w[i + 1] ~ /^(passed|failed|xfailed|xpassed|errors?)$/) total += w[i]
      next
    }
    runner == "vitest" && /^[[:space:]]*Tests[[:space:]]+[0-9]+ / {
      # "      Tests  1 failed | 2 passed | 1 expected fail | 1 skipped | 1 todo (6)"
      seen = 1
      line = $0
      sub(/^[[:space:]]*Tests[[:space:]]+/, "", line)
      sub(/[[:space:]]*\([0-9]+\)[[:space:]]*$/, "", line)
      n = split(line, part, "|")
      for (i = 1; i <= n; i++) {
        p = part[i]
        sub(/^[[:space:]]+/, "", p)
        sub(/[[:space:]]+$/, "", p)
        if (p ~ /^[0-9]+ (passed|failed|expected fail)$/) { split(p, w, " "); total += w[1] }
      }
      next
    }
    runner == "playwright" && /^  [0-9]+ (passed|failed|flaky)( \([^)]*\))?$/ {
      # "  1 failed" / "  1 flaky" / "  2 passed (935ms)"; skipped and "did not run" are left out
      seen = 1
      total += $1
      next
    }
    runner == "bats" && /^1\.\.[0-9]+$/ { seen = 1; next }
    runner == "bats" && /^(ok|not ok) [0-9]+( |$)/ {
      # "ok 2 skips # skip not here" ran nothing; "not ok 3 fails" ran and failed
      if ($0 !~ / # [Ss][Kk][Ii][Pp]( |$)/) total += 1
      next
    }
    runner == "bats" && /^[0-9]+ tests?, [0-9]+ failures?/ {
      # "4 tests, 1 failure, 1 skipped" (--formatter pretty)
      seen = 1
      total += $1
      if (match($0, /, [0-9]+ skipped/)) total -= substr($0, RSTART + 2, RLENGTH - 10)
      next
    }
    runner == "cargo" && /^test result: / {
      # one per test binary and the doctests: "test result: ok. 78 passed; 0 failed; 19 ignored; ..."
      seen = 1
      for (i = 2; i <= NF; i++) if ($i ~ /^(passed|failed);?$/) total += $(i - 1)
      next
    }
    END { if (seen) print total + 0 }'
}

# repo_name: the checkout's repo, the same name from any of its worktrees (the common git dir's
# parent); the working directory's name outside a repo.
repo_name() {
  local common
  common=$(env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || common=$PWD/.git
  common=${common%/.git}
  echo "${common##*/}"
}

strip_ansi() {
  sed $'s/\x1b\\[[0-9;?]*[A-Za-z]//g'
}

[ $# -ge 1 ] || usage
TIER=$1
shift
[[ "$TIER" =~ ^[A-Za-z0-9_-]+$ ]] || die "tier '$TIER' must match [A-Za-z0-9_-]+ (it becomes the key tier.<tier>.seconds)"

BUDGET=""
FLOORS=()   # "<runner> <min>" entries, in the order given
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  case "$1" in
    --budget)
      [ $# -ge 2 ] || usage
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--budget must be a positive whole number of seconds (got '$2')"
      BUDGET=$2
      shift 2
      ;;
    --floor)
      [ $# -ge 2 ] || usage
      [[ "$2" =~ ^[a-z]+=[0-9]+$ ]] || die "--floor takes <runner>=<min> (got '$2')"
      runner=${2%%=*}
      case " $RUNNERS " in *" $runner "*) ;; *) die "unknown runner '$runner' (one of: $RUNNERS)" ;; esac
      for f in ${FLOORS[@]+"${FLOORS[@]}"}; do
        [ "${f%% *}" != "$runner" ] || die "--floor $runner given twice"
      done
      FLOORS+=("$runner ${2#*=}")
      shift 2
      ;;
    *) usage ;;
  esac
done
[ $# -ge 2 ] && [ "$1" = "--" ] || usage
shift
[ -n "$BUDGET" ] || die "--budget is required: every tier has one (the test-value standard)"
ENFORCE=${TIER_BUDGET_ENFORCE:-1}
[[ "$ENFORCE" =~ ^[01]$ ]] || die "TIER_BUDGET_ENFORCE must be 0 or 1 (got '$ENFORCE')"
TAKE_SLOT=${TIER_SLOT:-1}
[[ "$TAKE_SLOT" =~ ^[01]$ ]] || die "TIER_SLOT must be 0 or 1 (got '$TAKE_SLOT')"

tmp=${TMPDIR:-/tmp}
LOG=$(mktemp "${tmp%/}/tier-$TIER.XXXXXX") || die "mktemp failed"
trap 'rm -f "$LOG"' EXIT

# A tier's budget is wall time; a nap mid-run would read as test time (bin/_awake_lib.sh).
devkit_stay_awake
if [ "$TAKE_SLOT" = 1 ] && ! slot_held_above; then
  # Only GATE_SLOTS is read from gate.env; the gate's other keys are its own.
  gate_env_load tier_guard GATE_SLOTS "$GATE_LOCAL_KEYS|$GATE_REMOTE_KEYS"
  slot_pool_init tier_guard
  slot_acquire "TIER $TIER" "$(repo_name):$TIER"
  echo "TIER $TIER slot $SLOT/$SLOTS"
fi
devkit_load_scale "$BUDGET"
start=$SECONDS
# 9>&- on both sides of the pipe: the slot's fd stays with this process alone, so a stray
# background child of the command cannot hold the slot after the tier ends (bin/_slot_lib.sh).
DEVKIT_LOAD_SCALE=$LOAD_SCALE "$@" 9>&- 2>&1 | tee "$LOG" 9>&-
rc=${PIPESTATUS[0]}
secs=$((SECONDS - start))
devkit_load_rescale
budget_text="budget ${BUDGET}s"
[ -z "$LOAD_NOTE" ] || budget_text=$LOAD_NOTE

if [ "$rc" -ne 0 ]; then
  echo "TIER $TIER FAIL (exit $rc, ${secs}s)"
  exit "$rc"
fi

failed=0
counts=""   # " <runner>=<n>" for the success line
metrics="  \"tier.$TIER.seconds\": $secs"
stripped=$(strip_ansi <"$LOG")
for f in ${FLOORS[@]+"${FLOORS[@]}"}; do
  runner=${f%% *}
  min=${f#* }
  n=$(printf '%s\n' "$stripped" | tier_count "$runner")
  if [ -z "$n" ]; then
    echo "TIER $TIER FLOOR $runner no summary line (floor $min)"
    echo "tier_guard: $runner printed no summary: it did not run, or a reporter replaced its default one (keep the default reporter alongside json)" >&2
    failed=1
    continue
  fi
  metrics="$metrics,"$'\n'"  \"tests.$TIER.$runner\": $n"
  counts="$counts $runner=$n"
  if [ "$n" -lt "$min" ]; then
    echo "TIER $TIER FLOOR $runner $n < $min"
    echo "tier_guard: a test file, marker or glob stopped being picked up, or tests now skip; lower a floor only in the PR that removes tests" >&2
    failed=1
  fi
done

# Inside a git hook GIT_DIR (and sometimes GIT_WORK_TREE) is exported, which makes rev-parse
# report the current directory as the top level: a tier run after `cd backend` would then write
# backend/build/metrics/ (Orbit #59). Drop both so the lookup answers for the real checkout.
root=$(env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
out=$root/build/metrics/tier-$TIER.json
if ! { mkdir -p "${out%/*}" && printf '{\n%s\n}\n' "$metrics" >"$out"; }; then
  die "could not write $out"
fi

if [ "$secs" -gt "$LOAD_BUDGET" ]; then
  echo "TIER $TIER OVERBUDGET ${secs}s ($budget_text)"
  if [ "$ENFORCE" = 1 ]; then
    echo "tier_guard: over budget even though the tests passed; find the new cost (pytest --durations=30, vitest's slowest files) and cut it or move it down a tier, never raise the budget per run" >&2
    failed=1
  else
    echo "TIER $TIER: over budget, not enforced (TIER_BUDGET_ENFORCE=0)"
  fi
fi

[ "$failed" = 0 ] || exit 1
echo "TIER $TIER: ${secs}s ($budget_text)$counts"
