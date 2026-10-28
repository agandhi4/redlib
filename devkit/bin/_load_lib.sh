# shellcheck shell=bash
# Machine load, and budgets that stretch under it. Sourced; defines functions and runs nothing.
# Used by: local_gate.sh (the load wait before a slot; each job's budget), tier_guard.sh (the
# tier's budget) and hook_steps.sh (the load note on its ledger rows, for a reader of the
# seconds to divide out).
#
# Why (closet #410, 2026-10-17): its db tier ran 61-65 s alone and twice failed its 110 s budget
# at a load average of ~13 on 8 cores, while parallel lanes gated other repos. A budget is a
# regression signal for the suite, and a box running twice its cores is not the suite's cost.
# Scale = min(1-minute load / cores, 2), one decimal, applied only above 1.0: a solo run keeps
# its exact budget, and the cap means a real doubling still fails on the busiest box. A budget
# checked after its command uses the larger of the start and end samples.
# Slots (devkit decisions 2026-10-26): a caller in the gate slot pool passes how many slots are
# held (bin/_slot_lib.sh slot_held_count, its own included), and the scale is at least that,
# under the same cap, at the smaller of the start and end counts. Why: the 1-minute load lags
# bursty parallel gates. Of 154 tier runs beside another gate (2026-10-19..26) 8 overran, 7 of
# them at ×1.0 (load at or under the 10 cores both samples); devkit #226's unit ran 293 s against 240 beside kitchen #15 and 174 s alone. Each run
# then gets the budget of its slot share; a run alone (1 slot held) keeps its exact budget, so a
# real slowdown still fails there, and beside a neighbour past 2x.
# Cores (devkit decisions 2026-10-27): "cores" above is capacity in performance-core equivalents,
# P + E × DEVKIT_ECORE_RATIO, on a box whose sysctl names two perf levels (Apple silicon); else
# the online core count (Linux, Intel). Why: this M4 is 4 P + 6 E; at load 8-10 a tier's shards
# land on E-cores and ran ~1.7x slower at ×1.0 against hw.ncpu's 10 (devkit #240's unit: 304 s
# vs 240 at load 7.9). The ratio is measured, not guessed: ECORE_RATIO_DEFAULT below.
#
#   devkit_loadavg                 "<1m> <5m>", or nothing when the load cannot be read
#   devkit_ncpu                    the online core count, or nothing: a count of things (the
#                                  admission pool's default size), never a load divisor
#   devkit_cpu_capacity            the load divisor: performance-core equivalents, one decimal
#                                  when fractional ("7.6"), or nothing
#   devkit_load_scale <budget-s> [<slots held>]
#                                  sets LOAD_SCALE ("1" when unscaled or unreadable),
#                                  LOAD_BUDGET (whole seconds) and LOAD_NOTE ("" when unscaled,
#                                  else `budget 110 s ×1.6 (load 13.1 on 8 cpus) → 176 s`, the
#                                  text printed on the status line so the number is explainable;
#                                  `; 2 gate slots held` inside the parentheses when more than one is)
#                                  and LOAD_LEDGER ("" or `load=13.1/8 scale=1.6`, ` slots=2` after)
#   devkit_load_rescale [<slots held>]
#                                  after the command: samples again and keeps the larger stretch,
#                                  the slots counting at the smaller of the two counts, its
#                                  LOAD_NOTE naming both samples (tier_guard.sh, local_gate.sh
#                                  jobs; a hook's ledger note keeps the start sample)
# Test hooks, environment only: DEVKIT_LOADAVG_CMD (a command printing "<1m> <5m> ..."),
# DEVKIT_NCPU (a core count; set, it is also the capacity, a box of equal cores) and
# DEVKIT_SYSCTL_CMD (a command run as `<cmd> <key>` in place of `sysctl -n <key>`).
# DEVKIT_ECORE_RATIO (environment) overrides the measured E/P throughput ratio, for another chip.

devkit_loadavg() {
  if [ -n "${DEVKIT_LOADAVG_CMD:-}" ]; then
    bash -c "$DEVKIT_LOADAVG_CMD"
  elif [ -r /proc/loadavg ]; then
    cat /proc/loadavg
  else
    sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'   # macOS: "{ 1.23 4.56 7.89 }"
  fi | awk '$1 ~ /^[0-9.]+$/ && $2 ~ /^[0-9.]+$/ { print $1, $2; exit }'
}

devkit_ncpu() {
  local n=${DEVKIT_NCPU:-}
  [ -n "$n" ] || n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=""
  [ -n "$n" ] || n=$(_devkit_sysctl hw.ncpu) || n=""
  [[ "$n" =~ ^[1-9][0-9]*$ ]] && echo "$n"
}

_devkit_sysctl() { # <key>
  if [ -n "${DEVKIT_SYSCTL_CMD:-}" ]; then
    bash -c "$DEVKIT_SYSCTL_CMD \"\$1\"" _ "$1"
  else
    sysctl -n "$1"
  fi 2>/dev/null
}

# What each efficiency core adds, as a share of a performance core, on this M4 (4 P + 6 E) for a
# tier's own work. Measured 2026-10-27 holding the whole admission pool, box 94% idle: ten
# concurrent copies of two bats files against four (the 4 P-cores the solo shards use) gave
# 5.1-5.6 P-core equivalents, 3 rounds, median 5.35, so (5.35 - 4) / 6 = 0.22. A pure-CPU awk
# loop gives 0.5: the gap is fork/exec contention, and the tiers are fork-heavy shell, pytest
# and node. DEVKIT_ECORE_RATIO overrides it (another chip, or a CPU-bound fleet's tiers).
readonly ECORE_RATIO_DEFAULT=0.22

