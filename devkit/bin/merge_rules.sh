#!/usr/bin/env bash
# The rules of `make merge PR=<n>`: squash-merge PR <n> only when the gate passed on its CURRENT
# head. Run as `merge_rules.sh <repo-root> <pr-number>` by pr_merge.sh, the entry every repo's
# Makefile calls, from origin/main's copy of this directory with main's plan (pr_merge.sh header),
# so a checkout's branch never decides the rules it or another PR merges under.
#
# Why: branch protection is unavailable on the fleet's private repos (free plan, 403), so nothing
# on GitHub stops a merge of a head the gate never saw (standardization/scorecard-design.md §5).
# This is the merge path that checks for itself; gate_bite.py counts the merges that skipped it.
#
# Refuses (exit 1, one `merge: refused: …` line on stderr) unless:
#   - the plan's GATE_SLUG is origin's repo, where origin is a GitHub URL (_gh_repo_lib.sh): every
#     gh call here names GATE_SLUG, so another slug would merge PR #<n> of another repo, a fork's
#     parent among them (redlib-org/redlib#605, 2026-10-26). A path origin (the tests) has none;
#   - the PR is OPEN;
#   - its head's latest `local-gate` status is `success` (GitHub's combined status: the newest
#     status per context), and so is every context the plan's literal
#     `GATE_MERGE_REQUIRES=<context>[,<context>...]` line names. closet's names codex-review,
#     which its GitHub protection requires too, and a completed Codex review posts no status: so
#     where the head has none, this is its one writer, from facts it checks itself, and posts it
#     just before the merge: "Codex reviewed <sha7>, 0 open threads" when codex_review.py finds
#     Codex's completed code review of exactly this head and no blocker at all, or "Not required
#     (<why>) for <sha7>" for a PR exempt from review below. A status something else posted
#     (pending, failure, a fallback record CODEX_FALLBACK=1 does not replace, below) is never
#     overwritten. Why (owner-autonomy decision,
#     2026-10-23): closet's agents hand-posted it after every clean Codex review.
#     Review carry: a head whose only commits since a reviewed one are merges of main, each
#     GitHub's merge of its parents (a resolved docs/decisions.md aside: _merge_carry.sh
#     main_merge_parents), has that commit's review: Codex's completed review of it, or its own
#     fallback record that Codex's state agrees with. The post then reads "Codex reviewed <sha7>,
#     0 open threads; carried to <head7>, only main merged since" (or the record, likewise), and
#     any record already on the head is not read, so claude-kit merge_driver.sh's "; carried
#     over, update-branch merge" copies (legacy) clear too. Why (2026-10-27): update-branch made
#     a new head Codex never saw, and merge_driver.sh was a second writer of the record.
#   - main has not moved past the main the gate ran on: the gate's own record of this head
#     ($XDG_STATE_HOME/<GATE_STATE_NAME>/logs/<n>/gate.json, gate_record.py main-of), else the
#     `on main <sha>` its local-gate status names (a remote gate's record is on its host), against
#     GitHub's main now. A moved main prints `re-gate: main moved <sha>→<sha>`: the gate tested
#     the merge into a main that no longer exists. Neither source naming a main is a refusal.
#     Carry: unless the gate's result carries (_merge_carry.sh carry_plan): every path but
#     docs/decisions.md of the head's merge into main now is the gated merge's, and GitHub's
#     merge (no merge driver) conflicts at most there, both sides only appending entries. The
#     same test runs when GitHub reads the PR as CONFLICTING on the gated main itself (a
#     conflict the gate's decisions driver resolved), UNKNOWN re-read for up to MERGE_RETRY_SECONDS
#     first (settle_mergeable: GitHub computes it lazily after a push). Just before the merge, where GitHub's merge
#     conflicts in the log, it commits that merge onto the head (decisions_merge.py resolves the
#     log, blank lines and date order kept), pushes it to the PR's branch, posts
#     local-gate "Gate of <sha7> carried: only docs/decisions.md differs from its tree; on main
#     <sha7>" and every other required success verbatim there, and merges that head; where it
#     is clean, that merge is the checked tree, so only local-gate is posted, on the head
#     itself. A carry refused says why: `(not carried: <why>)`. Why (2026-10-26): GitHub
#     ignores .gitattributes merge drivers, so any two PRs appending entries conflicted: devkit #234 re-gated 3x,
#     closet #434/#435 both rebased. Residual: Codex reviewed the old head, so a run that fails
#     after the push finds a Codex review of an older commit (`@codex review`, or the fallback).
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
#   - Unless the plan has a literal `GATE_CODEX_REVIEW=0` with a literal
#     `GATE_CODEX_REVIEW_REASON="<why>"` (printed on every merge; 0 with no reason is exit 2):
#     Codex reviewed THIS head. Why the default (devkit-bo, 2026-10-23): it was opt-in
#     (devkit#188), 8 of 9 consumers opted in, and redlib, which never did and recorded no
#     reason, merged #46 while Codex was hung 58 min. A code review that failed or
#     hung, never ran, or is of an older commit refuses, unless the head's
#     `codex-review` status is success and records a fallback review of this head: "Claude
#     adversarial review (Codex <why>) of <sha7>", <why> one of `at limit` (claude-kit work loop
#     §3c), `hung <N> min` or `failed`, or codex_gate.py --on-limit
#     self-review's "Codex unavailable (usage limit); <sha8> passed on Claude self-review" (the
#     headless worker, owner 2026-09-27). The <why> is Codex's observed state, never the agent's
#     word: `CODEX_FALLBACK=1 make merge PR=<n>` (the agent ran the review; nothing else) posts
#     the record with the <why> codex_review.py's blocker gives (gap_why: a failure, missing or
#     stale review answered by Codex's usage-limit note is `at limit`, any other failure
#     `failed`, a hung one `hung <its minutes now> min`), replacing a fallback record already
#     there that disagrees, or a pending or error status (never make merge's: codex_gate.py's,
#     whose run did not finish; the replaced one is logged), never a failure or another success;
#     a review Codex can still give (not yet posted, of an older commit) gets none. A
#     record already on the head must agree with that state (fallback_agrees): `at limit` and
#     the usage-limit form need a gap the note answers, `failed` a failed review, `hung <N> min`
#     a hung one now at least N min old, N not under the plan's limit; else it is refused as
#     contradicting it. Why (2026-10-26): hand-typed reasons were wrong, rollcall #91 "at limit"
#     while Codex ran ~20 min, devkit #234 "hung 180 min" for 155. Codex's open threads still
#     block then, as in codex_gate.py. A head-pinned review of the head also excuses a stale
#     Codex review: what Codex saw of an older commit adds nothing a review of the head lacks. Nor is a review
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
#     other repo-owned path takes the normal rule. The one repo-owned file a sync may change is
#     docs/metrics/ratchet.json, and only by tightening bounds against the merge base
#     (devkit_sync_only): the nightly sync's lock-in of what devkit's collectors re-measured
#     (devkit decisions 2026-10-28), which only makes the gate stricter. A person's
#     metrics-tighten beside other edits, or one that seeds or loosens a bound, is reviewed.
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
# Every Codex rule above (codex-review's post, the review owed, the fallback, the exemptions'
# place, open threads and running reviews) is one state machine, bin/_codex_rules.sh: its header
# is the table, tests/codex_transitions.tsv every combination; this script reads, prints, posts.
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
# The plan is <repo-root>'s scripts/ci/gate_plan.sh (GATE_PLAN overrides it, as for gate.sh;
# pr_merge.sh points it at main's); only its literal GATE_SLUG, GATE_MERGE_REQUIRES, GATE_CODEX_REVIEW,
# GATE_CODEX_REVIEW_REASON, GATE_CODEX_RUNNING_MAX_MIN, GATE_STATE_NAME and GATE_CODE_PATHS lines
# are read, never sourced.
# Exit: 0 merged, 1 refused (GitHub's moved-head refusals included), 2 usage or environment (no
# gh, no slug, gh could not answer), otherwise gh pr merge's own code.
set -uo pipefail

