#!/usr/bin/env bash
# Assert this checkout's git hooks actually run: core.hooksPath points at the repo's tracked
# .githooks/, and every hook devkit ships (templates/githooks beside this script, vendored at
# devkit/templates/githooks: pre-commit, pre-push, commit-msg) exists there and is executable.
#
# Why: on 2026-08-16 we found a tool installer (code-review-graph) had repointed finplat's
# core.hooksPath; its hooks had silently never run for two months. Nothing failed, so nothing
# noticed. `make install` calls this with --fix so the next install heals a repoint, and the
# gate preflight calls it to report one.
#
# git-lfs caveat: with core.hooksPath set, git ignores .git/hooks, which is where `git lfs
# install` put its pre-push. LFS objects then never upload and the push "succeeds". The
# templates/githooks pre-push chains `git lfs pre-push` through hook_steps.sh; this check fails
# when .gitattributes uses LFS and .githooks/pre-push neither chains it nor calls run_hook_steps.
#
# scripts/ci/hooks.conf, when present, must parse: every step goes through hook_steps.sh's own
# parser, so a bad path filter (unknown key, empty glob list) fails install and the gate
# preflight, naming the step, instead of blocking the next commit. A pre-commit step whose
# target names typecheck or unit (ci-typecheck, ci-unit-backend) is a warning on stderr, never a
# failure: those belong at pre-push (README "Git hooks"; closet's and rollcall's pre-commit
# ran tsc on every commit of every lane, p90 33 s and 51 s against the 30 s budget). A Makefile
# with a ci-lint target and no pre-commit step running ci-lint, a ci-lint-<area> or ci-quick is
# a warning too: devkit's own pre-commit skipped it, so lanes met E501 and the changed-file
# rules (changed_lint.py) only at the gate, a full gate cycle per finding (2026-10-22).
#
# --fix also adds `docs/decisions.md merge=union` to the root .gitattributes when it is missing,
# leaving the edit for the developer to commit: this is the one devkit path that installs
# repo-side setup (`make install`), and docs_check rule 12 reports the line missing in ci-quick,
# where this check never runs. Why union: bin/_gitattributes_lib.sh.
#
# --fix also gives docs/metrics/{ratchet,report-only,scorecard}.json devkit's per-key merge driver
# when the repo has docs/metrics/: the .gitattributes lines (left to commit) and this clone's
# merge.devkit-metrics.driver config, which no commit can carry (bin/_gitattributes_lib.sh). The
# check warns, never fails, when the lines are committed but this clone's driver is unset or not
# the vendored command; every hook and devkit-sync set it (metrics_driver_heal).
#
# Usage: devkit/bin/hooks_check.sh [--fix] [repo-root]
#   repo-root defaults to the current checkout. --fix sets core.hooksPath to .githooks (the
#   relative form, so each worktree runs its own checkout's hooks), installs a missing hook as a
#   byte copy of its template (executable; devkit-check's base copies then hold it there), and
#   adds the .gitattributes line before checking. Installed files are left for the developer
#   to commit.
#   Prints "hooks-check: ok" (exit 0) or "hooks-check: <reason>" (exit 1). Exit 2 on usage.
#   Under CI/GITHUB_ACTIONS it prints "hooks-check: skipped (CI)" and exits 0: runners never
#   install hooks, and the workflows run the checks themselves.
set -euo pipefail

FIX=0
ROOT=
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    -*) echo "usage: $0 [--fix] [repo-root]" >&2; exit 2 ;;
    *) [ -z "$ROOT" ] || { echo "usage: $0 [--fix] [repo-root]" >&2; exit 2; }; ROOT=$arg ;;
  esac
done

if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "hooks-check: skipped (CI)"; exit 0
fi

fail() { echo "hooks-check: $*"; exit 1; }

# shellcheck source=/dev/null  # bin/hook_steps.sh: _hook_parse_step, the one parser for hooks.conf steps
. "$(dirname "${BASH_SOURCE[0]}")/hook_steps.sh"
# shellcheck source=bin/_gitattributes_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_gitattributes_lib.sh"

