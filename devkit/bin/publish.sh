#!/usr/bin/env bash
# The fleet's one image publisher: move `latest` to origin/main when main is gated, booted and
# changes the image. Every app's `make publish` calls it; on linux-box the homelab unit
# devkit-publish@<repo>.timer runs that every 5 min (homelab hosts/linux-box/README.md).
# Design: ~/projects/solo/standardization/local-publish-design.md (owner answers 2026-10-27).
#
# Usage: devkit/bin/publish.sh <repo-checkout> [--ungated <reason>]
#   --ungated  the owner's escape for commits no gate passed (a hand merge); the reason goes
#              into the ship tag's message. Never in the unit.
# Output: one `PUBLISH <stage>: …` line per stage, then exactly one summary line
#   `PUBLISH <name> <sha7> published|up-to-date|skipped|refused|failed <secs>s` (the summary is
#   the API; stage lines are for journald). Exit 0 ok or nothing to do, 1 refused or failed
#   (published with a failed prune too: the image is out, the alert still fires), 2 usage or
#   environment (not native amd64, a missing tool, no PUBLISH_IMAGE).
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
#   4. No path in L..M the gate's IMAGE group would run for (devkit_image_group_runs: main's
#      .dockerignore and plan GATE_IMAGE_* lines): skipped, so a docs merge redeploys nothing.
#   5. Every first-parent commit in L..M is a merged PR whose head has `local-gate` success on
#      main = that commit's parent (`on main <sha7>` in its description, as merge_rules.sh reads
#      it). A Renovate PR whose diff only moves image digests (_dependency_pr.py digest-only)
#      passes on the smoke alone where main's plan says GATE_RENOVATE_AUTOMERGE=digest (the
#      documented hole, renovate/automerge-digest). Anything else is refused unless --ungated.
#   6. One admission from the box's pool (_slot_lib.sh, cost of an image job), taken only now so
#      a no-op run never queues behind a gate. `make ci-image`, then `make ci-smoke`, in a fresh worktree at M
#      with CI_IMAGE=<image>:sha-<7> CI_BUILD_VERSION=<7>: never a gate image (its version is
#      gate-<pr>), and nothing reaches the registry unless it booted reporting <7>.
#   7. Push sha-<7>; re-read `latest` and refuse if it moved since step 3 (a second mover); then
#      point `latest` at sha-<7> (`imagetools create`: one digest).
#   8. ship_tag.sh, 9. registry_prune.sh --keep 10. The local sha-<7> tag is removed on exit.
# A failed ship tag after `latest` moved is exit 1 and the next run is up-to-date, so the line
# names the ship_tag.sh command to rerun by hand.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/_gate_env.sh  # gate_plan_literal, fetch_main, gate_env_load
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_load_lib.sh  # devkit_ncpu, which slot_pool_init reads
. "$HERE/_load_lib.sh"
# shellcheck source=bin/_slot_lib.sh  # run_lock_acquire, slot_acquire
. "$HERE/_slot_lib.sh"
# shellcheck source=bin/_paths_lib.sh  # devkit_gate_areas, devkit_image_group_runs
. "$HERE/_paths_lib.sh"
# shellcheck source=bin/_timeout_lib.sh  # devkit_docker_guard
. "$HERE/_timeout_lib.sh"

KEEP_IMAGES=10
T0=$SECONDS
NAME=- SHA7=- ROOT='' UNGATED_REASON='' SLUG='' IMAGE='' M='' L='' LATEST_DIGEST=''
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/devkit-publish
SCRATCH=''
BUILD_WT=''
DIGEST_WHY=''
BUILT_TAG=''

usage() { echo "usage: $0 <repo-checkout> [--ungated <reason>]" >&2; exit 2; }
finish() { # <outcome> <exit code>
  echo "PUBLISH $NAME $SHA7 $1 $((SECONDS - T0))s"
  exit "$2"
}
refuse() { echo "PUBLISH refused: $*" >&2; finish refused 1; }
fail() { echo "PUBLISH failed: $*" >&2; finish failed 1; }
env_error() { echo "PUBLISH refused: $*" >&2; finish refused 2; }

