#!/usr/bin/env bash
# Nightly: keep each repo's vendored devkit at devkit's main, then a gated merge of minor and
# patch dependency PRs. Owner decision 2026-10-21: keep automatic minor/patch updates, but route
# every one through the repo's own gate; Renovate never merges by itself and no paid GitHub
# feature is involved. Owner 2026-10-22: devkit improves every project without a hand-run
# `make devkit-sync` PR per repo per devkit change. Scheduled by bin/install_dependency_merge.sh
# (templates/launchd/com.agandhi4.devkit.dependency-merge.plist), whose launcher runs devkit
# main's copy of this file from a clone of its own (bin/job_launcher.sh), never a checkout's.
#
# Usage: bin/dependency_merge.sh [--max <n>] [--dry-run] <repo-root>...
#   <repo-root>  a checkout whose scripts/ci/gate_plan.sh has literal GATE_SLUG and
#                GATE_STATE_NAME lines and whose Makefile has `gate` and `merge`
#   --max <n>    PRs gated per repo per run (default 3); the rest wait for the next run
#   --dry-run    print what each PR would get; no gate, merge, comment or log line
#
# Per repo: fetch origin main and add a detached worktree of it, so the plan (GATE_SLUG,
# GATE_STATE_NAME) and the vendored devkit are main's, never a developer's branch.
# The devkit sync comes first, so the dependency PRs gate on the newest devkit. A repo whose main
# has no .devkit-rev (devkit itself) has none. Against $DEVKIT_URL's main, fetched into the repo:
#   - main's .devkit-rev names it, or a commit vendoring the same tree (a tests/-only change):
#     `current`. One not on devkit's main (vendored from a branch): skipped, never moved back.
#   - else the one open PR labelled devkit-sync is reused when its branch is
#     devkit-sync/<main sha7>, it vendors that commit and it merges cleanly into main, so a head
#     whose gate failed stays that head (the marker below skips it) and is never re-gated in a
#     loop (one whose head is not the job's commit, job_sync_commit, is left alone). Otherwise, in a second worktree of main, `make devkit-sync` with
#     DEVKIT_COMMIT_TRAILER set to the model-agnostic default (a person's devkit.trailer config
#     never signs a job's commit), checked to vendor only (_vendor_paths.sh vendoring_only and
#     vendored_from, the very test pr_merge.sh's Codex exemption applies, so a sync that would
#     need a review is refused here, not pushed), force-pushed to devkit-sync/<sha7> and opened
#     as a draft (no Codex run, no fleet Workflow; pr_merge.sh readies it) with the devkit commit
#     range and the docs/decisions.md titles it adds. Any other open devkit-sync PR is closed as
#     superseded. The pre-push hook skips the repo's steps for it (hook_steps.sh vendoring only).
#     Every step reruns to the same end, so a run stopped at any one resumes the next night: a
#     devkit-sync/<sha7> already there with no open labelled PR is a run's own unfinished work when
#     its tip is the job's commit and no PR on it was ever closed or merged (adopt_sync_branch),
#     and is pushed over and opened; a person's commit there, or a PR closed by hand, is refused.
#     After the sync, every other devkit-sync/* branch whose tip is the job's commit, vendoring a
#     devkit commit main has moved past, with no open PR, is deleted (`pruned`, prune_sync_branches).
#   - then gated and merged as below, counting toward --max. A fail is a devkit regression: one
#     comment per head, the PR left open, the next devkit change opening its successor. A gate
#     failing on the metrics job is the same fail: the existing rules apply by hand (a gain wants
#     `make metrics-tighten` on the branch, a loss the metrics-rebaseline label), which makes it
#     a repo change under the normal Codex rule. Merged: the worktree moves to the new main.
# _dependency_pr.py classifies the open Renovate and Dependabot PRs against main, oldest first;
# majors and unreadable update types are skipped and listed. Then, per minor/patch PR:
#   - behind main: gated like any PR. The gate tests the merge into the current main and
#     pr_merge.sh merges only onto the main it gated, so a branch that is not rebased is no risk;
#     waiting for a rebase was (homelab #128, 2026-10-22): with Renovate's rebaseWhen
#     behind-base-branch, each merge this run made had Renovate force-push every other open
#     branch, racing the next merge. renovate/default.json keeps rebaseWhen auto (conflicts only,
#     no automerge and no up-to-date protection in this fleet), and Dependabot rebases only on a
#     conflict too.
#   - conflicting: `git merge-tree` of the head into the current origin/main fails. Skipped.
#   - this head already failed a gate here (the marker comment below): skipped until it moves.
#   - else `make gate PR=<n> GATE_ARGS="--expect-head <head>"`, which takes a machine gate slot
#     like any gate. PASS: `make merge PR=<n>`; a refusal to re-gate (main or the head moved
#     after the gate, or GitHub refused the merge for it: pr_merge.sh's `re-gate:` lines) is
#     "skipped behind", and the next run gates the new tree. Otherwise the verdict is the gate
#     record's (gate_record.py verdict-of), never make's exit code: make exits 2 for any failed recipe.
#     fail with a job failing on the PR's code: one PR comment per head naming the failing jobs
#     and rules (gate_record.py failures). error, no record of the head, or only machine
#     failures (a gate step such as worktree, toolchain or a conflict; the silence watchdog; a
#     budget overrun under load: `failures --code-only` is empty): logged with no comment and
#     no marker, so the next run retries the head. A Dependabot head is never parked on the box.
# Network: every call to GitHub (git fetch and push, gh) is retried after a transient failure
#   (net); one still failing is the outcome `network`, never "branch exists" or a regression.
# Power: a Mac macOS will sleep whatever caffeinate holds (lid closed on battery,
#   _awake_lib.sh's devkit_sleep_forced) stops the run before its next repo or PR, with one
#   `skipped run: <reason>` line and exit 0, as the kill switch does.
# Output: one `dependency-merge: <slug>#<n> <outcome> <detail>` line per PR (the sync's line is
#   `<slug>` alone until it has a PR), outcome one of merged failed error network refused skipped
#   closed pruned current would-sync would-prune would-gate, appended with a UTC stamp to
#   $XDG_STATE_HOME/devkit/dependency-merge.log; the gate and merge output of a PR go to
#   $XDG_STATE_HOME/devkit/dependency-merge/<repo>-<n>.log. Then one summary line per repo.
# Kill switch: ${XDG_CONFIG_HOME:-~/.config}/devkit/dependency-merge.off, read before every PR.
# One run at a time (flock); a second run exits 0 with one line.
# Exit 0 when it ran, whatever each PR's outcome; 1 when no repo could be read; 2 usage, a
# missing tool (bin/_toolchain_lib.sh's devkit_preflight: one line naming each), checked before any repo.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_toolchain_lib.sh
. "$HERE/_toolchain_lib.sh"
# shellcheck source=bin/_vendor_paths.sh  # DEVKIT_URL, vendor_tree_of, vendoring_only, vendored_from
. "$HERE/_vendor_paths.sh"
# shellcheck source=bin/_trailer_lib.sh  # DEVKIT_DEFAULT_TRAILER, the sync commit's trailer
. "$HERE/_trailer_lib.sh"
# shellcheck source=bin/_awake_lib.sh  # devkit_sleep_forced
. "$HERE/_awake_lib.sh"

