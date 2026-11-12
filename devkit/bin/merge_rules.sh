#!/usr/bin/env bash
# The rules of `make merge PR=<n>`: squash-merge PR <n> once its review rounds allow it. Run as
# `merge_rules.sh <repo-root> <pr-number>` by pr_merge.sh, the entry every repo's Makefile calls,
# from origin/main's copy of this directory with main's plan (pr_merge.sh header), so a
# checkout's branch never decides the rules it or another PR merges under.
#
# Why (owner, 2026-11-02): no pre-merge gate. A PR gets a fixed number of review rounds, then
# merges; main is fixed forward, and every check runs before a deploy. Branch protection is
# unavailable on the fleet's private repos (free plan, 403), so this is the merge path that
# checks for itself. The old gate scripts stay until they are deleted; nothing here reads them.
#
# A round is Codex's review of any commit of the PR, or a local review record (`make review
# PR=<n>`, bin/review_rules.sh, which runs the reviewer itself); codex_review.py reads them and
# gives the verdict, its docstring the rules. The cap is the plan's literal
# `DEVKIT_REVIEW_ROUNDS=<1-99>` line, default 3. Refuses (exit 1, one `merge: refused: …` line on
# stderr, then what clears it) unless:
#   - the plan's GATE_SLUG is origin's repo, where origin is a GitHub URL (_gh_repo_lib.sh): every
#     gh call here names GATE_SLUG, so another slug would merge PR #<n> of another repo, a fork's
#     parent among them (redlib-org/redlib#605, 2026-10-26). A path origin (the tests) has none;
#   - the PR is OPEN;
#   - below the cap, no Codex thread of priority P0 or P1 is unresolved (fix or answer it, then
#     resolve it: a reply alone leaves it open) and the latest round found no P0 or P1; at the
#     cap only a P0 blocks (unresolved, or a local one a later commit's round has not cleared)
#     and every P1 is filed with the P2s (owner 2026-11-02: a set number of rounds);
#   - it has a round, or needs none: a Renovate or Dependabot PR whose every commit is that bot's
#     and whose diff changes only dependency pins (_dependency_pr.py exempt; Codex never reviews
#     bot PRs, homelab #109/#110), a PR whose every changed path, both sides of a rename, is
#     `docs` in _paths_lib.sh's table (paths decide, never a label), or a devkit sync: every
#     changed path only vendors devkit at its head (_vendor_paths.sh devkit_sync_only) from a
#     commit on devkit's main forward of main's vendored one (vendored_from), devkit's own code,
#     reviewed there. Neither holds for a PR with no changed files, or one whose files GitHub
#     listed short of `changedFiles` (the API stops at 3000);
#   - every other context the plan's literal `GATE_MERGE_REQUIRES=<context>[,…]` names is success
#     on the head. `codex-review` (closet's, which its GitHub protection requires; Codex posts no
#     status) is this script's to write: it posts the round just before the merge, over anything
#     else there, saying what it replaced;
#   - GitHub can merge it. Nothing waits on Codex, and main moving is no refusal: GitHub squashes
#     the head onto main as it is now. CONFLICTING (UNKNOWN re-read for up to MERGE_RETRY_SECONDS
#     first: GitHub computes it lazily after a push) is resolved here when docs/decisions.md is
#     the only conflict and both sides only appended (_merge_carry.sh carry_plan; GitHub ignores
#     the merge driver, so any two PRs appending entries conflict: devkit #234, closet #434): the
#     merge of main is committed onto the head, pushed and merged. Any other conflict, or a
#     cross-repository PR's, is a real conflict: rebase it. A main whose protection wants the
#     branch up to date is answered by GitHub's update-branch, then the merge of the new head.
# Before deciding, a head with no local round, that older commits' local findings would be
# filed against unjudged (codex_review.py `unjudged`), gets one `make review` round
# (review_rules.sh), and the verdict is that round's: below the cap its P0/P1 blocks, at it only
# P0. Why (2026-11-02): a lane pushed its fix with no round, and #354 then filed every fixed
# finding (#358, #360, homelab #192-194 closed by hand). It is a new commit, so it counts; the
# count only ever reaches or passes the cap, where only P0 still blocks, so the round can refuse
# only what a round of the fix should. An unresolved Codex P0/P1 refuses first, with no round;
# a review that fails (no claude) is one note line and the old filing, never a refusal, though
# a record it posted before failing still counts (#362).
# Never refused for those: unaddressed P2-and-below findings (codex_review.py `unaddressed`) are
# each filed as an issue in the repo just before the merge (an issue already naming the finding
# is reused) and answered on the PR, `merge: filed …` per issue; that read of the rounds is fresh,
# so a P0/P1 that arrived since the check refuses there. Nothing a reviewer said is lost.
# A new head the merge itself causes (its merge of main, GitHub's update-branch) is merged only
# when it is exactly that merge; any other push in between refuses.
# Owner override: `make merge PR=<n> OWNER='<reason>'` skips the rounds, the findings and the
# exemptions, and only after its owner types `override <n>` at a terminal (stdin and /dev/tty):
# an agent's shell has none. The squash body ends `Owner-Override: <reason>`. Everything else
# above still holds. Why (owner, 2026-11-02): an escape hatch only a person can open.
# CODEX_FALLBACK=1 is gone (exit 2): `make review PR=<n>` is the round Codex could not give.
# A draft that passes is marked ready (`gh pr ready`), then merged: GitHub refuses a draft.
# A PR labelled metrics-rebaseline gets one `Metrics-Rebaseline: <key>=<old>→<new>` trailer per
# bound its head loosens in docs/metrics/ratchet.json against main (metrics_ratchet.py loosened)
# in the squash body: the label is not in git, the trailer is (instalite 2026-10-19).
# Every squash body carries one `Kind: product|tooling` trailer, the scorecard's OUTPUT readout
# (owner 2026-11-04: the share of the fleet's work that is product), and `Kind-By: <rule>`, the
# rule that decided it: `kit` (tooling) when the plan has the literal `GATE_KIT=1` (devkit,
# claude-kit: everything a kit merges is tooling); else `label`, the PR's `kind/product` or
# `kind/tooling` label (`make pr KIND=…`; both is a refusal); else `sync` or `bot` (tooling) for
# a devkit sync (title `Update devkit to …`) or a Renovate or Dependabot PR (_dependency_pr.py
# bot). Anything else is refused before its rounds are read: add the label. Paths never decide
# (2026-11-05): they read a ratchet sweep of app code as product, so the scorecard's first run
# inferred 85% product against an audit's 29%. One `merge: kind: <kind> (<why>)` line.
# The squash body is the PR's body, or with none the list of its commits' subjects, then the
# trailers: the Co-authored-by lines of its commits' messages and of every commit author but the
# PR's (GitHub writes those only into its own default message, which --body replaces: #412,
# #414), then Owner-Override last.
# The product floor was a merge gate in a kit repo 2026-11-05..2026-11-12; it is now scorecard's
# OUTPUT readout only, and nothing here reads it (why: docs/decisions.md 2026-11-12).
# Then `gh pr merge <n> --squash --match-head-commit <head> --delete-branch`, so a push between
# the check and the merge makes GitHub refuse it: one `merge: refused: … make merge again` line.
# That one gh call, and only it, carries DEVKIT_MERGE_VERIFIED=<the full head sha>: the gh shim
# refuses any `pr merge` whose --match-head-commit is not that value (owner, 2026-10-18), so this
# is the fleet's only merge path. Any inherited value is dropped first.
# After the merge, the branch's local leftovers go (merge_cleanup): every worktree of this repo
# on the merged branch whose tree is clean and HEAD the merged head, then the local branch when
# its tip is that head; one `merge: removed …` line each. Why (2026-11-01): ~/projects/solo held
# 28 worktrees of merged PRs. Left, each with a `merge: note:` line: the worktree the caller
# stands in, a dirty tree, unpushed work, the main checkout. Cleanup never changes the exit code.
#
# The plan is <repo-root>'s scripts/ci/gate_plan.sh (GATE_PLAN overrides it; pr_merge.sh points
# it at main's); only its literal GATE_SLUG, GATE_MERGE_REQUIRES, DEVKIT_REVIEW_ROUNDS,
# GATE_CODE_PATHS and GATE_KIT lines are read, never sourced.
# Exit: 0 merged, 1 refused (GitHub's moved-head refusals included), 2 usage or environment (no
# gh, no slug, gh could not answer), otherwise gh pr merge's own code.
set -uo pipefail

