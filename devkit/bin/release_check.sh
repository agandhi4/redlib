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
#   - No workflow line sets APP_VERSION, a `version=` output or the OCI version label to a
#     `sha-`-prefixed value: the version is the bare <sha7>, only image tags carry `sha-`
#     (observability.md; the 2026-10-13 fleet-wide fix in docs/decisions.md).
# Only the root Dockerfile is the app image, so only it is held to APP_VERSION.
#
# Second guard, on every Dockerfile (root and one level down, Dockerfile.* too): a final stage
# whose USER is not root (`root`, `0`, `0:<group>`; no USER means root) must EXPOSE only ports
# >= 1024, and every http(s) URL in its HEALTHCHECK must name one (no port means 80/443).
# Why: on 2026-10-13 Orbit's image ran nginx as uid 10001 on :80 and was down 16 h. Docker
# 20.10+ sets net.ipv4.ip_unprivileged_port_start=0 inside containers, so the Mac gate's smoke
# bound :80 fine; the Synology NAS's 4.4 kernel has no such namespaced sysctl and refused it.
# The fix is to listen on an unprivileged port, never `setcap cap_net_bind_service`: the deploy
# runs with no-new-privileges, which disables file capabilities. Ports given as variables, and
# HEALTHCHECKs that run a script instead of naming a URL, cannot be judged and pass.
# No Dockerfile at all means nothing to check.
# Usage: devkit/bin/release_check.sh [repo-root]      (part of ci-quick)
set -uo pipefail
# Before the cd: the script's own path may be relative.
# shellcheck source=/dev/null  # bin/_workflows_lib.sh: workflow_files, image_push_steps
. "$(dirname "${BASH_SOURCE[0]}")/_workflows_lib.sh"
# shellcheck source=bin/_dockerfile_lib.sh  # dockerfiles, final_stage
. "$(dirname "${BASH_SOURCE[0]}")/_dockerfile_lib.sh"
ROOT=${1:-$(git rev-parse --show-toplevel)}
cd "$ROOT" || exit 2
rc=0
fail() { echo "release-check: $*" >&2; rc=1; }

# A value that is the build arg: $APP_VERSION or ${APP_VERSION}, optionally quoted.
REF='["'"'"']?\$\{?APP_VERSION\}?["'"'"']?([[:space:]]|$)'
check_dockerfile() {
  local stage
  stage=$(final_stage Dockerfile)
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

# The version is the bare sha7; `sha-<7>` is only an image tag. Catches a version step that
# echoes `version=sha-…`, a literal build arg and a label alike; `value=sha-…` tags pass.
check_version_format() {
  local wf hit
  while IFS= read -r wf; do
    while IFS= read -r hit; do
      fail "$wf:${hit%%:*}: version value starts with 'sha-'; APP_VERSION is the bare sha7, only image tags carry 'sha-'"
    done < <(grep -nE "(^|[^A-Za-z0-9_])(APP_VERSION|version)=[\"']?sha-" "$wf")
  done < <(workflow_files)
}

# A non-root final stage may only listen on ports >= 1024 (header: the 2026-10-13 Orbit outage).
privileged_port() { # <dockerfile> <user> <port> <where>
  fail "$1: final stage runs as USER $2 but $4 uses port $3, below 1024; a non-root process cannot bind it on the NAS kernel (Orbit was down 16 h on 2026-10-13, and Docker Desktop allows it, so a Mac smoke passes). Listen on an unprivileged port (>= 1024) instead; never setcap: no-new-privileges disables file capabilities"
}
check_ports() { # <dockerfile>
  local f=$1 stage user port url authority word
  stage=$(final_stage "$f")
  user=$(grep -E '^[[:space:]]*USER[[:space:]]' <<< "$stage" | tail -1 | awk '{ print $2 }')
  user=${user%%:*}
  case "$user" in ""|root|0) return 0 ;; esac
  # EXPOSE 80 8080/tcp 9000-9010/udp: judge each port, a range by its low end.
  while IFS= read -r word; do
    port=${word%%/*}; port=${port%%-*}
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    [ "$port" -ge 1024 ] || privileged_port "$f" "$user" "$port" "EXPOSE $word"
  done < <(grep -E '^[[:space:]]*EXPOSE[[:space:]]' <<< "$stage" | sed -E 's/^[[:space:]]*EXPOSE[[:space:]]+//' | tr -s ' \t' '\n')
  # Scheme and authority of every URL. An authority ending in a bare `:` (a port spliced in by
  # code, closet's `'http://127.0.0.1:' + PORT`) or a `:$VAR` port cannot be judged.
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    authority=${url#*://}
    case "$authority" in
      *:) continue ;;
      *:*) port=${authority##*:} ;;
      *) case "$url" in https:*) port=443 ;; *) port=80 ;; esac ;;
    esac
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    [ "$port" -ge 1024 ] || privileged_port "$f" "$user" "$port" "HEALTHCHECK $url"
  done < <(grep -E '^[[:space:]]*HEALTHCHECK[[:space:]]' <<< "$stage" | grep -oE "https?://[^/[:space:]\"'?#]+" || true)
}

dockerfile_list=$(dockerfiles)
if [ -z "$dockerfile_list" ]; then
  echo "release-check: no Dockerfile; nothing to check"; exit 0
fi
while IFS= read -r f; do check_ports "$f"; done <<< "$dockerfile_list"
if [ -f Dockerfile ]; then
  check_dockerfile
  check_compose
  check_workflows
  check_version_format
else
  echo "release-check: no root Dockerfile; APP_VERSION not checked"
fi

[ $rc = 0 ] && echo "release-check: ok"
exit $rc
