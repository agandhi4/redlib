#!/usr/bin/env bash
# Nightly: keep each repo's vendored devkit at devkit's main, then merge minor and patch
# dependency PRs. Owner decision 2026-10-21: keep automatic minor/patch updates, but merge them
# through the repo's own `make merge`; Renovate never merges by itself and no paid GitHub feature
# is involved. Owner 2026-10-22: devkit improves every project without a hand-run
# `make devkit-sync` PR per repo per devkit change. Owner 2026-11-02: no pre-merge gate; every
# check runs before a deploy, so a merge here is `make merge` alone. Scheduled
# by bin/install_dependency_merge.sh (templates/launchd/com.agandhi4.devkit.dependency-merge.plist),
# whose launcher runs devkit main's copy of this file from a clone of its own
# (bin/job_launcher.sh), never a checkout's.
#
# Usage: bin/dependency_merge.sh [--max <n>] [--dry-run] <repo-root>...
#   <repo-root>  a checkout whose scripts/ci/gate_plan.sh has a literal GATE_SLUG line and whose
#                Makefile has `merge`
#   --max <n>    PRs merged per repo per run (default 3); the rest wait for the next run
#   --dry-run    print what each PR would get; no merge, comment or log line
#
# Per repo: fetch origin main and add a detached worktree of it, so the plan (GATE_SLUG) and the
# vendored devkit are main's, never a developer's branch.
# The devkit sync comes first, so the dependency PRs merge onto the newest devkit. A repo whose
# main has no .devkit-rev (devkit itself) has none. Against $DEVKIT_URL's main, fetched into the
# repo:
#   - main's .devkit-rev names it, or a commit vendoring the same tree (a tests/-only change):
#     `current`. One not on devkit's main (vendored from a branch): skipped, never moved back.
#   - else the one open PR labelled devkit-sync is reused when its branch is
#     devkit-sync/<main sha7>, it vendors that commit and it merges cleanly into main (one whose
#     head is not the job's commit, job_sync_commit, is left alone). Otherwise, in a second
#     worktree of main, `make devkit-sync` with DEVKIT_COMMIT_TRAILER set to the model-agnostic
#     default (a person's devkit.trailer config never signs a job's commit), checked to vendor
#     only (_vendor_paths.sh vendoring_only and vendored_from, the very test merge_rules.sh's
#     review exemption applies, so a sync that would need a review is refused here, not pushed),
#     force-pushed to devkit-sync/<sha7> and opened as a draft (merge_rules.sh readies it) with
#     the devkit commit range and the docs/decisions.md titles it adds. Any other open
#     devkit-sync PR is closed as superseded. The pre-push hook skips the repo's steps for it
#     (hook_steps.sh vendoring only). Every step reruns to the same end, so a run stopped at any
#     one resumes the next night: a devkit-sync/<sha7> already there with no open labelled PR is
#     a run's own unfinished work when its tip is the job's commit and no PR on it was ever
#     closed or merged (adopt_sync_branch), and is pushed over and opened; a person's commit
#     there, or a PR closed by hand, is refused. After the sync, every other devkit-sync/* branch
#     whose tip is the job's commit, vendoring a devkit commit main has moved past, with no open
#     PR, is deleted (`pruned`, prune_sync_branches).
#   - then merged as below, counting toward --max. Merged: the worktree moves to the new main.
#     A devkit regression shows on the repo's main, fixed forward like any change; the checks
#     that catch it run before a deploy, never here.
# _dependency_pr.py classifies the open Renovate and Dependabot PRs against main, oldest first;
# majors and unreadable update types are skipped and listed. Then, per minor/patch PR:
#   - behind main: merged like any PR (GitHub squash-merges onto main now). Waiting for a rebase
#     was the risk (homelab #128, 2026-10-22): with Renovate's rebaseWhen behind-base-branch, each
#     merge this run made had Renovate force-push every other open branch, racing the next merge.
#     renovate/default.json keeps rebaseWhen auto (conflicts only, no automerge and no up-to-date
#     protection in this fleet), and Dependabot rebases only on a conflict too.
#   - conflicting: `git merge-tree` of the head into the current origin/main fails. Skipped.
#   - else `make merge PR=<n>`: merged, or `refused` with merge_rules.sh's reason (a bot's
#     manifest-only diff needs no review; one that changes more is refused until someone
#     reviews it, and the next run tries again); a `run make merge PR=<n> again` refusal (the
#     head or main moved under the merge) is "skipped behind", retried next run.
# Vulnerabilities: after its PRs, each repo's worktree moves to origin/main and bin/vuln_watch.py
#   reruns the repo's metrics.conf vuln.py lines on devkit main's collector: one uncounted
#   `vuln: <slug> …` line (a NEW critical/high id named; `unmeasured (<why>)` when OSV or the conf
#   cannot be read, never clean), and one `security` issue per repo, opened for a new id, rewritten
#   as the ids change, closed when none is left. State: $XDG_STATE_HOME/devkit/vuln-watch/. Why
#   (closet #437, 2026-10-26): `vuln.*` keys are report-only, so advisories reached main unseen.
# Network: every call to GitHub (git fetch and push, gh) is retried after a transient failure
#   (net); one still failing is the outcome `network`, never "branch exists" or a regression.
# Power: a Mac macOS will sleep whatever caffeinate holds (lid closed on battery,
#   _awake_lib.sh's devkit_sleep_forced) stops the run before its next repo or PR, with one
#   `skipped run: <reason>` line and exit 0, as the kill switch does.
# Output: one `dependency-merge: <slug>#<n> <outcome> <detail>` line per PR (the sync's line is
#   `<slug>` alone until it has a PR), outcome one of merged network refused skipped closed
#   pruned current would-sync would-prune would-merge, appended with a UTC stamp to
#   $XDG_STATE_HOME/devkit/dependency-merge.log; the merge output of a PR goes to
#   $XDG_STATE_HOME/devkit/dependency-merge/<repo>-<n>.log. Then the checkout given is fast-forwarded
#   (refresh_checkout: one `checkout fast-forwarded` or `checkout stale` line, uncounted) and
#   one summary line per repo.
# Kill switch: ${XDG_CONFIG_HOME:-~/.config}/devkit/dependency-merge.off, read before every PR.
# One run at a time (flock); a second run exits 0 with one line.
# Exit 0 when it ran, whatever each PR's outcome; 1 when no repo could be read; 2 usage, a
# missing tool (bin/_toolchain_lib.sh's devkit_preflight: one line naming each), checked before any repo.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh  # gate_plan_main, fetch_main
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_toolchain_lib.sh
. "$HERE/_toolchain_lib.sh"
# shellcheck source=bin/_vendor_paths.sh  # DEVKIT_URL, VENDOR_SYNC_BOUNDS, vendor_tree_of, devkit_sync_only, vendored_from
. "$HERE/_vendor_paths.sh"
# shellcheck source=bin/_trailer_lib.sh  # DEVKIT_DEFAULT_TRAILER, the sync commit's trailer
. "$HERE/_trailer_lib.sh"
# shellcheck source=bin/_awake_lib.sh  # devkit_sleep_forced
. "$HERE/_awake_lib.sh"
# shellcheck source=bin/_metrics_conf_lib.sh  # metrics_conf_parse, the vuln watch's conf reader
. "$HERE/_metrics_conf_lib.sh"

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
  # Before any repo: without one every merge fails the same way, logged as N per-PR box errors
  # (2026-10-22: launchd's PATH had only Xcode's 3.9, then no uv). The toolchain directory goes
  # first on PATH, too, so a repo whose vendored devkit predates _toolchain_lib.sh still runs its
  # bare python3 and uv calls on it.
  devkit_preflight gh git make flock -- "${REPOS[@]}" \
    || { echo "dependency-merge: $DEVKIT_PREFLIGHT_ERROR; no repo merged" >&2; exit 2; }
  devkit_toolchain_bin || { echo "dependency-merge: $DEVKIT_PYTHON_ERROR; no repo merged" >&2; exit 2; }
  export PATH="$DEVKIT_TOOLCHAIN_BIN:$PATH"
}

