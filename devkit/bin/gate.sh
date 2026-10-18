#!/usr/bin/env bash
# `make gate` entry point: runs the PR gate on this machine (local_gate.sh) or on the gate host
# (remote_gate.sh). Every repo's Makefile calls this one line, so where gates run is a property
# of the machine, not of the repo:
#
#   gate: ; devkit/bin/gate.sh "$(PR)" $(GATE_ARGS)
#
# Remote when GATE_REMOTE_HOST is set (environment, or ~/.config/devkit/gate.env), unless:
#   - the repo's plan has a literal `GATE_REMOTE=0` line: the repo cannot be gated elsewhere
#     (an Xcode gate needs this Mac). The plan wins over everything below.
#   - GATE_REMOTE=0 (environment or gate.env): this run, or this machine, stays local.
#   - GATE_PLAN is set: a plan file outside the repo exists only on this machine.
# GATE_REMOTE=1 with no host is a usage error, never a silent local run.
#
# Expected head: the local branch named by the PR (gh's headRefName) holds the commit the
# caller means, so its tip is passed on as `--expect-head <sha>` and the gate waits for GitHub
# to show it (local_gate.sh header, "Expected head"). The branch need not be checked out: a
# lane pushes from its worktree and gates from another checkout of the same repo, and a gate
# started there right after a force-push gated the old head (finplat merge-queue lane,
# 2026-10-17). A local branch strictly behind its last-fetched origin/<branch> is a stale copy,
# not the caller's intent, and adds no expectation (with a note). Decided here, on the invoking
# machine, because the remote host's checkout is always on main. An explicit --expect-head in
# GATE_ARGS wins; no such local branch, no literal GATE_SLUG or a gh error means no
# expectation, the old behaviour.
# Exit codes are those of the gate that runs (0 pass, 1 fail, 2 usage or environment).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"

gate_env_load gate "$GATE_REMOTE_KEYS" "$GATE_LOCAL_KEYS"
gate_remote_settings_check

ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 2
PLAN=$ROOT/scripts/ci/gate_plan.sh

where=local
if [ -n "${GATE_PLAN:-}" ]; then
  where=local
elif [ -f "$PLAN" ] && [ "$(gate_plan_literal "$PLAN" GATE_REMOTE)" = 0 ]; then
  where=local
elif [ "${GATE_REMOTE:-}" = 0 ]; then
  where=local
elif [ -n "${GATE_REMOTE_HOST:-}" ]; then
  where=remote
elif [ "${GATE_REMOTE:-}" = 1 ]; then
  echo "gate: GATE_REMOTE=1 but GATE_REMOTE_HOST is not set (environment or gate.env)" >&2
  exit 2
fi

# expect_head_args <args...>: sets EXPECT_ARGS to `--expect-head <tip>` or nothing (header).
EXPECT_ARGS=()
expect_head_args() {
  local arg pr="" slug head_ref tip tracked
  for arg in "$@"; do
    case "$arg" in
      --expect-head) return 0 ;;
      ''|*[!0-9]*) ;;
      *) pr=$arg ;;
    esac
  done
  [ -n "$pr" ] || return 0
  [ -f "${GATE_PLAN:-$PLAN}" ] || return 0
  slug=$(gate_plan_literal "${GATE_PLAN:-$PLAN}" GATE_SLUG)
  [ -n "$slug" ] || return 0
  head_ref=$(gh pr view "$pr" --repo "$slug" --json headRefName --jq .headRefName 2>/dev/null) || return 0
  [ -n "$head_ref" ] || return 0
  tip=$(git -C "$ROOT" rev-parse -q --verify "refs/heads/$head_ref^{commit}") || return 0
  tracked=$(git -C "$ROOT" rev-parse -q --verify "refs/remotes/origin/$head_ref^{commit}") || tracked=""
  if [ -n "$tracked" ] && [ "$tracked" != "$tip" ] && git -C "$ROOT" merge-base --is-ancestor "$tip" "$tracked"; then
    echo "gate: local $head_ref (${tip:0:12}) is behind origin/$head_ref (${tracked:0:12}); gating without an expected head" >&2
    return 0
  fi
  EXPECT_ARGS=(--expect-head "$tip")
}
expect_head_args "$@"

if [ "$where" = remote ]; then exec "$HERE/remote_gate.sh" "$@" ${EXPECT_ARGS[@]+"${EXPECT_ARGS[@]}"}; fi
exec "$HERE/local_gate.sh" "$@" ${EXPECT_ARGS[@]+"${EXPECT_ARGS[@]}"}