readonly GATE_CONTEXT=local-gate
# Where a fallback review is recorded, and the context closet's GATE_MERGE_REQUIRES names.
readonly CODEX_CONTEXT=codex-review

usage() { echo "usage: $0 <repo-root> <pr-number>"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -eq 2 ] || { usage >&2; exit 2; }
case "$2" in
  ''|*[!0-9]*) usage >&2; exit 2 ;;
esac
PR=$2
unset DEVKIT_MERGE_VERIFIED
case "${CODEX_FALLBACK:-}" in
  ''|1) ;;
  *) echo "merge: CODEX_FALLBACK must be 1 (you ran the Claude adversarial review of the head) or unset (got '$CODEX_FALLBACK')" >&2; exit 2 ;;
esac

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_paths_lib.sh  # the path table: what a docs-only diff is (docs_exempt)
. "$HERE/_paths_lib.sh"
# shellcheck source=bin/_toolchain_lib.sh
. "$HERE/_toolchain_lib.sh"
# shellcheck source=bin/_vendor_paths.sh  # devkit_sync_only, vendored_from: the devkit-sync exemption
. "$HERE/_vendor_paths.sh"
# shellcheck source=bin/_merge_carry.sh  # carry_plan, carry_commit: a gate across a decisions-only main
. "$HERE/_merge_carry.sh"
# shellcheck source=bin/_trailer_lib.sh  # devkit_commit_trailer, for the carry's merge commit
. "$HERE/_trailer_lib.sh"
# shellcheck source=bin/_gh_repo_lib.sh  # origin_slug, slug_same: the PR is origin's
. "$HERE/_gh_repo_lib.sh"
# shellcheck source=bin/_codex_rules.sh  # the Codex state machine: codex_gap, codex_head, codex_transition
. "$HERE/_codex_rules.sh"
ROOT=$(git -C "$1" rev-parse --show-toplevel) || exit 2
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
if origin=$(origin_slug "$ROOT") && ! slug_same "$SLUG" "$origin"; then
  refuse "the plan's GATE_SLUG is $SLUG, not origin's repo $origin; make merge merges origin's PRs only (set GATE_SLUG=$origin)"
