#!/usr/bin/env bash
# The Mac's proof of main for every repo linux-box's publisher does not prove: a plan whose
# DEPLOY_KINDS (README "Deploy kinds") names anything but image alone, so ios and mac (the Xcode
# jobs linux-box skips), hosted (rollcall on Vercel, homelab's deploy.sh: their hosts apply main
# unchecked) and library and tooling (devkit, claude-kit: nothing deploys them, yet every repo
# syncs devkit's main), and a plan that declares no kind. An image-only plan is linux-box's:
# publish.sh already runs every job of it (owner 2026-11-02: every repo's main is proven). Run by
# the LaunchAgent com.agandhi4.devkit.main-check every 10 min (bin/install_main_check.sh), from
# devkit main's copy. It deploys nothing.
#
# Usage: bin/main_check.sh [--root <dir>]... [--repos a,b]
#   --root   where the checkouts live, repeatable (default _checkouts_lib.sh's
#            DEVKIT_CHECKOUT_PARENTS: ~/projects/solo and ~/projects/homelab): every checkout
#            devkit_checkouts finds there, the nightly dependency merge's scan too
#   --repos  only the checkouts with these names
# One checkout per origin slug, the first by name (_checkouts_lib.sh devkit_claim_checkout); a
# second clone of a repo is left out silently. Every git network call is bounded and never
# prompts (_timeout_lib.sh devkit_git_guard, DEVKIT_GIT_TIMEOUT), so a remote waiting on a
# password or a host key, or never answering, is one fetch error, never a stalled run (devkit #366).
# Per checkout: fetch origin main (M) and read M's plan, never the checkout's. No plan, or
# DEPLOY_KINDS=image: skipped. M already judged ($STATE/<name>: `<sha> pass` or `<sha> fail
# <first bad sha>`): up-to-date, and its status and main-red sync retried if GitHub failed it. A
# check already started in the repo's current window (bin/_cadence_lib.sh: the plan's
# MAIN_CHECK_MINUTES, at the slug's own minute, as the publisher's): waiting, so a busy main is
# checked at most once a window and the repos' checks spread over it.
# Otherwise check_tree.sh M (every job of M's plan, a clean worktree, each job admitted
# by the slot pool, so it never runs beside a lane's tests over capacity), then by its exit:
#   0  pass: recorded; M gets the `main-check` status success (_commit_status_lib.sh), and the
#      Mac's open main-red issues close, naming M
#   1  fail: recorded; M gets `main-check` failure, and the first bad commit (M, or the first red
#      one since the last pass, which a red M keeps) gets one main-red issue `main is red on the
#      Mac at <sha7>: <jobs>` (_issue_lib.sh devkit_main_red_file, publish.sh's), whose body names
#      the logs
#   2  the box (no docker, a toolchain, ENV_CAUSES): nothing recorded or posted, so the next
#      window checks again
# On battery the run is skipped, and the next tick tries again: a whole plan never drains it.
# Output: `MAIN <name> <sha7> pass|fail|up-to-date|waiting|error (<why>)` per checked checkout
# (`MAIN <name> error (...)` when its fetch fails); nothing for any other checkout; then
# `MAIN checked=<n> red=<n> errors=<n>`. Exit 0, 1 a repo is red, 2 usage, not a Mac, another run
# holds the lock, or a repo could not be read or checked.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh  # gate_plan_literal, fetch_main
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_issue_lib.sh  # devkit_main_red_file, devkit_main_red_heal
. "$HERE/_issue_lib.sh"
# shellcheck source=bin/_commit_status_lib.sh  # devkit_main_check_post
. "$HERE/_commit_status_lib.sh"
# shellcheck source=bin/_awake_lib.sh  # devkit_on_battery, devkit_stay_awake
. "$HERE/_awake_lib.sh"
# shellcheck source=bin/_load_lib.sh  # devkit_epoch, the cadence's clock
. "$HERE/_load_lib.sh"
# shellcheck source=bin/_cadence_lib.sh  # cadence_minutes, cadence_due, cadence_mark, cadence_utc
. "$HERE/_cadence_lib.sh"
# shellcheck source=bin/_checkouts_lib.sh  # DEVKIT_CHECKOUT_PARENTS, devkit_checkouts, devkit_claim_checkout
. "$HERE/_checkouts_lib.sh"
# shellcheck source=bin/_timeout_lib.sh  # devkit_git_guard
. "$HERE/_timeout_lib.sh"
devkit_git_guard main_check

# The main-red titles' place, unchanged from the Apple-only check (2026-11-02) so its open issues
# still close here; publish.sh's have none, and neither checker closes the other's.
readonly WHERE='on the Mac'
usage() { echo "usage: main_check.sh [--root <dir>]... [--repos a,b]" >&2; exit 2; }
ROOTS=() REPOS_ARG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || usage; ROOTS+=("$2"); shift ;;
    --repos) [ $# -ge 2 ] || usage; REPOS_ARG=$2; shift ;;
    *) usage ;;
  esac
  shift