ROOT=$(git -C "${ROOT:-.}" rev-parse --show-toplevel 2>/dev/null) || fail "${ROOT:-.} is not a git checkout"
ROOT=$(cd "$ROOT" && pwd -P)
# -P: a bin/ reached through a symlink still finds the templates of the devkit it belongs to.
TEMPLATES=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../templates/githooks
HOOKS=()
for template in "$TEMPLATES"/*; do
  if [ -f "$template" ]; then HOOKS+=("${template##*/}"); fi
done
[ "${#HOOKS[@]}" -gt 0 ] || { echo "hooks-check: no hook templates at $TEMPLATES" >&2; exit 2; }

if [ "$FIX" = 1 ]; then
  was=$(git -C "$ROOT" config --get core.hooksPath || true)
  if [ "$was" != .githooks ]; then
    git -C "$ROOT" config core.hooksPath .githooks
    echo "hooks-check: set core.hooksPath=.githooks (was '${was:-unset}')"
  fi
  for hook in "${HOOKS[@]}"; do
    [ ! -e "$ROOT/.githooks/$hook" ] || continue
    mkdir -p "$ROOT/.githooks"
    cp "$TEMPLATES/$hook" "$ROOT/.githooks/$hook"
    chmod +x "$ROOT/.githooks/$hook"
    echo "hooks-check: installed .githooks/$hook from devkit/templates/githooks; commit it"
  done
  attrs=$ROOT/.gitattributes
  if ! has_decisions_union "$attrs"; then
    # Start a new line when the file's last one has no newline.
    if [ -s "$attrs" ] && [ -n "$(tail -c 1 "$attrs")" ]; then echo >>"$attrs"; fi
    echo "$DECISIONS_UNION_LINE" >>"$attrs"
    echo "hooks-check: added '$DECISIONS_UNION_LINE' to .gitattributes; commit it"
  fi
  if [ -d "$ROOT/docs/metrics" ]; then
    added=0
    while IFS= read -r line; do
      grep -qxF "$line" "$attrs" 2>/dev/null && continue
      if [ -s "$attrs" ] && [ -n "$(tail -c 1 "$attrs")" ]; then echo >>"$attrs"; fi
      echo "$line" >>"$attrs"
      added=1
    done <<<"$METRICS_MERGE_LINES"
    [ "$added" = 0 ] || echo "hooks-check: added the docs/metrics merge=devkit-metrics lines to .gitattributes; commit it"
  fi
  metrics_driver_heal "$ROOT" "$(dirname "${BASH_SOURCE[0]}")" hooks-check
fi