fi
readonly CODEX_RUNNING_MAX_MIN=30

# refuse_codex <verdict>: codex_transition's running, unreviewed or findings refusal line, then
# how to clear it: one line per unresolved finding (path:line, title, URL, thread id) and how to
# resolve one, or how to get the head reviewed.
refuse_codex() {
  local running findings
  findings=$(awk -F'\t' '$1 == "unresolved" { n++ } END { print n + 0 }' <<<"$codex_blockers")
  case $1 in
    running)
      running=$(awk -F'\t' '$1 == "running" { printf "%s%s of %s", sep, $2, substr($3, 1, 12); sep = ", " }' <<<"$codex_blockers")
      echo "merge: refused: Codex review still running on PR #$PR ($running); make merge again when its summary comment says Completed (unresolved findings so far: $findings)" >&2 ;;
    unreviewed)
      echo "merge: refused: no Codex review of PR #$PR's head ${head:0:12} (GATE_CODEX_REVIEW=1; unresolved findings: $findings)" >&2
      review_gap_hints "$(grep -E "$REVIEW_GAPS" <<<"$codex_blockers")" ;;
    findings)
      echo "merge: refused: PR #$PR has $findings unresolved Codex finding(s); fix or answer each, then resolve its thread (a reply alone does not count)" >&2 ;;
  esac
  awk -F'\t' '$1 == "unresolved" { print "merge:   " $3 " " $4 " " $5 " (thread " $2 ")" }' <<<"$codex_blockers" >&2
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
          fallback_hint "$kind" "$detail"
        else
          echo "merge:   Codex has not reviewed it yet: wait for its summary comment, or comment '@codex review' (a draft: mark it ready, or comment)" >&2
        fi ;;
      stale)
        if [ "$detail" = limit ]; then
          echo "merge:   Codex reviewed ${sha:0:12}, an older commit, and has posted its usage-limit note since (comment '@codex review' once the limit resets). $review" >&2
          fallback_hint "$kind" "$detail"
        else
          echo "merge:   Codex reviewed ${sha:0:12}, an older commit: comment '@codex review' for this head" >&2
        fi ;;
      failed)
        if [ "$detail" = limit ]; then
          echo "merge:   Codex's review of ${sha:0:12} failed at its usage limit. $review" >&2
        else
          echo "merge:   Codex's review of ${sha:0:12} failed, with no usage-limit note after it ('@codex review' may retry it). $review" >&2
        fi
        fallback_hint "$kind" "$detail" ;;
      hung)
        echo "merge:   Codex's review of ${sha:0:12} has run $detail min, over GATE_CODEX_RUNNING_MAX_MIN=$running_max: treated as failed. $review" >&2
        fallback_hint "$kind" "$detail" ;;
    esac
  done <<<"$1"
  local recorded
  recorded=$(codex_review_success)
  [ -z "$recorded" ] || echo "merge:   the head's codex-review success ('$recorded') records no fallback review of ${head:0:7}" >&2
  if [ -n "${CODEX_FALLBACK:-}" ] && [ -n "$recorded" ]; then
    echo "merge:   CODEX_FALLBACK=1 never replaces a $CODEX_CONTEXT success other than a fallback record" >&2
  elif [ -n "${CODEX_FALLBACK:-}" ]; then
    echo "merge:   CODEX_FALLBACK=1 records a fallback only where Codex cannot review (failed, hung, or answered by its usage-limit note)" >&2
  fi
  [ -z "$not_exempt" ] || echo "merge:   a bot PR, but its review is required: $not_exempt" >&2
  [ -z "$not_docs" ] || echo "merge:   not docs-only, so its review is required: $not_docs" >&2
  [ -z "$not_sync" ] || echo "merge:   it changes .devkit-rev, but is no devkit sync, so its review is required: $not_sync" >&2
}