readonly MARKER=devkit-dependency-merge
readonly SYNC_LABEL=devkit-sync
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
  # Before any repo: without one every gate fails the same way, logged as N per-PR box errors
  # (2026-10-22: launchd's PATH had only Xcode's 3.9, then no uv). The toolchain directory goes
  # first on PATH, too, so a repo whose vendored devkit predates _toolchain_lib.sh still runs its
  # bare python3 and uv calls on it.
  devkit_preflight gh git make flock -- "${REPOS[@]}" \
    || { echo "dependency-merge: $DEVKIT_PREFLIGHT_ERROR; no repo gated" >&2; exit 2; }
  devkit_toolchain_bin || { echo "dependency-merge: $DEVKIT_PYTHON_ERROR; no repo gated" >&2; exit 2; }
  export PATH="$DEVKIT_TOOLCHAIN_BIN:$PATH"
}

parse_args "$@"
require_tools

# halted: true, saying why once, when the run must stop before its next repo or PR: the kill
# switch, or a Mac macOS will sleep whatever caffeinate holds (header, Power), where every gate
# would refuse and each PR log an error.
HALT_SAID=0
halted() {
  local why
  if [ -e "$OFF" ]; then
    why="$OFF exists; not running"
  elif devkit_sleep_forced; then
    why="skipped run: $DEVKIT_SLEEP_REASON"
  else
    return 1
  fi
  [ "$HALT_SAID" = 1 ] || echo "dependency-merge: $why"
  HALT_SAID=1
}
halted && exit 0

mkdir -p "$STATE/dependency-merge" || exit 2
# fd 8 is the run lock; every make below closes it (8>&-), so a process a gate leaves behind
# cannot hold it into the next night.
exec 8>>"$STATE/dependency-merge.lock"
flock -n 8 || { echo "dependency-merge: another run holds $STATE/dependency-merge.lock; not running"; exit 0; }

WT=""
SYNC_WT=""
OUTCOMES=""
LAST_OUTCOME=""
# remove_worktree <dir>: the worktree and its registration, or the directory a failed add left.
remove_worktree() {
  git -C "$1" worktree remove --force "$1" >/dev/null 2>&1 || rm -rf "$1"
}
cleanup_worktree() {
  [ -z "$SYNC_WT" ] || remove_worktree "$SYNC_WT"
  [ -z "$WT" ] || remove_worktree "$WT"
  SYNC_WT="" WT=""
}
trap cleanup_worktree EXIT

# record <slug>#<n> <outcome> <detail>
record() {
  local line="dependency-merge: $1 $2 $3"
  echo "$line"
  OUTCOMES="$OUTCOMES $2"
  LAST_OUTCOME=$2
  [ "$DRY_RUN" = 1 ] || printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$LOG"
}