readonly CODEX_CONTEXT=codex-review
readonly DEFAULT_ROUNDS=3

usage() { echo "usage: [OWNER='<reason>'] $0 <repo-root> <pr-number>"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ $# -eq 2 ] || { usage >&2; exit 2; }
case "$2" in
  ''|*[!0-9]*) usage >&2; exit 2 ;;
esac
PR=$2
unset DEVKIT_MERGE_VERIFIED
[ -z "${CODEX_FALLBACK:-}" ] \
  || { echo "merge: CODEX_FALLBACK is gone: run make review PR=$PR, a local review round, then make merge PR=$PR" >&2; exit 2; }
case "${OWNER:-}" in
  *$'\n'*) echo "merge: OWNER must be one line, the override's reason" >&2; exit 2 ;;
esac

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh  # gate_plan_literal, fetch_main
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_paths_lib.sh  # the path table: what a docs-only diff is (docs_exempt)
. "$HERE/_paths_lib.sh"
# shellcheck source=bin/_toolchain_lib.sh
. "$HERE/_toolchain_lib.sh"
# shellcheck source=bin/_vendor_paths.sh  # devkit_sync_only, vendored_from: the devkit-sync exemption
. "$HERE/_vendor_paths.sh"
# shellcheck source=bin/_merge_carry.sh  # carry_plan, carry_commit: a docs/decisions.md conflict
. "$HERE/_merge_carry.sh"
# shellcheck source=bin/_trailer_lib.sh  # devkit_commit_trailer, for the carry's merge commit
. "$HERE/_trailer_lib.sh"
# shellcheck source=bin/_gh_repo_lib.sh  # origin_slug, slug_same: the PR is origin's
. "$HERE/_gh_repo_lib.sh"
ROOT=$(git -C "$1" rev-parse --show-toplevel) || exit 2
PLAN=${GATE_PLAN:-$ROOT/scripts/ci/gate_plan.sh}

