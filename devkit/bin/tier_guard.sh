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
#              as run; repeat for a command that runs several runners (pytest then vitest).
#              `=<min>` may be left out once the repo's ratchet holds the floor (Floors, below)
#
# Output (an API, like local_gate's GATE lines). The command's own output streams through
# unchanged (stderr merged into stdout); a copy is kept only to read the summaries. Then:
#   TIER <tier> FAIL (exit <rc>, <s>s)                   the command failed: exits <rc>
#   TIER <tier> FLOOR <runner> <n> < <min>               ran fewer tests than the floor: exit 1
#   TIER <tier> FLOOR <runner> no summary line (floor <min>)                           exit 1
#   TIER <tier> OVERBUDGET <s>s (budget <b>s)            exit 1, unless TIER_BUDGET_ENFORCE=0
#                                                        or DEVKIT_CLOCK_SHIFT (Clock shift)
#   TIER <tier>: <s>s (budget <b>s) <runner>=<n>...      every check held: exit 0
# Under load the budget stretches (bin/_load_lib.sh: min(max(1-minute load / cores, gate slots
# held), 2), sampled when the command starts and when it ends, the larger stretch kept, only
# above 1.0) and both budget lines then read `(budget 110 s ×1.6 (load 2.0 at start, 13.1 at end
# on 8 cpus) → 176 s)`, with `; 2 gate slots held` before the `)` when more than one was;
# unloaded at both, they are exactly as above. The command runs with DEVKIT_LOAD_SCALE set to the
# start sample's factor ("1" unscaled), so its runner can stretch its own per-test timeouts
# by the factor its budget got (lint/vitest.base.mjs does, for vitest).
# Capacity: outside a gate the tier is first admitted to the machine-wide pool the gate's jobs
# share (bin/_slot_lib.sh; GATE_CAPACITY from the environment or gate.env, as the gate reads it)
# for its tier name's cost (unit 2, db 3, ...), holder `<repo>:<tier>`, so `make ci-unit` by hand
# in four worktrees queues instead of piling onto the gates' load (2026-10-21). While it does not
# fit it prints, at once and every 30 s (each heartbeat ending ` (waited <n>s)`),
#   TIER <tier> waiting for capacity: <repo>:<tier> needs <c> of <cap>, <u> in use (<holder> <c>, ...)[; queued behind ...]
# then `TIER <tier> admitted (cost <c> of <cap>[, queued <n>s])`. The wait is before the budget
# clock. Under a hook (bin/quiet_run.sh captures the step) the waiting lines, and the admitted
# line after a wait, reach the hook's own output on its notice fd (bin/_slot_lib.sh, Notices),
# so a queued pre-push says why it is quiet; the command runs with that fd closed. Inside a gate job (or another tier) DEVKIT_SLOT_HOLDER names a live holder and the tier
# runs on its units, silently; TIER_SLOT=0 (default 1) stays out of the pool for a deliberately
# quick single test.
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
# Clock shift (devkit decisions 2026-10-22): DEVKIT_CLOCK_SHIFT=<n>d runs the command with the
# wall clock <n> days ahead, so a test dated from the real clock beside a pinned one fails the
# day it is written, not a month later (finplat #706). The gate's CLOCK group sets it per offset
# (bin/_paths_lib.sh); by hand, `make <tier target> DEVKIT_CLOCK_SHIFT=30d`. pytest and vitest:
# the guard puts devkit/clock_shift/ on PYTHONPATH and its plugin in PYTEST_PLUGINS (contract in
# clock_shift/devkit_clock_shift.py) with DEVKIT_CLOCK_SHIFT_CONF=<root>/scripts/ci/clock_shift.conf,
# the repo's exceptions (pytest only), and names vitest's setup file as DEVKIT_CLOCK_SHIFT_VITEST,
# which the repo's vitest config loads through lint/vitest.base.mjs's clockShift() plugin
# (contract in clock_shift/vitest_clock_shift.mjs). Every floor must be one of those two (exit 2
# otherwise: another runner would run on the real clock and read as shifted). Shifted, the tier
# writes no metrics file (the unshifted run of the same tier owns tier.<tier>.*), puts back every
# file a scripts/ci/metrics.conf collector reads (bin/_metrics_conf_lib.sh's TIER_INPUTS: the
# coverage report, statements.json) as it found it, mtime and all, or removes it when there was
# none, and says so in one `TIER <tier> shift kept <n> metrics input(s): <files>` line, so the
# ratchet never reads a shifted run in any job order (rollcall #81: QUICK's real-clock ci-unit
# ran before CLOCK's shifted one, and the shifted coverage report was the one left). A Next
# build ts.mjs --bundle reads is too big to copy: a shifted run that changed its manifest fails
# (exit 1, as does an input it could not put back). Only what the guarded command writes is
# covered: a recipe step after tier_guard returns (kitchen's `coverage combine` in ci-db-backend)
# runs shifted and unguarded, so a shifted target writes its inputs inside the guard or not at
# all. Its budget is reported, not enforced (the unshifted run holds it). The success line ends
# ` shift=+<n>d`, and
#   TIER <tier> NOSHIFT <runner> (no shifted <runner> process: it ran on the real clock)  exit 1
# when the command passed but no process of a floored runner recorded its shift in the guard's
# DEVKIT_CLOCK_SHIFT_PROOF file (a recipe that drops the environment, a pytest in a container, a
# vitest config without clockShift()). A file, not an output line: vitest prints a setup
# file's output per test file, or not at all under `silent`.
#
# Floors (devkit decisions 2026-10-26): when <root>/docs/metrics/ratchet.json bounds
# tests.<tier>.<runner> (metrics_ratchet.py, Floors), that bound less 5% is the runner's floor
# (the gate's ratchet holds the exact bound; a run off the gate's box may skip a test that needs
# its environment), and the larger of it and a --floor number wins; a runner only the bounds name is floored too, so
# dropping it from the recipe cannot drop its floor. `make metrics-tighten` seeds the bound from
# this tier's count and raises it once the count is past it by more than 5%; the gate's metrics
# job fails until then. It moves down only through `make metrics-rebaseline KEYS=<key>` and the
# metrics-rebaseline label, in the PR that removes the tests (UNIT_BATS_FLOOR sat at 638 while
# 820 ran: a Makefile floor raised by hand never was). Budgets are set from GATE timings with
# headroom and only ever go down.
set -uo pipefail
# shellcheck source=bin/_load_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_load_lib.sh"
# shellcheck source=bin/_awake_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_awake_lib.sh"
# shellcheck source=bin/_gate_env.sh
. "$(dirname "${BASH_SOURCE[0]}")/_gate_env.sh"
# shellcheck source=bin/_slot_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_slot_lib.sh"
# shellcheck source=bin/_metrics_conf_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_metrics_conf_lib.sh"
# shellcheck source=bin/_toolchain_lib.sh  # devkit_python, for the ratchet's floors
. "$(dirname "${BASH_SOURCE[0]}")/_toolchain_lib.sh"