# GitHub drops calls (2026-10-24): finplat's sync push died on "RPC failed; curl 56 Connection
# reset" after it had landed, and rollcall's label call on "connection reset by peer", each then
# read as a repo problem. NET_TRIES and NET_BACKOFF_SECONDS are environment-only test hooks.
readonly NET_TRIES=${NET_TRIES:-3} NET_TEMPFAIL=75
readonly NET_TRANSIENT='connection reset|RPC failed|remote end hung up|unexpected disconnect|could not resolve host|timed out|TLS handshake|unexpected EOF|HTTP 5[0-9][0-9]|HTTP/[0-9.]+ 5[0-9][0-9]'

# net <cmd...>: run a call to GitHub, retrying a transient network failure with doubling backoff,
# NET_TRIES tries in all. A retry is safe for every call here: a push that landed is "up-to-date"
# the second time, a `gh pr create` that did is refused as existing and the next run adopts its
# PR, and the rest read or set state. Stdout is the last try's (a dropped one may have printed
# half), stderr every try's. Exit NET_TEMPFAIL when the last try still failed on the network.
net() {
  local try=1 delay=${NET_BACKOFF_SECONDS:-5} out err rc
  out=$(mktemp "${TMPDIR:-/tmp}/depmerge-net.XXXXXX") || return 2
  err=$(mktemp "${TMPDIR:-/tmp}/depmerge-net.XXXXXX") || { rm -f "$out"; return 2; }
  while :; do
    "$@" >"$out" 2>"$err"
    rc=$?
    cat "$err" >&2
    [ "$rc" != 0 ] || break
    grep -qiE "$NET_TRANSIENT" "$err" || break
    if [ "$try" -ge "$NET_TRIES" ]; then
      rc=$NET_TEMPFAIL
      break
    fi
    echo "dependency-merge: a transient network failure (try $try of $NET_TRIES); retrying in ${delay}s" >&2
    sleep "$delay"
    try=$((try + 1)) delay=$((delay * 2))
  done
  cat "$out"
  rm -f "$out" "$err"
  return "$rc"
}

# net_outcome <rc> <outcome>: `network` for net's NET_TEMPFAIL (nothing is wrong with the repo
# and the next run resumes where this one stopped), else <outcome>.
net_outcome() { if [ "$1" = "$NET_TEMPFAIL" ]; then echo network; else echo "$2"; fi; }

# record_fail <label> <rc> <outcome> <detail>: record a failed step, as net_outcome words it.
record_fail() { record "$1" "$(net_outcome "$2" "$3")" "$4"; }

# summary <label>: the counts of the outcomes recorded since the last summary, in a fixed order.
summary() {
  local outcome n counts=""
  for outcome in merged failed error network refused skipped closed pruned current would-sync would-prune would-gate; do
    n=$(tr ' ' '\n' <<<"$OUTCOMES" | grep -cx -- "$outcome")
    [ "$n" = 0 ] || counts="${counts:+$counts, }$outcome $n"
  done
  echo "dependency-merge: $1: ${counts:-no dependency PRs}"
  OUTCOMES=""
}

# failure_comment <n> <head> <failures> <kind>: the PR comment for a failed gate, marked with its
# head. <kind> is dependency or devkit-sync.
# shellcheck disable=SC2016  # the backticks are markdown code spans, not command substitution
failure_comment() {
  printf '<!-- %s head=%s -->\n' "$MARKER" "$2"
  if [ "$4" = devkit-sync ]; then
    printf '`make gate PR=%s` failed on head %s (bin/dependency_merge.sh, the nightly devkit sync): ' "$1" "${2:0:12}"
    printf "devkit's main breaks this repo, a devkit regression (or a bug this repo relied on). "
    printf 'This PR stays open and is not gated again; the next devkit change opens its successor. '
    printf 'A failing metrics job follows the usual rules by hand: a gain wants `make metrics-tighten` committed here, '
    printf 'a loss the metrics-rebaseline label; either makes this a repo change, under the normal Codex rule.\n\n'
  else
    printf '`make gate PR=%s` failed on head %s (bin/dependency_merge.sh, the nightly dependency merge). ' "$1" "${2:0:12}"
    printf 'This PR stays open; the nightly run gates it again once its head changes.\n\n'
  fi
  printf '%s\n' "${3:-no gate record of this head; see the log below}" | sed 's/^/- /'
  printf '\nLog on %s: `%s`\n' "$(hostname -s)" "$PR_LOG"
}

