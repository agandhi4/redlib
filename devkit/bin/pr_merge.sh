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
#   - Codex is not reviewing the PR, and every review thread whose first comment is Codex's is
#     resolved (codex_review.py: its summary comment's state marker and GraphQL isResolved). A
#     reply alone leaves a thread open: the fixer replies (fixed in <sha>, or why not), then
#     resolves it; resolving changes no commit, so the gate stays valid. Threads other reviewers
#     open never block. Why (2026-10-21): nine PRs across four repos merged with ~40 unanswered
#     Codex findings, several real bugs. There is no override: resolving a thread with the reason
#     is the override, and it is on the record. A Codex state codex_review.py does not know is
#     exit 2 (devkit#188). A review running longer than the plan's literal
#     `GATE_CODEX_RUNNING_MAX_MIN=<minutes>` (default 30) is hung, not running: it is treated as
#     failed, below, and the refusal names its age. Why (devkit #204, 2026-10-22): a review sat at
#     "Running since" for 40+ min and a re-ping hung again, so `running` held the merge forever.
#   - Only where the plan has a literal `GATE_CODEX_REVIEW=1` (devkit#188; opt-in, so a repo Codex
#     does not review is unaffected): Codex reviewed THIS head. A code review that failed or
#     hung, never ran, or is of an older commit refuses, unless the head's
#     `codex-review` status is success and records a fallback review of this head: "Claude
#     adversarial review (Codex <why>) of <sha7>", <why> one of `at limit` (claude-kit work loop
#     §3c), `hung <N> min` or `failed`, so the record says what happened (the refusal offers the
#     one codex_review.py's blocker names: a failure followed by Codex's usage-limit note is
#     `at limit`, any other `failed`), or codex_gate.py --on-limit
#     self-review's "Codex unavailable (usage limit); <sha8> passed on Claude self-review" (the
#     headless worker, owner 2026-09-27). Codex's open threads still block then, as in
#     codex_gate.py. A head-pinned review of the head also excuses a stale Codex review: what
#     Codex saw of an older commit adds nothing a review of the head lacks. Nor is a review
#     required of a Renovate or Dependabot PR whose every commit is that bot's and whose diff
#     changes only dependency pins (_dependency_pr.py exempt: whole manifests and lockfiles,
#     compose `image:` and Dockerfile `FROM` lines, lines under a `renovate:` comment); it prints
#     `codex-review: not required (bot dependency PR, manifest-only diff)`. Why: Codex never
#     reviews bot PRs (homelab #109/#110), so the nightly dependency merge was refused forever.
#     Nor of a PR whose every changed path, both sides of a rename, is `docs` in _paths_lib.sh's
#     table (the one the hooks and gate use, so docs/metrics/ratchet.json stays reviewed); it
#     prints `codex-review: not required (docs-only diff)`. Why (owner policy, closet #422):
#     claude-kit work-loop §3c skips Codex for docs-only PRs, so one was refused whenever Codex
#     was at its limit or a push left its review stale. Paths decide, never a label or a status
#     text, so no one can call a code PR docs-only. Neither exemption holds for a PR with no
#     changed files, or one whose files GitHub listed short of `changedFiles` (the API stops at
#     3000). Their open threads, and a running review, still block.
#     Nor of a devkit sync: a PR whose every changed path only vendors devkit at its head
#     (_vendor_paths.sh vendoring_only: devkit/ is the tree .devkit-rev records, every other path
#     is .devkit-rev or a base copy byte-equal to its base) from a commit on devkit's main that
#     descends from main's vendored one (vendored_from, against a fresh fetch of DEVKIT_URL); it
#     prints `codex-review: not required (devkit sync, vendoring-only diff from devkit main)`.
#     Why (owner, 2026-10-22): the nightly sync (dependency_merge.sh) opens one per repo per
#     devkit change, and the code is devkit's own, Codex-reviewed and gated on devkit main, so a
#     second review per consumer adds nothing; its effect on the repo is the gate's to judge.
#     Content decides, not the label or the author: a hand edit under devkit/, a downgrade or any
#     repo-owned path (a metrics-tighten of docs/metrics/ratchet.json included) takes the
#     normal rule.
# A draft that passes every check above is marked ready (`gh pr ready`, one `merge: … marked it
# ready` line) and then merged: the fleet Workflow gates a PR while it is a draft, and GitHub
# refuses to merge one (locus #136 needed a hand `gh pr ready`). A draft that fails a check is
# refused like any PR and stays a draft, an unreviewed one too, although readying it would ask
# Codex for its review: a refusal changes nothing on GitHub (rerun freely), and readying also
# starts the fleet Workflow for a PR that may never merge. `@codex review` works on a draft.
# A PR labelled metrics-rebaseline gets one `Metrics-Rebaseline: <key>=<old>→<new>` trailer per
# bound its head loosens in docs/metrics/ratchet.json against main (metrics_ratchet.py loosened,
# both commits fetched from origin), appended to the PR body as the squash body (`--body`). Why
# (instalite 2026-10-19): the label is not in git, so the scorecard's TREND guessed from the
# message and read a labelled loosening UNLABELLED; the trailer is the label's record in git,
# and scorecard.py counts a worsen labelled only when one names its key.
# Then runs `gh pr merge <n> --squash --match-head-commit <head> --delete-branch`, so a push
# between the check and the merge makes GitHub refuse it. GitHub's refusals that mean "what was
# gated is not what would land" (head or main moved under the merge, or a head behind a main whose
# protection wants it up to date) become one `merge: refused: re-gate: …` line and exit 1, the
# same as main moving before the call; any other gh failure exits with gh's code. homelab #128
# (2026-10-22): Renovate's rebase push landed during the merge ("Head branch is out of date").
# That one gh call, and only it, carries DEVKIT_MERGE_VERIFIED=<the full head sha>: no paid
# GitHub features (owner, 2026-10-18), so a gh shim refuses any `pr merge` whose
# --match-head-commit is not that value, and this is the fleet's only merge path. Any inherited
# value is dropped first, so it can only ever name a head checked here.
#
# The plan is scripts/ci/gate_plan.sh of the repo holding this script (GATE_PLAN overrides it, as
# for gate.sh); only its literal GATE_SLUG, GATE_MERGE_REQUIRES, GATE_CODEX_REVIEW,
# GATE_CODEX_RUNNING_MAX_MIN, GATE_STATE_NAME and GATE_CODE_PATHS lines are read, never sourced.
# Exit: 0 merged, 1 refused (GitHub's moved-head refusals included), 2 usage or environment (no
# gh, no slug, gh could not answer), otherwise gh pr merge's own code.
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
# shellcheck source=bin/_paths_lib.sh  # the path table: what a docs-only diff is (docs_exempt)
. "$HERE/_paths_lib.sh"
# shellcheck source=bin/_toolchain_lib.sh
. "$HERE/_toolchain_lib.sh"
# shellcheck source=bin/_vendor_paths.sh  # vendoring_only, vendored_from: the devkit-sync exemption
. "$HERE/_vendor_paths.sh"
ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 2
PLAN=${GATE_PLAN:-$ROOT/scripts/ci/gate_plan.sh}