devkit_preflight gh git || { echo "merge: $DEVKIT_PREFLIGHT_ERROR" >&2; exit 2; }
[ -f "$PLAN" ] || { echo "merge: no plan at $PLAN" >&2; exit 2; }
SLUG=$(gate_plan_literal "$PLAN" GATE_SLUG)
# The path table's repo carve-out (_paths_lib.sh header), read by docs_exempt.
devkit_load_code_paths "$PLAN"
[ -n "$SLUG" ] || { echo "merge: $PLAN has no literal GATE_SLUG=owner/repo line" >&2; exit 2; }
REQUIRED=$(gate_plan_literal "$PLAN" GATE_MERGE_REQUIRES)
REQUIRED=${REQUIRED//,/ }
KIT=$(gate_plan_literal "$PLAN" GATE_KIT)
CAP=$(gate_plan_literal "$PLAN" DEVKIT_REVIEW_ROUNDS)
[[ "${CAP:=$DEFAULT_ROUNDS}" =~ ^[1-9][0-9]?$ ]] \
  || { echo "merge: $PLAN: DEVKIT_REVIEW_ROUNDS must be a whole number of rounds, 1 to 99 (got '$CAP')" >&2; exit 2; }

refuse() { echo "merge: refused: $*" >&2; exit 1; }
if origin=$(origin_slug "$ROOT") && ! same_repo "$SLUG" "$origin"; then
  refuse "the plan's GATE_SLUG is $SLUG, not origin's repo $origin (nor a name GitHub redirects to it); make merge merges origin's PRs only (set GATE_SLUG=$origin)"
fi

# confirm_owner: the OWNER override goes ahead only once its owner types `override <n>` at a
# terminal (header). No tty, or another answer, refuses.
confirm_owner() {
  local answer
  { [ -t 0 ] && : </dev/tty; } 2>/dev/null \
    || refuse "OWNER= skips PR #$PR's review rounds only for its owner at a terminal, who types the confirmation; get a review round instead (make review PR=$PR)"
  printf "merge: OWNER override of PR #%s (%s) skips its review rounds. Type 'override %s' to merge: " "$PR" "$OWNER" "$PR" >/dev/tty
  IFS= read -r answer </dev/tty || answer=""
  [ "$answer" = "override $PR" ] || refuse "the OWNER override of PR #$PR was not confirmed (typed '$answer')"
  echo "merge: OWNER override of PR #$PR confirmed: $OWNER"
}
[ -z "${OWNER:-}" ] || confirm_owner

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
# read_main: main_now, GitHub's main (a devkit sync's vendored_from, the conflict's other side).
read_main() {
  main_now=$(gh api "repos/$SLUG/commits/main" --jq .sha) && [[ "$main_now" =~ ^[0-9a-f]{40}$ ]] \
    || { echo "merge: cannot read main of $SLUG (gh above)" >&2; exit 2; }
}
read_main

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

# review_exempt: 0, naming why in $exemption, when PR <n> needs no review round (header); else
# 1, with each exemption's reason, where it has one, in $not_exempt, $not_docs and $not_sync.
not_exempt=""
not_docs=""
not_sync=""
review_exempt() {
  [ -n "${files+x}" ] || pr_changes
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

# read_verdict: codex_review.py's verdict on the rounds of $rounds_head, into the caller's $verdict.
read_verdict() {
  local rc
  verdict=$("$DEVKIT_PYTHON" -I "$HERE/codex_review.py" rounds "$SLUG" "$PR" "$CAP" "$rounds_head")
  rc=$?
  # Python's own uncaught-exception exit is 1 too: 1 with no verdict line is a crash, not a refusal.
  { [ "$rc" = 0 ] || { [ "$rc" = 1 ] && grep -q '^rounds' <<<"$verdict"; }; } \
    || { echo "merge: cannot read PR #$PR's review rounds (above)" >&2; exit 2; }
}

# review_head: the one `make review` round of the head an `unjudged` verdict owes (header), main's
# review_rules.sh beside this script, under the same plan. Its exit decides nothing: the caller
# reads the rounds again either way, since a review can post its record and still fail after
# (#362: a P0/P1 it posted must block). A failure is one note line, never a refusal.
review_head() {
  local rc
  echo "merge: $(awk -F'\t' '$1 == "unjudged" { print $2 }' <<<"$verdict") older commits' finding(s) and no local round of ${rounds_head:0:12} to judge them; one make review round of it first"
  "$HERE/review_rules.sh" "$ROOT" "$PR"
  rc=$?
  [ "$rc" = 0 ] \
    || echo "merge: note: the review round of ${rounds_head:0:12} failed (exit $rc, above); the rounds are read again: a record it posted counts, else its older commits' findings are filed unjudged"
}

# check_rounds: refuse unless the rounds allow the merge (header); set $round_status, the line
# codex-review records. codex_review.py's lines are its docstring's.
round_status=""
check_rounds() {
  local verdict count latest source sha reviewer blocking
  read_verdict
  # An unresolved Codex P0/P1 refuses whatever a new round says: no round for it.
  if grep -q $'^unjudged\t' <<<"$verdict" && ! grep -q $'^blocking\tunresolved\t' <<<"$verdict"; then
    review_head
    read_verdict
  fi
  count=$(awk -F'\t' '$1 == "rounds" { print $2 }' <<<"$verdict")
  latest=$(grep $'^latest\t' <<<"$verdict")
  IFS=$'\t' read -r _ source sha reviewer <<<"$latest"
  blocking=$(grep $'^blocking\t' <<<"$verdict")
  if [ -n "$blocking" ]; then
    if grep -q $'^blocking\tunresolved\t' <<<"$blocking"; then
      echo "merge: refused: PR #$PR has $(grep -c $'^blocking\tunresolved\t' <<<"$blocking") unresolved P0/P1 Codex finding(s); fix or answer each, then resolve its thread (a reply alone does not count)" >&2
    else
      echo "merge: refused: round $count of $CAP on PR #$PR ($source review of ${sha:0:12}) found P0/P1: push the fix, then another round: comment '@codex review', or make review PR=$PR" >&2
    fi
    awk -F'\t' '{ print "merge:   " $3 " " $4 " " $5 " " $6 " (" $2 ")" }' <<<"$blocking" >&2
    # shellcheck disable=SC2016  # the mutation to type, $id and all
    ! grep -q $'^blocking\tunresolved\t' <<<"$blocking" \
      || echo "merge: resolve: gh api graphql -f query='mutation(\$id: ID!) { resolveReviewThread(input: {threadId: \$id}) { thread { isResolved } } }' -f id=<thread>" >&2
    exit 1
  fi
  if [ -n "$latest" ]; then
    round_status="Review round $count/$CAP: latest $source of ${sha:0:7}"
    echo "merge: review: round $count of $CAP, latest the $source review of ${sha:0:12} by $reviewer"
  elif review_exempt; then
    round_status="Not required ($exemption) for ${head:0:7}"
    echo "merge: review: not required ($exemption)"
  else
    echo "merge: refused: no review round on PR #$PR: comment '@codex review' (any head counts), or make review PR=$PR (a local round)" >&2
    [ -z "$not_exempt" ] || echo "merge:   a bot PR, but its review is required: $not_exempt" >&2
    [ -z "$not_docs" ] || echo "merge:   not docs-only, so its review is required: $not_docs" >&2
    [ -z "$not_sync" ] || echo "merge:   it changes .devkit-rev, but is no devkit sync, so its review is required: $not_sync" >&2
    exit 1
  fi
}

# pr_title: PR <n>'s title, read once, into $title.
pr_title() {
  [ -z "${title+x}" ] || return 0
  title=$(gh pr view "$PR" --repo "$SLUG" --json title --jq .title) \
    || { echo "merge: cannot read PR #$PR's title (gh above)" >&2; exit 2; }
}

# pr_automated: 0 when PR <n> is a devkit sync (its title) or a Renovate or Dependabot PR (its
# author), with `sync` or `bot` in $automated and the reason in $automated_why; else 1. The Kind
# reads it (header).
pr_automated() {
  local rc
  pr_title
  case "$title" in
    "Update devkit to "*) automated=sync automated_why="a devkit sync"; return 0 ;;
  esac
  [ -n "${files+x}" ] || pr_changes
  "$DEVKIT_PYTHON" -I "$HERE/_dependency_pr.py" bot "$author" >/dev/null
  rc=$?
  case $rc in
    0) automated=bot automated_why="a $author PR" ;;
    1) return 1 ;;
    *) echo "merge: cannot tell whether $author is a dependency bot (python above)" >&2; exit 2 ;;
  esac
}