# fallback_hint <gap kind> <detail>: the one command that records the fallback, and the record
# it will post. The agent never types the reason (header).
fallback_hint() {
  echo "merge:   CODEX_FALLBACK=1 make merge PR=$PR   (posts $CODEX_CONTEXT: '$(fallback_record "$(gap_why "$1" "$2")")')" >&2
}

fallback_record() { echo "Claude adversarial review (Codex $1) of ${head:0:7}"; }

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

# review_exempt: return 0, naming why in $exemption and printing one `not required` line, when
# PR <n> needs no Codex review (header): a bot dependency PR, a docs-only diff or a devkit sync.
# Else 1, with each one's reason, where it has one, in $not_exempt, $not_docs and $not_sync for
# review_gap_hints. Decided once per run (a sync's check fetches twice): both the required-status
# loop and check_codex ask, and the first answer stands.
not_exempt=""
not_docs=""
not_sync=""
exempt_verdict=""
review_exempt() {
  [ -z "$exempt_verdict" ] || return "$exempt_verdict"
  exempt_verdict=1
  _review_exempt || return 1
  exempt_verdict=0
  echo "merge: codex-review: not required ($exemption)"
}
_review_exempt() {
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
  (cd "$ROOT" && devkit_sync_only "$head" "$(git merge-base "$head" "$main_now")" "$touched") \
    || { not_sync="a path other than devkit/, .devkit-rev, byte-equal base copies and tightened bounds, or a devkit/ that is not the tree its .devkit-rev records"; return 1; }
  (cd "$ROOT" && vendored_from "$head" "$upstream" "$main_now") \
    || { not_sync="its .devkit-rev names no commit on devkit main, forward of main's, whose vendored tree it records"; return 1; }
}

# codex_review_success [<statuses>]: the codex-review description in <statuses> (default the
# head's) when it is success.
codex_review_success() {
  awk -F'\t' -v c="$CODEX_CONTEXT" '$1 == c && $2 == "success" { print $3; exit }' <<<"${1-$statuses}"
}

# carry_review: when the head only merges main into a commit Codex reviewed, or into one whose
# fallback record Codex's state agrees with (_merge_carry.sh main_merge_parents), that review is
# the head's (header, "Carry"): drop the review gaps from $codex_blockers (open threads and a
# running review still block) and set $codex_carried, the record posted where codex-review is
# required and absent. Asked only for a gap on a merge head, so no other head fetches anything.
# Why (2026-10-27): claude-kit's merge_driver.sh re-posted the old head's record after
# update-branch with "; carried over, update-branch merge" appended, a form no merge parses.
codex_carried=""
carry_review() {
  local merged parents parent stale recorded
  grep -qE "$REVIEW_GAPS" <<<"$codex_blockers" || return 0
  merged=$(gh api "repos/$SLUG/commits/$head" --jq '.parents | length') \
    || { echo "merge: cannot read ${head:0:12}'s parents (gh above)" >&2; exit 2; }
  [ "$merged" = 2 ] || return 0
  fetch_main "$ROOT" "pull/$PR/head" \
    || { echo "merge: cannot fetch PR #$PR's head and main to see what its merges of main changed (git above)" >&2; exit 2; }
  parents=$(main_merge_parents "$ROOT" "$head" "$main_now") \
    || { echo "merge: cannot read the merges of main into ${head:0:12} (git above)" >&2; exit 2; }
  stale=$(awk -F'\t' '$1 == "stale" { print $3; exit }' <<<"$codex_blockers")
  for parent in $parents; do
    # Codex's own review clears only its stale code-review line: a security review that failed
    # or hung is a gap of its own (#266 Codex). A fallback record clears every gap, as on a head.
    if [ -n "$stale" ] && [[ "$parent" == "$stale"* ]]; then
      codex_carried="Codex reviewed ${parent:0:7}, 0 open threads"
      codex_blockers=$(grep -vE $'^stale\tcode_review\t' <<<"$codex_blockers")
    else
      commit_fallback "$parent"
      { [ -n "$recorded" ] && fallback_agrees "$recorded" "$codex_blockers" "$running_max"; } || continue
      codex_carried=$recorded
      codex_blockers=$(grep -vE "$REVIEW_GAPS" <<<"$codex_blockers")
    fi
    echo "merge: ${head:0:12} only merges main into ${parent:0:12}, so its review carries: $codex_carried"
    codex_carried="$codex_carried; carried to ${head:0:7}, only main merged since"
    return 0
  done
}