RUNNERS="pytest vitest playwright cargo bats"

usage() {
  echo "usage: $0 <tier> --budget <seconds> [--floor <runner>[=<min>]]... -- <command...>" >&2
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

TIER=""
BUDGET=""
FLOORS=()   # "<runner> <min>" entries, in the order given
# add_floor <runner>[=<min>]: one --floor, onto FLOORS.
add_floor() {
  local runner=${1%%=*} min=0 f
  [[ "$1" =~ ^[a-z]+(=[0-9]+)?$ ]] || die "--floor takes <runner>[=<min>] (got '$1')"
  case " $RUNNERS " in *" $runner "*) ;; *) die "unknown runner '$runner' (one of: $RUNNERS)" ;; esac
  for f in ${FLOORS[@]+"${FLOORS[@]}"}; do
    [ "${f%% *}" != "$runner" ] || die "--floor $runner given twice"
  done
  [ "$runner" = "$1" ] || min=${1#*=}
  FLOORS+=("$runner $min")
}
# parse_args "$@": TIER, BUDGET and FLOORS; ARG_WORDS counts the words up to and with `--`,
# which the caller shifts off to leave the command.
parse_args() {
  [ $# -ge 1 ] || usage
  TIER=$1
  shift
  [[ "$TIER" =~ ^[A-Za-z0-9_-]+$ ]] || die "tier '$TIER' must match [A-Za-z0-9_-]+ (it becomes the key tier.<tier>.seconds)"
  ARG_WORDS=1
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      --budget)
        [ $# -ge 2 ] || usage
        [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--budget must be a positive whole number of seconds (got '$2')"
        BUDGET=$2
        ;;
      --floor)
        [ $# -ge 2 ] || usage
        add_floor "$2"
        ;;
      *) usage ;;
    esac
    shift 2
    ARG_WORDS=$((ARG_WORDS + 2))
  done
  [ $# -ge 2 ] && [ "$1" = "--" ] || usage
  ARG_WORDS=$((ARG_WORDS + 1))
  [ -n "$BUDGET" ] || die "--budget is required: every tier has one (the test-value standard)"
}
parse_args "$@"
shift "$ARG_WORDS"
ENFORCE=${TIER_BUDGET_ENFORCE:-1}
[[ "$ENFORCE" =~ ^[01]$ ]] || die "TIER_BUDGET_ENFORCE must be 0 or 1 (got '$ENFORCE')"
TAKE_SLOT=${TIER_SLOT:-1}
[[ "$TAKE_SLOT" =~ ^[01]$ ]] || die "TIER_SLOT must be 0 or 1 (got '$TAKE_SLOT')"

# Inside a git hook GIT_DIR (and sometimes GIT_WORK_TREE) is exported, which makes rev-parse
# report the current directory as the top level: a tier run after `cd backend` would then write
# backend/build/metrics/ (Orbit #59). Drop both so the lookup answers for the real checkout.
root=$(env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --show-toplevel 2>/dev/null) || root=$PWD

# ratchet_floors: FLOORS raised to the ratchet's bounds (header: Floors).
ratchet_floors() {
  local bounds=$root/docs/metrics/ratchet.json listed runner min f found merged _tier
  [ -f "$bounds" ] || return 0
  devkit_python || die "$DEVKIT_PYTHON_ERROR"
  listed=$("$DEVKIT_PYTHON" -I "$(dirname "${BASH_SOURCE[0]}")/metrics_ratchet.py" floors \
    --bounds "$bounds" --tier "$TIER") || exit 2
  while read -r _tier runner min; do
    [ -n "$runner" ] || continue
    case " $RUNNERS " in
      *" $runner "*) ;;
      *) die "$bounds: floor tests.$TIER.$runner is no runner tier_guard counts (one of: $RUNNERS)" ;;
    esac
    found=0 merged=()
    for f in ${FLOORS[@]+"${FLOORS[@]}"}; do
      if [ "${f%% *}" = "$runner" ]; then
        found=1
        [ "${f#* }" -ge "$min" ] || f="$runner $min"
      fi
      merged+=("$f")
    done
    [ "$found" = 1 ] || merged+=("$runner $min")
    FLOORS=("${merged[@]}")
  done <<<"$listed"
}
ratchet_floors

