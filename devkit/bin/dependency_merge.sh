#!/usr/bin/env bash
# Nightly gated merge of minor and patch dependency PRs. Owner decision 2026-10-21: keep
# automatic minor/patch updates, but route every one through the repo's own gate; Renovate never
# merges by itself and no paid GitHub feature is involved. Scheduled by
# bin/install_dependency_merge.sh (templates/launchd/com.agandhi4.devkit.dependency-merge.plist).
#
# Usage: bin/dependency_merge.sh [--max <n>] [--dry-run] <repo-root>...
#   <repo-root>  a checkout whose scripts/ci/gate_plan.sh has literal GATE_SLUG and
#                GATE_STATE_NAME lines and whose Makefile has `gate` and `merge`
#   --max <n>    PRs gated per repo per run (default 3); the rest wait for the next run
#   --dry-run    print what each PR would get; no gate, merge, comment or log line
#
# Per repo: fetch origin main and add a detached worktree of it, so the plan (GATE_SLUG,
# GATE_STATE_NAME) and the vendored devkit are main's, never a developer's branch.
# _dependency_pr.py classifies the open Renovate and Dependabot PRs against main, oldest first;
# majors and unreadable update types are skipped and listed. Then, per minor/patch PR:
#   - behind (Renovate only): the main fetched at the start of the repo's turn is not an
#     ancestor of the head. Skipped, "behind main, Renovate will rebase" (renovate/default.json
#     rebaseWhen). Read once per repo on purpose: a merge this run makes moves main, and
#     re-reading it would put every later PR behind, one merge per repo per night. Dependabot
#     rebases only on a conflict, so its PRs are not held to this; the gate tests the merge into
#     the current main regardless.
#   - conflicting: `git merge-tree` of the head into the current origin/main fails. Skipped.
#   - this head already failed a gate here (the marker comment below): skipped until it moves.
#   - else `make gate PR=<n> GATE_ARGS="--expect-head <head>"`, which takes a machine gate slot
#     like any gate. PASS: `make merge PR=<n>`. Otherwise the verdict is the gate record's
#     (gate_record.py verdict-of), never make's exit code: make exits 2 for any failed recipe.
#     fail with a job failing on the PR's code: one PR comment per head naming the failing jobs
#     and rules (gate_record.py failures). error, no record of the head, or only machine
#     failures (a gate step such as worktree, toolchain or a conflict; the silence watchdog; a
#     budget overrun under load: `failures --code-only` is empty): logged with no comment and
#     no marker, so the next run retries the head. A Dependabot head is never parked on the box.
# Output: one `dependency-merge: <slug>#<n> <outcome> <detail>` line per PR, outcome one of
#   merged failed error refused skipped would-gate, appended with a UTC stamp to
#   $XDG_STATE_HOME/devkit/dependency-merge.log; the gate and merge output of a PR go to
#   $XDG_STATE_HOME/devkit/dependency-merge/<repo>-<n>.log. Then one summary line per repo.
# Kill switch: ${XDG_CONFIG_HOME:-~/.config}/devkit/dependency-merge.off, read before every PR.
# One run at a time (flock); a second run exits 0 with one line.
# Exit 0 when it ran, whatever each PR's outcome; 1 when no repo could be read; 2 usage or a
# missing tool.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"

readonly MARKER=devkit-dependency-merge
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/devkit
OFF=${XDG_CONFIG_HOME:-$HOME/.config}/devkit/dependency-merge.off
LOG=$STATE/dependency-merge.log

usage() { echo "usage: dependency_merge.sh [--max <n>] [--dry-run] <repo-root>..."; }
MAX=3
DRY_RUN=0
REPOS=()
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --max)
        [ $# -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
        MAX=$2; shift ;;
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage >&2; exit 2 ;;
      *) REPOS+=("$1") ;;
    esac
    shift
  done
  [ "${#REPOS[@]}" -gt 0 ] || { usage >&2; exit 2; }
}

require_tools() {
  local tool
  for tool in gh git make python3; do
    command -v "$tool" >/dev/null || { echo "dependency-merge: $tool not found" >&2; exit 2; }
  done
  command -v flock >/dev/null || { echo "dependency-merge: flock not found (macOS: brew install flock)" >&2; exit 2; }
}

parse_args "$@"
require_tools

OFF_SAID=0
switched_off() {
  [ -e "$OFF" ] || return 1
  [ "$OFF_SAID" = 1 ] || echo "dependency-merge: $OFF exists; not running"
  OFF_SAID=1
}
switched_off && exit 0

mkdir -p "$STATE/dependency-merge" || exit 2
# fd 8 is the run lock; every make below closes it (8>&-), so a process a gate leaves behind
# cannot hold it into the next night.
exec 8>>"$STATE/dependency-merge.lock"
flock -n 8 || { echo "dependency-merge: another run holds $STATE/dependency-merge.lock; not running"; exit 0; }

