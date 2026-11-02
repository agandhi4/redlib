#!/usr/bin/env bash
# The publisher's dead-man switch: run hourly on the Mac (com.agandhi4.devkit.publisher-deadman,
# bin/install_publisher_deadman.sh). linux-box down, its timers stopped or a publish wedged is the
# failure it exists to catch, so it reads GitHub alone and never reaches for linux-box.
#
# Usage: bin/publisher_deadman.sh [--repos a,b] [--hours <n>]
#   --repos  repos.json keys (default: all); a repo whose main plan has no PUBLISH_IMAGE is skipped.
#            Report only: the issue is the whole fleet's, so a partial run never files, rewrites or
#            closes it (devkit #310: `--repos lib` closed an alert naming a stalled app)
#   --hours  how long an unpublished image input may wait (default 6), past the repo's check
#            window: publish.sh starts a check at most once per MAIN_CHECK_MINUTES (default 180,
#            bin/_cadence_lib.sh), so a repo waits up to that long by design and is allowed
#            --hours plus its window, in whole hours rounded up (9 by default: a 3 h wait and a
#            check's length never page)
# A repo is stalled when main has commits past the image `latest` carries (that version's sha-*
# tag; the newest sha-* tag proves nothing, since publish.sh pushes sha-<7> before it moves
# `latest`, devkit #308), the newest of them is older than that (the newest, not the oldest: docs
# and tests merges the publisher checks but never builds pile up past the image, and a fresh code
# merge after them is no stall yet), and they change an image input (devkit_image_inputs_changed:
# the publisher's own test, so a run that ended `checked` is alive and a docs merge is owed
# nothing; a rename counts both its paths, as the publisher's --no-renames diff does, devkit
# #312). An open main-red issue is named beside it, never a
# reason to stay quiet. One `publisher stalled` issue (label publisher-stalled) in
# <owner>/devkit names every stalled repo: filed, or its body updated; closed with a comment once
# a run finds none and could read every repo.
# Output: `DEADMAN <repo> ok|stalled|skipped|error (<why>)` per repo, then `DEADMAN stalled=<n>
# issue: <what was done>`. Exit 0 every repo read, 1 a GitHub read failed (named above), 2 usage.
# Env: DEVKIT_GITHUB_DATA (the repos.json dir; default devkit's github/).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh  # gate_plan_literal
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_issue_lib.sh  # devkit_issue_upsert, devkit_issue_close
. "$HERE/_issue_lib.sh"
# shellcheck source=bin/_paths_lib.sh  # devkit_image_inputs_changed
. "$HERE/_paths_lib.sh"
# shellcheck source=bin/_load_lib.sh  # devkit_epoch, which _cadence_lib.sh needs sourced
. "$HERE/_load_lib.sh"
# shellcheck source=bin/_cadence_lib.sh  # cadence_minutes
. "$HERE/_cadence_lib.sh"

readonly TITLE='publisher stalled'
usage() { echo "usage: publisher_deadman.sh [--repos a,b] [--hours <n>]" >&2; exit 2; }
REPOS_ARG='' HOURS=6
while [ $# -gt 0 ]; do
  case "$1" in
    --repos) [ $# -ge 2 ] || usage; REPOS_ARG=$2; shift ;;
    --hours) [ $# -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] || usage; HOURS=$2; shift ;;
    *) usage ;;
  esac
  shift
done
REPOS_FILE=${DEVKIT_GITHUB_DATA:-$HERE/../github}/repos.json
OWNER=$(jq -er .owner "$REPOS_FILE") || { echo "publisher_deadman: cannot read .owner from $REPOS_FILE" >&2; exit 2; }
if [ -n "$REPOS_ARG" ]; then REPOS=$(tr ',' '\n' <<<"$REPOS_ARG"); else REPOS=$(jq -r '.repos | keys[]' "$REPOS_FILE"); fi
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/deadman.XXXXXX") || exit 2
trap 'rm -rf "$SCRATCH"' EXIT
STALLED='' ERRORS=0

# raw_file <slug> <path> <out>: main's copy of <path>; exit 1 when main has none, 2 a gh error.
raw_file() {
  gh api "repos/$1/contents/$2?ref=main" -H 'Accept: application/vnd.github.raw' >"$3" 2>"$SCRATCH/gh.err" && return 0
  grep -q 'HTTP 404' "$SCRATCH/gh.err" && return 1
  return 2
}

