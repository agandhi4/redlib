#!/usr/bin/env bash
# Assert this checkout's git hooks actually run: core.hooksPath points at the repo's tracked
# .githooks/, and pre-commit and pre-push there exist and are executable.
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
# preflight, naming the step, instead of blocking the next commit.
#
# Usage: devkit/bin/hooks_check.sh [--fix] [repo-root]
#   repo-root defaults to the current checkout. --fix sets core.hooksPath to .githooks (the
#   relative form, so each worktree runs its own checkout's hooks) before checking.
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

ROOT=$(git -C "${ROOT:-.}" rev-parse --show-toplevel 2>/dev/null) || fail "${ROOT:-.} is not a git checkout"
ROOT=$(cd "$ROOT" && pwd -P)

if [ "$FIX" = 1 ]; then
  was=$(git -C "$ROOT" config --get core.hooksPath || true)
  if [ "$was" != .githooks ]; then
    git -C "$ROOT" config core.hooksPath .githooks
    echo "hooks-check: set core.hooksPath=.githooks (was '${was:-unset}')"
  fi
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

for hook in pre-commit pre-push; do
  [ -e "$ROOT/.githooks/$hook" ] || fail ".githooks/$hook is missing"
  [ -x "$ROOT/.githooks/$hook" ] || fail ".githooks/$hook is not executable (fix: chmod +x and commit the mode)"
done

if grep -qs 'filter=lfs' "$ROOT/.gitattributes" && ! grep -qE 'git lfs pre-push|run_hook_steps pre-push' "$ROOT/.githooks/pre-push"; then
  fail ".gitattributes uses LFS but .githooks/pre-push does not chain 'git lfs pre-push', so LFS objects never upload"
fi

CONF=$ROOT/scripts/ci/hooks.conf
if [ -f "$CONF" ]; then
  check_steps() { # <array name> <steps...>: print the first bad step's error
    local name=$1 step
    shift
    for step in "$@"; do
      _hook_parse_step "$step" || { echo "$name: $HOOK_STEP_ERROR"; return 0; }
    done
  }
  conf_error=$(
    PRE_COMMIT_STEPS=() PRE_PUSH_STEPS=()
    # shellcheck source=/dev/null
    . "$CONF" || { echo "cannot be sourced"; exit 0; }
    check_steps PRE_COMMIT_STEPS ${PRE_COMMIT_STEPS[@]+"${PRE_COMMIT_STEPS[@]}"}
    check_steps PRE_PUSH_STEPS ${PRE_PUSH_STEPS[@]+"${PRE_PUSH_STEPS[@]}"}
  )
  [ -z "$conf_error" ] || fail "scripts/ci/hooks.conf ${conf_error%%$'\n'*}"
fi

echo "hooks-check: ok"