# pr_kind: the squash body's Kind into $kind, the rule that decided into $kind_by, and why into
# $kind_why; refuse a PR none decides (header).
pr_kind() {
  local labelled=""
  if [ "$KIT" = 1 ]; then
    kind=tooling kind_by=kit kind_why="a kit repo, GATE_KIT=1"; return
  fi
  case ",$labels," in *,kind/product,*) labelled=product ;; esac
  case ",$labels," in *,kind/tooling,*) labelled="${labelled:+$labelled }tooling" ;; esac
  case "$labelled" in
    "product tooling") refuse "PR #$PR carries both kind/product and kind/tooling; remove the wrong one, then make merge PR=$PR again" ;;
    ?*) kind=$labelled kind_by=label kind_why="label kind/$labelled"; return ;;
  esac
  if pr_automated; then
    kind=tooling kind_by=$automated kind_why=$automated_why; return
  fi
  refuse "PR #$PR declares no kind: add KIND: gh pr edit $PR --repo $SLUG --add-label kind/product|kind/tooling (a metrics/complexity/clone/size refactor is tooling), then make merge PR=$PR again"
}

body=$(gh pr view "$PR" --repo "$SLUG" --json body --jq .body) \
  || { echo "merge: cannot read PR #$PR's body (gh above)" >&2; exit 2; }