# gate_pr <slug> <state name> <n> <head> <kind>: gate, then merge or comment, and record the
# outcome. <kind> (dependency, devkit-sync) words the comment and a failure's record.
gate_pr() {
  local slug=$1 n=$3 head=$4 kind=$5 rc gate_json verdict failures refusal regression=""
  gate_json=${XDG_STATE_HOME:-$HOME/.local/state}/$2/logs/$n/gate.json
  PR_LOG=$STATE/dependency-merge/${slug#*/}-$n.log
  make -C "$WT" gate PR="$n" GATE_ARGS="--expect-head $head" >"$PR_LOG" 2>&1 8>&-
  rc=$?
  if [ "$rc" = 0 ]; then
    if make -C "$WT" merge PR="$n" >>"$PR_LOG" 2>&1 8>&-; then
      record "$slug#$n" merged "head ${head:0:12}"
    else
      refusal=$(grep -E '^merge: refused: ' "$PR_LOG" | tail -n 1)
      case "$refusal" in
        "merge: refused: re-gate: "*) record "$slug#$n" skipped "behind (${refusal#merge: refused: re-gate: }); the next run re-gates" ;;
        *) record "$slug#$n" refused "${refusal:-make merge failed; see $PR_LOG}" ;;
      esac
    fi
    return 0
  fi
  verdict=$("$DEVKIT_PYTHON" -I "$HERE/gate_record.py" verdict-of "$gate_json" "$head")
  if [ "$verdict" != fail ]; then
    record "$slug#$n" error "make gate exit $rc, gate verdict ${verdict:-unrecorded} (the box, not the PR); see $PR_LOG"
    return 0
  fi
  failures=$("$DEVKIT_PYTHON" -I "$HERE/gate_record.py" failures "$gate_json" "$head")
  if [ -z "$("$DEVKIT_PYTHON" -I "$HERE/gate_record.py" failures --code-only "$gate_json" "$head")" ]; then
    record "$slug#$n" error "only the machine failed (gate step, silence or budget; not the PR): $(paste -sd ';' - <<<"${failures:-whole-gate budget}"); see $PR_LOG"
    return 0
  fi
  [ "$kind" != devkit-sync ] || regression="devkit regression: "
  if net gh pr comment "$n" --repo "$slug" --body "$(failure_comment "$n" "$head" "$failures" "$kind")" >/dev/null; then
    record "$slug#$n" failed "$regression$(paste -sd ';' - <<<"${failures:-no gate record}"); commented"
  else
    record "$slug#$n" failed "$regression$(paste -sd ';' - <<<"${failures:-no gate record}"); comment not posted (gh above)"
  fi
}

# check_pr <slug> <n> <head>: print why PR <n> is not gated now, or nothing.
check_pr() {
  local slug=$1 n=$2 head=$3 bodies
  # refs/worktree/ is private to this worktree and goes with it: the checkout's refs stay as they were.
  net fetch_main "$WT" "+pull/$n/head:refs/worktree/dependency-pr" \
    || { echo "$(net_outcome $? error) cannot fetch main and PR #$n (git above)"; return; }
  [ "$(git -C "$WT" rev-parse refs/worktree/dependency-pr)" = "$head" ] \
    || { echo "skipped head moved since the PR list; next run"; return; }
  git -C "$WT" merge-tree --write-tree origin/main "$head" >/dev/null 2>&1 \
    || { echo "skipped conflicts with main, Renovate will rebase"; return; }
  bodies=$(net gh api "repos/$slug/issues/$n/comments" --paginate --jq '.[].body') \
    || { echo "$(net_outcome $? error) cannot read PR #$n's comments (gh above)"; return; }
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
  list=$(net gh pr list --repo "$1" --base main --state open --limit 1000 \
    --json number,author,title,labels,headRefOid,createdAt,body) || return
  numbers=$("$DEVKIT_PYTHON" -I "$HERE/_dependency_pr.py" needs-commits <<<"$list") || return
  {
    printf '%s\n' "$list"
    for n in $numbers; do
      net gh pr view "$n" --repo "$1" --json number,headRefOid,commits || exit
    done
  } | "$DEVKIT_PYTHON" -I "$HERE/_dependency_pr.py"
}

# repo_error <label> <why>: one line, and the repo counts as not read.
repo_error() { echo "dependency-merge: $1: cannot run: $2" >&2; return 1; }

# open_repo <dir>: set SLUG, STATE_NAME, PRS (_dependency_pr.py lines) and WT (a detached
# worktree of origin/main now, whose plan and vendored devkit run every gate and merge).
open_repo() {
  local root
  root=$(cd "$1" 2>/dev/null && pwd -P) || { repo_error "$1" "not a directory"; return; }
  net gate_plan_main "$root" || { repo_error "$root" "$PLAN_ERROR"; return; }
  SLUG=$PLAN_SLUG STATE_NAME=$PLAN_STATE_NAME
  PRS=$(list_prs "$SLUG") || { repo_error "$SLUG" "cannot list its open PRs (gh or _dependency_pr.py above)"; return; }
  WT=$STATE/dependency-merge/wt-${SLUG#*/}
  git -C "$root" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT"
  git -C "$root" worktree add -q --detach "$WT" "$PLAN_MAIN" || { WT=""; repo_error "$SLUG" "cannot add a worktree of main (git above)"; return; }
}

# handle_pr <n> <head> <decision> <detail> [<kind>]: record a skip, or gate (GATED counts toward
# --max) when <decision> is gate or pushed (below). <kind> is gate_pr's, dependency by default.
handle_pr() {
  local n=$1 head=$2 kind=${5:-dependency} why=""
  case $3 in gate|pushed) ;; *) record "$SLUG#$n" skipped "$4"; return ;; esac
  [ "$GATED" -lt "$MAX" ] || { record "$SLUG#$n" skipped "limit of $MAX gated per run reached; next run"; return; }
  # pushed: a head this run just made on a fresh main. It has no failed gate and cannot conflict,
  # and GitHub may not have moved refs/pull/<n>/head to it yet, which check_pr would call moved.
  [ "$3" = pushed ] || why=$(check_pr "$SLUG" "$n" "$head")
  [ -z "$why" ] || { record "$SLUG#$n" "${why%% *}" "${why#* }"; return; }
  GATED=$((GATED + 1))
  if [ "$DRY_RUN" = 1 ]; then
    record "$SLUG#$n" would-gate "$4: make gate PR=$n, then make merge PR=$n on PASS"
  else
    gate_pr "$SLUG" "$STATE_NAME" "$n" "$head" "$kind"
  fi
}