WT=""
OUTCOMES=""
cleanup_worktree() {
  [ -n "$WT" ] || return 0
  git -C "$WT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
  WT=""
}
trap cleanup_worktree EXIT

# record <slug>#<n> <outcome> <detail>
record() {
  local line="dependency-merge: $1 $2 $3"
  echo "$line"
  OUTCOMES="$OUTCOMES $2"
  [ "$DRY_RUN" = 1 ] || printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$LOG"
}

# summary <label>: the counts of the outcomes recorded since the last summary, in a fixed order.
summary() {
  local outcome n counts=""
  for outcome in merged failed error refused skipped would-gate; do
    n=$(tr ' ' '\n' <<<"$OUTCOMES" | grep -cx -- "$outcome")
    [ "$n" = 0 ] || counts="${counts:+$counts, }$outcome $n"
  done
  echo "dependency-merge: $1: ${counts:-no dependency PRs}"
  OUTCOMES=""
}

# failure_comment <n> <head> <failures>: the PR comment for a failed gate, marked with its head.
# shellcheck disable=SC2016  # the backticks are markdown code spans, not command substitution
failure_comment() {
  printf '<!-- %s head=%s -->\n' "$MARKER" "$2"
  printf '`make gate PR=%s` failed on head %s (bin/dependency_merge.sh, the nightly dependency merge). ' "$1" "${2:0:12}"
  printf 'This PR stays open; the nightly run gates it again once its head changes.\n\n'
  printf '%s\n' "${3:-no gate record of this head; see the log below}" | sed 's/^/- /'
  printf '\nLog on %s: `%s`\n' "$(hostname -s)" "$PR_LOG"
}

