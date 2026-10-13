#!/usr/bin/env bash
# Run one hook step quietly: one line when it passes, the tail of its output when it fails.
# Presentation only. It never changes what a step checks, and it returns the step's own exit
# code. Lifted from finplat's .githooks/_quiet_lib.sh; the tail size and ANSI stripping match
# closet's scripts/git-hook-output.ts so every repo's hooks read the same.
#
# Usage, executed:  devkit/bin/quiet_run.sh <label> -- <cmd...>
#        sourced:   . devkit/bin/quiet_run.sh; run_step <label> <cmd...>
#   Pass:  "✓ <label> (<n>s)", plus " — <summary>" when the output has a test/lint summary line
#          (pytest/vitest/Playwright counts, ruff "All checks passed", "already formatted").
#   Fail:  "✗ <label> (<n>s)", then the last QUIET_TAIL (default 40) ANSI-stripped lines between
#          markers naming the kept log; exits with the command's code.
#   QUIET_VERBOSE=1 streams the output instead of capturing it; the status line still follows.
#
# Every call gets its own log from mktemp, removed on pass and kept on fail, so a hook can call
# it any number of times with no shared state. Sourcing defines run_step and runs nothing: it
# sets no options and no traps in the caller's shell. Executed, it does not inherit the
# caller's `set -e`/ERR trap, so it is safe from sh hooks and Makefiles too.

run_step() {
  local label=$1
  shift
  local tail_n=${QUIET_TAIL:-40} start dur rc log summary
  start=$(date +%s)
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
    # The LAST summary-shaped line: vitest prints an unrelated tip after its real summary.
    # `|| true` because a non-matching grep must not trip a sourcing caller's `set -e`.
    summary=$(_quiet_strip_ansi <"$log" | grep -aE '[0-9]+ (passed|failed|errors?|warnings?|deselected|skipped|flaky)|already formatted|All checks passed|no issues found' | tail -n 1 | sed 's/^[[:space:]]*//') || true
    rm -f "$log"
    if [ -n "$summary" ]; then
      echo "✓ $label (${dur}s) — $summary"
    else
      echo "✓ $label (${dur}s)"
    fi
  else
    echo "✗ $label (${dur}s)"
    echo "--- last $tail_n lines (full log: $log) ---"
    _quiet_strip_ansi <"$log" | tail -n "$tail_n"
    echo "--- end log: $log ---"
  fi
  return "$rc"
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