SHIFT=${DEVKIT_CLOCK_SHIFT:-}
# clock_shift_env: under DEVKIT_CLOCK_SHIFT, the plugins' environment (header, "Clock shift").
clock_shift_env() {
  local f plugin_dir
  [[ "$SHIFT" =~ ^[1-9][0-9]*d$ ]] || die "DEVKIT_CLOCK_SHIFT must be whole days ahead, like 30d (got '$SHIFT')"
  [ "${#FLOORS[@]}" -gt 0 ] || die "DEVKIT_CLOCK_SHIFT needs --floor pytest=<min> or vitest=<min>: the floor is how the shift is checked"
  for f in "${FLOORS[@]}"; do
    case ${f%% *} in
      pytest | vitest) ;;
      *) die "DEVKIT_CLOCK_SHIFT shifts pytest and vitest only; tier $TIER floors ${f%% *}, which would run on the real clock (give the CLOCK group a target without it)" ;;
    esac
  done
  plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../clock_shift" 2>/dev/null && pwd) \
    || die "no clock_shift/ beside $(dirname "${BASH_SOURCE[0]}") (an older devkit-sync; VENDOR_PATHS lists it)"
  export PYTHONPATH="$plugin_dir${PYTHONPATH:+:$PYTHONPATH}"
  export PYTEST_PLUGINS="devkit_clock_shift${PYTEST_PLUGINS:+,$PYTEST_PLUGINS}"
  export DEVKIT_CLOCK_SHIFT_CONF="$root/scripts/ci/clock_shift.conf"
  export DEVKIT_CLOCK_SHIFT_VITEST="$plugin_dir/vitest_clock_shift.mjs"
}
[ -z "$SHIFT" ] || clock_shift_env