# judge <repo>: one DEADMAN line; appends to STALLED; 1 on a read error.
judge() {
  local repo=$1 slug=$OWNER/$1 tree=$SCRATCH/$1 image owner pkg built age files rc=0 reds plan_slug hours
  mkdir -p "$tree/scripts/ci"
  raw_file "$slug" scripts/ci/gate_plan.sh "$tree/scripts/ci/gate_plan.sh" || rc=$?
  case $rc in
    0) ;;
    1) echo "DEADMAN $repo skipped (no scripts/ci/gate_plan.sh on main)"; return 0 ;;
    *) echo "DEADMAN $repo error (reading its plan: $(tr '\n' ' ' <"$SCRATCH/gh.err"))"; return 1 ;;
  esac
  image=$(gate_plan_literal "$tree/scripts/ci/gate_plan.sh" PUBLISH_IMAGE)
  [ -n "$image" ] || { echo "DEADMAN $repo skipped (publishes no image)"; return 0; }
  cadence_minutes "$tree/scripts/ci/gate_plan.sh" \
    || { echo "DEADMAN $repo error (${CADENCE_ERROR#"$tree/"})"; return 1; }
  hours=$(( HOURS + (CADENCE_MINUTES + 59) / 60 ))
  # publish.sh files main-red in the plan's slug.
  plan_slug=$(gate_plan_literal "$tree/scripts/ci/gate_plan.sh" GATE_SLUG)
  raw_file "$slug" .dockerignore "$tree/.dockerignore" || rc=$?
  [ "$rc" != 2 ] || { echo "DEADMAN $repo error (reading .dockerignore: $(tr '\n' ' ' <"$SCRATCH/gh.err"))"; return 1; }
  owner=${image#ghcr.io/}; pkg=${owner#*/}; owner=${owner%%/*}
  # Newest first, as the API lists them; the publisher tags every image it pushes sha-<7> and
  # points `latest` at one of them (one digest, so one version carries both tags).
  # Line 1: latest's sha-* tag ("" when none of the page carries it); line 2: whether any does.
  built=$(gh api "users/$owner/packages/container/$pkg/versions?per_page=30" \
    --jq '([.[] | .metadata.container.tags | select(index("latest")) | .[] | select(startswith("sha-"))][0] // ""),
          ([.[] | .metadata.container.tags[] | select(startswith("sha-"))] | length > 0)') \
    || { echo "DEADMAN $repo error (reading $image's versions; gh above)"; return 1; }
  if [ -z "$(head -n 1 <<<"$built")" ]; then
    [ "$(tail -n 1 <<<"$built")" = true ] || { echo "DEADMAN $repo skipped (no sha-* image yet: a first publish is the owner's)"; return 0; }
    # sha-* pushes past the page with latest beyond it: no baseline, and never a reason to close.
    echo "DEADMAN $repo error (no version among $image's 30 newest carries latest with a sha-* tag)"; return 1
  fi
  built=$(head -n 1 <<<"$built")
  # Line 1: the newest unpublished commit's age in hours (-1: none); then the changed paths.
  files=$(gh api "repos/$slug/compare/${built#sha-}...main" \
    --jq '(.commits[-1].commit.committer.date // null | if . then (now - fromdateiso8601) / 3600 | floor else -1 end), (.files // [] | .[] | .filename, (.previous_filename // empty))') \
    || { echo "DEADMAN $repo error (comparing ${built#sha-}...main; gh above)"; return 1; }
  age=$(head -n 1 <<<"$files")
  if [ "$age" -lt 0 ]; then echo "DEADMAN $repo ok (main is $built)"; return 0; fi
  if [ "$age" -lt "$hours" ]; then echo "DEADMAN $repo ok (the newest commit past $built is ${age}h old)"; return 0; fi
  rc=0
  devkit_image_inputs_changed "$tree" "$(tail -n +2 <<<"$files")" >/dev/null || rc=$?
  case $rc in
    0) ;;
    1) echo "DEADMAN $repo ok (nothing past $built is an image input)"; return 0 ;;
    *) echo "DEADMAN $repo error (cannot classify the paths past $built against main's plan; above)"; return 1 ;;
  esac
  reds=$(gh issue list --repo "${plan_slug:-$slug}" --label main-red --state open --json number --jq length) \
    || { echo "DEADMAN $repo error (reading its main-red issues; gh above)"; return 1; }
  # Named, never a reason to stay quiet: only a live publisher closes main-red, so an open one
  # also outlives a publisher that died after filing it.
  [ "$reds" = 0 ] && reds='' || reds="; $reds main-red issue(s) open: main may just be red"
  echo "DEADMAN $repo stalled (image inputs past $built, the newest commit ${age}h old, unpublished$reds)"
  STALLED="$STALLED- $slug: main has image inputs past \`$built\`, the newest commit ${age}h old$reds
"
}

for repo in $REPOS; do judge "$repo" || ERRORS=$((ERRORS + 1)); done
if [ -n "$REPOS_ARG" ]; then
  said="left as is: --repos reads part of the fleet"
elif [ -n "$STALLED" ]; then
  said=$(devkit_issue_upsert "$OWNER/devkit" publisher-stalled "$TITLE" "publisher_deadman.sh on $(hostname), $(date -u +%Y-%m-%dT%H:%MZ): nothing was published for over ${HOURS}h past their check windows while these repos had image inputs to publish. The publisher (devkit-publish@<repo>.timer on linux-box, bin/publish.sh) is down, stopped or stuck: check \`systemctl list-timers 'devkit-publish@*'\` and \`journalctl -u 'devkit-publish@*'\` there.

$STALLED
This issue closes itself once every repo is published or owed nothing.") || said="gh failed (above); not filed"
elif [ "$ERRORS" = 0 ]; then
  said=$(devkit_issue_close "$OWNER/devkit" publisher-stalled "publisher_deadman.sh on $(hostname): every publishing repo is published or owed nothing; closing.") || said="gh failed (above); none closed"
else
  said="left as is: $ERRORS repo(s) could not be read"
fi
echo "DEADMAN stalled=$(grep -c . <<<"$STALLED") issue: $said"
[ "$ERRORS" = 0 ]