devkit_preflight gh git || { echo "merge: $DEVKIT_PREFLIGHT_ERROR" >&2; exit 2; }
[ -f "$PLAN" ] || { echo "merge: no plan at $PLAN" >&2; exit 2; }
SLUG=$(gate_plan_literal "$PLAN" GATE_SLUG)
# The path table's repo carve-out (_paths_lib.sh header), read by docs_exempt.
devkit_load_code_paths "$PLAN"
[ -n "$SLUG" ] || { echo "merge: $PLAN has no literal GATE_SLUG=owner/repo line" >&2; exit 2; }
REQUIRED=$GATE_CONTEXT
extra=$(gate_plan_literal "$PLAN" GATE_MERGE_REQUIRES)
[ -z "$extra" ] || REQUIRED="$REQUIRED ${extra//,/ }"

refuse() { echo "merge: refused: $*" >&2; exit 1; }
# The two fallback records (header), whole, with the reviewed head last: a head SHA anywhere
# else in the text is no record of it (#207 Codex). "Claude adversarial review (Codex <why>) of
# <sha7>" is fallback_hint's; `at limit` was its only <why> until 2026-10-22 and is still
# claude-kit §3c's, so it must match. The other is codex_gate.py --on-limit self-review's.
readonly FALLBACK_RECORD_RES=(
  '^Claude adversarial review \(Codex (at limit|hung [1-9][0-9]* min|failed)\) of ([0-9a-f]{7,40})$'
  '^Codex unavailable \(usage limit\); ([0-9a-f]{7,40}) passed on Claude self-review$'
)
# The blockers that say Codex did not review this head (codex_review.py), which only an opted-in
# plan refuses and a fallback record excuses.
readonly REVIEW_GAPS=$'^(failed|hung|unreviewed|stale)\t'
readonly CODEX_RUNNING_MAX_MIN=30

