#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# Contract tests for bin/throwaway_pg.sh: the docker argv it builds, its single stdout line, the
# readiness wait and its cleanup on failure. No Docker: a fake `docker` on PATH logs each call's
# argv (one line per call, args joined by spaces) to $DOCKER_LOG and answers:
#   run                    prints a fake container id
#   inspect -f …Running…   "true", or "false" when FAKE_DOCKER_DEAD=1
#   exec … pg_isready      fails until call number $FAKE_PG_READY_AFTER (default 1), or always
#                          when FAKE_PG_NEVER_READY=1; counted in $TMP/isready.count
#   port <name> 5432/tcp   127.0.0.1:54321, or 127.0.0.1:$PG_PORT when the test set one
#   rm -fv                 ok, or exit 1 ("No such container") when FAKE_DOCKER_ABSENT=1
#   logs                   two fake log lines

bats_require_minimum_version 1.5.0  # run --separate-stderr

SCRIPT="$BATS_TEST_DIRNAME/../bin/throwaway_pg.sh"

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/throwaway_pg.XXXXXX")
  BIN=$TMP/bin
  export DOCKER_LOG=$TMP/docker.log
  export ISREADY_COUNT=$TMP/isready.count
  export PATH=$BIN:$PATH
  unset PG_IMAGE PG_USER PG_PASSWORD PG_DB PG_PORT PG_NETWORK PG_TMPFS PG_ARGS PG_READY_TIMEOUT
  unset FAKE_DOCKER_DEAD FAKE_PG_NEVER_READY FAKE_PG_READY_AFTER FAKE_DOCKER_ABSENT
  mkdir -p "$BIN"
  write_fake_docker
}

teardown() {
  rm -rf "$TMP"
}

write_fake_docker() {
  cat >"$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$1" in
  run) echo 0123456789abcdef ;;
  inspect) [ "${FAKE_DOCKER_DEAD:-0}" = 1 ] && echo false || echo true ;;
  exec)
    [ "${FAKE_PG_NEVER_READY:-0}" = 1 ] && exit 1
    n=$(( $(cat "$ISREADY_COUNT" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$ISREADY_COUNT"
    [ "$n" -ge "${FAKE_PG_READY_AFTER:-1}" ] || exit 1
    ;;
  port) echo "127.0.0.1:${PG_PORT:-54321}" ;;
  rm) [ "${FAKE_DOCKER_ABSENT:-0}" = 1 ] && { echo "Error: No such container: $3" >&2; exit 1; } ;;
  logs) printf 'pg log line one\npg log line two\n' ;;
esac
exit 0
FAKE
  chmod +x "$BIN/docker"
}

# Run the script with stderr kept apart: stdout is the contract, stderr is diagnostics.
run_pg() { run --separate-stderr "$SCRIPT" "$@"; }

run_line() { grep -m 1 '^run ' "$DOCKER_LOG"; }
# call_index <prefix>: 1-based line number of the first docker call starting with <prefix>.
call_index() { grep -n -m 1 -- "^$1" "$DOCKER_LOG" | cut -d: -f1; }
logged() { grep -qF -- "$1" "$DOCKER_LOG"; }
# Negations live in functions: a bare `!` in a bats test body does not fail the test (SC2314).
not_logged() { [ ! -e "$DOCKER_LOG" ] || ! grep -qF -- "$1" "$DOCKER_LOG"; }
run_has() { [[ " $(run_line) " == *" $1 "* ]]; }
run_lacks() { [[ " $(run_line) " != *" $1 "* ]]; }

@test "usage: no args, one arg, or an unknown verb exit 2 without touching docker" {
  run_pg
  [ "$status" -eq 2 ]
  run_pg up
  [ "$status" -eq 2 ]
  run_pg start n
  [ "$status" -eq 2 ]
  run_pg up 'bad name'
  [ "$status" -eq 2 ]
  not_logged run
}