parse_args "$@"
require_tools

# halted: true, saying why once, when the run must stop before its next repo or PR: the kill
# switch, or a Mac macOS will sleep whatever caffeinate holds (header, Power), where every merge
# would fail and each PR log an error.
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
# fd 8 is the run lock; every make below closes it (8>&-), so a process a merge leaves behind
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

# note <text>: print `dependency-merge: <text>` and append it to the log, counted by no summary.
note() {
  echo "dependency-merge: $1"
  [ "$DRY_RUN" = 1 ] || printf '%s dependency-merge: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$LOG"
}

# record <slug>#<n> <outcome> <detail>
record() {
  note "$1 $2 $3"
  OUTCOMES="$OUTCOMES $2"
  LAST_OUTCOME=$2
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
  for outcome in merged error network refused skipped closed pruned current would-sync would-prune would-merge; do
    n=$(tr ' ' '\n' <<<"$OUTCOMES" | grep -cx -- "$outcome")
    [ "$n" = 0 ] || counts="${counts:+$counts, }$outcome $n"
  done
  echo "dependency-merge: $1: ${counts:-no dependency PRs}"
  OUTCOMES=""
}

# main_wants_gate: true while $WT's vendored merge rules predate devkit #288 and still want the
# head's local-gate success (`GATE_CONTEXT=local-gate` in devkit/bin/merge_rules.sh). Such a
# main also vendors the real gate, so its own `make gate` posts what its rules read; without it
# every PR, the devkit-sync that brings the new rules included, is refused every night (review of
# #292). Remove once every repo's main has synced past #288.
main_wants_gate() {
  grep -qs '^readonly GATE_CONTEXT=local-gate' "$WT/devkit/bin/merge_rules.sh"
}