# sync_body <old> <new>: the devkit-sync PR's body, read from the devkit history fetched into $WT.
# shellcheck disable=SC2016  # the backticks are markdown code spans, not command substitution
sync_body() {
  local titles
  printf 'Nightly devkit sync (devkit/bin/dependency_merge.sh): `make devkit-sync` from %s to %s. ' "${1:0:7}" "${2:0:7}"
  printf 'It only vendors (devkit/, .devkit-rev, base copies) code reviewed and gated on devkit main, so `make merge` '
  printf 'asks no Codex review of it (pr_merge.sh); the gate judges its effect on this repo.\n\n'
  printf 'Devkit commits %s..%s:\n' "${1:0:7}" "${2:0:7}"
  # GitHub refuses a body over 65536 characters; a repo far behind lists the newest 50.
  git -C "$WT" log --no-merges --format='- %h %s' -n 50 "$1..$2"
  local more
  more=$(( $(git -C "$WT" rev-list --no-merges --count "$1..$2") - 50 ))
  [ "$more" -le 0 ] || printf -- '- ... and %s older\n' "$more"
  titles=$(git -C "$WT" diff "$1" "$2" -- docs/decisions.md | sed -n 's/^+## /- /p')
  printf '\nDecisions added (devkit docs/decisions.md):\n%s\n' "${titles:-- none}"
}

# reusable_sync <head> <upstream>: true when the open sync PR's <head> (fetched to
# refs/worktree/devkit-sync) still vendors <upstream> and merges cleanly into main, so pushing a
# fresh sync over it would only discard its gate record.
reusable_sync() {
  local rev
  [ "$(git -C "$WT" rev-parse refs/worktree/devkit-sync)" = "$1" ] || return 1
  rev=$(git -C "$WT" show "$1:.devkit-rev" 2>/dev/null) || return 1
  [ "${rev%% *}" = "$2" ] && git -C "$WT" merge-tree --write-tree origin/main "$1" >/dev/null 2>&1
}

# job_sync_commit <dir> <commit>: true when <commit> is a sync commit as push_sync makes it:
# subject "Update devkit to ...", the model-agnostic trailer, one parent on origin/main and nothing
# but vendoring on top of it. A person's commit on the branch, or the job's amended with other
# paths, is not.
job_sync_commit() {
  local parent paths
  git -C "$1" log -1 --format=%s "$2" 2>/dev/null | grep -q '^Update devkit to ' || return 1
  git -C "$1" log -1 --format=%B "$2" | grep -qxF "$DEVKIT_DEFAULT_TRAILER" || return 1
  parent=$(git -C "$1" log -1 --format=%P "$2")
  [[ "$parent" =~ ^[0-9a-f]+$ ]] || return 1
  git -C "$1" merge-base --is-ancestor "$parent" refs/remotes/origin/main || return 1
  paths=$(git -C "$1" -c core.quotePath=false diff --name-only --no-renames "$parent" "$2")
  (cd "$1" && vendoring_only "$2" "$paths")
}

# adopt_sync_branch <tip> <log>: true when devkit-sync/<sha7>, found at <tip> with no open labelled
# PR on it, is a run's own unfinished work, which this run then pushes over and opens: the job's
# commit (job_sync_commit) with no PR on it ever closed or merged. finplat's push landed as the
# network dropped and rollcall's label call failed after its push (2026-10-24); #219's guard
# took each for a person's branch, and no later run synced either repo again. An open PR on it
# (gh pr create opened it, then could not label it) becomes SYNC_REUSE. Else records why and
# returns 1: a person's commit there, or a PR closed by hand, is never overwritten or re-opened.
adopt_sync_branch() {
  local tip=$1 log=$2 branch=$SYNC_LABEL/${SYNC_NEW:0:7} prs n state
  job_sync_commit "$SYNC_WT" "$tip" || {
    record "$SLUG" skipped "$branch is at ${tip:0:12}, not a devkit-sync commit (a person's push?); not overwritten"
    return 1
  }
  prs=$(net gh pr list --repo "$SLUG" --head "$branch" --state all --json number,state \
    --jq '.[] | [.number, .state] | @tsv' 2>>"$log") \
    || { record_fail "$SLUG" $? error "cannot list the PRs on $branch; see $log"; return 1; }
  while IFS=$'\t' read -r n state; do
    case $state in
      '') ;;
      OPEN) SYNC_REUSE=$n ;;
      *)
        record "$SLUG" skipped "$branch is PR #$n's, $state (by hand: never re-opened); not overwritten"
        return 1 ;;
    esac
  done <<<"$prs"
}