# commit_fallback <commit>: set $recorded to <commit>'s own codex-review fallback record, else "".
commit_fallback() {
  local listed
  recorded=""
  listed=$(gh api "repos/$SLUG/commits/$1/status?per_page=100" --jq '.statuses[] | [.context, .state, .description] | @tsv') \
    || { echo "merge: cannot read the statuses of $SLUG@${1:0:12} (gh above)" >&2; exit 2; }
  listed=$(codex_review_success "$listed")
  ! fallback_record_of "$listed" "$1" || recorded=$listed
}

# read_codex: set $codex_blockers to codex_review.py's blocker lines for the head, read once per
# run (the required-status loop and check_codex both ask); fail closed (exit 2) when unreadable.
# Empty means Codex completed a code review of exactly this head and left no open thread.
running_max=""
codex_blockers=""
codex_read=""
read_codex() {
  local rc
  [ -z "$codex_read" ] || return 0
  running_max=$(gate_plan_literal "$PLAN" GATE_CODEX_RUNNING_MAX_MIN)
  # Bounded so timedelta cannot overflow (devkit #206 Codex finding).
  [[ "${running_max:=$CODEX_RUNNING_MAX_MIN}" =~ ^[1-9][0-9]{0,5}$ ]] \
    || { echo "merge: $PLAN: GATE_CODEX_RUNNING_MAX_MIN must be whole minutes, 1 to 999999 (got '$running_max')" >&2; exit 2; }
  codex_blockers=$("$DEVKIT_PYTHON" -I "$HERE/codex_review.py" "$SLUG" "$PR" "$head" "$running_max")
  rc=$?
  # Python's own uncaught-exception exit is 1 too: 1 with no blocker line is a crash, not "none".
  { [ "$rc" = 0 ] || { [ "$rc" = 1 ] && [ -n "$codex_blockers" ]; }; } \
    || { echo "merge: cannot read Codex's review of PR #$PR (above)" >&2; exit 2; }
  codex_read=1
  carry_review
}

# codex_decide: run the Codex state machine (_codex_rules.sh) once per run: read the plan's
# switch and Codex's state, classify it and the head's codex-review status, take the table's
# transition, and set $codex_status, the record posted just before the merge (none on a refusal).
# Asked by the required-status loop (codex-review with no success) and check_codex, the first
# answer standing. A plan literal that is not 0 or 1, or 0 with no reason, is exit 2.
codex_decided=""
codex_plan=""
codex_plan_reason=""
codex_description=""
codex_replaces=""
codex_decide() {
  local got required=0 exempt_outcome
  [ -z "$codex_decided" ] || return 0
  codex_plan=$(gate_plan_literal "$PLAN" GATE_CODEX_REVIEW)
  case "${codex_plan:=1}" in
    1) ;;
    0)
      codex_plan_reason=$(gate_plan_text "$PLAN" GATE_CODEX_REVIEW_REASON)
      [ -n "$codex_plan_reason" ] || { echo "merge: $PLAN: GATE_CODEX_REVIEW=0 needs a literal GATE_CODEX_REVIEW_REASON=\"<why>\" line: Codex review is the fleet default" >&2; exit 2; } ;;
    *) echo "merge: $PLAN: GATE_CODEX_REVIEW must be 0 or 1 (got '$codex_plan')" >&2; exit 2 ;;
  esac
  read_codex
  IFS=$'\t' read -r got codex_description < <(awk -F'\t' -v c="$CODEX_CONTEXT" '$1 == c { print $2 "\t" $3; exit }' <<<"$statuses")
  case " $REQUIRED " in *" $CODEX_CONTEXT "*) required=1 ;; esac
  codex_gap "$codex_blockers"
  codex_head "$got" "$codex_description" "$head" "$codex_blockers" "$running_max"
  set -- "$CODEX_GAP" "$CODEX_RESIDUAL" "$CODEX_HEAD" "${CODEX_FALLBACK:-0}" "$required" "$codex_plan"
  # Whether the PR is exempt costs a files read (a sync's, two fetches): asked only where the
  # table's answer turns on it.
  codex_transition "$@" 1
  exempt_outcome="$CODEX_VERDICT $CODEX_POST $CODEX_EXCUSE"
  codex_transition "$@" 0
  if [ "$exempt_outcome" != "$CODEX_VERDICT $CODEX_POST $CODEX_EXCUSE" ] && review_exempt; then
    codex_transition "$@" 1
  fi
  codex_decided=1
  case $CODEX_POST in
    clean) codex_status=${codex_carried:-"Codex reviewed ${head:0:7}, 0 open threads"} ;;
    exempt) codex_status="Not required ($exemption) for ${head:0:7}" ;;
    # Never make merge's own (it writes only success): codex_gate.py's, whose run did not finish.
    fallback-replacing) codex_status=$(fallback_record "$CODEX_WHY") codex_replaces="$got '$codex_description'" ;;
    fallback) codex_status=$(fallback_record "$CODEX_WHY") ;;
  esac
}

