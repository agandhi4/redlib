#!/usr/bin/env bash
# The fleet's one image publisher and main's proof: check every new commit of origin/main
# (check_tree.sh), then move `latest` to the newest one that passes, boots and changes the image.
# Every app's `make publish` calls it; on linux-box the homelab unit devkit-publish@<repo>.timer
# runs that every 5 min (homelab hosts/linux-box/README.md), and a run starts a check at most once
# per MAIN_CHECK_MINUTES window (step 4).
# Design: ~/projects/solo/standardization/local-publish-design.md (owner answers 2026-10-27).
#
# Usage: devkit/bin/publish.sh <repo-checkout> [--ungated <reason> | --recheck <commit>]
#   --ungated  the owner's escape: publish main without checking it; the reason is logged and
#              goes into the ship tag's message. Never in the unit.
#   --recheck  forget <commit>'s red record, then publish as usual: the walk (step 4) checks it
#              again when it reaches it (a newer green commit makes it moot), in or out of window.
# Output: one `PUBLISH <stage>: …` line per stage, then exactly one summary line
#   `PUBLISH <name> <sha7> published|checked|up-to-date|skipped|refused|failed <secs>s` (the
#   summary is the API; stage lines are for journald): `checked` is main proven green at <sha7>
#   with no image input to publish since `latest`, `up-to-date` nothing new to check or publish,
#   `skipped` a check waiting for its window. Exit 0 ok or nothing to do, 1 refused or failed
#   (published with a failed prune too: the image is out, the alert still fires), 2 usage or
#   environment (not native amd64, a missing tool, no PUBLISH_IMAGE, the docker daemon down, a
#   check that could not run): the box, never a red commit.
#
# In order, and why:
#   1. Native amd64 only (`uname -m` and the daemon both x86_64), and the build runs with
#      DOCKER_DEFAULT_PLATFORM=linux/amd64 and the default (docker-driver) builder: an arm64
#      image from the Mac crash-looped the NAS (instalite-relay, 2026-10-18). The Mac never
#      publishes. The docker driver pushes one manifest, no attestation, so keep-10 is 10 images.
#   1b. Every docker call runs with a per-run DOCKER_CONFIG whose credential helper answers with
#      gh's token (docker_as_gh): no docker login, no token on disk, nothing to go stale.
#   2. A flock per repo ($XDG_STATE_HOME/devkit-publish/<name>.lock), then everything below
#      inside it, so two runs can never move `latest` out of order.
#   3. M = origin/main (fetched), L = the commit `latest` was built from (its OCI revision
#      label, else its version label: images built by `make ci-image` carry only the version,
#      the bare sha7). The registry is the state; no deployed-sha file. L == M: up-to-date.
#      L not an ancestor of M: refused, `latest` never moves backward. No `latest`: first
#      publish, M alone is checked.
#   4. No pre-merge gate exists (devkit decisions 2026-11-02), so main is proven here, whatever
#      the commits change (devkit #355: a tests- or Makefile-only commit is checked too): walk
#      the first-parent commits above the floor, newest first, and run check_tree.sh (every job
#      of that commit's plan, a flake retried once, ratchets report-only) on each until one
#      passes; that commit is P. The floor is L, or the green record ($STATE/<name>.green) when
#      it lies in L..M: the commit an earlier run checked green and had nothing to publish, so
#      it is never checked again; a green record at M is up-to-date. A red commit is remembered
#      ($STATE/<name>.red/<sha>) and not rechecked for RED_HOURS (24; then once more, so a red
#      the box caused heals) or until --recheck; the oldest red one above P (the first bad
#      commit) gets one `main-red` issue, and every other open one is closed naming P. None
#      green: refused, `latest` stays.
#      The window (bin/_cadence_lib.sh, owner 2026-11-02: the box's load): a run starts its first
#      check_tree only when no run has started one since the repo's current window opened (its
#      minute of every MAIN_CHECK_MINUTES, a plan line, default 180; $STATE/<name>.checked holds
#      the last start). Else it is skipped, naming when the next window opens; the walk's
#      remembered reds cost nothing and still decide. Once a run starts a check, it finishes its
#      walk, so the first bad commit is still found in one run. --recheck ignores the window and
#      its check counts as the window's. Gotcha: a run that meets an unchecked commit below
#      remembered reds (an earlier run cut short) is skipped there, not refused, until the next
#      window; the first run already filed main-red for them.
#      Urgent: the owner ships now with `--recheck origin/main` (main checked at once, window or
#      not) or `--ungated '<reason>'` (unchecked); the timer itself never waits less.
#   5. Image inputs decide only whether P is built: no path in L..P the gate's IMAGE group would
#      run for (devkit_image_inputs_changed: main's .dockerignore and plan GATE_IMAGE_* lines)
#      is `checked`, P becomes the green record, and nothing is built, so a docs merge redeploys
#      nothing. --ungated has checked nothing, so it records nothing and is skipped there.
#   6. `make ci-image`, then `make ci-smoke`, in a fresh worktree at P with
#      CI_IMAGE=<image>:sha-<7> CI_BUILD_VERSION=<7>: never a check image (its version is
#      check-<pid>), and nothing reaches the registry unless it booted reporting <7>.
#   7. Push sha-<7>; re-read `latest` and refuse if it moved since step 3 (a second mover); then
#      point `latest` at sha-<7> (`imagetools create`: one digest).
#   8. ship_tag.sh, 9. registry_prune.sh --keep 10. The local sha-<7> tag is removed on exit.
# A failed ship tag after `latest` moved is exit 1 and the next run is up-to-date, so the line
# names the ship_tag.sh command to rerun by hand.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/_gate_env.sh  # gate_plan_literal, fetch_main
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_issue_lib.sh  # devkit_main_red_file, devkit_main_red_heal
. "$HERE/_issue_lib.sh"
# shellcheck source=bin/_paths_lib.sh  # devkit_image_inputs_changed
. "$HERE/_paths_lib.sh"
# shellcheck source=bin/_timeout_lib.sh  # devkit_docker_check, devkit_docker_guard
. "$HERE/_timeout_lib.sh"
# shellcheck source=bin/_load_lib.sh  # devkit_epoch, the window's clock
. "$HERE/_load_lib.sh"
# shellcheck source=bin/_cadence_lib.sh  # cadence_minutes, cadence_due, cadence_mark, cadence_utc
. "$HERE/_cadence_lib.sh"