# refuse_codex <codex_review.py lines>: the refusal line, then how to clear it: one line per
# unresolved finding (path:line, title, URL, thread id) and how to resolve one, or how to get
# the head reviewed.
refuse_codex() {
  local running gaps findings
  running=$(awk -F'\t' '$1 == "running" { printf "%s%s of %s", sep, $2, substr($3, 1, 12); sep = ", " }' <<<"$1")
  gaps=$(grep -E "$REVIEW_GAPS" <<<"$1")
  findings=$(awk -F'\t' '$1 == "unresolved" { n++ } END { print n + 0 }' <<<"$1")
  if [ -n "$running" ]; then
    echo "merge: refused: Codex review still running on PR #$PR ($running); make merge again when its summary comment says Completed (unresolved findings so far: $findings)" >&2
  elif [ -n "$gaps" ]; then
    echo "merge: refused: no Codex review of PR #$PR's head ${head:0:12} (GATE_CODEX_REVIEW=1; unresolved findings: $findings)" >&2
    review_gap_hints "$gaps"
  else
    echo "merge: refused: PR #$PR has $findings unresolved Codex finding(s); fix or answer each, then resolve its thread (a reply alone does not count)" >&2
  fi
  awk -F'\t' '$1 == "unresolved" { print "merge:   " $3 " " $4 " " $5 " (thread " $2 ")" }' <<<"$1" >&2
  [ "$findings" = 0 ] || echo "merge: resolve: gh api graphql -f query='mutation(\$id: ID!) { resolveReviewThread(input: {threadId: \$id}) { thread { isResolved } } }' -f id=<thread>" >&2
  exit 1
}

# review_gap_hints <gap lines>: what each gap means and the one way out of it. The fallback
# record is offered only where Codex cannot review (failed, hung, or a usage-limit note answering
# the newest request, codex_review.py): a review merely stale or not yet posted wants Codex, not a
# stand-in.
review_gap_hints() {
  local kind sha detail
  local review="Run claude-kit work-loop's Claude adversarial review (SKILL.md §3c), fix what it finds, then record it on this head:"
  # <detail>: a hung review's minutes, any other gap's cause, `limit` or `-` (codex_review.py).
  while IFS=$'\t' read -r kind _ sha detail; do
    case $kind in
      unreviewed)
        if [ "$detail" = limit ]; then
          echo "merge:   Codex has not reviewed it: it posted its usage-limit note instead (comment '@codex review' once the limit resets). $review" >&2
          fallback_hint "at limit"
        else
          echo "merge:   Codex has not reviewed it yet: wait for its summary comment, or comment '@codex review' (a draft: mark it ready, or comment)" >&2
        fi ;;
      stale)
        if [ "$detail" = limit ]; then
          echo "merge:   Codex reviewed ${sha:0:12}, an older commit, and has posted its usage-limit note since (comment '@codex review' once the limit resets). $review" >&2
          fallback_hint "at limit"
        else
          echo "merge:   Codex reviewed ${sha:0:12}, an older commit: comment '@codex review' for this head" >&2
        fi ;;
      failed)
        if [ "$detail" = limit ]; then
          echo "merge:   Codex's review of ${sha:0:12} failed at its usage limit. $review" >&2
          fallback_hint "at limit"
        else
          echo "merge:   Codex's review of ${sha:0:12} failed, with no usage-limit note after it ('@codex review' may retry it). $review" >&2
          fallback_hint failed
        fi ;;
      hung)
        echo "merge:   Codex's review of ${sha:0:12} has run $detail min, over GATE_CODEX_RUNNING_MAX_MIN=$running_max: treated as failed. $review" >&2
        fallback_hint "hung $detail min" ;;
    esac
  done <<<"$1"
  local recorded
  recorded=$(codex_review_success)
  [ -z "$recorded" ] || echo "merge:   the head's codex-review success ('$recorded') records no fallback review of ${head:0:7}" >&2
  [ -z "$not_exempt" ] || echo "merge:   a bot PR, but its review is required: $not_exempt" >&2
  [ -z "$not_docs" ] || echo "merge:   not docs-only, so its review is required: $not_docs" >&2
  [ -z "$not_sync" ] || echo "merge:   it changes .devkit-rev, but is no devkit sync, so its review is required: $not_sync" >&2
}