@test "up with defaults: stale container removed first, tmpfs, loopback-only random port, one stdout line" {
  run_pg up n
  [ "$status" -eq 0 ]
  [ "$output" = "PG_PORT=54321" ]
  [ "$(call_index 'rm -fv n')" -lt "$(call_index 'run ')" ]
  run_has "-d"
  run_lacks "--rm"   # the container must outlive a crash for docker logs; down removes it
  run_has "--name n"
  run_has "--tmpfs /var/lib/postgresql:rw"
  run_has "-p 127.0.0.1::5432"
  run_has "-e POSTGRES_USER=ci"
  run_has "-e POSTGRES_PASSWORD=ci"
  run_has "-e POSTGRES_DB=ci"
  [[ "$(run_line)" == *" postgres:18" ]]
  run_lacks "--network"
  logged "port n 5432/tcp"
}

@test "PG_PORT pins the loopback host port and is echoed back" {
  PG_PORT=55432 run_pg up n
  [ "$status" -eq 0 ]
  [ "$output" = "PG_PORT=55432" ]
  run_has "-p 127.0.0.1:55432:5432"
}

@test "PG_PORT that is not a number is a usage error" {
  PG_PORT=abc run_pg up n
  [ "$status" -eq 2 ]
  not_logged run
}

@test "PG_TMPFS=0 drops the tmpfs mount" {
  PG_TMPFS=0 run_pg up n
  [ "$status" -eq 0 ]
  run_lacks "--tmpfs"
}

@test "PG_NETWORK joins the network and still publishes on loopback" {
  PG_NETWORK=net1 run_pg up n
  [ "$status" -eq 0 ]
  [ "$output" = "PG_PORT=54321" ]
  run_has "--network net1"
  run_has "-p 127.0.0.1::5432"
}

@test "PG_ARGS are word-split and appended after the image, in order; image and credentials honoured" {
  PG_ARGS='-c autovacuum=off -c fsync=off' PG_IMAGE=postgres:18-alpine PG_USER=u PG_DB=d run_pg up n
  [ "$status" -eq 0 ]
  [[ "$(run_line)" == *" postgres:18-alpine -c autovacuum=off -c fsync=off" ]]
  run_has "-e POSTGRES_USER=u"
  run_has "-e POSTGRES_DB=d"
  logged "exec n pg_isready -h 127.0.0.1 -U u -d d -q"
}

@test "readiness: polls pg_isready over TCP until it succeeds" {
  FAKE_PG_READY_AFTER=3 run_pg up n
  [ "$status" -eq 0 ]
  [ "$output" = "PG_PORT=54321" ]
  [ "$(cat "$ISREADY_COUNT")" -eq 3 ]
  [ "$(grep -c '^exec n pg_isready -h 127.0.0.1 ' "$DOCKER_LOG")" -eq 3 ]
}

@test "container dies during startup: exit 1, reason on stderr, logs dumped, container removed" {
  FAKE_DOCKER_DEAD=1 run_pg up n
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"n exited before accepting connections"* ]]
  [[ "$stderr" == *"pg log line one"* ]]
  [ "$(grep -c '^rm -fv n$' "$DOCKER_LOG")" -eq 2 ]
  not_logged "exec n pg_isready"
}

@test "never ready: times out after PG_READY_TIMEOUT, logs dumped, container removed" {
  local started=$SECONDS
  FAKE_PG_NEVER_READY=1 PG_READY_TIMEOUT=1 run_pg up n
  [ "$status" -eq 1 ]
  [ $((SECONDS - started)) -le 5 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not ready after 1s"* ]]
  [[ "$stderr" == *"pg log line two"* ]]
  logged "logs --tail 40 n"
  [ "$(call_index 'logs ')" -lt "$(grep -n '^rm -fv n$' "$DOCKER_LOG" | tail -n 1 | cut -d: -f1)" ]
}

@test "url prints the loopback connection string, percent-encoding credentials" {
  run_pg url n
  [ "$status" -eq 0 ]
  [ "$output" = "postgresql://ci:ci@127.0.0.1:54321/ci" ]
  PG_PASSWORD='p@ss:w/rd' run_pg url n
  [ "$output" = "postgresql://ci:p%40ss%3Aw%2Frd@127.0.0.1:54321/ci" ]
}

@test "url on a container that is not running exits 1" {
  FAKE_DOCKER_DEAD=1 run_pg url n
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "down is idempotent: exit 0 and silent when the container is absent" {
  FAKE_DOCKER_ABSENT=1 run_pg down n
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  logged "rm -fv n"
}