KEEP_IMAGES=10
RED_HOURS=24
T0=$SECONDS
NAME=- SHA7=- ROOT='' UNGATED_REASON='' RECHECK='' SLUG='' IMAGE='' M='' L='' P='' FLOOR='' LATEST_DIGEST=''
CHECK_MINUTES='' CHECK_STARTED=''
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/devkit-publish
SCRATCH=''
BUILD_WT=''
BUILT_TAG=''

usage() { echo "usage: $0 <repo-checkout> [--ungated <reason> | --recheck <commit>]" >&2; exit 2; }
finish() { # <outcome> <exit code>
  echo "PUBLISH $NAME $SHA7 $1 $((SECONDS - T0))s"
  exit "$2"
}
refuse() { echo "PUBLISH refused: $*" >&2; finish refused 1; }
fail() { echo "PUBLISH failed: $*" >&2; finish failed 1; }
env_error() { echo "PUBLISH refused: $*" >&2; finish refused 2; }

# shellcheck disable=SC2329  # the EXIT trap's, set before the first stage
cleanup() {
  # The registry holds the image; a sha-<7> tag left on the daemon would pin its layers forever
  # (docker image prune spares tagged images). The build cache the gate shares is not an image.
  [ -z "$BUILT_TAG" ] || docker image rm -f "$BUILT_TAG" >/dev/null 2>&1
  if [ -n "$BUILD_WT" ] && [ -d "$BUILD_WT" ]; then git -C "$ROOT" worktree remove --force "$BUILD_WT" >/dev/null 2>&1; fi
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --ungated)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "publish: --ungated needs a reason" >&2; usage; }
        UNGATED_REASON=$2; shift ;;
      --recheck)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "publish: --recheck needs a commit" >&2; usage; }
        RECHECK=$2; shift ;;
      -h|--help) usage ;;
      -*) echo "publish: unknown option $1" >&2; usage ;;
      *) [ -z "$ROOT" ] || usage; ROOT=$1 ;;
    esac
    shift
  done
  [ -n "$ROOT" ] || usage
  [ -z "$UNGATED_REASON" ] || [ -z "$RECHECK" ] || { echo "publish: --ungated checks nothing to recheck" >&2; usage; }
  ROOT=$(cd "$ROOT" && pwd) || usage
}