fallback_hint() { # <why>
  echo "merge:   gh api repos/$SLUG/statuses/$head -f state=success -f context=codex-review -f description='Claude adversarial review (Codex $1) of ${head:0:7}'" >&2
}

# pr_changes: read PR <n>'s authors and changed files once, for every exemption (header): sets
# $changed (GitHub's changedFiles), $author, $commit_authors, $files (one JSON object per line),
# $touched (every path, both sides of a rename) and $short (why the list is not the whole PR,
# else ""). gh or python failing is exit 2, like every read before the merge.
pr_changes() {
  local who listed
  who=$(gh pr view "$PR" --repo "$SLUG" --json changedFiles,author,commits \
    --jq '[.changedFiles, .author.login, ([.commits[].authors[] | .login // "?"] | unique | join(","))] | @tsv') \
    || { echo "merge: cannot read PR #$PR's authors (gh above)" >&2; exit 2; }
  IFS=$'\t' read -r changed author commit_authors <<<"$who"
  files=$(gh api --paginate "repos/$SLUG/pulls/$PR/files?per_page=100" \
    --jq '.[] | {filename, previous_filename, status, patch}') \
    || { echo "merge: cannot read PR #$PR's changed files (gh above)" >&2; exit 2; }
  # The files API stops at 3000 without saying so; an unlisted file would go unchecked.
  listed=$(grep -c . <<<"$files")
  short=""
  [ "$listed" = "$changed" ] || short="GitHub listed $listed of its ${changed:-?} changed files"
  touched=$("$DEVKIT_PYTHON" -I "$HERE/_dependency_pr.py" paths <<<"$files") \
    || { echo "merge: cannot read the paths PR #$PR changes (python above)" >&2; exit 2; }
}

# review_exempt: return 0, naming why in $exemption, when PR <n> needs no Codex review (header):
# a bot dependency PR, a docs-only diff or a devkit sync. Else 1, with each one's reason, where it
# has one, in $not_exempt, $not_docs and $not_sync for review_gap_hints.
not_exempt=""
not_docs=""
not_sync=""
review_exempt() {
  pr_changes
  [ -n "$files" ] || return 1
  if dependency_exempt; then
    exemption="bot dependency PR, manifest-only diff"
  elif docs_exempt; then
    exemption="docs-only diff"
  elif sync_exempt; then
    exemption="devkit sync, vendoring-only diff from devkit main"
  else
    return 1
  fi
}

# dependency_exempt: 0 when the PR is a bot's and changes only dependency pins
# (_dependency_pr.py exempt); else 1, with its reason for a bot's PR in $not_exempt.
dependency_exempt() {
  local out rc
  out=$("$DEVKIT_PYTHON" -I "$HERE/_dependency_pr.py" exempt "$author" "$commit_authors" <<<"$files")
  rc=$?
  case $rc in
    0) [ -z "$short" ] && return 0; not_exempt=$short; return 1 ;;
    1) not_exempt=$out; return 1 ;;
    *) echo "merge: cannot tell whether PR #$PR is a manifest-only dependency PR (python above)" >&2; exit 2 ;;
  esac
}