HOOKS_PATH=$(git -C "$ROOT" config --get core.hooksPath || true)
case "$HOOKS_PATH" in
  .githooks|.githooks/|./.githooks|./.githooks/) ;;
  "") fail "core.hooksPath is unset, so .githooks never runs (fix: $0 --fix)" ;;
  /*)
    resolved=$(cd "$HOOKS_PATH" 2>/dev/null && pwd -P) || resolved=
    [ "$resolved" = "$ROOT/.githooks" ] ||
      fail "core.hooksPath is '$HOOKS_PATH', not $ROOT/.githooks (fix: $0 --fix)"
    ;;
  *) fail "core.hooksPath is '$HOOKS_PATH', not .githooks (fix: $0 --fix)" ;;
esac

for hook in "${HOOKS[@]}"; do
  [ -e "$ROOT/.githooks/$hook" ] || fail ".githooks/$hook is missing (fix: $0 --fix)"
  [ -x "$ROOT/.githooks/$hook" ] || fail ".githooks/$hook is not executable (fix: chmod +x and commit the mode)"
done

if grep -qs 'filter=lfs' "$ROOT/.gitattributes" && ! grep -qE 'git lfs pre-push|run_hook_steps pre-push' "$ROOT/.githooks/pre-push"; then
  fail ".gitattributes uses LFS but .githooks/pre-push does not chain 'git lfs pre-push', so LFS objects never upload"
fi

if want=$(metrics_driver_wanted "$ROOT" "$(dirname "${BASH_SOURCE[0]}")"); then
  have=$(git -C "$ROOT" config --get merge.devkit-metrics.driver || true)
  if [ -z "$have" ]; then
    echo "hooks-check: warning: .gitattributes names merge=devkit-metrics but this clone has no driver, so docs/metrics/*.json merge as text (fix: $0 --fix)" >&2
  elif [ "$have" != "$want" ]; then
    echo "hooks-check: warning: this clone's merge.devkit-metrics.driver is '$have', not the vendored '$want' (fix: $0 --fix; the next hook run sets it too)" >&2
  fi
fi

CONF=$ROOT/scripts/ci/hooks.conf
if [ -f "$CONF" ]; then
  check_steps() { # <array name> <steps...>: print the first bad step's error
    local name=$1 step
    shift
    for step in "$@"; do
      _hook_parse_step "$step" || { echo "error $name: $HOOK_STEP_ERROR"; return 0; }
    done
  }
  slow_precommit_steps() { # <steps...>: a warning line per step that typechecks or runs unit tests
    local step word words
    for step in "$@"; do
      _hook_parse_step "$step" || continue
      IFS='-_' read -r -a words <<<"$HOOK_STEP_TARGET"
      for word in "${words[@]}"; do
        case "$word" in
          typecheck|unit)
            echo "hooks-check: warning: scripts/ci/hooks.conf runs '$HOOK_STEP_LABEL' ($HOOK_STEP_TARGET) at pre-commit; typecheck and unit steps belong in PRE_PUSH_STEPS (devkit README \"Git hooks\": pre-commit p90 <= 30 s)"
            break ;;
        esac
      done
    done
  }
  unlinted_precommit() { # <steps...>: a warning line when the Makefile has ci-lint and no step runs it
    local step
    case "$(cd "$ROOT" && makefile_targets)" in *" ci-lint "*) ;; *) return 0 ;; esac
    for step in "$@"; do
      _hook_parse_step "$step" || continue
      case "$HOOK_STEP_TARGET" in ci-lint|ci-lint-*|ci-quick) return 0 ;; esac
    done
    echo "hooks-check: warning: the Makefile has ci-lint but no PRE_COMMIT_STEPS entry runs it (ci-lint, ci-lint-<area> or ci-quick), so a line-length or changed-file lint finding surfaces only at the gate; add \"lint=ci-lint\" to scripts/ci/hooks.conf"
  }
  # One subshell sources the conf: "error <reason>" lines fail the check, other lines are warnings.
  conf_report=$(
    PRE_COMMIT_STEPS=() PRE_PUSH_STEPS=() COMMIT_MSG_STEPS=()
    # shellcheck source=/dev/null
    . "$CONF" || { echo "error cannot be sourced"; exit 0; }
    check_steps PRE_COMMIT_STEPS ${PRE_COMMIT_STEPS[@]+"${PRE_COMMIT_STEPS[@]}"}
    check_steps PRE_PUSH_STEPS ${PRE_PUSH_STEPS[@]+"${PRE_PUSH_STEPS[@]}"}
    for step in ${COMMIT_MSG_STEPS[@]+"${COMMIT_MSG_STEPS[@]}"}; do
      _hook_parse_msg_step "$step" || { echo "error COMMIT_MSG_STEPS: $HOOK_STEP_ERROR"; break; }
    done
    slow_precommit_steps ${PRE_COMMIT_STEPS[@]+"${PRE_COMMIT_STEPS[@]}"}
    unlinted_precommit ${PRE_COMMIT_STEPS[@]+"${PRE_COMMIT_STEPS[@]}"}
  )
  conf_error=$(grep -m1 '^error ' <<<"$conf_report" || true)
  [ -z "$conf_error" ] || fail "scripts/ci/hooks.conf ${conf_error#error }"
  grep -v '^error ' <<<"$conf_report" | grep . >&2 || true
fi

echo "hooks-check: ok"
