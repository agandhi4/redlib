#!/usr/bin/env bash
# Guard: the image is the single source of APP_VERSION. Owner rule (2026-10-13): the build passes
# the sha once, the image carries it as env and OCI label, the app reports it as the health
# `version` key, and the deploy side never sets it (a runtime value on `:latest` cannot know the
# sha, so it would be a second, wrong source). Design: release-identity-design.md §3-4.
#   - Dockerfile, final stage (only its ENV and LABEL reach the image): `ARG APP_VERSION`,
#     `ENV APP_VERSION=$APP_VERSION`, `LABEL org.opencontainers.image.version=$APP_VERSION`
#     (braces and quotes allowed; multi-key and `\`-continued instructions are understood).
#   - Compose files (compose*.y*ml, docker-compose*.y*ml at the root, deploy/**/*.y*ml) set no
#     APP_VERSION under `environment:`, in map, list, bare pass-through or inline form.
#   - Workflow steps that push an image pass it: docker/build-push-action with `push:` not false
#     needs `APP_VERSION=` under `build-args:`; a `run:` step that builds and pushes
#     (`--push` or `docker push`) needs `--build-arg APP_VERSION=`.
# Only the root Dockerfile is the app image; none means nothing to check.
# Usage: devkit/bin/release_check.sh [repo-root]      (part of ci-quick)
set -uo pipefail
# Before the cd: the script's own path may be relative.
# shellcheck source=/dev/null  # bin/_workflows_lib.sh: workflow_files, image_push_steps
. "$(dirname "${BASH_SOURCE[0]}")/_workflows_lib.sh"
ROOT=${1:-$(git rev-parse --show-toplevel)}
cd "$ROOT" || exit 2
rc=0
fail() { echo "release-check: $*" >&2; rc=1; }

if [ ! -f Dockerfile ]; then
  echo "release-check: no Dockerfile; nothing to check"; exit 0
fi

# Logical Dockerfile lines (continuations joined) of the stage after the last FROM.
final_stage() {
  awk '
    { line = (cont ? cont " " : "") $0; cont = "" }
    line ~ /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, "", line); cont = line; next }
    line ~ /^[[:space:]]*FROM[[:space:]]/ { n = 0; next }
    { stage[++n] = line }
    END { for (i = 1; i <= n; i++) print stage[i] }
  ' Dockerfile
}

# A value that is the build arg: $APP_VERSION or ${APP_VERSION}, optionally quoted.
REF='["'"'"']?\$\{?APP_VERSION\}?["'"'"']?([[:space:]]|$)'
check_dockerfile() {
  local stage
  stage=$(final_stage)
  grep -Eq '^[[:space:]]*ARG[[:space:]]+APP_VERSION([=[:space:]]|$)' <<< "$stage" \
    || fail "Dockerfile final stage has no 'ARG APP_VERSION'"
  grep -Eq "^[[:space:]]*ENV[[:space:]](.*[[:space:]])?APP_VERSION=$REF" <<< "$stage" \
    || fail "Dockerfile final stage has no 'ENV APP_VERSION=\$APP_VERSION'"
  grep -Eq "^[[:space:]]*LABEL[[:space:]](.*[[:space:]])?[\"']?org\\.opencontainers\\.image\\.version[\"']?=$REF" <<< "$stage" \
    || fail "Dockerfile final stage has no 'LABEL org.opencontainers.image.version=\$APP_VERSION'"
}

compose_files() {
  local f
  for f in compose*.yml compose*.yaml docker-compose*.yml docker-compose*.yaml; do
    [ -f "$f" ] && echo "$f"
  done
  [ -d deploy ] && find deploy -type f \( -name '*.yml' -o -name '*.yaml' \) | sort
}

# Prints line numbers where an `environment:` block (or inline value) sets APP_VERSION.
compose_env_hits() {
  awk '
    function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
    /^[[:space:]]*(#|$)/ { next }
    in_env && indent($0) <= env_ind { in_env = 0 }
    /^[[:space:]]*environment:/ {
      rest = $0; sub(/^[[:space:]]*environment:[[:space:]]*/, "", rest); sub(/[[:space:]]#.*/, "", rest)
      if (rest == "") { in_env = 1; env_ind = indent($0) }
      else if (rest ~ /(^|[^A-Za-z0-9_])APP_VERSION([^A-Za-z0-9_]|$)/) print NR
      next
    }
    in_env && $0 ~ /^[[:space:]]*(-[[:space:]]*)?["'"'"']?APP_VERSION["'"'"']?[[:space:]]*([:=]|$)/ { print NR }
  ' "$1"
}

check_compose() {
  local f n
  while IFS= read -r f; do
    for n in $(compose_env_hits "$f"); do
      fail "$f:$n: sets APP_VERSION under environment:; the image is its only source"
    done
  done < <(compose_files)
}

# Every step that builds and pushes must pass the version; a bare `docker push` of an image an
# earlier step built is judged at that build step.
check_workflows() {
  local wf n kind versioned
  while IFS= read -r wf; do
    while read -r n kind versioned; do
      [ "$versioned" = 1 ] && continue
      case "$kind" in
        action) fail "$wf:$n: build-push-action pushes without 'APP_VERSION=' in build-args:" ;;
        build-push) fail "$wf:$n: step builds and pushes an image without '--build-arg APP_VERSION='" ;;
      esac
    done < <(image_push_steps "$wf")
  done < <(workflow_files)
}

check_dockerfile
check_compose
check_workflows

[ $rc = 0 ] && echo "release-check: ok"
exit $rc