# check_codex: refuse, or fail closed (exit 2), unless the Codex state machine's verdict is merge
# (header).
check_codex() {
  codex_decide
  awk -F'\t' -v max="$running_max" '$1 == "hung" {
    printf "merge: the Codex %s of %s has run %s min, over %s: hung, treated as failed\n", $2, substr($3, 1, 12), $4, max }' <<<"$codex_blockers"
  [ "$codex_plan" = 1 ] || echo "merge: codex-review: not required by the plan (GATE_CODEX_REVIEW=0: $codex_plan_reason)"
  case $CODEX_EXCUSE in
    record) echo "merge: no Codex review of head ${head:0:12}; its codex-review status records the fallback: $codex_description" ;;
    fallback) echo "merge: no Codex review of head ${head:0:12}; CODEX_FALLBACK=1 records the fallback Codex's state calls for: $codex_status" ;;
  esac
  case $CODEX_VERDICT in
    merge) ;;
    contradicts) refuse "the head's $CODEX_CONTEXT record '$codex_description' contradicts what Codex did: $disagreement; CODEX_FALLBACK=1 make merge PR=$PR records the observed reason" ;;
    running|unreviewed|findings) refuse_codex "$CODEX_VERDICT" ;;
    # `context` is the required-status loop's, which refused before this.
    *) refuse "the Codex state machine has no transition for gap=$CODEX_GAP residual=$CODEX_RESIDUAL head=$CODEX_HEAD (bin/_codex_rules.sh); not merging" ;;
  esac
}

info=$(gh pr view "$PR" --repo "$SLUG" --json state,headRefOid,isDraft,labels,mergeable,headRefName,isCrossRepository \
  --jq '[.state, .headRefOid, .isDraft, .mergeable, .headRefName, .isCrossRepository, ([.labels[].name] | join(","))] | @tsv') \
  || { echo "merge: cannot read PR #$PR of $SLUG (gh above)" >&2; exit 2; }
# Labels last: tab is IFS whitespace, so an empty field anywhere else would shift the rest.
IFS=$'\t' read -r state head draft mergeable branch cross labels <<<"$info"
[ "$state" = OPEN ] || refuse "PR #$PR is ${state:-unknown}, not OPEN"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "merge: gh gave no head commit for PR #$PR ('$head')" >&2; exit 2; }

statuses=$(gh api "repos/$SLUG/commits/$head/status?per_page=100" \
  --jq '.statuses[] | [.context, .state, .description] | @tsv') \
  || { echo "merge: cannot read the statuses of $SLUG@${head:0:12} (gh above)" >&2; exit 2; }
# read_main: set main_now to GitHub's main; main_unmoved: refuse unless it is the gated main.
read_main() {
  main_now=$(gh api "repos/$SLUG/commits/main" --jq .sha) && [[ "$main_now" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "merge: cannot read main of $SLUG (gh above)" >&2; exit 2; }
}
main_unmoved() {
  case "$main_now" in
    "$gated_main"*) ;;
    *) refuse "re-gate: main moved ${gated_main:0:12}→${main_now:0:12}; run make gate PR=$PR" ;;
  esac
}
# Read before the required statuses: a devkit sync's exemption (vendored_from) checks against it.
read_main
wrong=""
codex_status=""
for context in $REQUIRED; do
  got=$(awk -F'\t' -v c="$context" '$1 == c { print $2; exit }' <<<"$statuses")
  [ "$got" = success ] && continue
  # make merge is codex-review's one writer, from facts it checks itself (_codex_rules.sh table,
  # step 1): over none, or a pending or error the fallback answers; never over a failure.
  if [ "$context" = "$CODEX_CONTEXT" ]; then
    codex_decide
    [ "$CODEX_VERDICT" = context ] || continue
  fi
  wrong="${wrong:+$wrong, }$context=${got:-none}"
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