pr_kind
echo "merge: kind: $kind ($kind_why)"

# The head the rounds are judged at, and the filing too: only a round of it says which older
# findings are fixed (codex_review.py). $head moves later only to a merge of main into it.
rounds_head=$head
if [ -n "${OWNER:-}" ]; then
  round_status="Owner override: $OWNER"
else
  check_rounds
fi
round_status=${round_status:0:140}  # GitHub's limit for a status description

wrong=""
for context in $REQUIRED; do
  [ "$context" != "$CODEX_CONTEXT" ] || continue  # posted below (header)
  got=$(awk -F'\t' -v c="$context" '$1 == c { print $2; exit }' <<<"$statuses")
  [ "$got" = success ] || wrong="${wrong:+$wrong, }$context=${got:-none}"
done
[ -z "$wrong" ] || refuse "PR #$PR head ${head:0:12} has $wrong (each of '$REQUIRED' must be success)"

# settle_mergeable: GitHub computes `mergeable` lazily, so just after a push (the head's, or main's)
# it reads UNKNOWN. Re-read it every MERGE_POLL_SECONDS for at most MERGE_RETRY_SECONDS; still
# UNKNOWN, one line says the merge goes ahead as is.
settle_mergeable() {
  local deadline=$((SECONDS + ${MERGE_RETRY_SECONDS:-30}))
  while [ "$mergeable" = UNKNOWN ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep "${MERGE_POLL_SECONDS:-2}"
    mergeable=$(gh pr view "$PR" --repo "$SLUG" --json mergeable --jq .mergeable) \
      || { echo "merge: cannot read PR #$PR's mergeable state (gh above)" >&2; exit 2; }
  done
  [ "$mergeable" != UNKNOWN ] \
    || echo "merge: GitHub still reads PR #$PR's mergeability as UNKNOWN after ${MERGE_RETRY_SECONDS:-30} s; merging as is (a conflict then fails the merge: rerun make merge PR=$PR)"
}

# wait_head <old head> [<expected head>]: poll until GitHub shows a head other than <old head>,
# for at most MERGE_RETRY_SECONDS; set $head to it, or refuse. The new head must be <expected
# head> (the pushed merge of main), or, with none given, GitHub's update-branch: a merge of main
# now into <old head>. Anything else is someone's push, which the rules have not judged (#288
# Codex: a docs-only PR's code commit would merge on the docs exemption).
wait_head() {
  local now parents deadline=$((SECONDS + ${MERGE_RETRY_SECONDS:-30}))
  while :; do
    now=$(gh pr view "$PR" --repo "$SLUG" --json headRefOid --jq .headRefOid) \
      || { echo "merge: cannot read PR #$PR's head (gh above)" >&2; exit 2; }
    if [ "$now" != "$1" ]; then
      if [ -z "${2:-}" ]; then
        parents=$(gh api "repos/$SLUG/commits/$now" --jq '[.parents[].sha] | join(" ")') \
          || { echo "merge: cannot read ${now:0:12}'s parents (gh above)" >&2; exit 2; }
        read_main
      fi
      [ "$now" = "${2:-$now}" ] && [ "${parents:-$1 $main_now}" = "$1 $main_now" ] \
        || refuse "PR #$PR's head moved to ${now:0:12}, which is not the merge of main make merge asked for; make merge PR=$PR again"
      # The new head has none of the old one's statuses: post_round has nothing to replace.
      head=$now statuses=""
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] \
      || refuse "GitHub does not show PR #$PR's new head after ${MERGE_RETRY_SECONDS:-30} s; make merge PR=$PR again"
    sleep "${MERGE_POLL_SECONDS:-2}"
  done
}