# The lock key comes from the checkout's plan (the unit keeps the checkout at main); every
# other setting is read from main's plan once it is fetched (read_main).
check_host() {
  local tool arch daemon
  for tool in git gh make flock; do
    command -v "$tool" >/dev/null || env_error "$tool not found on PATH"
  done
  SLUG=$(gate_plan_literal "$ROOT/scripts/ci/gate_plan.sh" GATE_SLUG 2>/dev/null)
  [[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || env_error "$ROOT/scripts/ci/gate_plan.sh has no literal GATE_SLUG=owner/repo"
  NAME=${SLUG#*/}
  arch=$(uname -m)
  [ "$arch" = x86_64 ] \
    || env_error "this host is $arch; images publish only from a native amd64 host (linux-box), never the Mac: an arm64 image crash-looped the NAS (instalite-relay, 2026-10-18)"
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/publish.XXXXXX") || env_error "mktemp failed"
  docker_as_gh
  # Down is exit 2 with the summary line; the guard alone would exit 1 without it.
  devkit_docker_check publish || env_error "$DEVKIT_DOCKER_ERROR"
  devkit_docker_guard publish
  daemon=$(docker info --format '{{.OSType}}/{{.Architecture}}') || env_error "docker info failed (above)"
  [ "$daemon" = linux/x86_64 ] || env_error "the docker daemon is $daemon, not linux/x86_64; an emulated build is never published"
  docker buildx version >/dev/null 2>&1 || env_error "docker buildx not found (it reads and moves registry tags)"
  echo "PUBLISH host: $(hostname) linux/x86_64, native"
}

read_main() {
  local plan
  fetch_main "$ROOT" || fail "git fetch of origin main failed (above)"
  M=$(git -C "$ROOT" rev-parse --verify -q refs/remotes/origin/main) || fail "no origin/main after the fetch"
  SHA7=${M:0:7}
  mkdir -p "$SCRATCH/tree/scripts/ci"
  plan=$SCRATCH/tree/scripts/ci/gate_plan.sh
  git -C "$ROOT" show "$M:scripts/ci/gate_plan.sh" >"$plan" 2>/dev/null || env_error "main $SHA7 has no scripts/ci/gate_plan.sh"
  # The gate reads main's root .dockerignore to decide what the image sees; so does step 5.
  git -C "$ROOT" show "$M:.dockerignore" >"$SCRATCH/tree/.dockerignore" 2>/dev/null || rm -f "$SCRATCH/tree/.dockerignore"
  [ "$(gate_plan_literal "$plan" GATE_SLUG)" = "$SLUG" ] || refuse "main's plan names GATE_SLUG=$(gate_plan_literal "$plan" GATE_SLUG), the checkout's $SLUG"
  IMAGE=$(gate_plan_literal "$plan" PUBLISH_IMAGE)
  [ -n "$IMAGE" ] || env_error "main's plan has no PUBLISH_IMAGE= line: $SLUG publishes no image"
  [[ "$IMAGE" =~ ^ghcr\.io/[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || env_error "PUBLISH_IMAGE=$IMAGE is not ghcr.io/<owner>/<name>"
  cadence_minutes "$plan" || env_error "main's plan: $CADENCE_ERROR"
  CHECK_MINUTES=$CADENCE_MINUTES
  ghcr_user
  echo "PUBLISH main: $SHA7 ($IMAGE)"
}

# docker_as_gh: every docker call from here on (the daemon checks, the build make runs, inspect,
# push, imagetools, the prune's manifest reads, the cleanup's image rm) runs with a docker config
# private to this run whose only content routes ghcr.io to docker_credential_gh.sh, which answers
# with gh's current token. No token is written anywhere, and the host's ~/.docker/config.json is
# never read: on 2026-10-29 its month-old login still pushed to existing packages but was denied
# creating kitchen's first one. Set before the daemon checks, so every call sees the same
# (default) context; the host's config has no other context, proxy or registry login to lose.
docker_as_gh() {
  export DOCKER_CONFIG=$SCRATCH/docker
  mkdir -p "$DOCKER_CONFIG" "$SCRATCH/bin" || env_error "cannot create $DOCKER_CONFIG"
  echo '{"credHelpers":{"ghcr.io":"devkit-gh"}}' >"$DOCKER_CONFIG/config.json"
  ln -s "$HERE/docker_credential_gh.sh" "$SCRATCH/bin/docker-credential-devkit-gh" || env_error "cannot link the credential helper"
  PATH=$SCRATCH/bin:$PATH
}

# The helper's Username: the image's owner, the account gh's token is issued to (read_main).
ghcr_user() { local owner=${IMAGE#ghcr.io/}; export DEVKIT_GHCR_USER=${owner%%/*}; }

# read_latest: LATEST_DIGEST and the label naming its commit (LATEST_LABEL), "" when there is no
# `latest` tag. Any other registry error is a failure, never "no latest".
# Gotcha: buildx prints its human summary, not the template, for a --format that starts with
# `{{.Manifest` (util/imagetools/printers.go), so the digest goes last. Each label sits in its own
# `with`, outside the separators, so an image with no labels still yields three fields.
LATEST_FORMAT='{{with .Image}}{{with .Config.Labels}}{{index . "org.opencontainers.image.revision"}}{{end}}{{end}}|{{with .Image}}{{with .Config.Labels}}{{index . "org.opencontainers.image.version"}}{{end}}{{end}}|{{.Manifest.Digest}}'
read_latest() {
  local out err=$SCRATCH/inspect.err rev ver
  LATEST_DIGEST='' LATEST_LABEL=''
  if ! out=$(docker buildx imagetools inspect "$IMAGE:latest" --format "$LATEST_FORMAT" 2>"$err"); then
    grep -q 'not found' "$err" && return 0
    fail "reading $IMAGE:latest failed: $(tr '\n' ' ' <"$err")"
  fi
  IFS='|' read -r rev ver LATEST_DIGEST <<<"$out"
  [[ "$LATEST_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "unexpected inspect output for $IMAGE:latest: $(head -n 1 <<<"$out")"
  LATEST_LABEL=${rev:-$ver}
}

# Step 3 (header).
judge_position() {
  read_latest
  if [ -z "$LATEST_DIGEST" ]; then
    echo "PUBLISH latest: none; first publish of $IMAGE, main $SHA7 alone is checked"
    return 0
  fi
  [[ "$LATEST_LABEL" =~ ^[0-9a-f]{7,40}$ ]] \
    || refuse "$IMAGE:latest has no commit in its revision or version label (got '${LATEST_LABEL}'); cannot tell what is deployed"
  L=$(git -C "$ROOT" rev-parse --verify -q "$LATEST_LABEL^{commit}") \
    || refuse "$IMAGE:latest names $LATEST_LABEL, which is no commit of $SLUG's main"
  echo "PUBLISH latest: ${L:0:7} (${LATEST_DIGEST:0:19})"
  [ "$L" != "$M" ] || { echo "PUBLISH up-to-date: latest is main $SHA7"; finish up-to-date 0; }
  git -C "$ROOT" merge-base --is-ancestor "$L" "$M" \
    || refuse "latest ${L:0:7} is not behind main $SHA7; latest never moves backward"
}

# Step 5 (header), after pick_commit: SHA7 is P's. Judged against main's plan and .dockerignore,
# as the gate's IMAGE group is.
judge_inputs() {
  local changed n rc=0
  [ -n "$L" ] || return 0
  changed=$(git -C "$ROOT" diff --no-renames --name-only "$L" "$P") || fail "git diff ${L:0:7} $SHA7 failed"
  n=$(grep -c . <<<"$changed")
  devkit_image_inputs_changed "$SCRATCH/tree" "$changed" || rc=$?
  case $rc in
    0) echo "PUBLISH inputs: $n paths changed in ${L:0:7}..$SHA7, image inputs among them" ;;
    1) if [ -n "$UNGATED_REASON" ]; then
         echo "PUBLISH skipped: none of the $n paths changed in ${L:0:7}..$SHA7 is an image input"; finish skipped 0
       fi
       printf '%s\n' "$P" >"$STATE/$NAME.green" || env_error "cannot write $STATE/$NAME.green"
       echo "PUBLISH checked: $SHA7 is green; none of the $n paths changed in ${L:0:7}..$SHA7 is an image input, so nothing is built"
       finish checked 0 ;;
    *) fail "cannot classify the changed paths against main's plan and .dockerignore (above)" ;;
  esac
}

# --recheck <commit> (header): after the fetch, so a commit only origin has resolves too.
forget_red() {
  local c
  [ -n "$RECHECK" ] || return 0
  c=$(git -C "$ROOT" rev-parse --verify -q "$RECHECK^{commit}") || env_error "--recheck $RECHECK is no commit of $SLUG"
  if [ -f "$STATE/$NAME.red/$c" ]; then
    rm -f "$STATE/$NAME.red/$c"
    echo "PUBLISH recheck: forgot ${c:0:7}'s red record; the walk checks it again"
  else
    echo "PUBLISH recheck: ${c:0:7} has no red record"
  fi
}

# Step 4 (header). check_commit <commit>: 0 green, 1 red. A red verdict is kept in
# $STATE/<name>.red/<sha> (check_tree's output, the main-red issue's evidence), so a red commit is
# checked once per RED_HOURS, not on every timer run; --recheck forgets it sooner. check_tree's
# exit 2 (the box: no docker, no disk, no network) is this run's exit 2 and records nothing.
check_commit() {
  local c=$1 red=$STATE/$NAME.red/$1 out=$SCRATCH/check.out rc=0
  if [ -f "$red" ] && [ -n "$(find "$red" -mmin +$((RED_HOURS * 60)))" ]; then
    rm -f "$red"
    echo "PUBLISH check: ${c:0:7}'s red record is over ${RED_HOURS}h old; checking it again"
  fi
  if [ -f "$red" ]; then echo "PUBLISH check: ${c:0:7} red (kept in $red; recheck: publish.sh --recheck ${c:0:7})"; return 1; fi
  in_window "$c"
  echo "PUBLISH check: ${c:0:7}, every job of its plan (check_tree.sh)"
  "$HERE/check_tree.sh" "$c" --repo "$ROOT" ${L:+--base "$L"} --log-dir "$STATE/$NAME.check/${c:0:7}" >"$out" 2>&1 7>&- || rc=$?
  grep -E '^CHECK [^ ]+ (FAIL|REPORTED|PASS on retry)|^CHECK note: (flaky|ratchet)' "$out" | sed 's/^/PUBLISH   /'
  case $rc in
    0) echo "PUBLISH check: ${c:0:7} green"; return 0 ;;
    1) mkdir -p "$STATE/$NAME.red" && cp "$out" "$red"
       echo "PUBLISH check: ${c:0:7} red ($(sed -n 's/^CHECK VERDICT FAIL .*failed=//p' "$out"))"
       return 1 ;;
    2) cat "$out" >&2; env_error "check_tree.sh could not check ${c:0:7} (exit 2: the box, not the commit; above)" ;;
    *) cat "$out" >&2; fail "check_tree.sh could not check ${c:0:7} (exit $rc, above)" ;;
  esac
}

# in_window <commit>: this run's first check starts only in a window no run has checked in yet
# (step 4); the run is skipped otherwise. The start is recorded before check_tree runs, so a
# check the box breaks (exit 2) or systemd stops still spends its window.
in_window() {
  local stamp=$STATE/$NAME.checked
  if [ -z "$CHECK_STARTED" ] && [ -z "$RECHECK" ] && ! cadence_due "$SLUG" "$CHECK_MINUTES" "$stamp"; then
    echo "PUBLISH skipped: ${1:0:7} waits for the next check window, $(cadence_utc "$CADENCE_NEXT") (a check started at $(cadence_utc "$(head -n 1 "$stamp")"); $SLUG checks at minute $CADENCE_MINUTE of every ${CHECK_MINUTES}, MAIN_CHECK_MINUTES)"
    finish skipped 0
  fi
  [ -n "$CHECK_STARTED" ] || cadence_mark "$stamp" || env_error "cannot write $stamp"
  CHECK_STARTED=1
}

# red_title <commit>: the main-red issue's title, its dedup key (_issue_lib.sh).
red_title() { devkit_main_red_title "$STATE/$NAME.red/$1" "$1"; }

# main_red <first bad commit>: one open main-red issue per first bad commit, with check_tree's
# failing jobs and log tail.
main_red() {
  local c=$1 said
  said=$(devkit_main_red_file "$SLUG" "$c" "$STATE/$NAME.red/$c" "publish.sh on $(hostname) checked ${c:0:7} (\`$(git -C "$ROOT" log -1 --format=%s "$c")\`), the first red commit since the last green one, and published nothing newer than that green one. It is checked again after ${RED_HOURS}h, or now: \`devkit/bin/publish.sh <checkout> --recheck ${c:0:7}\`. This issue closes itself once a commit passes.") \
    || said="gh failed (above); not filed"
  echo "PUBLISH main-red: ${c:0:7}: $said"
}

# heal_main_red [<keep title>]: P passed, so every open main-red issue of the publisher's but the
# current first bad commit's is over (never the Mac's: apple_check.sh closes its own). A gh error
# is a line, never the outcome.
heal_main_red() {
  local said
  said=$(devkit_main_red_heal "$SLUG" "publish.sh on $(hostname): ${P:0:7} (\`$(git -C "$ROOT" log -1 --format=%s "$P")\`) passes every check, so main is green there; closing." "${1:-}") \
    || said="gh failed (above); none closed"
  echo "PUBLISH main-red: green at ${P:0:7}: $said"
}

# Step 4 (header): FLOOR, L or the green record when it is a commit of L..M. A record outside
# that range is stale (a publish moved L past it, or main was rewritten) and ignored.
judge_floor() {
  local g
  FLOOR=$L
  [ -n "$L" ] && [ -f "$STATE/$NAME.green" ] || return 0
  g=$(head -n 1 "$STATE/$NAME.green")
  [[ "$g" =~ ^[0-9a-f]{40}$ ]] && git -C "$ROOT" merge-base --is-ancestor "$L" "$g" 2>/dev/null     && git -C "$ROOT" merge-base --is-ancestor "$g" "$M" 2>/dev/null || return 0
  FLOOR=$g
  [ "$FLOOR" != "$L" ] || return 0
  [ "$FLOOR" != "$M" ] || { echo "PUBLISH up-to-date: main $SHA7 is checked green, and nothing since latest ${L:0:7} is an image input"; finish up-to-date 0; }
  echo "PUBLISH floor: ${FLOOR:0:7}, checked green with nothing to publish; the walk starts above it"
}

# Step 4 (header): P, the newest first-parent commit above FLOOR that check_tree passes.
pick_commit() {
  local c candidates first_bad=''
  if [ -n "$UNGATED_REASON" ]; then
    echo "PUBLISH check: ${M:0:7} UNCHECKED; --ungated: $UNGATED_REASON"
    P=$M; return
  fi
  judge_floor
  if [ -z "$L" ]; then candidates=$M; else candidates=$(git -C "$ROOT" rev-list --first-parent "$FLOOR..$M"); fi
  for c in $candidates; do
    if check_commit "$c"; then P=$c; break; fi
    first_bad=$c
  done
  [ -z "$first_bad" ] || main_red "$first_bad"
  [ -n "$P" ] || refuse "no commit in ${FLOOR:+${FLOOR:0:7}..}$SHA7 passes its checks (main-red above); latest stays. Only the owner overrides, with publish.sh --ungated '<reason>'"
  heal_main_red "${first_bad:+$(red_title "$first_bad")}"
  # Not "publishing": judge_inputs may still end the run `checked` (make review, devkit #357).
  [ "$P" = "$M" ] || echo "PUBLISH check: ${P:0:7} is the newest green commit; main $SHA7 is red"
  SHA7=${P:0:7}
}

in_worktree_make() { # <target> <tag>
  BUILDX_BUILDER=default DOCKER_DEFAULT_PLATFORM=linux/amd64 \
    make -C "$BUILD_WT" --no-print-directory "$1" CI_IMAGE="$2" CI_BUILD_VERSION="$SHA7" 7>&-
}

# Step 6 (header).
build_image() {
  local tag=$IMAGE:sha-$SHA7 built
  BUILD_WT=$STATE/$NAME.wt
  git -C "$ROOT" worktree remove --force "$BUILD_WT" >/dev/null 2>&1
  rm -rf "$BUILD_WT"
  git -C "$ROOT" worktree prune
  git -C "$ROOT" worktree add -q --detach "$BUILD_WT" "$P" || fail "git worktree add at $SHA7 failed (above)"
  echo "PUBLISH build: make ci-image, then ci-smoke, CI_IMAGE=$tag CI_BUILD_VERSION=$SHA7"
  BUILT_TAG=$tag
  # Two make calls, never one with both goals: under an inherited -j they would run at once and
  # the smoke could boot a previous build of the same tag (Codex, devkit #273).
  in_worktree_make ci-image "$tag" || fail "make ci-image failed at $SHA7 (above); nothing was pushed"
  in_worktree_make ci-smoke "$tag" || fail "make ci-smoke failed at $SHA7 (above); nothing was pushed"
  built=$(docker image inspect --format '{{.Os}}/{{.Architecture}} {{index .Config.Labels "org.opencontainers.image.version"}}' "$tag") \
    || fail "cannot inspect the built $tag"
  [ "$built" = "linux/amd64 $SHA7" ] || fail "$tag is '$built', not 'linux/amd64 $SHA7'; not pushed"
}

# Step 7 (header).
push_image() {
  local tag=$IMAGE:sha-$SHA7 before=$LATEST_DIGEST
  DOCKER_CALL_TIMEOUT=900 docker push -q "$tag" >/dev/null || fail "docker push $tag failed (above)"
  echo "PUBLISH push: $tag"
  read_latest
  [ "$LATEST_DIGEST" = "$before" ] \
    || refuse "$IMAGE:latest moved during this publish (${before:-none} -> ${LATEST_DIGEST:-none}); something else moves it, so $tag stays unshipped"
  docker buildx imagetools create -t "$IMAGE:latest" "$tag" >/dev/null || fail "pointing $IMAGE:latest at $tag failed (above)"
  echo "PUBLISH latest: $IMAGE:latest = sha-$SHA7"
}

# Steps 8 and 9 (header).
ship_and_prune() {
  local note=() tag
  [ -z "$UNGATED_REASON" ] || note=(--note "Published ungated: $UNGATED_REASON")
  tag=$("$HERE/ship_tag.sh" "$SLUG" "$P" ${note[@]+"${note[@]}"}) \
    || fail "latest moved to $SHA7 but the ship tag failed (above); rerun: devkit/bin/ship_tag.sh $SLUG $P"
  echo "PUBLISH ship: ${tag#SHIP_TAG=}"
  "$HERE/registry_prune.sh" "$IMAGE" --keep "$KEEP_IMAGES" \
    || { echo "PUBLISH prune: failed (above); $SHA7 is published" >&2; finish published 1; }
}

parse_args "$@"
# bash runs the EXIT trap on a fatal TERM too (systemd's TimeoutStartSec, a stop), so the run's
# scratch dir and worktree never outlive it (tests/publish_contract.bats).
trap cleanup EXIT
check_host
mkdir -p "$STATE" || env_error "cannot create $STATE"
# fd 7 is the lock; check_tree's jobs and the builds close it, so a leftover child never holds it.
exec 7>>"$STATE/$NAME.lock" || env_error "cannot open $STATE/$NAME.lock"
if ! flock -n 7; then
  echo "PUBLISH waiting for another publish of $NAME ($(head -n 1 "$STATE/$NAME.lock" 2>/dev/null))"
  flock 7 || env_error "flock on $STATE/$NAME.lock failed (exit $?)"
fi
printf 'pid %s since %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATE/$NAME.lock"
read_main
forget_red
judge_position
pick_commit
judge_inputs
build_image
push_image
ship_and_prune
finish published 0
