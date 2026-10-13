#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# shellcheck disable=SC2016  # fixtures hold literal $APP_VERSION / ${{ }} text on purpose
# Contract tests for bin/ship_tag.sh and bin/release_check.sh. No network.
# ship_tag: a stateful fake `gh api` keeps refs in $STATE/refs/<tag> and tag objects in
# $STATE/objs/<sha>, each holding "<type> <sha>"; it builds the JSON GitHub would return and
# applies --jq with jq. It logs mutations to $GH_LOG as "<METHOD> <path> <k=v ...>". Knobs:
#   FAKE_COMPARE  compare status (default behind); "missing" answers 404
#   FAKE_RACE     "<type> <sha>": the refs POST first creates that ref, then answers 422, as if
#                 another shipper won
# release_check: fixture repos written per test under $TMP/repo.

bats_require_minimum_version 1.5.0  # run --separate-stderr

SHIP="$BATS_TEST_DIRNAME/../bin/ship_tag.sh"
CHECK="$BATS_TEST_DIRNAME/../bin/release_check.sh"
SHA=0123456789abcdef0123456789abcdef01234567
OTHER=fedcba9876543210fedcba9876543210fedcba98
TAG=ship-2026-10-12-0123456

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/release.XXXXXX")
  export STATE=$TMP/state GH_LOG=$TMP/gh.log PATH=$TMP/bin:$PATH
  unset FAKE_COMPARE FAKE_RACE
  mkdir -p "$TMP/bin" "$STATE/refs" "$STATE/objs" "$TMP/repo"
  : >"$GH_LOG"
  fake_gh
}

teardown() {
  rm -rf "$TMP"
}

fake_gh() {
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = api ] || { echo "fake gh: unsupported: $*" >&2; exit 64; }
shift
method=GET jq_expr=. path= fields=()
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;;
    --jq) jq_expr=$2; shift ;;
    -f) fields+=("$2"); shift ;;
    -*) echo "fake gh: unsupported flag $1" >&2; exit 64 ;;
    *) path=$1 ;;
  esac
  shift
done
field() { local f; for f in "${fields[@]}"; do [ "${f%%=*}" = "$1" ] && { echo "${f#*=}"; return; }; done; }
not_found() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
answer() { jq -r "$jq_expr" <<<"$1"; exit 0; }
obj() { # <file> -> {"type":..,"sha":..}
  local t s; read -r t s <"$1"; jq -cn --arg t "$t" --arg s "$s" '{type: $t, sha: $s}'
}
[ "$method" = GET ] || echo "$method $path ${fields[*]}" >>"$GH_LOG"
case "$method $path" in
  "GET repos/acme/app/compare/main..."*)
    [ "${FAKE_COMPARE:-behind}" != missing ] || not_found
    answer "{\"status\":\"${FAKE_COMPARE:-behind}\"}" ;;
  "GET repos/acme/app/git/ref/tags/"*)
    f=$STATE/refs/${path##*/}; [ -f "$f" ] || not_found
    answer "{\"ref\":\"refs/tags/${path##*/}\",\"object\":$(obj "$f")}" ;;
  "GET repos/acme/app/git/tags/"*)
    f=$STATE/objs/${path##*/}; [ -f "$f" ] || not_found
    answer "{\"sha\":\"${path##*/}\",\"object\":$(obj "$f")}" ;;
  "POST repos/acme/app/git/tags")
    new=feed$(field object | cut -c5-)
    echo "$(field type) $(field object)" >"$STATE/objs/$new"
    answer "{\"sha\":\"$new\"}" ;;
  "POST repos/acme/app/git/refs")
    f=$STATE/refs/$(field ref | sed 's|^refs/tags/||')
    [ -z "${FAKE_RACE:-}" ] || echo "$FAKE_RACE" >"$f"
    [ ! -f "$f" ] || { echo "gh: Reference already exists (HTTP 422)" >&2; exit 1; }
    echo "tag $(field sha)" >"$f"
    answer "{\"ref\":\"$(field ref)\"}" ;;
esac
echo "fake gh: unexpected $method $path" >&2; exit 64
SH
  chmod +x "$TMP/bin/gh"
}

# An existing annotated tag: ref -> tag object -> commit.
existing_tag() { # <commit sha>
  echo "commit $1" >"$STATE/objs/aaaa$1"
  echo "tag aaaa$1" >"$STATE/refs/$TAG"
}
mutations() { grep -c . "$GH_LOG" || true; }
ship() { run --separate-stderr "$SHIP" acme/app "$@"; }

# --- ship_tag.sh ----------------------------------------------------------------------------

