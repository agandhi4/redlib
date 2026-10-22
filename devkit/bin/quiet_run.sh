#!/usr/bin/env bash
# Run one hook step quietly: one line when it passes, the tail of its output when it fails.
# Presentation only. It never changes what a step checks, and it returns the step's own exit
# code. Lifted from finplat's .githooks/_quiet_lib.sh; the tail size and ANSI stripping match
# closet's scripts/git-hook-output.ts so every repo's hooks read the same.
#
# Usage, executed:  devkit/bin/quiet_run.sh <label> -- <cmd...>
#        sourced:   . devkit/bin/quiet_run.sh; run_step <label> <cmd...>
#   Pass:  "✓ <label> (<n>s)", plus " — <summary>" when the output has a test/lint summary line
#          (pytest/vitest/Playwright counts, ruff "All checks passed", "already formatted"; cargo's
#          per-binary "test result:" lines summed into one).
#   Fail:  "✗ <label> (<n>s)", then the last QUIET_TAIL (default 40) ANSI-stripped lines between
#          markers naming the kept log; exits with the command's code.
#   QUIET_VERBOSE=1 streams the output instead of capturing it; the status line still follows.
#
# Every call gets its own log from mktemp, removed on pass and kept on fail, so a hook can call
# it any number of times with no shared state. A sourced call sets QUIET_FAILED_LOG to the kept
# log on fail and empties it otherwise (QUIET_VERBOSE keeps none), so the caller can read the
# step's output (hook_steps.sh: the npm ci hint). Sourcing defines run_step and runs nothing: it
# sets no options and no traps in the caller's shell. Executed, it does not inherit the
# caller's `set -e`/ERR trap, so it is safe from sh hooks and Makefiles too.

run_step() {
  local label=$1
  shift
  local tail_n=${QUIET_TAIL:-40} start dur rc log summary
  start=$(date +%s)
  # shellcheck disable=SC2034  # read by the sourcing caller (header)
  QUIET_FAILED_LOG=
  if [ "${QUIET_VERBOSE:-0}" = 1 ]; then
    rc=0
    "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "✓ $label ($(( $(date +%s) - start ))s)"
    else
      echo "✗ $label ($(( $(date +%s) - start ))s)"
    fi
    return "$rc"
  fi

  local tmp=${TMPDIR:-/tmp}
  log=$(mktemp "${tmp%/}/devkit-quiet.XXXXXX") || return 1
  rc=0
  "$@" >"$log" 2>&1 || rc=$?
  dur=$(( $(date +%s) - start ))

  if [ "$rc" -eq 0 ]; then
    summary=$(_quiet_strip_ansi <"$log" | _quiet_summary) || true
    rm -f "$log"
    if [ -n "$summary" ]; then
      echo "✓ $label (${dur}s) — $summary"
    else
      echo "✓ $label (${dur}s)"
    fi
  else
    # shellcheck disable=SC2034  # read by the sourcing caller (header)
    QUIET_FAILED_LOG=$log
    echo "✗ $label (${dur}s)"
    echo "--- last $tail_n lines (full log: $log) ---"
    _quiet_strip_ansi <"$log" | tail -n "$tail_n"
    echo "--- end log: $log ---"
  fi
  return "$rc"
}

# stdin: a passing step's ANSI-stripped output. stdout: its one-line summary, or nothing.
# cargo prints one "test result:" line per test binary and the doctests come last, so the last
# line read "0 passed" for redlib's whole unit suite; those lines are summed instead. Otherwise
# the LAST summary-shaped line wins: vitest prints an unrelated tip after its real summary.
# Always exits 0: a non-matching grep must not trip a sourcing caller's `set -e`.
_quiet_summary() {
  awk '
    /^test result: / {
      suites++
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^passed;?$/) passed += $(i - 1)
        if ($i ~ /^ignored;?$/) ignored += $(i - 1)
      }
      next
    }
    /[0-9]+ (passed|failed|errors?|warnings?|deselected|skipped|flaky)|already formatted|All checks passed|no issues found/ { last = $0 }
    END {
      if (suites) printf "cargo test: %d passed; %d ignored (%d suites)\n", passed, ignored, suites
      else if (last != "") { sub(/^[[:space:]]+/, "", last); print last }
    }'
}

_quiet_strip_ansi() {
  sed $'s/\x1b\\[[0-9;?]*[A-Za-z]//g'
}

# Sourced: the functions are the whole contract.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

set -euo pipefail
usage() { echo "usage: $0 <label> -- <cmd...>" >&2; exit 2; }
[ $# -ge 3 ] && [ "$2" = "--" ] || usage
LABEL=$1
shift 2
rc=0
run_step "$LABEL" "$@" || rc=$?
exit "$rc"