# shellcheck disable=SC2329  # the EXIT trap's, set before the first stage
cleanup() {
  slot_release 2>/dev/null
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
      -h|--help) usage ;;
      -*) echo "publish: unknown option $1" >&2; usage ;;
      *) [ -z "$ROOT" ] || usage; ROOT=$1 ;;
    esac
    shift
  done
  [ -n "$ROOT" ] || usage
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
  # The gate reads main's root .dockerignore to decide what the image sees; so does step 4.
  git -C "$ROOT" show "$M:.dockerignore" >"$SCRATCH/tree/.dockerignore" 2>/dev/null || rm -f "$SCRATCH/tree/.dockerignore"
  [ "$(gate_plan_literal "$plan" GATE_SLUG)" = "$SLUG" ] || refuse "main's plan names GATE_SLUG=$(gate_plan_literal "$plan" GATE_SLUG), the checkout's $SLUG"
  IMAGE=$(gate_plan_literal "$plan" PUBLISH_IMAGE)
  [ -n "$IMAGE" ] || env_error "main's plan has no PUBLISH_IMAGE= line: $SLUG publishes no image"
  [[ "$IMAGE" =~ ^ghcr\.io/[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || env_error "PUBLISH_IMAGE=$IMAGE is not ghcr.io/<owner>/<name>"
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

# Step 4 (header). The plan is sourced the way the gate sources it, in a subshell with the
# skeleton's helpers absent: only its declarations matter here.
judge_inputs() {
  local changed n rc=0
  [ -n "$L" ] || return 0
  changed=$(git -C "$ROOT" diff --no-renames --name-only "$L" "$M") || fail "git diff ${L:0:7} $SHA7 failed"
  n=$(grep -c . <<<"$changed")
  (
    set +eu
    # shellcheck disable=SC2034  # read by the plan (gate image names) and _paths_lib.sh
    PR=publish WT=$SCRATCH/tree CHANGED=$changed GATE_CODE_PATHS=
    # shellcheck source=/dev/null  # main's plan, as local_gate.sh sources it
    . "$SCRATCH/tree/scripts/ci/gate_plan.sh"
    devkit_gate_areas "$CHANGED"
    devkit_image_group_runs
  ) || rc=$?
  case $rc in
    0) echo "PUBLISH inputs: $n paths changed in ${L:0:7}..$SHA7, image inputs among them" ;;
    1) echo "PUBLISH skipped: none of the $n paths changed in ${L:0:7}..$SHA7 is an image input"; finish skipped 0 ;;
    *) fail "cannot classify the changed paths against main's plan and .dockerignore (above)" ;;
  esac
}

# ungated <commit> <why>: refused, or let through with the owner's --ungated reason.
ungated() {
  [ -n "$UNGATED_REASON" ] \
    || refuse "${1:0:7} is ungated: $2. Merge through make merge; only the owner overrides, with publish.sh --ungated '<reason>'"
  echo "PUBLISH gate: ${1:0:7} UNGATED ($2); --ungated: $UNGATED_REASON"
}

# renovate_digest_only <pr> <author>: exit 0 when PR <pr> is Renovate's, every commit its, and
# its diff only moves image digests (_dependency_pr.py digest-only, the one definition of the
# hole renovate/automerge-digest opens); exit 1 with DIGEST_WHY saying why not. A gh or
# classifier error fails the run (so never call it inside $(...), where fail cannot exit).
renovate_digest_only() {
  local authors files rc=0
  authors=$(gh api --paginate "repos/$SLUG/pulls/$1/commits" --jq '.[] | .author.login // ""' | paste -sd, -) \
    || fail "cannot read PR #$1's commits (gh above)"
  files=$(gh api --paginate "repos/$SLUG/pulls/$1/files" --jq '.[]') || fail "cannot read PR #$1's files (gh above)"
  DIGEST_WHY=$("$HERE/python.sh" -I "$HERE/_dependency_pr.py" digest-only "$2" "$authors" <<<"$files") || rc=$?
  [ "$rc" -le 1 ] || fail "_dependency_pr.py digest-only failed on PR #$1 (above)"
  return "$rc"
}