# plan_carry: when main moved past the gated main, or GitHub cannot merge the PR, refuse unless
# the gate carries (header, "Carry"): then set $carry_tree and make the main it checks against
# the gated one. Reads git objects, so main and the head are fetched here.
carry_tree=""
carry_resolved=""
plan_carry() {
  local refusal gated
  case "$main_now" in
    "$gated_main"*) refusal="PR #$PR conflicts with main ${main_now:0:12} on GitHub, whose merge ignores the decisions driver the gate's merge used; rebase it and run make gate PR=$PR" ;;
    *) refusal="re-gate: main moved ${gated_main:0:12}→${main_now:0:12}; run make gate PR=$PR" ;;
  esac
  [ "$cross" = false ] && [ -n "$branch" ] \
    || refuse "$refusal (not carried: the head branch of a cross-repository PR is not this repo's to push)"
  fetch_main "$ROOT" "pull/$PR/head" \
    || refuse "$refusal (not carried: cannot fetch PR #$PR's head and main, git above)"
  gated=$(git -C "$ROOT" rev-parse --verify -q "$gated_main^{commit}") \
    || refuse "$refusal (not carried: the gated main ${gated_main:0:12} is not in this clone)"
  carry_plan "$ROOT" "$head" "$gated" "$main_now" || refuse "$refusal (not carried: $CARRY_WHY)"
  carry_tree=$CARRY_TREE carry_resolved=$CARRY_RESOLVED
  echo "merge: main ${main_now:0:12} differs from the gated main ${gated_main:0:12} only in $CARRY_PATH appends: carrying the gate of ${head:0:12}"
  gated_main=$main_now
}
# settle_mergeable: GitHub computes `mergeable` lazily, so just after a push (the head's, or main's)
# it reads UNKNOWN, and a decisions.md conflict there went uncarried until GitHub's merge refused
# it (#238 follow-up). Re-read it every MERGE_POLL_SECONDS for at most MERGE_RETRY_SECONDS; still
# UNKNOWN, one line says the merge goes ahead uncarried.
settle_mergeable() {
  local deadline=$((SECONDS + ${MERGE_RETRY_SECONDS:-30}))
  while [ "$mergeable" = UNKNOWN ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep "${MERGE_POLL_SECONDS:-2}"
    mergeable=$(gh pr view "$PR" --repo "$SLUG" --json mergeable --jq .mergeable) \
      || { echo "merge: cannot read PR #$PR's mergeable state (gh above)" >&2; exit 2; }
  done
  [ "$mergeable" != UNKNOWN ] \
    || echo "merge: GitHub still reads PR #$PR's mergeability as UNKNOWN after ${MERGE_RETRY_SECONDS:-30} s; merging uncarried (a decisions.md conflict then fails the merge: rerun make merge PR=$PR)"
}
case "$main_now" in "$gated_main"*) settle_mergeable; [ "$mergeable" != CONFLICTING ] || plan_carry ;; *) plan_carry ;; esac

# apply_carry: where GitHub's merge conflicts in the log, commit the carried merge onto the head,
# push it to the PR's branch, wait for GitHub to show it as the head, and post every required
# context there: local-gate names the head it carries and the main its tree is on; any other is
# the old head's success, verbatim (a context with none yet is posted by its own step below, onto
# the new head). From here on $head is it. Where GitHub's merge is clean, it already is the
# carried tree: only local-gate is posted, on the head as it is, so nothing is pushed (a pushed
# commit would make a bot's PR a person's: Renovate stops rebasing it, the bot exemption ends).
apply_carry() {
  local carried context description deadline
  [ -n "$carry_resolved" ] || { post_carried "$head" "$GATE_CONTEXT"; return; }
  carried=$(carry_commit "$ROOT" "$carry_tree" "$head" "$main_now" "$PR") \
    || { echo "merge: cannot commit the carried merge (git above)" >&2; exit 2; }
  git -C "$ROOT" push -q origin "$carried:refs/heads/$branch" \
    || { echo "merge: cannot push the carried merge ${carried:0:12} to $branch (git above)" >&2; exit 2; }
  echo "merge: pushed ${carried:0:12} to $branch: main ${main_now:0:12} merged into ${head:0:12}, $CARRY_PATH resolved"
  deadline=$((SECONDS + ${MERGE_RETRY_SECONDS:-30}))
  until [ "$(gh pr view "$PR" --repo "$SLUG" --json headRefOid --jq .headRefOid)" = "$carried" ]; do
    [ "$SECONDS" -lt "$deadline" ] \
      || refuse "re-gate: GitHub does not show the carried merge ${carried:0:12} as PR #$PR's head after ${MERGE_RETRY_SECONDS:-30} s; make merge PR=$PR again"
    sleep "${MERGE_POLL_SECONDS:-2}"
  done
  # shellcheck disable=SC2086  # $REQUIRED is a space-separated list
  post_carried "$carried" $REQUIRED
  head=$carried
}