@test "ship: creates the annotated tag object, then the ref; SHIP_TAG is the only stdout" {
  ship "$SHA" --date 2026-10-12
  [ "$status" -eq 0 ]
  [ "$output" = "SHIP_TAG=$TAG" ]
  [ "$(mutations)" -eq 2 ]
  [ "$(sed -n 1p "$GH_LOG")" = "POST repos/acme/app/git/tags tag=$TAG message=Shipped $SHA on 2026-10-12 object=$SHA type=commit" ]
  [ "$(sed -n 2p "$GH_LOG")" = "POST repos/acme/app/git/refs ref=refs/tags/$TAG sha=feed${SHA:4}" ]
  [ "$(cat "$STATE/objs/feed${SHA:4}")" = "commit $SHA" ]
}

@test "ship: the date defaults to today in UTC" {
  ship "$SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "SHIP_TAG=ship-$(date -u +%F)-0123456" ]
}

@test "ship: rerun for the same sha is a no-op success" {
  existing_tag "$SHA"
  ship "$SHA" --date 2026-10-12
  [ "$status" -eq 0 ]
  [ "$output" = "SHIP_TAG=$TAG" ]
  [[ "$stderr" == *"ship_tag: $TAG already at 0123456"* ]]
  [ "$(mutations)" -eq 0 ]
}

@test "ship: a tag of that name on another commit is refused, never moved" {
  existing_tag "$OTHER"
  ship "$SHA" --date 2026-10-12
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"already points at fedcba9, not 0123456"* ]]
  [ "$(mutations)" -eq 0 ]
}

@test "ship: a sha not reachable from main is refused before any write" {
  local s
  for s in ahead diverged missing; do
    FAKE_COMPARE=$s ship "$SHA" --date 2026-10-12
    [ "$status" -eq 1 ]
    [ -z "$output" ]
  done
  [[ "$stderr" == *"cannot compare 0123456 with main"* ]]
  FAKE_COMPARE=identical ship "$SHA" --date 2026-10-12
  [ "$status" -eq 0 ]
  FAKE_COMPARE=ahead ship "$SHA" --date 2026-10-13
  [[ "$stderr" == *"not reachable from main"* ]]
  [ "$(mutations)" -eq 2 ]
}

@test "ship: 422 race on the ref, winner at the same sha, is success" {
  echo "commit $SHA" >"$STATE/objs/bbbb"
  FAKE_RACE="tag bbbb" ship "$SHA" --date 2026-10-12
  [ "$status" -eq 0 ]
  [ "$output" = "SHIP_TAG=$TAG" ]
  [[ "$stderr" == *"appeared concurrently"* ]]
  [[ "$stderr" == *"already at 0123456"* ]]
}

@test "ship: 422 race on the ref, winner at another sha, fails" {
  FAKE_RACE="commit $OTHER" ship "$SHA" --date 2026-10-12
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"already points at fedcba9"* ]]
}

@test "ship: usage errors exit 2 without calling gh" {
  ship
  [ "$status" -eq 2 ]
  run --separate-stderr "$SHIP"
  [ "$status" -eq 2 ]
  ship 0123456
  [ "$status" -eq 2 ]
  ship "$SHA" --date 12/10/2026
  [ "$status" -eq 2 ]
  ship "$SHA" --date
  [ "$status" -eq 2 ]
  ship "$SHA" extra
  [ "$status" -eq 2 ]
  run --separate-stderr "$SHIP" not-a-repo "$SHA"
  [ "$status" -eq 2 ]
  [ "$(mutations)" -eq 0 ]
}

# --- release_check.sh -----------------------------------------------------------------------

GOOD_DOCKERFILE='FROM node:22 AS web
ARG APP_VERSION
RUN echo build
FROM python:3.13-slim
ARG APP_VERSION=dev
ENV PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION}
LABEL org.opencontainers.image.source="https://github.com/acme/app" \
      org.opencontainers.image.version="$APP_VERSION"
CMD ["app"]'

GOOD_WORKFLOW='name: build
on:
  push:
    branches: [main]
jobs:
  image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Smoke build
        uses: docker/build-push-action@v6
        with:
          load: true
          push: false
      - name: Publish
        uses: docker/build-push-action@v6
        with:
          push: true
          build-args: |
            APP_VERSION=${{ github.sha }}
      - name: Manual publish
        run: |
          docker buildx build --build-arg APP_VERSION="${GITHUB_SHA::7}" -t x .
          docker push x'

repo_file() { # <path> <content>
  mkdir -p "$TMP/repo/$(dirname "$1")"
  printf '%s\n' "$2" >"$TMP/repo/$1"
}
good_repo() {
  repo_file Dockerfile "$GOOD_DOCKERFILE"
  repo_file .github/workflows/build.yml "$GOOD_WORKFLOW"
  repo_file compose.yml 'services:
  app:
    image: ghcr.io/acme/app:latest
    environment:
      DATABASE_URL: postgres://db
      - LOG_LEVEL=info'
}
check() { run --separate-stderr "$CHECK" "$TMP/repo"; }