# gate_pr <slug> <state name> <n> <head>: gate, then merge or comment, and record the outcome.
gate_pr() {
  local slug=$1 n=$3 head=$4 rc gate_json verdict failures refusal
  gate_json=${XDG_STATE_HOME:-$HOME/.local/state}/$2/logs/$n/gate.json
  PR_LOG=$STATE/dependency-merge/${slug#*/}-$n.log
  make -C "$WT" gate PR="$n" GATE_ARGS="--expect-head $head" >"$PR_LOG" 2>&1 8>&-
  rc=$?
  if [ "$rc" = 0 ]; then
    if make -C "$WT" merge PR="$n" >>"$PR_LOG" 2>&1 8>&-; then
      record "$slug#$n" merged "head ${head:0:12}"
    else
      refusal=$(grep -E '^merge: refused: ' "$PR_LOG" | tail -n 1)
      record "$slug#$n" refused "${refusal:-make merge failed; see $PR_LOG}"
    fi
    return 0
  fi
  verdict=$(python3 -I "$HERE/gate_record.py" verdict-of "$gate_json" "$head")
  if [ "$verdict" != fail ]; then
    record "$slug#$n" error "make gate exit $rc, gate verdict ${verdict:-unrecorded} (the box, not the PR); see $PR_LOG"
    return 0
  fi
  failures=$(python3 -I "$HERE/gate_record.py" failures "$gate_json" "$head")
  if [ -z "$(python3 -I "$HERE/gate_record.py" failures --code-only "$gate_json" "$head")" ]; then
    record "$slug#$n" error "only the machine failed (gate step, silence or budget; not the PR): $(paste -sd ';' - <<<"${failures:-whole-gate budget}"); see $PR_LOG"
    return 0
  fi
  if gh pr comment "$n" --repo "$slug" --body "$(failure_comment "$n" "$head" "$failures")" >/dev/null; then
    record "$slug#$n" failed "$(paste -sd ';' - <<<"${failures:-no gate record}"); commented"
  else
    record "$slug#$n" failed "$(paste -sd ';' - <<<"${failures:-no gate record}"); comment not posted (gh above)"
  fi
}

# check_pr <slug> <n> <head> <main at start> <bot>: print why PR <n> is not gated now, or nothing.
check_pr() {
  local slug=$1 n=$2 head=$3 main0=$4 bodies
  # refs/worktree/ is private to this worktree and goes with it: the checkout's refs stay as they were.
  git -C "$WT" fetch -q --no-tags origin +main:refs/remotes/origin/main "+pull/$n/head:refs/worktree/dependency-pr" \
    || { echo "error cannot fetch main and PR #$n (git above)"; return; }
  [ "$(git -C "$WT" rev-parse refs/worktree/dependency-pr)" = "$head" ] \
    || { echo "skipped head moved since the PR list; next run"; return; }
  [ "$5" != renovate ] || git -C "$WT" merge-base --is-ancestor "$main0" "$head" \
    || { echo "skipped behind main, Renovate will rebase"; return; }
  git -C "$WT" merge-tree --write-tree origin/main "$head" >/dev/null 2>&1 \
    || { echo "skipped conflicts with main, Renovate will rebase"; return; }
  bodies=$(gh api "repos/$slug/issues/$n/comments" --paginate --jq '.[].body') \
    || { echo "error cannot read PR #$n's comments (gh above)"; return; }
  if grep -qF "<!-- $MARKER head=$head -->" <<<"$bodies"; then
    echo "skipped its gate already failed on head ${head:0:12} (see its comment); a new head retries"
  fi
}

# list_prs <slug>: _dependency_pr.py's lines for the open PRs against main. The list never asks
# for `commits` (GitHub refuses that query for 100 PRs: _dependency_pr.py's docstring); the PRs
# whose verdict reads commits get one `gh pr view` each. gh pages the list 100 at a time up to
# --limit, so a repo with more than 100 open PRs is listed whole.
list_prs() {
  local list numbers n
  list=$(gh pr list --repo "$1" --base main --state open --limit 1000 \
    --json number,author,title,labels,headRefOid,createdAt,body) || return
  numbers=$(python3 -I "$HERE/_dependency_pr.py" needs-commits <<<"$list") || return
  {
    printf '%s\n' "$list"
    for n in $numbers; do
      gh pr view "$n" --repo "$1" --json number,headRefOid,commits || exit
    done
  } | python3 -I "$HERE/_dependency_pr.py"
}

# repo_error <label> <why>: one line, and the repo counts as not read.
repo_error() { echo "dependency-merge: $1: cannot run: $2" >&2; return 1; }

# open_repo <dir>: set SLUG, STATE_NAME, MAIN0 (origin/main now, the "behind" reference for
# the whole turn), PRS (_dependency_pr.py lines) and WT (a detached worktree of MAIN0).
open_repo() {
  local root plan
  root=$(cd "$1" 2>/dev/null && pwd -P) || { repo_error "$1" "not a directory"; return; }
  git -C "$root" fetch -q --no-tags origin main || { repo_error "$root" "git fetch origin main failed (above)"; return; }
  MAIN0=$(git -C "$root" rev-parse --verify origin/main) || { repo_error "$root" "no origin/main"; return; }
  plan=$(git -C "$root" show "$MAIN0:scripts/ci/gate_plan.sh" 2>/dev/null) \
    || { repo_error "$root" "main has no scripts/ci/gate_plan.sh"; return; }
  SLUG=$(gate_plan_literal <(echo "$plan") GATE_SLUG)
  STATE_NAME=$(gate_plan_literal <(echo "$plan") GATE_STATE_NAME)
  # The slug names the worktree that is rm -rf'd below: owner/repo, nothing that climbs.
  [[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$SLUG" != *..* ]] && [ -n "$STATE_NAME" ] \
    || { repo_error "$root" "main's gate plan lacks a literal GATE_SLUG=owner/repo or GATE_STATE_NAME"; return; }
  PRS=$(list_prs "$SLUG") || { repo_error "$SLUG" "cannot list its open PRs (gh or _dependency_pr.py above)"; return; }
  WT=$STATE/dependency-merge/wt-${SLUG#*/}
  git -C "$root" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT"
  git -C "$root" worktree add -q --detach "$WT" "$MAIN0" || { WT=""; repo_error "$SLUG" "cannot add a worktree of main (git above)"; return; }
}

# handle_pr <n> <head> <bot> <decision> <detail>: record a skip, or gate (GATED counts toward --max).
handle_pr() {
  local n=$1 head=$2 why
  [ "$4" = gate ] || { record "$SLUG#$n" skipped "$5"; return; }
  [ "$GATED" -lt "$MAX" ] || { record "$SLUG#$n" skipped "limit of $MAX gated per run reached; next run"; return; }
  why=$(check_pr "$SLUG" "$n" "$head" "$MAIN0" "$3")
  [ -z "$why" ] || { record "$SLUG#$n" "${why%% *}" "${why#* }"; return; }
  GATED=$((GATED + 1))
  if [ "$DRY_RUN" = 1 ]; then
    record "$SLUG#$n" would-gate "$5: make gate PR=$n, then make merge PR=$n on PASS"
  else
    gate_pr "$SLUG" "$STATE_NAME" "$n" "$head"
  fi
}

run_repo() {
  local n head bot decision detail
  open_repo "$1" || return
  GATED=0
  while IFS=$'\t' read -r n head bot decision detail <&3; do
    [ -n "$n" ] || continue  # the here-string of an empty list is one empty line
    if switched_off; then break; fi
    handle_pr "$n" "$head" "$bot" "$decision" "$detail"
  done 3<<<"$PRS"
  cleanup_worktree
  summary "$SLUG"
}

read_any=0
for repo in "${REPOS[@]}"; do
  if switched_off; then break; fi
  run_repo "$repo" && read_any=1
done
[ "$read_any" = 1 ] || exit 1
exit 0