# merge_pr <slug> <n> <head>: `make merge PR=<n>` from main's worktree, and the outcome; first
# `make gate` pinned to the head while main's rules still want it (main_wants_gate).
merge_pr() {
  local slug=$1 n=$2 head=$3 refusal
  PR_LOG=$STATE/dependency-merge/${slug#*/}-$n.log
  : >"$PR_LOG"
  if main_wants_gate && ! make -C "$WT" gate PR="$n" GATE_ARGS="--expect-head $head" >>"$PR_LOG" 2>&1 8>&-; then
    record "$slug#$n" error "make gate failed under main's pre-#288 merge rules, which want local-gate; retried next run; see $PR_LOG"
    return 0
  fi
  if make -C "$WT" merge PR="$n" >>"$PR_LOG" 2>&1 8>&-; then
    record "$slug#$n" merged "head ${head:0:12}"
    return 0
  fi
  refusal=$(grep -E '^merge: refused: ' "$PR_LOG" | tail -n 1)
  # The head or main moved under the merge (merge_rules.sh's "moved … again" refusals): retried
  # next run. A conflict's "rebase it …, then make merge again" is a refusal, never behind.
  case "$refusal" in
    *" moved "*"; make merge PR=$n again"|*"new head after"*"; make merge PR=$n again") record "$slug#$n" skipped "behind (${refusal#merge: refused: }); the next run merges again" ;;
    "merge: refused: "*) record "$slug#$n" refused "${refusal#merge: refused: }" ;;
    *) record "$slug#$n" error "make merge failed with no refusal line; see $PR_LOG" ;;
  esac
}

# check_pr <n> <head>: print why PR <n> is not merged now, or nothing.
check_pr() {
  local n=$1 head=$2
  # refs/worktree/ is private to this worktree and goes with it: the checkout's refs stay as they were.
  net fetch_main "$WT" "+pull/$n/head:refs/worktree/dependency-pr" \
    || { echo "$(net_outcome $? error) cannot fetch main and PR #$n (git above)"; return; }
  [ "$(git -C "$WT" rev-parse refs/worktree/dependency-pr)" = "$head" ] \
    || { echo "skipped head moved since the PR list; next run"; return; }
  git -C "$WT" merge-tree --write-tree origin/main "$head" >/dev/null 2>&1 \
    || echo "skipped conflicts with main, Renovate will rebase"
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

# open_repo <dir>: set ROOT (<dir>, resolved), SLUG, PRS (_dependency_pr.py lines) and WT (a
# detached worktree of origin/main now, whose plan and vendored devkit run every merge).
open_repo() {
  local root
  root=$(cd "$1" 2>/dev/null && pwd -P) || { repo_error "$1" "not a directory"; return; }
  ROOT=$root
  net gate_plan_main "$root" || { repo_error "$root" "$PLAN_ERROR"; return; }
  SLUG=$PLAN_SLUG
  PRS=$(list_prs "$SLUG") || { repo_error "$SLUG" "cannot list its open PRs (gh or _dependency_pr.py above)"; return; }
  WT=$STATE/dependency-merge/wt-${SLUG#*/}
  git -C "$root" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT"
  git -C "$root" worktree add -q --detach "$WT" "$PLAN_MAIN" || { WT=""; repo_error "$SLUG" "cannot add a worktree of main (git above)"; return; }
}

# handle_pr <n> <head> <decision> <detail>: record a skip, or merge when <decision> is gate or
# pushed (below; _dependency_pr.py still says `gate` for a PR that may merge). Only a merge (or a
# dry run's would-merge) counts toward --max: a refused PR, retried every night until a review
# lands, must not take the slot of a newer one that could merge (review, #292).
handle_pr() {
  local n=$1 head=$2 why=""
  case $3 in gate|pushed) ;; *) record "$SLUG#$n" skipped "$4"; return ;; esac
  [ "$MERGED" -lt "$MAX" ] || { record "$SLUG#$n" skipped "limit of $MAX merged per run reached; next run"; return; }
  # pushed: a head this run just made on a fresh main. It cannot conflict, and GitHub may not
  # have moved refs/pull/<n>/head to it yet, which check_pr would call moved.
  [ "$3" = pushed ] || why=$(check_pr "$n" "$head")
  [ -z "$why" ] || { record "$SLUG#$n" "${why%% *}" "${why#* }"; return; }
  if [ "$DRY_RUN" = 1 ]; then
    record "$SLUG#$n" would-merge "$4: make merge PR=$n"
  else
    merge_pr "$SLUG" "$n" "$head"
  fi
  case $LAST_OUTCOME in merged|would-merge) MERGED=$((MERGED + 1)) ;; esac
}