@test "check: no Dockerfile means nothing to check" {
  check
  [ "$status" -eq 0 ]
  [ "$output" = "release-check: no Dockerfile; nothing to check" ]
}

@test "check: a conforming repo passes" {
  good_repo
  check
  [ "$status" -eq 0 ]
  [ "$output" = "release-check: ok" ]
  [ -z "$stderr" ]
}

@test "check: Dockerfile without ARG, ENV or LABEL fails one line each" {
  repo_file Dockerfile 'FROM python:3.13-slim
CMD ["app"]'
  check
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(grep -c '^release-check: Dockerfile final stage has no' <<<"$stderr")" -eq 3 ]
}

@test "check: ARG/ENV/LABEL only in an earlier stage do not count" {
  repo_file Dockerfile 'FROM node:22 AS web
ARG APP_VERSION
ENV APP_VERSION=$APP_VERSION
LABEL org.opencontainers.image.version=$APP_VERSION
FROM python:3.13-slim
CMD ["app"]'
  check
  [ "$status" -eq 1 ]
  [ "$(grep -c '^release-check: Dockerfile final stage has no' <<<"$stderr")" -eq 3 ]
}

@test "check: ENV or LABEL with a literal instead of the build arg fails" {
  good_repo
  repo_file Dockerfile 'FROM python:3.13-slim
ARG APP_VERSION
ENV APP_VERSION=dev
LABEL org.opencontainers.image.version=1.0'
  check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no 'ENV APP_VERSION=\$APP_VERSION'"* ]]
  [[ "$stderr" == *"no 'LABEL org.opencontainers.image.version=\$APP_VERSION'"* ]]
  [[ "$stderr" != *"no 'ARG APP_VERSION'"* ]]
}

@test "check: compose setting APP_VERSION in any environment form fails with file:line" {
  good_repo
  repo_file compose.yml 'services:
  app:
    environment:
      APP_VERSION: abc1234'
  repo_file docker-compose.prod.yaml 'services:
  app:
    environment:
      - "APP_VERSION=${GIT_SHA}"
  worker:
    environment:
      - APP_VERSION'
  repo_file deploy/nas/stack.yml 'services:
  app:
    environment: { APP_VERSION: x }'
  check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"compose.yml:4: sets APP_VERSION"* ]]
  [[ "$stderr" == *"docker-compose.prod.yaml:4: sets APP_VERSION"* ]]
  [[ "$stderr" == *"docker-compose.prod.yaml:7: sets APP_VERSION"* ]]
  [[ "$stderr" == *"deploy/nas/stack.yml:3: sets APP_VERSION"* ]]
  [ "$(grep -c 'sets APP_VERSION' <<<"$stderr")" -eq 4 ]
}

@test "check: APP_VERSION outside environment, or in other yml files, passes" {
  good_repo
  repo_file compose.yml 'services:
  app:
    image: ghcr.io/acme/app:${APP_VERSION:-latest}
    environment:
      LOG_LEVEL: info
    labels:
      APP_VERSION: not-env'
  repo_file config/app.yml 'environment:
  APP_VERSION: not a compose file'
  check
  [ "$status" -eq 0 ]
}

@test "check: build-push-action that pushes without APP_VERSION build-arg fails" {
  good_repo
  repo_file .github/workflows/build.yml 'jobs:
  image:
    steps:
      - name: Publish
        uses: docker/build-push-action@v6
        with:
          push: ${{ github.event_name == '"'push'"' }}
          build-args: |
            GIT_SHA=${{ github.sha }}
        env:
          APP_VERSION=nope
      - name: Smoke
        uses: docker/build-push-action@v6
        with:
          load: true'
  check
  [ "$status" -eq 1 ]
  [ "$(grep -c '^release-check:' <<<"$stderr")" -eq 1 ]
  [[ "$stderr" == *".github/workflows/build.yml:4: build-push-action pushes without 'APP_VERSION=' in build-args:"* ]]
}

@test "check: a run step that builds and pushes without --build-arg APP_VERSION fails" {
  good_repo
  repo_file .github/workflows/publish.yaml 'jobs:
  image:
    steps:
      - run: docker build -t x . && docker push x
      - name: buildx push
        run: |
          docker buildx build \
            --push -t x .
      - name: build only
        run: docker build -t x .
      - name: retag
        run: docker push x'
  check
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"publish.yaml:4: step builds and pushes"* ]]
  [[ "$stderr" == *"publish.yaml:5: step builds and pushes"* ]]
  [ "$(grep -c '^release-check:' <<<"$stderr")" -eq 2 ]
}