# fetch_sync_branches <dir> <log>: origin's devkit-sync* branches into their tracking refs, or
# record why not and return 1. Pruned: a stale refs/remotes/origin/devkit-sync (a branch of that
# name, long deleted) D/F-conflicts with each devkit-sync/<sha7> one, and push's tracking update
# failed on it (rollcall, 2026-10-24).
fetch_sync_branches() {
  net git -C "$1" fetch -q --prune --no-tags origin \
    "+refs/heads/$SYNC_LABEL*:refs/remotes/origin/$SYNC_LABEL*" >>"$2" 2>&1 8>&- \
    || { record_fail "$SLUG" $? error "cannot fetch origin's $SYNC_LABEL branches; see $2"; return 1; }
}

# push_sync <log> <lease>: make devkit-sync in a fresh worktree of main, check that it only
# vendors, and force-push it to devkit-sync/<sha7> over <lease>: the open PR's head, or "" for
# none, when a branch already there is pushed over only if adopt_sync_branch adopts it. Sets
# SYNC_NEW and SYNC_HEAD (and SYNC_REUSE as adopt_sync_branch does); else records why, returns 1.
push_sync() {
  local log=$1 main paths upstream
  main=$(git -C "$WT" rev-parse HEAD)
  SYNC_WT=$STATE/dependency-merge/sync-${SLUG#*/}
  remove_worktree "$SYNC_WT"
  git -C "$WT" worktree add -q --detach "$SYNC_WT" "$main" >>"$log" 2>&1 \
    || { SYNC_WT=""; record "$SLUG" error "cannot add a worktree of main for the sync; see $log"; return 1; }
  DEVKIT_COMMIT_TRAILER=$DEVKIT_DEFAULT_TRAILER make -C "$SYNC_WT" devkit-sync >>"$log" 2>&1 8>&- \
    || { record "$SLUG" error "make devkit-sync failed (a conflict or a refused commit), not forced; see $log"; return 1; }
  SYNC_NEW=$(cut -d' ' -f1 "$SYNC_WT/.devkit-rev")
  SYNC_HEAD=$(git -C "$SYNC_WT" rev-parse HEAD)
  paths=$(git -C "$SYNC_WT" -c core.quotePath=false diff --name-only --no-renames "$main" HEAD)
  [ -n "$paths" ] || { record "$SLUG" error "make devkit-sync committed nothing; see $log"; return 1; }
  # The test pr_merge.sh's exemption applies: a sync that would need a review is never pushed.
  # devkit's main is fetched again, not read from the record under test: devkit-sync fetched it
  # just now, so it is at least the commit it vendored.
  upstream=$(net fetch_devkit_main "$SYNC_WT") \
    || { record_fail "$SLUG" $? error "cannot fetch devkit's main from $DEVKIT_URL (git above)"; return 1; }
  (cd "$SYNC_WT" && vendoring_only HEAD "$paths" && vendored_from HEAD "$upstream" "$main") || {
    record "$SLUG" refused "the sync is not vendoring only (outside devkit/: $(grep -v '^devkit/' <<<"$paths" | paste -sd ' ' -)); not pushed"
    return 1
  }
  local lease=$2 branch=$SYNC_LABEL/${SYNC_NEW:0:7} there
  # make devkit-sync fetches devkit's main itself: one merged since is another branch, and the
  # open PR found for the old one is superseded (close_superseded).
  [ "$SYNC_NEW" = "$SYNC_UPSTREAM" ] || lease="" SYNC_REUSE=""
  fetch_sync_branches "$SYNC_WT" "$log" || return 1  # also reads the branch's tip
  # An unleased branch is judged first, never pushed into blind: a push of the very commit it
  # holds (a sync rebuilt in the same second) is "up-to-date" past any lease (#219).
  if [ -z "$lease" ]; then
    there=$(git -C "$SYNC_WT" rev-parse -q --verify "refs/remotes/origin/$branch")
    if [ -n "$there" ]; then
      adopt_sync_branch "$there" "$log" || return 1
      lease=$there
    fi
  fi
  # Leased: a branch that moved since it was read (a person's push) is never overwritten.
  net git -C "$SYNC_WT" push -q "--force-with-lease=refs/heads/$branch:$lease" origin "HEAD:refs/heads/$branch" \
    >>"$log" 2>&1 8>&- \
    || { record_fail "$SLUG" $? skipped "cannot push $branch (moved since this run read it: a person's push?); not overwritten; see $log"; return 1; }
}

# open_sync_pr <n or ""> <old> <log>: update PR <n>'s body and label, or open the draft PR for the
# branch push_sync pushed. Sets SYNC_PR; else records why and returns 1.
open_sync_pr() {
  local body url
  body=$(sync_body "$2" "$SYNC_NEW")
  # The label on both paths: the edit labels a PR gh pr create opened but could not label.
  net gh label create "$SYNC_LABEL" --repo "$SLUG" --force --color 0e8a16 \
    --description "Nightly devkit sync (devkit bin/dependency_merge.sh)" >>"$3" 2>&1 \
    || { record_fail "$SLUG" $? error "cannot create the $SYNC_LABEL label; see $3"; return 1; }
  if [ -n "$1" ]; then
    SYNC_PR=$1
    net gh pr edit "$1" --repo "$SLUG" --add-label "$SYNC_LABEL" --body "$body" >>"$3" 2>&1 \
      || { record_fail "$SLUG#$1" $? error "cannot update its body and label; see $3"; return 1; }
    return 0
  fi
  url=$(net gh pr create --repo "$SLUG" --base main --head "$SYNC_LABEL/${SYNC_NEW:0:7}" --draft \
    --label "$SYNC_LABEL" --title "Update devkit to ${SYNC_NEW:0:7}" --body "$body" 2>>"$3") \
    || { record_fail "$SLUG" $? error "cannot open the sync PR; see $3"; return 1; }
  SYNC_PR=${url##*/}
  [[ "$SYNC_PR" =~ ^[0-9]+$ ]] || { record "$SLUG" error "gh pr create printed no PR URL ('$url')"; return 1; }
}

# close_superseded <open sync PR lines>: close every one but $SYNC_PR, naming its successor.
close_superseded() {
  local n
  while IFS=$'\t' read -r n _ _; do
    [ -n "$n" ] && [ "$n" != "$SYNC_PR" ] || continue
    if net gh pr close "$n" --repo "$SLUG" --delete-branch \
      --comment "Superseded by #$SYNC_PR (devkit ${SYNC_NEW:0:7}), opened by the nightly devkit sync." >/dev/null; then
      record "$SLUG#$n" closed "superseded by #$SYNC_PR"
    else
      record_fail "$SLUG#$n" $? error "cannot close it as superseded by #$SYNC_PR (gh above)"
    fi
  done <<<"$1"
}

# sync_behind: set SYNC_OLD and SYNC_UPSTREAM (devkit's main) and return 0 when main's vendored
# devkit should move to it (header); else record why not (nothing for a repo vendoring none).
sync_behind() {
  local rev
  SYNC_UPSTREAM="" SYNC_NEW=""
  rev=$(git -C "$WT" show HEAD:.devkit-rev 2>/dev/null) || return 1
  SYNC_OLD=${rev%% *}
  SYNC_UPSTREAM=$(net fetch_devkit_main "$WT") \
    || { record_fail "$SLUG" $? error "cannot fetch devkit's main from $DEVKIT_URL (git above)"; return 1; }
  [ "$SYNC_OLD" != "$SYNC_UPSTREAM" ] || { record "$SLUG" current "devkit at ${SYNC_OLD:0:7}"; return 1; }
  git -C "$WT" merge-base --is-ancestor "$SYNC_OLD" "$SYNC_UPSTREAM" 2>/dev/null \
    || { record "$SLUG" skipped ".devkit-rev ${SYNC_OLD:0:7} is not on devkit's main; a sync would move it back"; return 1; }
  [ "$(cd "$WT" && vendor_tree_of "$SYNC_UPSTREAM")" != "${rev#* }" ] \
    || { record "$SLUG" current "devkit at ${SYNC_OLD:0:7}; main ${SYNC_UPSTREAM:0:7} vendors the same tree"; return 1; }
}

# find_sync_pr <open sync PR lines>: set SYNC_REUSE to the open PR on devkit-sync/<upstream sha7>
# and fetch its head, and set SYNC_PR, SYNC_HEAD and SYNC_NEW too when that head can be gated as it
# is (reusable_sync). Else records why and returns 1.
find_sync_pr() {
  local n branch head
  SYNC_REUSE="" SYNC_REUSE_HEAD="" SYNC_PR="" SYNC_HEAD="" SYNC_NEW=""
  while IFS=$'\t' read -r n branch head; do
    [ "$branch" != "$SYNC_LABEL/${SYNC_UPSTREAM:0:7}" ] || SYNC_REUSE=$n SYNC_REUSE_HEAD=$head
  done <<<"$1"
  [ -n "$SYNC_REUSE" ] || return 0
  net fetch_main "$WT" "+pull/$SYNC_REUSE/head:refs/worktree/devkit-sync" \
    || { record_fail "$SLUG#$SYNC_REUSE" $? error "cannot fetch main and its head (git above)"; return 1; }
  ! reusable_sync "$SYNC_REUSE_HEAD" "$SYNC_UPSTREAM" \
    || SYNC_PR=$SYNC_REUSE SYNC_HEAD=$SYNC_REUSE_HEAD SYNC_NEW=$SYNC_UPSTREAM
}

# sync_devkit: bring main's vendored devkit to devkit's main (header): record why not, or reuse or
# open the one devkit-sync PR and gate it (handle_pr). Merged: $WT moves to the new main.
sync_devkit() {
  local open log decision=gate
  sync_behind || return 0
  open=$(net gh pr list --repo "$SLUG" --base main --state open --label "$SYNC_LABEL" \
    --json number,headRefName,headRefOid --jq '.[] | [.number, .headRefName, .headRefOid] | @tsv') \
    || { record_fail "$SLUG" $? error "cannot list its open $SYNC_LABEL PRs (gh above)"; return; }
  find_sync_pr "$open" || return 0
  if [ "$DRY_RUN" = 1 ]; then
    record "$SLUG" would-sync "${SYNC_OLD:0:7}..${SYNC_UPSTREAM:0:7} ($(git -C "$WT" rev-list --count "$SYNC_OLD..$SYNC_UPSTREAM") devkit commits${SYNC_REUSE:+; PR #$SYNC_REUSE open})"
    return
  fi
  if [ -z "$SYNC_PR" ]; then
    log=$STATE/dependency-merge/${SLUG#*/}-devkit-sync.log
    : >"$log"
    # Regenerating replaces the PR's head: only one that is the job's own sync commit.
    if [ -n "$SYNC_REUSE" ] && ! job_sync_commit "$WT" "$SYNC_REUSE_HEAD"; then
      record "$SLUG#$SYNC_REUSE" skipped "its head ${SYNC_REUSE_HEAD:0:12} is not a devkit-sync commit (a person's push?) and no longer applies; not overwritten"
      return
    fi
    push_sync "$log" "$SYNC_REUSE_HEAD" || return
    open_sync_pr "$SYNC_REUSE" "$SYNC_OLD" "$log" || return
    decision=pushed
  fi
  close_superseded "$open"
  handle_pr "$SYNC_PR" "$SYNC_HEAD" "$decision" "devkit-sync ${SYNC_OLD:0:7}..${SYNC_NEW:0:7}" devkit-sync
  [ "$LAST_OUTCOME" = merged ] || return 0
  { net fetch_main "$WT" && git -C "$WT" checkout -q --detach refs/remotes/origin/main; } \
    || record "$SLUG" error "cannot move the worktree to the new main (git above); its dependency PRs gate on the old devkit"
}

# prune_sync_branches: delete each devkit-sync/* branch on origin this job left behind: its tip is
# the job's own commit (job_sync_commit, adoption's test, so never a person's), it vendors a commit
# devkit's main has since moved past, and no open PR is on it. Branches of closed or merged PRs
# included: close_superseded deletes its own, but a hand-closed PR's or an older run's stayed (finplat
# and rollcall devkit-sync/c94512c, 2026-10-24). The branch of devkit's main now (SYNC_UPSTREAM, or
# SYNC_NEW when the sync vendored a newer one) stays: a run's unfinished work, which the next adopts.
# Leased: a branch that moved since it was read is kept.
prune_sync_branches() {
  [ -n "$SYNC_UPSTREAM" ] || return 0  # devkit itself, or devkit's main unread
  local log=$STATE/dependency-merge/${SLUG#*/}-devkit-sync.log branch tip rev stale="" open detail
  fetch_sync_branches "$WT" "$log" || return 0
  while read -r branch tip; do
    case $branch in "$SYNC_LABEL/${SYNC_UPSTREAM:0:7}"|"$SYNC_LABEL/${SYNC_NEW:0:7}") continue ;; esac
    job_sync_commit "$WT" "$tip" || continue
    rev=$(git -C "$WT" show "$tip:.devkit-rev" 2>/dev/null) || continue
    rev=${rev%% *}
    if [ "$rev" != "$SYNC_UPSTREAM" ] && git -C "$WT" merge-base --is-ancestor "$rev" "$SYNC_UPSTREAM" 2>/dev/null; then
      stale="$stale$branch $tip $rev"$'\n'
    fi
  done < <(git -C "$WT" for-each-ref --format='%(refname:lstrip=3) %(objectname)' "refs/remotes/origin/$SYNC_LABEL/")
  [ -n "$stale" ] || return 0
  open=$(net gh pr list --repo "$SLUG" --state open --limit 1000 --json headRefName --jq '.[].headRefName') \
    || { record_fail "$SLUG" $? error "cannot list its open PRs, so no $SYNC_LABEL branch is pruned (gh above)"; return 0; }
  while read -r branch tip rev; do
    if [ -z "$branch" ] || grep -qxF "$branch" <<<"$open"; then continue; fi
    detail="$branch (the job's commit vendoring ${rev:0:7}, superseded by devkit ${SYNC_UPSTREAM:0:7}; no open PR)"
    if [ "$DRY_RUN" = 1 ]; then
      record "$SLUG" would-prune "$detail"
    elif net git -C "$WT" push -q "--force-with-lease=refs/heads/$branch:$tip" origin --delete "refs/heads/$branch" \
      >>"$log" 2>&1 8>&-; then
      record "$SLUG" pruned "$detail"
    else
      record_fail "$SLUG" $? error "cannot delete $branch (moved since this run read it?); see $log"
    fi
  done <<<"$stale"
}

run_repo() {
  local n head decision detail
  open_repo "$1" || return
  GATED=0
  halted || { sync_devkit; prune_sync_branches; }
  while IFS=$'\t' read -r n head _ decision detail <&3; do
    [ -n "$n" ] || continue  # the here-string of an empty list is one empty line
    if halted; then break; fi
    handle_pr "$n" "$head" "$decision" "$detail"
  done 3<<<"$PRS"
  cleanup_worktree
  summary "$SLUG"
}

read_any=0
for repo in "${REPOS[@]}"; do
  if halted; then break; fi
  run_repo "$repo" && read_any=1
done
[ "$read_any" = 1 ] || exit 1
exit 0