# Step 5 for one first-parent commit (header).
check_commit() { # <commit> <plan GATE_RENOVATE_AUTOMERGE>
  local c=$1 parent pr num head login status state desc why
  parent=$(git -C "$ROOT" rev-parse --verify -q "$c^1") || { ungated "$c" "a root commit"; return; }
  pr=$(gh api "repos/$SLUG/commits/$c/pulls" \
    --jq ".[] | select(.merge_commit_sha == \"$c\") | [.number, .head.sha, .user.login] | @tsv") \
    || fail "cannot read the PR of ${c:0:7} (gh above)"
  [ -n "$pr" ] || { ungated "$c" "no merged PR has it as its merge commit"; return; }
  IFS=$'\t' read -r num head login <<<"$(head -n 1 <<<"$pr")"
  status=$(gh api "repos/$SLUG/commits/$head/status" \
    --jq '.statuses[] | select(.context == "local-gate") | .state + "\t" + .description') \
    || fail "cannot read PR #$num's local-gate status (gh above)"
  IFS=$'\t' read -r state desc <<<"$status"
  if [ "$state" = success ] && [[ "$desc" =~ on\ main\ ${parent:0:7}([^0-9a-f]|$) ]]; then
    echo "PUBLISH gate: ${c:0:7} PR #$num, local-gate on main ${parent:0:7}"
    return
  fi
  why="PR #$num head ${head:0:7} has local-gate '${state:-none}' (${desc:-no description}), not success on main ${parent:0:7}"
  if [ "$2" = digest ]; then
    if renovate_digest_only "$num" "$login"; then
      echo "PUBLISH gate: ${c:0:7} PR #$num, Renovate digest-only (GATE_RENOVATE_AUTOMERGE=digest): the smoke gates it"
      return
    fi
    why="$why; not a digest-only Renovate PR: $DIGEST_WHY"
  fi
  ungated "$c" "$why"
}

check_gates() {
  local renovate c
  renovate=$(gate_plan_literal "$SCRATCH/tree/scripts/ci/gate_plan.sh" GATE_RENOVATE_AUTOMERGE)
  if [ -z "$L" ]; then check_commit "$M" "$renovate"; return; fi
  for c in $(git -C "$ROOT" rev-list --first-parent --reverse "$L..$M"); do
    check_commit "$c" "$renovate"
  done
}

in_worktree_make() { # <target> <tag>
  BUILDX_BUILDER=default DOCKER_DEFAULT_PLATFORM=linux/amd64 \
    make -C "$BUILD_WT" --no-print-directory "$1" CI_IMAGE="$2" CI_BUILD_VERSION="$SHA7"
}

# Step 6 (header).
build_image() {
  local tag=$IMAGE:sha-$SHA7 built
  gate_env_load publish GATE_CAPACITY "$GATE_LOCAL_KEYS|$GATE_REMOTE_KEYS"
  slot_pool_init publish
  slot_acquire PUBLISH "$NAME:publish" "$(slot_cost publish ci-image)"
  export DEVKIT_SLOT_HOLDER=$$
  BUILD_WT=$STATE/$NAME.wt
  git -C "$ROOT" worktree remove --force "$BUILD_WT" >/dev/null 2>&1
  rm -rf "$BUILD_WT"
  git -C "$ROOT" worktree prune
  git -C "$ROOT" worktree add -q --detach "$BUILD_WT" "$M" || fail "git worktree add at $SHA7 failed (above)"
  echo "PUBLISH build: make ci-image, then ci-smoke, CI_IMAGE=$tag CI_BUILD_VERSION=$SHA7"
  BUILT_TAG=$tag
  # Two make calls, never one with both goals: under an inherited -j they would run at once and
  # the smoke could boot a previous build of the same tag (Codex, devkit #273).
  in_worktree_make ci-image "$tag" || fail "make ci-image failed at $SHA7 (above); nothing was pushed"
  in_worktree_make ci-smoke "$tag" || fail "make ci-smoke failed at $SHA7 (above); nothing was pushed"
  slot_release
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
  tag=$("$HERE/ship_tag.sh" "$SLUG" "$M" ${note[@]+"${note[@]}"}) \
    || fail "latest moved to $SHA7 but the ship tag failed (above); rerun: devkit/bin/ship_tag.sh $SLUG $M"
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
run_lock_acquire PUBLISH "$STATE/$NAME.lock" "another publish of $NAME"
read_main
judge_position
judge_inputs
check_gates
build_image
push_image
ship_and_prune
finish published 0