# resolve_conflict: GitHub reads the PR as CONFLICTING: commit main's merge with docs/decisions.md
# resolved onto the head and push it (header), or refuse a real conflict. Reads git objects, so
# main and the head are fetched here.
resolve_conflict() {
  local refusal="PR #$PR conflicts with main ${main_now:0:12}" carried
  [ "$cross" = false ] && [ -n "$branch" ] \
    || refuse "$refusal, and a cross-repository PR's branch is not this repo's to push; rebase it on main, then make merge PR=$PR again"
  fetch_main "$ROOT" "pull/$PR/head" \
    || { echo "merge: cannot fetch PR #$PR's head and main to resolve its conflict (git above)" >&2; exit 2; }
  # The "gated" main is main itself: only the conflict is judged, every other path is GitHub's merge.
  carry_plan "$ROOT" "$head" "$main_now" "$main_now" \
    || refuse "$refusal: $CARRY_WHY; rebase it on main, then make merge PR=$PR again"
  [ -n "$CARRY_RESOLVED" ] || return 0
  carried=$(carry_commit "$ROOT" "$CARRY_TREE" "$head" "$main_now" "$PR") \
    || { echo "merge: cannot commit the merge of main (git above)" >&2; exit 2; }
  git -C "$ROOT" push -q origin "$carried:refs/heads/$branch" \
    || { echo "merge: cannot push the merge of main ${carried:0:12} to $branch (git above)" >&2; exit 2; }
  echo "merge: pushed ${carried:0:12} to $branch: main ${main_now:0:12} merged into ${head:0:12}, $CARRY_PATH resolved"
  wait_head "$head" "$carried"
}
settle_mergeable
[ "$mergeable" != CONFLICTING ] || resolve_conflict

readonly BOUNDS=docs/metrics/ratchet.json
trailers=""
case ",$labels," in
  *,metrics-rebaseline,*)
    fetch_main "$ROOT" "pull/$PR/head" \
      || { echo "merge: cannot fetch PR #$PR's head and main to read its loosened bounds (git above)" >&2; exit 2; }
    loosened=$("$DEVKIT_PYTHON" -I "$HERE/metrics_ratchet.py" loosened --repo "$ROOT" --bounds "$BOUNDS" \
      --base-ref "$main_now" --head-ref "$head") \
      || { echo "merge: cannot compare $BOUNDS at ${head:0:12} with main (python above)" >&2; exit 2; }
    if [ -n "$loosened" ]; then
      trailers=$(awk '{ print "Metrics-Rebaseline: " $0 }' <<<"$loosened")
      echo "merge: PR #$PR carries metrics-rebaseline; the squash body names what it loosens: $(paste -sd ' ' - <<<"$loosened")"
    else
      echo "merge: PR #$PR carries metrics-rebaseline but loosens no bound in $BOUNDS; no trailer"
    fi
    ;;
