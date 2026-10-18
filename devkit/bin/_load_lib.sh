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
#
#   devkit_loadavg                 "<1m> <5m>", or nothing when the load cannot be read
#   devkit_ncpu                    the online core count, or nothing
#   devkit_load_scale <budget-s>   sets LOAD_SCALE ("1" when unscaled or unreadable),
#                                  LOAD_BUDGET (whole seconds) and LOAD_NOTE ("" when unscaled,
#                                  else `budget 110 s ×1.6 (load 13.1 on 8 cpus) → 176 s`, the
#                                  text printed on the status line so the number is explainable)
#                                  and LOAD_LEDGER ("" or `load=13.1/8 scale=1.6`)
#   devkit_load_rescale            after the command: samples again and keeps the larger stretch,
#                                  its LOAD_NOTE naming both samples (tier_guard.sh, local_gate.sh
#                                  jobs; a hook's ledger note keeps the start sample)
# Test hooks, environment only: DEVKIT_LOADAVG_CMD (a command printing "<1m> <5m> ...") and
# DEVKIT_NCPU (a core count).

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
  [ -n "$n" ] || n=$(sysctl -n hw.ncpu 2>/dev/null) || n=""
  [[ "$n" =~ ^[1-9][0-9]*$ ]] && echo "$n"
}

# _devkit_stretch <budget> <1m load> <ncpu>: "<scale> <stretched budget>", or nothing when
# unscaled. The scale is rounded to one decimal before it multiplies, so the printed factor and
# the printed budget agree (×1.6 of 110 is 176, not the 180 an unrounded 1.6375 gives).
_devkit_stretch() {
  [ -n "$2" ] && [ -n "$3" ] && [ "$1" -gt 0 ] || return 0
  awk -v b="$1" -v l="$2" -v n="$3" 'BEGIN {
    s = l / n; if (s > 2) s = 2
    s = sprintf("%.1f", s)
    if (s + 0 <= 1) exit
    print s, int(b * s + 0.5)
  }'
}

# shellcheck disable=SC2034  # LOAD_* are this function's output, read by the caller
devkit_load_scale() {
  local budget=$1 out
  LOAD_SCALE=1 LOAD_BUDGET=$budget LOAD_NOTE="" LOAD_LEDGER="" LOAD_BASE=$budget
  read -r LOAD_START _ <<<"$(devkit_loadavg)"
  LOAD_NCPU=$(devkit_ncpu)
  out=$(_devkit_stretch "$budget" "$LOAD_START" "$LOAD_NCPU")
  [ -n "$out" ] || return 0
  read -r LOAD_SCALE LOAD_BUDGET <<<"$out"
  LOAD_NOTE="budget $budget s ×$LOAD_SCALE (load $LOAD_START on $LOAD_NCPU cpus) → $LOAD_BUDGET s"
  LOAD_LEDGER="load=$LOAD_START/$LOAD_NCPU scale=$LOAD_SCALE"
}

# devkit_load_rescale: after the measured command, after devkit_load_scale. Samples the load
# again and keeps the larger of the two stretches; when either stretched, LOAD_NOTE names both
# samples: `budget 110 s ×1.6 (load 2.0 at start, 13.1 at end on 8 cpus) → 176 s`. Why (closet
# db tier, 2026-10-18): a start-only sample read a quiet box, neighbours' gates then pushed the
# load up mid-run, and the tier failed 124 s against an unstretched 110 s.
# shellcheck disable=SC2034  # LOAD_* are this function's output, read by the caller
devkit_load_rescale() {
  local end out scale budget
  read -r end _ <<<"$(devkit_loadavg)"
  out=$(_devkit_stretch "$LOAD_BASE" "$end" "$LOAD_NCPU")
  if [ -n "$out" ]; then
    read -r scale budget <<<"$out"
    if [ "$budget" -gt "$LOAD_BUDGET" ]; then
      LOAD_SCALE=$scale LOAD_BUDGET=$budget
      LOAD_LEDGER="load=$end/$LOAD_NCPU scale=$LOAD_SCALE"
    fi
  fi
  [ -n "$out" ] || [ -n "$LOAD_NOTE" ] || return 0
  LOAD_NOTE="budget $LOAD_BASE s ×$LOAD_SCALE (load ${LOAD_START:-?} at start, ${end:-?} at end on $LOAD_NCPU cpus) → $LOAD_BUDGET s"
}
