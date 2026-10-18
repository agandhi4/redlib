#!/usr/bin/env bash
# `make merge PR=<n>`: squash-merge PR <n> only when the gate passed on its CURRENT head. Every
# repo's Makefile calls this one line, as it calls gate.sh:
#
#   merge: ; devkit/bin/pr_merge.sh "$(PR)"
#
# Why: branch protection is unavailable on the fleet's private repos (free plan, 403), so nothing
# on GitHub stops a merge of a head the gate never saw (standardization/scorecard-design.md §5).
# This is the merge path that checks for itself; gate_bite.py counts the merges that skipped it.
#
# Refuses (exit 1, one `merge: refused: …` line on stderr) unless:
#   - the PR is OPEN;
#   - its head's latest `local-gate` status is `success` (GitHub's combined status: the newest
#     status per context), and so is every context the plan's literal
#     `GATE_MERGE_REQUIRES=<context>[,<context>...]` line names (closet: codex-review).
#   - main has not moved past the main the gate ran on: the gate's own record of this head
#     ($XDG_STATE_HOME/<GATE_STATE_NAME>/logs/<n>/gate.json, gate_record.py main-of), else the
#     `on main <sha>` its local-gate status names (a remote gate's record is on its host), against
#     GitHub's main now. A moved main prints `re-gate: main moved <sha>→<sha>`: the gate tested
#     the merge into a main that no longer exists. Neither source naming a main is a refusal.
# Then runs `gh pr merge <n> --squash --match-head-commit <head> --delete-branch`, so a push
# between the check and the merge makes GitHub refuse it, and exits with gh's code.
# That one gh call, and only it, carries DEVKIT_MERGE_VERIFIED=<the full head sha>: no paid
# GitHub features (owner, 2026-10-18), so a gh shim refuses any `pr merge` whose
# --match-head-commit is not that value, and this is the fleet's only merge path. Any inherited
# value is dropped first, so it can only ever name a head checked here.
#
# The plan is scripts/ci/gate_plan.sh of the repo holding this script (GATE_PLAN overrides it, as
# for gate.sh); only its literal GATE_SLUG and GATE_MERGE_REQUIRES lines are read, never sourced.
# Exit: 0 merged, 1 refused, 2 usage or environment (no gh, no slug, gh could not answer),
# otherwise gh pr merge's own code.
set -uo pipefail

readonly GATE_CONTEXT=local-gate

usage() { echo "usage: $0 <pr-number>"; }
[ $# -eq 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  ''|*[!0-9]*) usage >&2; exit 2 ;;
esac
PR=$1
unset DEVKIT_MERGE_VERIFIED

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"
ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 2
PLAN=${GATE_PLAN:-$ROOT/scripts/ci/gate_plan.sh}

command -v gh >/dev/null || { echo "merge: gh not found (brew install gh)" >&2; exit 2; }
[ -f "$PLAN" ] || { echo "merge: no plan at $PLAN" >&2; exit 2; }
SLUG=$(gate_plan_literal "$PLAN" GATE_SLUG)
[ -n "$SLUG" ] || { echo "merge: $PLAN has no literal GATE_SLUG=owner/repo line" >&2; exit 2; }
REQUIRED=$GATE_CONTEXT
extra=$(gate_plan_literal "$PLAN" GATE_MERGE_REQUIRES)
[ -z "$extra" ] || REQUIRED="$REQUIRED ${extra//,/ }"

refuse() { echo "merge: refused: $*" >&2; exit 1; }

info=$(gh pr view "$PR" --repo "$SLUG" --json state,headRefOid --jq '[.state, .headRefOid] | @tsv') \
  || { echo "merge: cannot read PR #$PR of $SLUG (gh above)" >&2; exit 2; }
IFS=$'\t' read -r state head <<<"$info"
[ "$state" = OPEN ] || refuse "PR #$PR is ${state:-unknown}, not OPEN"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "merge: gh gave no head commit for PR #$PR ('$head')" >&2; exit 2; }

statuses=$(gh api "repos/$SLUG/commits/$head/status?per_page=100" \
  --jq '.statuses[] | [.context, .state, .description] | @tsv') \
  || { echo "merge: cannot read the statuses of $SLUG@${head:0:12} (gh above)" >&2; exit 2; }
wrong=""
for context in $REQUIRED; do
  got=$(awk -F'\t' -v c="$context" '$1 == c { print $2; exit }' <<<"$statuses")
  [ "$got" = success ] || wrong="${wrong:+$wrong, }$context=${got:-none}"
done
if [ -n "$wrong" ]; then
  hint=""
  case " $wrong" in *" $GATE_CONTEXT="*) hint="; run make gate PR=$PR on this head" ;; esac
  refuse "PR #$PR head ${head:0:12} has $wrong (each of '$REQUIRED' must be success)$hint"
fi

gated_main=""
state_name=$(gate_plan_literal "$PLAN" GATE_STATE_NAME)
record=${XDG_STATE_HOME:-$HOME/.local/state}/$state_name/logs/$PR/gate.json
if [ -n "$state_name" ] && [ -f "$record" ]; then
  gated_main=$(python3 -I "$HERE/gate_record.py" main-of "$record" "$head") \
    || { echo "merge: cannot read $record (python3 above)" >&2; exit 2; }
fi
if [ -z "$gated_main" ]; then
  description=$(awk -F'\t' -v c="$GATE_CONTEXT" '$1 == c { print $3; exit }' <<<"$statuses")
  [[ "$description" =~ on\ main\ ([0-9a-f]{7,40}) ]] && gated_main=${BASH_REMATCH[1]}
fi
[ -n "$gated_main" ] || refuse "re-gate: cannot tell which main the gate of ${head:0:12} ran on (no $record and no \`on main <sha>\` in its status); run make gate PR=$PR"
main_now=$(gh api "repos/$SLUG/commits/main" --jq .sha) && [[ "$main_now" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "merge: cannot read main of $SLUG (gh above)" >&2; exit 2; }
case "$main_now" in
  "$gated_main"*) ;;
  *) refuse "re-gate: main moved ${gated_main:0:12}→${main_now:0:12}; run make gate PR=$PR" ;;
esac

echo "merge: PR #$PR head ${head:0:12}: $REQUIRED success on main ${main_now:0:12}; squash-merging"
exec env DEVKIT_MERGE_VERIFIED="$head" gh pr merge "$PR" --repo "$SLUG" --squash --match-head-commit "$head" --delete-branch