# post_carried <commit> <context>...: post each context's carried success on <commit>: local-gate's
# names the head it carries; any other is the head's own success, verbatim, an empty description
# included (by state, not text); a context the head has none of is skipped.
post_carried() {
  local commit=$1 context description
  shift
  for context in "$@"; do
    if [ "$context" = "$GATE_CONTEXT" ]; then
      description="Gate of ${head:0:7} carried: only $CARRY_PATH differs from its tree; on main ${main_now:0:7}"
    else
      description=$(awk -F'\t' -v c="$context" '$1 == c && $2 == "success" { print "=" $3; exit }' <<<"$statuses")
      [ -n "$description" ] || continue
      description=${description#=}
    fi
    gh api "repos/$SLUG/statuses/$commit" -f state=success -f context="$context" -f description="$description" >/dev/null \
      || { echo "merge: cannot post $context on ${commit:0:12} (gh above)" >&2; exit 2; }
    echo "merge: posted $context success on ${commit:0:12}: $description"
  done
}

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

# Again: the exemption's fetches and every read since take seconds, and --match-head-commit pins
# only the head, so a main that moved in them would merge onto a base no gate ran (#219). Before
# a draft is readied, which a refusal must not leave done, and once more after it.
read_main
main_unmoved
if [ -n "$carry_tree" ]; then
  apply_carry
  # The push, GitHub's catching up and the posts take seconds; main may have moved in them (#238 Codex).
  read_main
  main_unmoved
fi
if [ -n "$codex_status" ]; then
  [ -z "$codex_replaces" ] \
    || echo "merge: replacing ${head:0:12}'s $CODEX_CONTEXT $codex_replaces, which make merge did not write (it writes only success)"
  gh api "repos/$SLUG/statuses/$head" -f state=success -f context="$CODEX_CONTEXT" \
    -f description="$codex_status" >/dev/null \
    || { echo "merge: cannot post $CODEX_CONTEXT on ${head:0:12} (gh above)" >&2; exit 2; }
  echo "merge: posted $CODEX_CONTEXT success on ${head:0:12}: $codex_status"
fi
if [ "$draft" = true ]; then
  gh pr ready "$PR" --repo "$SLUG" >/dev/null \
    || { echo "merge: cannot mark draft PR #$PR ready (gh above)" >&2; exit 2; }
  echo "merge: PR #$PR was a draft; its gate passed on head ${head:0:12}, so marked it ready"
  read_main
  main_unmoved
fi
echo "merge: PR #$PR head ${head:0:12}: $REQUIRED success on main ${main_now:0:12}; squash-merging"
# merge_pr: the one gh call that carries DEVKIT_MERGE_VERIFIED (header).
merge_pr() { env DEVKIT_MERGE_VERIFIED="$head" gh pr merge "$PR" --repo "$SLUG" --squash --match-head-commit "$head" --delete-branch ${merge_body[@]+"${merge_body[@]}"} 2>&1; }
# wait_unblocked: poll the PR's mergeStateStatus until GitHub stops reading it BLOCKED (or
# UNKNOWN, still computing), for at most MERGE_RETRY_SECONDS (default 30), every
# MERGE_POLL_SECONDS (default 2). 0 once it has, 1 when the bound passes first.
wait_unblocked() {
  local merge_state deadline=$((SECONDS + ${MERGE_RETRY_SECONDS:-30}))
  while :; do
    merge_state=$(gh pr view "$PR" --repo "$SLUG" --json mergeStateStatus --jq .mergeStateStatus) \
      || { echo "merge: cannot read PR #$PR's merge state (gh above)" >&2; exit 2; }
    case "$merge_state" in BLOCKED|UNKNOWN) ;; *) return 0 ;; esac
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "${MERGE_POLL_SECONDS:-2}"
  done
}
merged=$(merge_pr)
rc=$?
# GitHub recomputes a protected PR's merge state after a status lands, asynchronously: just after
# the post it can still read blocked. One retry, once GitHub says the PR is no longer blocked,
# and only onto the gated main: the wait is long enough for main to move, and --match-head-commit
# pins only the head (closet #428 / Orbit #121 Codex).
if [ "$rc" != 0 ] && [ -n "$codex_status" ] && [[ "$merged" == *"base branch policy prohibits the merge"* ]]; then
  echo "merge: GitHub has not counted the posted $CODEX_CONTEXT yet; waiting up to ${MERGE_RETRY_SECONDS:-30} s for it"
  if wait_unblocked; then
    read_main
    main_unmoved
    merged=$(merge_pr)
    rc=$?
  else
    echo "merge: PR #$PR still reads blocked after ${MERGE_RETRY_SECONDS:-30} s; not retrying"
  fi
fi
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