# sync_body <old> <new>: the devkit-sync PR's body, read from the devkit history fetched into $WT.
# shellcheck disable=SC2016  # the backticks are markdown code spans, not command substitution
sync_body() {
  local titles
  printf 'Nightly devkit sync (devkit/bin/dependency_merge.sh): `make devkit-sync` from %s to %s. ' "${1:0:7}" "${2:0:7}"
  printf 'It only vendors (devkit/, .devkit-rev, base copies) code reviewed on devkit main, so `make merge` '
  printf 'asks no review of it (merge_rules.sh); its effect on this repo is judged before a deploy.\n\n'
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
# refs/worktree/devkit-sync) still vendors <upstream> and merges cleanly into main, so a fresh
# sync would only repeat it.
reusable_sync() {
  local rev
  [ "$(git -C "$WT" rev-parse refs/worktree/devkit-sync)" = "$1" ] || return 1
  rev=$(git -C "$WT" show "$1:.devkit-rev" 2>/dev/null) || return 1
  [ "${rev%% *}" = "$2" ] && git -C "$WT" merge-tree --write-tree origin/main "$1" >/dev/null 2>&1
}

# job_sync_commit <dir> <commit>: true when <commit> is a sync commit as push_sync makes it:
# subject "Update devkit to ...", the model-agnostic trailer, one parent
# on origin/main and nothing but vendoring (and tightened bounds) on top of it. A person's commit
# on the branch, or the job's amended with other paths, is not.
job_sync_commit() {
  local parent paths
  git -C "$1" log -1 --format=%s "$2" 2>/dev/null | grep -q '^Update devkit to ' || return 1
  git -C "$1" log -1 --format=%B "$2" | grep -qxF "$DEVKIT_DEFAULT_TRAILER" || return 1
  parent=$(git -C "$1" log -1 --format=%P "$2")
  [[ "$parent" =~ ^[0-9a-f]+$ ]] || return 1
  git -C "$1" merge-base --is-ancestor "$parent" refs/remotes/origin/main || return 1
  paths=$(git -C "$1" -c core.quotePath=false diff --name-only --no-renames "$parent" "$2")
  (cd "$1" && devkit_sync_only "$2" "$parent" "$paths")
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
  (cd "$SYNC_WT" && devkit_sync_only HEAD "$main" "$paths" && vendored_from HEAD "$upstream" "$main") || {
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
# and fetch its head, and set SYNC_PR, SYNC_HEAD and SYNC_NEW too when that head can be merged as
# it is (reusable_sync). Else records why and returns 1.
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
# open the one devkit-sync PR and merge it (handle_pr). Merged: $WT moves to the new main.
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
  handle_pr "$SYNC_PR" "$SYNC_HEAD" "$decision" "devkit-sync ${SYNC_OLD:0:7}..${SYNC_NEW:0:7}"
  [ "$LAST_OUTCOME" = merged ] || return 0
  { net fetch_main "$WT" && git -C "$WT" checkout -q --detach refs/remotes/origin/main; } \
    || record "$SLUG" error "cannot move the worktree to the new main (git above); its dependency PRs merge under the old devkit's rules"
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

# refresh_checkout: fast-forward the checkout the job was given ($ROOT, a repo's primary one) to
# origin/main after this run's merges, only when it is on main with no tracked changes and the
# move is a pure fast-forward (merge --ff-only); else one `checkout stale` line, nothing touched.
# Never a stash, reset or branch switch: a person or a lane may be mid-work there. Why
# (2026-10-26): a fleet survey for devkit #244 read rollcall's main 9 behind and reported a fixed
# warning as live. Surveys still read origin/main (lane rules); this narrows what a slip costs.
refresh_checkout() {
  local branch behind ahead why=""
  net fetch_main "$ROOT" || { note "checkout unread: $SLUG: cannot fetch origin main (git above); left as is"; return 0; }
  behind=$(git -C "$ROOT" rev-list --count HEAD..refs/remotes/origin/main) || return 0
  [ "$behind" != 0 ] || return 0
  branch=$(git -C "$ROOT" symbolic-ref -q --short HEAD) || branch="a detached HEAD"
  ahead=$(git -C "$ROOT" rev-list --count refs/remotes/origin/main..HEAD)
  if [ "$branch" != main ]; then
    why="not main"
  elif ! git -C "$ROOT" diff --quiet HEAD --; then
    why="tracked changes"
  elif [ "$ahead" != 0 ]; then
    why="$ahead local commit(s) not on origin/main"
  elif [ "$DRY_RUN" = 1 ]; then
    note "checkout would fast-forward: $SLUG main, $behind behind"
    return 0
  elif ! git -C "$ROOT" merge -q --ff-only refs/remotes/origin/main >/dev/null 2>&1 8>&-; then
    why="merge --ff-only refused (an untracked file in the way, or a git lock)"
  fi
  if [ -n "$why" ]; then
    note "checkout stale: $SLUG on $branch, $behind behind ($why); left as is"
  else
    note "checkout fast-forwarded: $SLUG main, $behind commit(s) to $(git -C "$ROOT" rev-parse --short=7 HEAD)"
  fi
}

# conf_commands <conf>: each collector command of a metrics.conf, one per line; exit 2 with the
# parser's message on a malformed line (the lib calls die(), which must not end this run).
conf_commands() {
  (
    die() { echo "$*" >&2; exit 2; }
    metrics_conf_parse "$1"
    printf '%s\n' ${COMMANDS[@]+"${COMMANDS[@]}"}
  )
}

# watch_vulns: bin/vuln_watch.py over origin/main as this run left it, merges included (header,
# Vulnerabilities). Its one line is noted, never counted: an advisory is not a PR outcome.
watch_vulns() {
  local conf=$WT/scripts/ci/metrics.conf out cmd line args=()
  if [ -f "$conf" ]; then
    out=$(conf_commands "$conf" 2>&1) \
      || { out=${out##*$'\n'}; note "vuln: $SLUG unmeasured (${out#"$WT/"})"; return 0; }
    while IFS= read -r cmd; do
      [ -z "$cmd" ] || args+=(--command "$cmd")
    done <<<"$out"
  fi
  [ "$DRY_RUN" = 0 ] || args+=(--dry-run)
  line=$("$DEVKIT_PYTHON" -I "$HERE/vuln_watch.py" --slug "$SLUG" --root "$WT" \
    --state-dir "$STATE/vuln-watch" ${args[@]+"${args[@]}"} 8>&-) \
    || line="vuln: $SLUG unmeasured (vuln_watch.py exit $?; stderr above)"
  note "$line"
}

# refresh_main: the worktree moved to origin/main as the night's merges left it, for the vuln
# watch. Failed, the watch is one `unmeasured` line and does not run.
refresh_main() {
  { net fetch_main "$WT" && git -C "$WT" checkout -q --detach refs/remotes/origin/main; } >/dev/null 8>&- && return 0
  note "vuln: $SLUG unmeasured (cannot move the worktree to origin main; git above)"
  return 1
}

run_repo() {
  local n head decision detail
  open_repo "$1" || return
  MERGED=0
  halted || { sync_devkit; prune_sync_branches; }
  while IFS=$'\t' read -r n head _ decision detail <&3; do
    [ -n "$n" ] || continue  # the here-string of an empty list is one empty line
    if halted; then break; fi
    handle_pr "$n" "$head" "$decision" "$detail"
  done 3<<<"$PRS"
  if ! halted && refresh_main; then watch_vulns; fi
  cleanup_worktree
  halted || refresh_checkout
  summary "$SLUG"
}

read_any=0
for repo in "${REPOS[@]}"; do
  if halted; then break; fi
  run_repo "$repo" && read_any=1
done
[ "$read_any" = 1 ] || exit 1
exit 0