# docs_exempt: 0 when every path the PR touches, both sides of a rename, is `docs` in the path
# table; else 1, naming in $not_docs the first other path of a PR that touches docs at all (a
# plain code PR gets no hint), or the short listing.
docs_exempt() {
  local path DEVKIT_AREA DEVKIT_AREAS
  devkit_areas "$touched"
  # DEVKIT_AREAS is " a b ", docs first in DEVKIT_AREA_ORDER.
  case "$DEVKIT_AREAS" in
    " docs ") [ -z "$short" ] && return 0; not_docs=$short; return 1 ;;
    " docs "*) ;;
    *) return 1 ;;
  esac
  while IFS= read -r path; do
    _devkit_area "$path"
    [ "$DEVKIT_AREA" = docs ] || { not_docs="$path is $DEVKIT_AREA"; return 1; }
  done <<<"$touched"
  return 1
}

# sync_exempt: 0 when PR <n> is a devkit sync (header); else 1, naming why in $not_sync for a PR
# that changes .devkit-rev (any other PR gets no hint). Both checks read git objects, so the head
# and devkit's main are fetched here, into this clone; a fetch failing is exit 2.
sync_exempt() {
  local upstream
  grep -qxF .devkit-rev <<<"$touched" || return 1
  [ -z "$short" ] || { not_sync=$short; return 1; }
  fetch_main "$ROOT" "pull/$PR/head" \
    || { echo "merge: cannot fetch PR #$PR's head and main to check its vendoring (git above)" >&2; exit 2; }
  upstream=$(fetch_devkit_main "$ROOT") \
    || { echo "merge: cannot fetch devkit's main from $DEVKIT_URL (git above)" >&2; exit 2; }
  (cd "$ROOT" && vendoring_only "$head" "$touched") \
    || { not_sync="a path other than devkit/, .devkit-rev and byte-equal base copies, or a devkit/ that is not the tree its .devkit-rev records"; return 1; }
  (cd "$ROOT" && vendored_from "$head" "$upstream" "$main_now") \
    || { not_sync="its .devkit-rev names no commit on devkit main, forward of main's, whose vendored tree it records"; return 1; }
}

# codex_review_success: the description of the head's codex-review status when it is success.
codex_review_success() {
  awk -F'\t' '$1 == "codex-review" && $2 == "success" { print $3; exit }' <<<"$statuses"
}

# fallback_review: print the head's codex-review success description and return 0 when it
# records a fallback review of THIS head in one of the two forms (header); else 1.
fallback_review() {
  local description re sha
  description=$(codex_review_success)
  for re in "${FALLBACK_RECORD_RES[@]}"; do
    [[ "$description" =~ $re ]] || continue
    sha=${BASH_REMATCH[${#BASH_REMATCH[@]} - 1]}
    case "$head" in "$sha"*) echo "$description"; return 0 ;; esac
  done
  return 1
}

# check_codex: refuse (refuse_codex) or fail closed (exit 2) unless Codex's review clears the
# merge (header). Reads $statuses, the head's combined status, so a fallback is pinned to it.
running_max=""
check_codex() {
  local codex rc required recorded
  running_max=$(gate_plan_literal "$PLAN" GATE_CODEX_RUNNING_MAX_MIN)
  # Bounded so timedelta cannot overflow (devkit #206 Codex finding).
  [[ "${running_max:=$CODEX_RUNNING_MAX_MIN}" =~ ^[1-9][0-9]{0,5}$ ]] \
    || { echo "merge: $PLAN: GATE_CODEX_RUNNING_MAX_MIN must be whole minutes, 1 to 999999 (got '$running_max')" >&2; exit 2; }
  codex=$("$DEVKIT_PYTHON" -I "$HERE/codex_review.py" "$SLUG" "$PR" "$head" "$running_max")
  rc=$?
  # Python's own uncaught-exception exit is 1 too: 1 with no blocker line is a crash, not "none".
  { [ "$rc" = 0 ] || { [ "$rc" = 1 ] && [ -n "$codex" ]; }; } \
    || { echo "merge: cannot read Codex's review of PR #$PR (above)" >&2; exit 2; }
  awk -F'\t' -v max="$running_max" '$1 == "hung" {
    printf "merge: the Codex %s of %s has run %s min, over %s: hung, treated as failed\n", $2, substr($3, 1, 12), $4, max }' <<<"$codex"
  required=$(gate_plan_literal "$PLAN" GATE_CODEX_REVIEW)
  case "$required" in
    1) ;;
    '' | 0) codex=$(grep -vE "$REVIEW_GAPS" <<<"$codex") ;;
    *) echo "merge: $PLAN: GATE_CODEX_REVIEW must be 0 or 1 (got '$required')" >&2; exit 2 ;;
  esac
  if grep -qE "$REVIEW_GAPS" <<<"$codex"; then
    if recorded=$(fallback_review); then
      echo "merge: no Codex review of head ${head:0:12}; its codex-review status records the fallback: $recorded"
      codex=$(grep -vE "$REVIEW_GAPS" <<<"$codex")
    elif review_exempt; then
      echo "merge: codex-review: not required ($exemption)"
      codex=$(grep -vE "$REVIEW_GAPS" <<<"$codex")
    fi
  fi
  [ -z "$codex" ] || refuse_codex "$codex"
}