# keep_inputs / put_back_inputs: a shifted run's metrics inputs (header, "Clock shift"). KEPT
# holds each file input's path (absolute) by index, and $KEEP/<index> its copy when it existed.
# A Next build (next-build kind) is a whole .next/ tree that ts.mjs --bundle reads, too big to
# copy per run: BUILDS holds its manifest and BUILD_STAMPS the manifest's checksum, and a
# shifted run that changed it fails instead (a pytest or vitest tier has no business building).
KEEP=""
KEPT=()
BUILDS=()
BUILD_STAMPS=()
build_stamp() { if [ -e "$1" ]; then cksum <"$1"; else echo none; fi; }
keep_inputs() {
  local list kind f p
  list=$(cd "$root" && metrics_conf_tier_inputs scripts/ci/metrics.conf) || exit 2
  [ -n "$list" ] || return 0
  KEEP=$(mktemp -d "${tmp%/}/tier-$TIER-keep.XXXXXX") || die "mktemp failed"
  while read -r kind f; do
    case $f in /*) p=$f ;; *) p=$root/$f ;; esac
    if [ "$kind" = next-build ]; then
      BUILDS+=("$p")
      BUILD_STAMPS+=("$(build_stamp "$p")")
      continue
    fi
    [ ! -e "$p" ] || cp -p "$p" "$KEEP/${#KEPT[@]}" || die "could not keep $p"
    KEPT+=("$p")
  done <<<"$list"
}
# Runs right after the command and again from the EXIT trap (an interrupted run); the second
# finds nothing left to do. Non-zero when any input could not be put back, or a build moved:
# the tier then fails, since the metrics job would read the shifted run.
put_back_inputs() {
  local i ok=0
  for ((i = 0; i < ${#KEPT[@]}; i++)); do
    if [ -e "$KEEP/$i" ]; then
      mkdir -p "$(dirname "${KEPT[$i]}")" && cp -p "$KEEP/$i" "${KEPT[$i]}"
    else
      rm -f "${KEPT[$i]}" && [ ! -e "${KEPT[$i]}" ]
    fi || { echo "tier_guard: could not put back ${KEPT[$i]}: the metrics job would read the shifted run's" >&2; ok=1; }
  done
  for ((i = 0; i < ${#BUILDS[@]}; i++)); do
    [ "$(build_stamp "${BUILDS[$i]}")" = "${BUILD_STAMPS[$i]}" ] && continue
    echo "tier_guard: the shifted run rebuilt ${BUILDS[$i]%/.next/*}/.next (${BUILDS[$i]#"$root/"} changed), which ts.mjs --bundle reads; build outside the shifted target" >&2
    ok=1
  done
  [ "${#KEPT[@]}" -eq 0 ] || echo "TIER $TIER shift kept ${#KEPT[@]} metrics input(s): ${KEPT[*]#"$root/"}"
  if [ "$ok" != 0 ] && [ -n "$KEEP" ]; then
    echo "tier_guard: the real-clock copies stay in $KEEP (by index, in the order above)" >&2
  elif [ -n "$KEEP" ]; then
    rm -rf "$KEEP"
  fi
  KEEP="" KEPT=() BUILDS=() BUILD_STAMPS=()
  return "$ok"
}

tmp=${TMPDIR:-/tmp}
LOG=$(mktemp "${tmp%/}/tier-$TIER.XXXXXX") || die "mktemp failed"
PROOF=""
trap 'slot_release; rm -f "$LOG" ${PROOF:+"$PROOF"}; put_back_inputs || exit 1' EXIT
if [ -n "$SHIFT" ]; then
  PROOF=$(mktemp "${tmp%/}/tier-$TIER-shift.XXXXXX") || die "mktemp failed"
  export DEVKIT_CLOCK_SHIFT_PROOF=$PROOF
  keep_inputs
fi

# A tier's budget is wall time; a nap mid-run would read as test time (bin/_awake_lib.sh).
devkit_stay_awake
# held_slots: the pool's holder count for the budget's stretch (bin/_load_lib.sh, Slots); 1 under
# TIER_SLOT=0, which stays out of the pool altogether.
held_slots() { if [ "$TAKE_SLOT" = 1 ]; then slot_held_count; else echo 1; fi; }
# take_slot: under TIER_SLOT=1, the tier's capacity, unless a tier above it already holds it.
take_slot() {
  local cost
  # Only GATE_CAPACITY is read from gate.env; the gate's other keys are its own. Inside a gate
  # too: the tier asks for nothing there, but its budget stretches by the holders.
  gate_env_load tier_guard GATE_CAPACITY "$GATE_LOCAL_KEYS|$GATE_REMOTE_KEYS"
  slot_pool_init tier_guard
  slot_held_above && return 0
  cost=$(slot_cost "$TIER")
  slot_acquire "TIER $TIER" "$(repo_name):$TIER" "$cost"
  if [ "$SLOT_QUEUED" = 0 ]; then
    echo "TIER $TIER admitted (cost $cost of $SLOT_CAPACITY)"
  else
    slot_notice "TIER $TIER admitted (cost $cost of $SLOT_CAPACITY, queued ${SLOT_QUEUED}s)"
  fi
  # The holder for a tier the command runs inside this one (it asks for nothing again).
  export DEVKIT_SLOT_HOLDER=$$
}
[ "$TAKE_SLOT" = 0 ] || take_slot
# Done with the notice fd (header, Capacity): a tier inside this one never waits, so nothing in
# the command writes to it, and a server the command leaves behind must not hold the hook's
# output open.
if [ "${DEVKIT_NOTICE_FD:-}" = 6 ]; then exec 6>&-; unset DEVKIT_NOTICE_FD; fi
devkit_load_scale "$BUDGET" "$(held_slots)"
start=$SECONDS
DEVKIT_LOAD_SCALE=$LOAD_SCALE "$@" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
secs=$((SECONDS - start))
put_back=0
put_back_inputs || put_back=1
devkit_load_rescale "$(held_slots)"
slot_release
budget_text="budget ${BUDGET}s"
[ -z "$LOAD_NOTE" ] || budget_text=$LOAD_NOTE

# fail_command: the command failed; exits with its code.
fail_command() {
  echo "TIER $TIER FAIL (exit $rc, ${secs}s)"
  # pytest exits 1 when tests failed; a usage error (4, a bad clock_shift.conf line) is not rot.
  if [ -n "$SHIFT" ] && [ "$rc" -eq 1 ]; then
    echo "tier_guard: failed with the wall clock $SHIFT ahead: a fixture dated from the real clock beside a pinned one, or a fixed date the clock will pass. Date it from the pinned clock; list a test the shift cannot reach (a database's now(), a file's mtime) in scripts/ci/clock_shift.conf with the reason" >&2
  fi
  exit "$rc"
}
[ "$rc" -eq 0 ] || fail_command

failed=$put_back   # a metrics input left as the shifted run wrote it fails the tier
counts=""   # " <runner>=<n>" for the success line
metrics="  \"tier.$TIER.seconds\": $secs"
stripped=$(strip_ansi <"$LOG")
# judge_floor <runner> <min>: the runner's count from the log onto metrics and counts; failed=1
# when it ran unshifted under a shift, printed no summary or fell under its floor.
judge_floor() {
  local runner=$1 min=$2 n
  if [ -n "$SHIFT" ] && ! grep -q "^$runner +$SHIFT " "$PROOF"; then
    echo "TIER $TIER NOSHIFT $runner (no shifted $runner process: it ran on the real clock)"
    case $runner in
      pytest) echo "tier_guard: pytest did not load devkit_clock_shift: the recipe must run pytest in this environment (PYTEST_PLUGINS, PYTHONPATH)" >&2 ;;
      vitest) echo "tier_guard: vitest never ran devkit's clock-shift setup file: add clockShift() (devkit/lint/vitest.base.mjs) to the root config's plugins, and keep the environment (DEVKIT_CLOCK_SHIFT_VITEST)" >&2 ;;
    esac
    failed=1
  fi
  n=$(printf '%s\n' "$stripped" | tier_count "$runner")
  if [ -z "$n" ]; then
    echo "TIER $TIER FLOOR $runner no summary line (floor $min)"
    echo "tier_guard: $runner printed no summary: it did not run, or a reporter replaced its default one (keep the default reporter alongside json)" >&2
    failed=1
    return
  fi
  metrics="$metrics,"$'\n'"  \"tests.$TIER.$runner\": $n"
  counts="$counts $runner=$n"
  if [ "$n" -lt "$min" ]; then
    echo "TIER $TIER FLOOR $runner $n < $min"
    echo "tier_guard: a test file, marker or glob stopped being picked up, or tests now skip; lower a floor only in the PR that removes tests (make metrics-rebaseline KEYS=tests.$TIER.$runner and the metrics-rebaseline label)" >&2
    failed=1
  fi
}
for f in ${FLOORS[@]+"${FLOORS[@]}"}; do judge_floor "${f%% *}" "${f#* }"; done

# write_tier_json: build/metrics/tier-<tier>.json, the unshifted run's only (header, "Clock shift").
write_tier_json() {
  local out=$root/build/metrics/tier-$TIER.json
  [ -z "$SHIFT" ] || return 0
  { mkdir -p "${out%/*}" && printf '{\n%s\n}\n' "$metrics" >"$out"; } || die "could not write $out"
}
write_tier_json

# A shifted run is reported, never failed, on its budget: the unshifted run of the same suite
# holds it, and the CLOCK group runs every shifted tier at once, in bursts shorter than the
# 1-minute load average the stretch reads (locus #148 and Orbit #118: clock-unit-30d 25 s and
# 38 s against 20 s and 30 s, unstretched, while their unshifted unit-backend passed).
judge_budget() {
  [ "$secs" -gt "$LOAD_BUDGET" ] || return 0
  echo "TIER $TIER OVERBUDGET ${secs}s ($budget_text)"
  if [ -n "$SHIFT" ]; then
    echo "TIER $TIER: over budget, not enforced (shifted: the unshifted run holds the budget)"
  elif [ "$ENFORCE" = 1 ]; then
    echo "tier_guard: over budget even though the tests passed; find the new cost (pytest --durations=30, vitest's slowest files) and cut it or move it down a tier, never raise the budget per run" >&2
    failed=1
  else
    echo "TIER $TIER: over budget, not enforced (TIER_BUDGET_ENFORCE=0)"
  fi
}
judge_budget

[ "$failed" = 0 ] || exit 1
echo "TIER $TIER: ${secs}s ($budget_text)$counts${SHIFT:+ shift=+$SHIFT}"