esac

nl=$'\n'
trailers="${trailers:+$trailers$nl}Kind: $kind${nl}Kind-By: $kind_by"
# The commits' subjects (the body of a PR with none) and co-authors (header), in one read.
# shellcheck disable=SC2016  # jq's $a and \(…), not the shell's
commit_lines=$(gh pr view "$PR" --repo "$SLUG" --json author,commits --jq '.author.login as $a | .commits[]
  | ("S\t* " + .messageHeadline),
    (.messageBody | split("\n")[] | select(test("^co-authored-by:"; "i")) | "C\t" + .),
    (.authors[] | select(.login != $a and (.email // "") != "") | "C\tCo-authored-by: \(.name) <\(.email)>")') \
  || { echo "merge: cannot read PR #$PR's commits (gh above)" >&2; exit 2; }
coauthors=$(awk -F'\t' '$1 == "C" { sub(/[[:space:]]+$/, "", $2); if (!seen[tolower($2)]++) print $2 }' <<<"$commit_lines")
[ -z "$coauthors" ] || trailers="$trailers$nl$coauthors"
[ -z "${OWNER:-}" ] || trailers="$trailers${nl}Owner-Override: $OWNER"
squash=$body
[ -n "$squash" ] || squash=$(awk -F'\t' '$1 == "S" { print $2 }' <<<"$commit_lines")
# The gh shim refuses a body holding a local review record's token outside make review: a body
# that quotes one is broken with a word joiner (U+2060, as codex_review.py's `file` does).
squash=${squash//devkit-review-record:v1/devkit-review-record$'\xe2\x81\xa0':v1}
merge_body=(--body "${squash:+$squash$nl$nl}$trailers")

if [ "$draft" = true ]; then
  gh pr ready "$PR" --repo "$SLUG" >/dev/null \
    || { echo "merge: cannot mark draft PR #$PR ready (gh above)" >&2; exit 2; }
  echo "merge: PR #$PR was a draft; its review rounds allow the merge, so marked it ready"
fi
if [ -z "${OWNER:-}" ]; then
  filed=$("$DEVKIT_PYTHON" -I "$HERE/codex_review.py" file "$SLUG" "$PR" "$CAP" "$rounds_head")
  case $? in
    0) ;;
    # Read afresh: a P0/P1 that arrived since check_rounds (header: nothing waits on Codex).
    1) refuse "a P0/P1 finding reached PR #$PR during the merge: $(awk -F'\t' '$1 == "blocking" { printf "%s%s %s %s", sep, $3, $4, $5; sep = "; " }' <<<"$filed"); make merge PR=$PR again once it is answered" ;;
    *) echo "merge: cannot file PR #$PR's unaddressed review findings (above)" >&2; exit 2 ;;
  esac
  awk -F'\t' '$1 == "filed" { print "merge: filed " $3 " " $4 " as " $2 ": " $5 }' <<<"$filed"
fi
# post_round: codex-review, where the plan requires it, records the round on the head (header).
post_round() {
  local was
  case " $REQUIRED " in *" $CODEX_CONTEXT "*) ;; *) return 0 ;; esac
  was=$(awk -F'\t' -v c="$CODEX_CONTEXT" '$1 == c { print $2 " \x27" $3 "\x27"; exit }' <<<"$statuses")
  [ -z "$was" ] || echo "merge: replacing ${head:0:12}'s $CODEX_CONTEXT $was"
  gh api "repos/$SLUG/statuses/$head" -f state=success -f context="$CODEX_CONTEXT" \
    -f description="$round_status" >/dev/null \
    || { echo "merge: cannot post $CODEX_CONTEXT on ${head:0:12} (gh above)" >&2; exit 2; }
  echo "merge: posted $CODEX_CONTEXT success on ${head:0:12}: $round_status"
}
post_round

