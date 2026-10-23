#!/usr/bin/env bash
# `make merge PR=<n>`: squash-merge PR <n> under origin/main's merge rules (merge_rules.sh, whose
# header is the contract). Every repo's Makefile calls this one line, as it calls gate.sh:
#
#   merge: ; devkit/bin/pr_merge.sh "$(PR)"
#
# The rules and the plan they read are main's, never this checkout's: fetch_main, then run
# main's merge_rules.sh from main's copy of this directory (devkit/bin/ in a consumer, bin/ in
# devkit itself), extracted to a temp dir, with GATE_PLAN set to main's scripts/ci/gate_plan.sh,
# against this repo. Why (homelab #134, 2026-10-23): a checkout on a feature branch whose vendored
# devkit differed from main's ran that branch's rules, so any branch could change, or weaken, the
# rules its own or another PR merges under. The same principle as gate_plan_main and the gate's
# merged tree: what enforces is what main holds. A checkout whose devkit is NEWER than main's
# does not win either: a devkit change to the rules governs a repo's merges once it is on that
# repo's main, its own sync PR included.
# A caller's GATE_PLAN still wins, as for gate.sh (a plan outside the repo, the tests).
# Bootstrap: a main with no merge_rules.sh at this path (its devkit predates main-decided rules,
# or devkit's own main before 2026-10-23) has no rules to defer to, so this checkout's run, with
# one note line naming main. Nothing else falls back: a failed fetch, archive or a main with no
# plan is exit 2.
# Residual: this entry is the checkout's own. devkit-check holds a consumer's devkit/ to the
# devkit commit its .devkit-rev names, and every such commit since this one carries this entry.
# Exit: merge_rules.sh's (0 merged, 1 refused, 2 usage or environment, else gh's own code).
set -uo pipefail

usage() { echo "usage: $0 <pr-number>"; }
[ $# -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  ''|*[!0-9]*) usage >&2; exit 2 ;;
esac

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh  # fetch_main
. "$HERE/_gate_env.sh"
ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 2
# This directory's path in the repo: devkit/bin/ in a consumer, bin/ in devkit.
PREFIX=$(git -C "$HERE" rev-parse --show-prefix) || exit 2

fetch_main "$ROOT" || { echo "merge: cannot fetch origin main, whose rules decide the merge (git above)" >&2; exit 2; }
# The full ref: a local branch named origin/main would otherwise win.
MAIN=$(git -C "$ROOT" rev-parse --verify -q refs/remotes/origin/main) \
  || { echo "merge: no origin/main after the fetch" >&2; exit 2; }
if ! git -C "$ROOT" cat-file -e "$MAIN:${PREFIX}merge_rules.sh" 2>/dev/null; then
  echo "merge: origin/main ${MAIN:0:12} has no ${PREFIX}merge_rules.sh (its devkit predates main-decided rules); this checkout's rules decide"
  exec "$HERE/merge_rules.sh" "$ROOT" "$1"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/devkit-merge.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
git -C "$ROOT" archive "$MAIN" -- "$PREFIX" | tar -x -C "$TMP" \
  || { echo "merge: cannot extract ${PREFIX} of origin/main ${MAIN:0:12} (git above)" >&2; exit 2; }
if [ -z "${GATE_PLAN:-}" ]; then
  git -C "$ROOT" show "$MAIN:scripts/ci/gate_plan.sh" >"$TMP/gate_plan.sh" 2>/dev/null \
    || { echo "merge: origin/main ${MAIN:0:12} has no scripts/ci/gate_plan.sh" >&2; exit 2; }
  export GATE_PLAN=$TMP/gate_plan.sh
fi
echo "merge: rules and plan from origin/main ${MAIN:0:12}"
"$TMP/${PREFIX}merge_rules.sh" "$ROOT" "$1"