devkit_cpu_capacity() {
  local p="" e="" r=${DEVKIT_ECORE_RATIO:-$ECORE_RATIO_DEFAULT} ratio_re='^(0?\.[0-9]*[1-9][0-9]*|1(\.0*)?)$'
  if [ -z "${DEVKIT_NCPU:-}" ]; then
    p=$(_devkit_sysctl hw.perflevel0.logicalcpu) e=$(_devkit_sysctl hw.perflevel1.logicalcpu)
  fi
  if ! [[ "$p" =~ ^[1-9][0-9]*$ && "$e" =~ ^[0-9]+$ ]]; then
    devkit_ncpu
  elif ! [[ "$r" =~ $ratio_re ]]; then
    echo "load: DEVKIT_ECORE_RATIO must be a decimal in (0, 1] (got '$r'); dividing by the core count" >&2
    devkit_ncpu
  else
    awk -v p="$p" -v e="$e" -v r="$r" 'BEGIN { c = sprintf("%.1f", p + e * r); sub(/\.0$/, "", c); print c }'
  fi
}

# _devkit_stretch <budget> <1m load> <ncpu> [<slots held>]: "<scale> <stretched budget>", or
# nothing when unscaled. The scale is rounded to one decimal before it multiplies, so the printed
# factor and the printed budget agree (×1.6 of 110 is 176, not the 180 an unrounded 1.6375
# gives). An unreadable load leaves the slots alone to stretch it.
_devkit_stretch() {
  [ "$1" -gt 0 ] || return 0
  awk -v b="$1" -v l="$2" -v n="$3" -v h="${4:-1}" 'BEGIN {
    s = (l != "" && n != "") ? l / n : 0
    if (h > s) s = h
    if (s > 2) s = 2
    s = sprintf("%.1f", s)
    if (s + 0 <= 1) exit
    print s, int(b * s + 0.5)
  }'
}

# shellcheck disable=SC2034  # LOAD_* are this function's output, read by the caller
devkit_load_scale() {
  local budget=$1 out
  LOAD_SCALE=1 LOAD_BUDGET=$budget LOAD_NOTE="" LOAD_LEDGER="" LOAD_BASE=$budget
  LOAD_HELD_START=${2:-1} LOAD_HELD=${2:-1}
  read -r LOAD_START _ <<<"$(devkit_loadavg)"
  LOAD_NCPU=$(devkit_cpu_capacity)
  out=$(_devkit_stretch "$budget" "$LOAD_START" "$LOAD_NCPU" "$LOAD_HELD")
  [ -n "$out" ] || return 0
  read -r LOAD_SCALE LOAD_BUDGET <<<"$out"
  LOAD_NOTE="budget $budget s ×$LOAD_SCALE (load ${LOAD_START:-?} on ${LOAD_NCPU:-?} cpus$(_devkit_held_note)) → $LOAD_BUDGET s"
  LOAD_LEDGER="load=${LOAD_START:-?}/${LOAD_NCPU:-?} scale=$LOAD_SCALE$(_devkit_held_note ledger)"
}

# _devkit_held_note [ledger]: `; <n> gate slots held` (`; <a> at start, <b> at end` once
# rescaled to a different count), or ` slots=<n>` for the ledger; nothing while one is held.
_devkit_held_note() {
  [ "$LOAD_HELD" -gt 1 ] || [ "$LOAD_HELD_START" -gt 1 ] || return 0
  if [ "${1:-}" = ledger ]; then
    echo " slots=$LOAD_HELD"
  elif [ "$LOAD_HELD" = "$LOAD_HELD_START" ]; then
    echo "; $LOAD_HELD gate slots held"
  else
    echo "; gate slots held $LOAD_HELD_START at start, $LOAD_HELD at end"
  fi
}

# devkit_load_rescale: after the measured command, after devkit_load_scale. Samples the load
# again and keeps the larger of the two stretches; when either stretched, LOAD_NOTE names both
# samples: `budget 110 s ×1.6 (load 2.0 at start, 13.1 at end on 8 cpus) → 176 s`. Why (closet
# db tier, 2026-10-18): a start-only sample read a quiet box, neighbours' gates then pushed the
# load up mid-run, and the tier failed 124 s against an unstretched 110 s.
# shellcheck disable=SC2034  # LOAD_* are this function's output, read by the caller
devkit_load_rescale() {
  local end held out scale budget sample
  LOAD_HELD=${1:-1}
  read -r end _ <<<"$(devkit_loadavg)"
  # Slots count only when held at both samples: a held slot is a snapshot, not an average, and a
  # neighbour's slot spans its near-idle setup and cleanup too (adversarial review of #234).
  held=$LOAD_HELD
  [ "$LOAD_HELD_START" -ge "$held" ] || held=$LOAD_HELD_START
  LOAD_SCALE=1 LOAD_BUDGET=$LOAD_BASE
  for sample in "${LOAD_START:-}" "${end:-}"; do
    out=$(_devkit_stretch "$LOAD_BASE" "$sample" "$LOAD_NCPU" "$held")
    [ -n "$out" ] || continue
    read -r scale budget <<<"$out"
    [ "$budget" -gt "$LOAD_BUDGET" ] || continue
    LOAD_SCALE=$scale LOAD_BUDGET=$budget
    LOAD_LEDGER="load=${sample:-?}/${LOAD_NCPU:-?} scale=$LOAD_SCALE$(_devkit_held_note ledger)"
  done
  [ "$LOAD_SCALE" != 1 ] || [ -n "$LOAD_NOTE" ] || return 0
  LOAD_NOTE="budget $LOAD_BASE s ×$LOAD_SCALE (load ${LOAD_START:-?} at start, ${end:-?} at end on ${LOAD_NCPU:-?} cpus$(_devkit_held_note)) → $LOAD_BUDGET s"
}
