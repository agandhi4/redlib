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
#     exit 2 (devkit#188).
#   - Only where the plan has a literal `GATE_CODEX_REVIEW=1` (devkit#188; opt-in, so a repo Codex
#     does not review is unaffected): Codex reviewed THIS head. A code review that failed (its
#     usage limit), never ran, or is of an older commit refuses, unless the head's `codex-review`
#     status is success and records a fallback review of this head: "Claude adversarial review
#     (Codex at limit) of <sha7>" (claude-kit work loop §3c), or codex_gate.py --on-limit
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
# shellcheck source=bin/_paths_lib.sh  # the path table: what a docs-only diff is (docs_exempt)
. "$HERE/_paths_lib.sh"
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
readonly ADVERSARIAL_REVIEW="Claude adversarial review (Codex at limit)"
# The blockers that say Codex did not review this head (codex_review.py), which only an opted-in
# plan refuses and a fallback record excuses.
readonly REVIEW_GAPS=$'^(failed|unreviewed|stale)\t'

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
# record is offered only for a failed review: a missing or stale one wants Codex, not a stand-in.
review_gap_hints() {
  local kind sha
  while IFS=$'\t' read -r kind _ sha; do
    case $kind in
      unreviewed) echo "merge:   Codex has not reviewed it yet: wait for its summary comment, or comment '@codex review' (a draft: mark it ready, or comment)" >&2 ;;
      stale) echo "merge:   Codex reviewed ${sha:0:12}, an older commit: comment '@codex review' for this head" >&2 ;;
      failed)
        echo "merge:   Codex's review of ${sha:0:12} failed (its usage limit): run claude-kit work-loop's Claude adversarial review (SKILL.md §3c), fix what it finds, then record it on this head:" >&2
        echo "merge:   gh api repos/$SLUG/statuses/$head -f state=success -f context=codex-review -f description='$ADVERSARIAL_REVIEW of ${head:0:7}'" >&2 ;;
    esac
  done <<<"$1"
  local recorded
  recorded=$(codex_review_success)
  [ -z "$recorded" ] || echo "merge:   the head's codex-review success ('$recorded') records no fallback review of ${head:0:7}" >&2
  [ -z "$not_exempt" ] || echo "merge:   a bot PR, but its review is required: $not_exempt" >&2
  [ -z "$not_docs" ] || echo "merge:   not docs-only, so its review is required: $not_docs" >&2
}

# pr_changes: read PR <n>'s authors and changed files once, for both exemptions (header): sets
# $changed (GitHub's changedFiles), $author, $commit_authors, $files (one JSON object per line)
# and $short (why the list is not the whole PR, else ""). gh failing is exit 2, like every read
# before the merge.
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
}

# review_exempt: return 0, naming why in $exemption, when PR <n> needs no Codex review (header):
# a bot dependency PR, or a docs-only diff. Else 1, with each one's reason, where it has one, in
# $not_exempt and $not_docs for review_gap_hints.
not_exempt=""
not_docs=""
review_exempt() {
  pr_changes
  [ -n "$files" ] || return 1
  if dependency_exempt; then
    exemption="bot dependency PR, manifest-only diff"
  elif docs_exempt; then
    exemption="docs-only diff"
  else
    return 1
  fi
}

# dependency_exempt: 0 when the PR is a bot's and changes only dependency pins
# (_dependency_pr.py exempt); else 1, with its reason for a bot's PR in $not_exempt.
dependency_exempt() {
  local out rc
  out=$(python3 -I "$HERE/_dependency_pr.py" exempt "$author" "$commit_authors" <<<"$files")
  rc=$?
  case $rc in
    0) [ -z "$short" ] && return 0; not_exempt=$short; return 1 ;;
    1) not_exempt=$out; return 1 ;;
    *) echo "merge: cannot tell whether PR #$PR is a manifest-only dependency PR (python3 above)" >&2; exit 2 ;;
  esac
}

# docs_exempt: 0 when every path the PR touches, both sides of a rename, is `docs` in the path
# table; else 1, naming in $not_docs the first other path of a PR that touches docs at all (a
# plain code PR gets no hint), or the short listing.
docs_exempt() {
  local touched path DEVKIT_AREA DEVKIT_AREAS
  touched=$(python3 -I "$HERE/_dependency_pr.py" paths <<<"$files") \
    || { echo "merge: cannot read the paths PR #$PR changes (python3 above)" >&2; exit 2; }
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

# codex_review_success: the description of the head's codex-review status when it is success.
codex_review_success() {
  awk -F'\t' '$1 == "codex-review" && $2 == "success" { print $3; exit }' <<<"$statuses"
}

# fallback_review: print the head's codex-review success description and return 0 when it
# records a fallback review of THIS head in one of claude-kit's two forms (header); else 1.
fallback_review() {
  local description sha
  description=$(codex_review_success)
  case "$description" in
    "$ADVERSARIAL_REVIEW"*|"Codex unavailable (usage limit); "*" passed on Claude self-review") ;;
    *) return 1 ;;
  esac
  while read -r sha; do
    case "$head" in "$sha"*) echo "$description"; return 0 ;; esac
  done < <(grep -oE '[0-9a-f]{7,40}' <<<"$description")
  return 1
}

# check_codex: refuse (refuse_codex) or fail closed (exit 2) unless Codex's review clears the
# merge (header). Reads $statuses, the head's combined status, so a fallback is pinned to it.
check_codex() {
  local codex rc required recorded
  codex=$(python3 -I "$HERE/codex_review.py" "$SLUG" "$PR" "$head")
  rc=$?
  [ "$rc" -le 1 ] || { echo "merge: cannot read Codex's review of PR #$PR (above)" >&2; exit 2; }
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

# Fail closed, like every gh read above: a Codex state this cannot read is exit 2, never a merge.
check_codex

readonly BOUNDS=docs/metrics/ratchet.json
merge_body=()
case ",$labels," in
  *,metrics-rebaseline,*)
    git -C "$ROOT" fetch -q --no-tags origin "pull/$PR/head" main \
      || { echo "merge: cannot fetch PR #$PR's head and main to read its loosened bounds (git above)" >&2; exit 2; }
    loosened=$(python3 -I "$HERE/metrics_ratchet.py" loosened --repo "$ROOT" --bounds "$BOUNDS" \
      --base-ref "$main_now" --head-ref "$head") \
      || { echo "merge: cannot compare $BOUNDS at ${head:0:12} with main (python3 above)" >&2; exit 2; }
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
exec env DEVKIT_MERGE_VERIFIED="$head" gh pr merge "$PR" --repo "$SLUG" --squash --match-head-commit "$head" --delete-branch ${merge_body[@]+"${merge_body[@]}"}