info=$(gh pr view "$PR" --repo "$SLUG" --json state,headRefOid,isDraft,labels \
  --jq '[.state, .headRefOid, .isDraft, ([.labels[].name] | join(","))] | @tsv') \
  || { echo "merge: cannot read PR #$PR of $SLUG (gh above)" >&2; exit 2; }
IFS=$'\t' read -r state head draft labels <<<"$info"
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
  gated_main=$("$DEVKIT_PYTHON" -I "$HERE/gate_record.py" main-of "$record" "$head") \
    || { echo "merge: cannot read $record (python above)" >&2; exit 2; }
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

# Fail closed, like every gh read above: a Codex state this cannot read is exit 2, never a merge.
check_codex

readonly BOUNDS=docs/metrics/ratchet.json
merge_body=()
case ",$labels," in
  *,metrics-rebaseline,*)
    fetch_main "$ROOT" "pull/$PR/head" \
      || { echo "merge: cannot fetch PR #$PR's head and main to read its loosened bounds (git above)" >&2; exit 2; }
    loosened=$("$DEVKIT_PYTHON" -I "$HERE/metrics_ratchet.py" loosened --repo "$ROOT" --bounds "$BOUNDS" \
      --base-ref "$main_now" --head-ref "$head") \
      || { echo "merge: cannot compare $BOUNDS at ${head:0:12} with main (python above)" >&2; exit 2; }
    if [ -n "$loosened" ]; then
      body=$(gh pr view "$PR" --repo "$SLUG" --json body --jq .body) \
        || { echo "merge: cannot read PR #$PR's body (gh above)" >&2; exit 2; }
      nl=$'\n'
      merge_body=(--body "${body:+$body$nl$nl}$(awk '{ print "Metrics-Rebaseline: " $0 }' <<<"$loosened")")
      echo "merge: PR #$PR carries metrics-rebaseline; the squash body names what it loosens: $(paste -sd ' ' - <<<"$loosened")"
    else
      echo "merge: PR #$PR carries metrics-rebaseline but loosens no bound in $BOUNDS; no trailer"
    fi
    ;;
esac

if [ "$draft" = true ]; then
  gh pr ready "$PR" --repo "$SLUG" >/dev/null \
    || { echo "merge: cannot mark draft PR #$PR ready (gh above)" >&2; exit 2; }
  echo "merge: PR #$PR was a draft; its gate passed on head ${head:0:12}, so marked it ready"
fi
echo "merge: PR #$PR head ${head:0:12}: $REQUIRED success on main ${main_now:0:12}; squash-merging"
merged=$(env DEVKIT_MERGE_VERIFIED="$head" gh pr merge "$PR" --repo "$SLUG" --squash --match-head-commit "$head" --delete-branch ${merge_body[@]+"${merge_body[@]}"} 2>&1)
rc=$?
if [ "$rc" = 0 ]; then
  [ -z "$merged" ] || printf '%s\n' "$merged"
  exit 0
fi
[ -z "$merged" ] || printf '%s\n' "$merged" >&2
case "$merged" in
  *"Head branch is out of date"*|*"Head branch was modified"*|*"Base branch was modified"*)
    refuse "re-gate: GitHub refused to merge head ${head:0:12} into main ${main_now:0:12} (one of them moved, or main wants the branch up to date); run make gate PR=$PR on the new head" ;;
esac
exit "$rc"