# merge_pr: the one gh call that carries DEVKIT_MERGE_VERIFIED (header).
merge_pr() { env DEVKIT_MERGE_VERIFIED="$head" gh pr merge "$PR" --repo "$SLUG" --squash --match-head-commit "$head" --delete-branch "${merge_body[@]}" 2>&1; }
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
echo "merge: PR #$PR head ${head:0:12} onto main ${main_now:0:12}; squash-merging"
merged=$(merge_pr)
rc=$?
case "$rc:$merged" in
  0:*) ;;
  # GitHub recomputes a protected PR's merge state after a status lands, asynchronously: just
  # after the post it can still read blocked (closet #428). One retry once it is not.
  *"base branch policy prohibits the merge"*)
    if [ -n "$REQUIRED" ] && wait_unblocked; then merged=$(merge_pr); rc=$?; fi ;;
  # Main moved under the merge: squash onto the new main, once.
  *"Base branch was modified"*) merged=$(merge_pr); rc=$? ;;
  # A protection that wants the branch up to date: GitHub's update-branch (a merge of main;
  # GitHub refuses a conflicting one), then the new head, with its own codex-review.
  *"Head branch is out of date"*)
    gh api -X PUT "repos/$SLUG/pulls/$PR/update-branch" -f expected_head_sha="$head" >/dev/null \
      || refuse "PR #$PR is behind main and GitHub cannot update it (a real conflict, gh above); rebase it on main, then make merge PR=$PR again"
    echo "merge: PR #$PR was behind main; GitHub merged main into it"
    wait_head "$head"
    post_round
    merged=$(merge_pr)
    rc=$? ;;
esac
# merge_cleanup: the merged branch's local leftovers (header). Reads `git worktree list`
# through $ROOT, which may itself be a lane worktree: the list is the repo's, whichever worktree
# asks. Detached worktrees (the gate's) have no branch line and are never touched.
merge_cleanup() {
  [ -n "$branch" ] || return 0
  local wt wt_branch wt_head main_wt cwd left=0
  cwd=$(pwd -P)/  # physical: git prints worktree paths resolved (/tmp vs /private/tmp on macOS)
  # The main checkout: the parent of the common dir, from any worktree.
  main_wt=$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)") || return 0
  while IFS=$'\t' read -r wt wt_branch wt_head; do
    [ "$wt_branch" = "refs/heads/$branch" ] || continue
    if [ "$wt" = "$main_wt" ]; then
      echo "merge: note: the main checkout $wt is on $branch; git -C $wt checkout main"; left=1; continue
    fi
    case "$cwd" in "$wt"/*)
      echo "merge: note: worktree $wt ($branch) is where this runs; leave it, then: git worktree remove $wt && git branch -D $branch"
      left=1; continue ;;
    esac
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      echo "merge: note: worktree $wt ($branch) has uncommitted changes; left in place"; left=1; continue
    fi
    if [ "$wt_head" != "$head" ]; then
      echo "merge: note: worktree $wt ($branch) is at ${wt_head:0:12}, not the merged head ${head:0:12}; left in place"; left=1; continue
    fi
    if git -C "$ROOT" worktree remove "$wt" 2>&1; then
      echo "merge: removed worktree $wt ($branch)"
    else
      echo "merge: note: could not remove worktree $wt ($branch) (git above)"; left=1
    fi
  done < <(git -C "$ROOT" worktree list --porcelain \
    | awk '/^worktree /{p=substr($0,10); h=""} /^HEAD /{h=substr($0,6)} /^branch /{print p "\t" substr($0,8) "\t" h}')
  [ "$left" = 0 ] || return 0
  local tip
  tip=$(git -C "$ROOT" rev-parse -q --verify "refs/heads/$branch") || return 0
  if [ "$tip" = "$head" ]; then
    git -C "$ROOT" branch -D "$branch" >/dev/null 2>&1 && echo "merge: deleted local branch $branch"
  else
    echo "merge: note: local branch $branch is at ${tip:0:12}, not the merged head ${head:0:12}; left in place"
  fi
}

[ "$rc" = 0 ] && { [ -z "$merged" ] || printf '%s\n' "$merged"; merge_cleanup; exit 0; }
[ -z "$merged" ] || printf '%s\n' "$merged" >&2
case "$merged" in
  *"Head branch was modified"*|*"Base branch was modified"*|*"Head branch is out of date"*)
    refuse "PR #$PR or main moved under the merge of ${head:0:12}; make merge PR=$PR again" ;;
esac
exit "$rc"