done
# A root given must exist; a default parent this box lacks is scanned as empty.
for root in ${ROOTS[@]+"${ROOTS[@]}"}; do
  [ -d "$root" ] || { echo "main_check: no directory $root" >&2; exit 2; }
done
[ ${#ROOTS[@]} -gt 0 ] || ROOTS=("${DEVKIT_CHECKOUT_PARENTS[@]}")
[ "$(uname -s)" = Darwin ] || { echo "main_check: this host is $(uname -s); the Mac's main check runs only on the Mac (linux-box's is publish.sh)" >&2; exit 2; }
command -v flock >/dev/null || { echo "main_check: flock not found (brew install flock)" >&2; exit 2; }
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/devkit-main-check
mkdir -p "$STATE" || exit 2
# A run by hand beside launchd's would check the same commit twice and race the records.
exec 8>>"$STATE/lock"
flock -n 8 || { echo "MAIN skipped (another main_check.sh holds $STATE/lock)"; exit 2; }
if devkit_on_battery; then
  echo "MAIN skipped (on battery: the checks wait for power; the next run checks)"
  echo "MAIN checked=0 red=0 errors=0"
  exit 0
fi
devkit_stay_awake
CHECKED=0 RED=0 ERRORS=0 SAID='' MAIN_SHA=''

# mac_proves <plan>: false when the plan's DEPLOY_KINDS is image alone, which linux-box's
# publisher proves (every job of the plan, before latest moves); true for any other kind, a mix
# with image (kitchen's image,ios: the Xcode jobs need the Mac, and check_tree runs a whole plan),
# or none declared (nothing else would check it; the scorecard's deploy_kinds fails it).
mac_proves() {
  [ "$(gate_plan_literal "$1" DEPLOY_KINDS)" != image ]
}

# prune_logs <name>: a whole plan's logs (xcodebuild's included) per checked main add up; keep
# the newest LOG_KEEP and the first bad commit's, which its main-red issue names.
readonly LOG_KEEP=5
prune_logs() {
  local keep d
  keep=$(awk '$2 == "fail" { print substr($3, 1, 7) }' "$STATE/$1" 2>/dev/null)
  # shellcheck disable=SC2012  # the names are sha7s, and ls -t is the one portable mtime sort
  for d in $(ls -t "$STATE/$1.check" 2>/dev/null | tail -n +$((LOG_KEEP + 1))); do
    [ "$d" = "$keep" ] || rm -rf "${STATE:?}/$1.check/$d"
  done
}

# checked_main <checkout> <plan file>: true, with MAIN_SHA its origin/main and <plan file> main's
# plan, when that plan is one the Mac proves.
checked_main() {
  MAIN_SHA=$(git -C "$1" rev-parse --verify -q refs/remotes/origin/main) || return 1
  git -C "$1" show "$MAIN_SHA:scripts/ci/gate_plan.sh" >"$2" 2>/dev/null && mac_proves "$2"
}

# sync_github <name> <dir> <slug> <main> pass|fail [<first bad>]: the verdict on GitHub, the
# main-check status on <main> and the main-red issues, setting SAID. A gh failure is retried at
# every later tick of the same main ($STATE/<name>.synced holds the main whose sync went through),
# never left until main moves. The status goes first: a job reading it (dependency_merge.sh) acts
# on it, an issue only tells a person.
sync_github() {
  local name=$1 dir=$2 slug=$3 m=$4 first_bad=${6:-} jobs
  if [ "$5" = pass ]; then
    devkit_main_check_post "$slug" "$m" pass "main_check.sh: every job of its plan passes on the Mac" \
      || { SAID="gh failed (above); no status posted, retried next tick"; return; }
    SAID=$(devkit_main_red_heal "$slug" "main_check.sh on $(hostname): ${m:0:7} passes every job of its plan on the Mac; closing." "" "$WHERE") \
      || { SAID="gh failed (above); none closed, retried next tick"; return; }
  else
    jobs=$(sed -n 's/^CHECK VERDICT FAIL .*failed=//p' "$STATE/$name.check.out")
    devkit_main_check_post "$slug" "$m" fail "main_check.sh: failed on the Mac: ${jobs:-see the main-red issue}" \
      || { SAID="gh failed (above); no status posted, retried next tick"; return; }
    SAID=$(devkit_main_red_file "$slug" "$first_bad" "$STATE/$name.red" "main_check.sh on $(hostname) checked ${first_bad:0:7} (\`$(git -C "$dir" log -1 --format=%s "$first_bad")\`), the first red main since the last green one, with every job of its plan. Logs: \`$STATE/$name.check/${first_bad:0:7}/\` on the Mac. A newer main is checked in the repo's next check window (MAIN_CHECK_MINUTES), and this issue closes itself once one passes." "$WHERE") \
      || { SAID="gh failed (above); not filed, retried next tick"; return; }
  fi
  echo "$m" >"$STATE/$name.synced"
}

# judge <checkout>: one MAIN line; counts into CHECKED, RED, ERRORS.
judge() {
  local dir=$1 name=${1##*/} m plan slug sha='' prev='' first_bad='' out rc=0 synced=''
  plan=$STATE/$name.plan
  # Every checkout under the roots is fetched, so a repo that adds a plan or drops image is seen;
  # one that fails (an SSH remote launchd has no agent for) is an error only when its last-known
  # main is one the Mac proves, and any other says nothing.
  if ! fetch_main "$dir" 2>"$STATE/$name.err"; then
    checked_main "$dir" "$plan" || return 0
    echo "MAIN $name error (git fetch of origin main: $(tr '\n' ' ' <"$STATE/$name.err"))"; ERRORS=$((ERRORS + 1)); return
  fi
  checked_main "$dir" "$plan" || return 0
  m=$MAIN_SHA
  slug=$(gate_plan_literal "$plan" GATE_SLUG)
  [ -n "$slug" ] || { echo "MAIN $name error (main's plan has no literal GATE_SLUG=owner/repo to post the status and file main-red in)"; ERRORS=$((ERRORS + 1)); return; }
  [ ! -f "$STATE/$name" ] || read -r sha prev first_bad <"$STATE/$name"
  if [ "$sha" = "$m" ]; then
    [ "$prev" != fail ] || RED=$((RED + 1))
    [ ! -f "$STATE/$name.synced" ] || synced=$(head -n 1 "$STATE/$name.synced")
    if [ "$synced" = "$m" ]; then echo "MAIN $name ${m:0:7} up-to-date (checked: $prev)"; return; fi
    sync_github "$name" "$dir" "$slug" "$m" "$prev" "$first_bad"
    echo "MAIN $name ${m:0:7} up-to-date (checked: $prev; main-red: $SAID)"
    return
  fi
  cadence_minutes "$plan" || { echo "MAIN $name error (main's plan: $CADENCE_ERROR)"; ERRORS=$((ERRORS + 1)); return; }
  if ! cadence_due "$slug" "$CADENCE_MINUTES" "$STATE/$name.started"; then
    echo "MAIN $name ${m:0:7} waiting (a check started at $(cadence_utc "$(head -n 1 "$STATE/$name.started")"); the next window opens $(cadence_utc "$CADENCE_NEXT"), minute $CADENCE_MINUTE of every $CADENCE_MINUTES)"
    return
  fi
  cadence_mark "$STATE/$name.started" || { echo "MAIN $name error (cannot write $STATE/$name.started)"; ERRORS=$((ERRORS + 1)); return; }
  out=$STATE/$name.check.out
  "$HERE/check_tree.sh" "$m" --repo "$dir" --log-dir "$STATE/$name.check/${m:0:7}" >"$out" 2>&1 8>&- || rc=$?
  CHECKED=$((CHECKED + 1))
  case $rc in
    0)
      echo "$m pass" >"$STATE/$name"
      sync_github "$name" "$dir" "$slug" "$m" pass
      echo "MAIN $name ${m:0:7} pass (main-red: $SAID)" ;;
    1)
      RED=$((RED + 1))
      # A red main stays one issue, the first bad commit's (its output kept as <name>.red), until
      # a pass; filing it again is a no-op while it is open (the title is the key).
      if [ "$prev" != fail ] || [ ! -f "$STATE/$name.red" ]; then first_bad=$m; cp "$out" "$STATE/$name.red"; fi
      echo "$m fail $first_bad" >"$STATE/$name"
      sync_github "$name" "$dir" "$slug" "$m" fail "$first_bad"
      echo "MAIN $name ${m:0:7} fail ($(sed -n 's/^CHECK VERDICT FAIL .*failed=//p' "$out"); main-red: $SAID)" ;;
    *)
      ERRORS=$((ERRORS + 1))
      echo "MAIN $name ${m:0:7} error (check_tree.sh exit $rc, the box, not the commit: $(grep -m 1 -E 'ERROR|check_tree:' "$out" || tail -n 1 "$out"))" ;;
  esac
}

SEEN=,
for dir in $(devkit_checkouts "${ROOTS[@]}"); do
  if [ -n "$REPOS_ARG" ]; then
    case ",$REPOS_ARG," in *",${dir##*/},"*) SEEN+="${dir##*/}," ;; *) continue ;; esac
  fi
  devkit_claim_checkout "$dir" || continue
  judge "$dir"
  prune_logs "${dir##*/}"
done
# A --repos name the scan never found is a typo or a missing clone, never a silent pass.
for name in $(tr ',' ' ' <<<"$REPOS_ARG"); do
  case $SEEN in *",$name,"*) ;; *) echo "MAIN $name error (no git checkout of that name under ${ROOTS[*]})"; ERRORS=$((ERRORS + 1)) ;; esac
done
echo "MAIN checked=$CHECKED red=$RED errors=$ERRORS"
[ "$ERRORS" = 0 ] || exit 2
[ "$RED" = 0 ] || exit 1
