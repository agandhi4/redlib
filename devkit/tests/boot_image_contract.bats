#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# Contract tests for bin/boot_image.sh: the docker argv it builds, its single stdout line, the
# health poll and its cleanup on failure. No Docker, no network. Fakes on PATH log each call's
# argv (one line per call, args joined by spaces) to $DOCKER_LOG:
#   docker run              prints a fake container id
#   docker inspect          "true", or "false" when FAKE_DOCKER_DEAD=1
#   docker port             127.0.0.1:48001
#   docker logs             two fake log lines; network create/rm and rm -fv succeed
#   curl                    prints the next code from FAKE_CURL_CODES (space-separated, the
#                           last repeats; default 200), counted in $CURL_COUNT; logs "curl <url>"
#                           Without -w (the BOOT_EXPECT_VERSION body fetch) it prints
#                           $FAKE_HEALTH_BODY, logs "curl-body <url>" and is not counted.
# Postgres tests copy the script into $TMP/kit next to a FAKE throwaway_pg.sh, which logs
# "throwaway_pg <argv> PG_NETWORK=<value>" to the same log and fails when FAKE_PG_FAIL=1.

bats_require_minimum_version 1.5.0  # run --separate-stderr

SCRIPT="$BATS_TEST_DIRNAME/../bin/boot_image.sh"

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/boot_image.XXXXXX")
  BIN=$TMP/bin
  export DOCKER_LOG=$TMP/docker.log
  export CURL_COUNT=$TMP/curl.count
  export PATH=$BIN:$PATH
  unset BOOT_HOST_PORT BOOT_HEALTH_STATUS BOOT_TIMEOUT BOOT_ENV_FILE BOOT_ENV BOOT_WITH_PG
  unset BOOT_LOG_TAIL BOOT_RUN_ARGS PG_NETWORK FAKE_DOCKER_DEAD FAKE_CURL_CODES FAKE_PG_FAIL
  unset BOOT_EXPECT_VERSION FAKE_HEALTH_BODY
  export BOOT_IMAGE=app:test BOOT_PORT=8000 BOOT_HEALTH_PATH=/health/ready
  mkdir -p "$BIN"
  write_fakes
}

teardown() {
  rm -rf "$TMP"
}

write_fakes() {
  cat >"$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$1" in
  run) echo 0123456789abcdef ;;
  inspect) [ "${FAKE_DOCKER_DEAD:-0}" = 1 ] && echo false || echo true ;;
  port) echo "127.0.0.1:48001" ;;
  logs) printf 'app log line one\napp log line two\n' ;;
esac
exit 0
FAKE
  cat >"$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" -w "*) ;;
  *) printf 'curl-body %s\n' "${!#}" >>"$DOCKER_LOG"; printf '%s' "${FAKE_HEALTH_BODY:-}"; exit 0 ;;
esac
printf 'curl %s\n' "${!#}" >>"$DOCKER_LOG"
n=$(( $(cat "$CURL_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$CURL_COUNT"
set -- ${FAKE_CURL_CODES:-200}
[ "$n" -le $# ] || n=$#
printf '%s' "${!n}"
FAKE
  chmod +x "$BIN/docker" "$BIN/curl"
}

# Copy the script beside a fake throwaway_pg.sh; sets SCRIPT to the copy.
use_fake_pg() {
  mkdir -p "$TMP/kit"
  cp "$BATS_TEST_DIRNAME/../bin/boot_image.sh" "$TMP/kit/"
  cat >"$TMP/kit/throwaway_pg.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'throwaway_pg %s PG_NETWORK=%s\n' "$*" "${PG_NETWORK:-}" >>"$DOCKER_LOG"
[ "$1" = up ] || exit 0
[ "${FAKE_PG_FAIL:-0}" = 1 ] && exit 1
echo PG_PORT=54321
FAKE
  chmod +x "$TMP/kit/throwaway_pg.sh"
  SCRIPT=$TMP/kit/boot_image.sh
}

run_boot() { run --separate-stderr "$SCRIPT" "$@"; }

# PATH holding the fakes plus only the system tools the script needs; json parsers opt in.
# Proves each json_version branch, since a dev box has jq and python3 both.
restricted_path() { # [jq] [python3]
  local sys=$TMP/sys tool
  mkdir -p "$sys"
  for tool in bash dirname head sed cat sleep "$@"; do
    ln -sf "$(command -v "$tool")" "$sys/$tool"
  done
  echo "$BIN:$sys"
}

run_line() { grep -m 1 '^run ' "$DOCKER_LOG"; }
# call_index <prefix>: 1-based line number of the first logged call starting with <prefix>.
call_index() { grep -n -m 1 -- "^$1" "$DOCKER_LOG" | cut -d: -f1; }
last_index() { grep -n -- "^$1" "$DOCKER_LOG" | tail -n 1 | cut -d: -f1; }
logged() { grep -qF -- "$1" "$DOCKER_LOG"; }
# Negations live in functions: a bare `!` in a bats test body does not fail the test (SC2314).
not_logged() { [ ! -e "$DOCKER_LOG" ] || ! grep -qF -- "$1" "$DOCKER_LOG"; }
run_has() { [[ " $(run_line) " == *" $1 "* ]]; }
curl_calls() { grep -c '^curl ' "$DOCKER_LOG"; }
# After teardown the last app/network calls are removals.
torn_down() {
  [ "$(last_index 'rm -fv n-app')" -gt "$(call_index 'run ')" ]
  [ "$(last_index 'network rm n-net')" -gt "$(call_index 'run ')" ]
}

@test "usage: no args, one arg, an unknown verb or a bad name exit 2 without touching docker" {
  run_boot
  [ "$status" -eq 2 ]
  run_boot up
  [ "$status" -eq 2 ]
  run_boot start n
  [ "$status" -eq 2 ]
  run_boot up 'bad name'
  [ "$status" -eq 2 ]
  not_logged run
}

@test "missing BOOT_IMAGE, BOOT_PORT or BOOT_HEALTH_PATH exits 2 naming the variable" {
  local var
  for var in BOOT_IMAGE BOOT_PORT BOOT_HEALTH_PATH; do
    run --separate-stderr env -u "$var" "$SCRIPT" up n
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"$var is required"* ]]
  done
  not_logged run
}

@test "malformed env values are usage errors" {
  BOOT_PORT=http run_boot up n
  [ "$status" -eq 2 ]
  BOOT_HEALTH_STATUS=2xx run_boot up n
  [ "$status" -eq 2 ]
  BOOT_ENV_FILE=$TMP/missing.env run_boot up n
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"BOOT_ENV_FILE"* ]]
  not_logged run
}

@test "happy path: leftovers removed, private network, loopback random port, polls until 2xx, one stdout line" {
  FAKE_CURL_CODES="000 000 200" run_boot up n
  [ "$status" -eq 0 ]
  [ "$output" = "BASE=http://127.0.0.1:48001" ]
  [ "$(call_index 'rm -fv n-app')" -lt "$(call_index 'network create n-net')" ]
  [ "$(call_index 'network create n-net')" -lt "$(call_index 'run ')" ]
  run_has "-d"
  run_has "--name n-app"
  run_has "--network n-net"
  run_has "-p 127.0.0.1::8000"
  [[ "$(run_line)" == *" app:test" ]]
  [[ "$(run_line)" != *"--rm"* ]]
  logged "port n-app 8000/tcp"
  logged "curl http://127.0.0.1:48001/health/ready"
  [ "$(curl_calls)" -eq 3 ]
  not_logged "throwaway_pg up"
}

@test "BOOT_HOST_PORT pins the loopback host port and BASE uses it" {
  BOOT_HOST_PORT=19001 run_boot up n
  [ "$status" -eq 0 ]
  [ "$output" = "BASE=http://127.0.0.1:19001" ]
  run_has "-p 127.0.0.1:19001:8000"
  logged "curl http://127.0.0.1:19001/health/ready"
}

@test "BOOT_HEALTH_STATUS=204 accepts 204 only; 200 keeps polling" {
  BOOT_HEALTH_STATUS=204 FAKE_CURL_CODES="200 204" run_boot up n
  [ "$status" -eq 0 ]
  [ "$output" = "BASE=http://127.0.0.1:48001" ]
  [ "$(curl_calls)" -eq 2 ]
}

@test "BOOT_ENV_FILE, BOOT_ENV lines and BOOT_RUN_ARGS reach docker run before the image" {
  printf 'A=1\n' >"$TMP/app.env"
  BOOT_ENV_FILE=$TMP/app.env BOOT_ENV=$'SECRET_KEY=abc\n\nCORS_ORIGINS=http://x' \
    BOOT_RUN_ARGS='--tmpfs /data -v /a:/b:ro' run_boot up n
  [ "$status" -eq 0 ]
  run_has "--env-file $TMP/app.env"
  run_has "-e SECRET_KEY=abc"
  run_has "-e CORS_ORIGINS=http://x"
  [[ "$(run_line)" == *" --tmpfs /data -v /a:/b:ro app:test" ]]
  [[ "$(run_line)" != *"-e  "* ]]
}

@test "BOOT_WITH_PG=1: Postgres up on the private network before the app; down removes it" {
  use_fake_pg
  BOOT_WITH_PG=1 run_boot up n
  [ "$status" -eq 0 ]
  [ "$output" = "BASE=http://127.0.0.1:48001" ]
  logged "throwaway_pg up n-pg PG_NETWORK=n-net"
  [ "$(call_index 'network create n-net')" -lt "$(call_index 'throwaway_pg up')" ]
  [ "$(call_index 'throwaway_pg up')" -lt "$(call_index 'run ')" ]
  [[ "$stderr" == *"PG_PORT=54321"* ]]
  : >"$DOCKER_LOG"
  run_boot down n
  [ "$status" -eq 0 ]
  logged "throwaway_pg down n-pg"
  [ "$(call_index 'rm -fv n-app')" -lt "$(call_index 'throwaway_pg down')" ]
  [ "$(call_index 'throwaway_pg down')" -lt "$(call_index 'network rm n-net')" ]
}

@test "BOOT_WITH_PG=1 and Postgres fails: exit 1, app never started, network removed" {
  use_fake_pg
  BOOT_WITH_PG=1 FAKE_PG_FAIL=1 run_boot up n
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  not_logged "run "
  [ "$(last_index 'network rm n-net')" -gt "$(call_index 'throwaway_pg up')" ]
}

@test "app dies during boot: exit 1, no BASE, logs dumped, everything removed" {
  use_fake_pg
  BOOT_WITH_PG=1 FAKE_DOCKER_DEAD=1 FAKE_CURL_CODES=000 BOOT_LOG_TAIL=25 run_boot up n
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"n-app exited before /health/ready answered"* ]]
  [[ "$stderr" == *"app log line one"* ]]
  logged "logs --tail 25 n-app"
  logged "logs --tail 25 n-pg"
  [ "$(curl_calls)" -eq 1 ]
  torn_down
  [ "$(last_index 'throwaway_pg down')" -gt "$(call_index 'run ')" ]
}

@test "health never answers: exits 1 after BOOT_TIMEOUT, logs dumped, everything removed" {
  local started=$SECONDS
  BOOT_TIMEOUT=1 FAKE_CURL_CODES=503 run_boot up n
  [ "$status" -eq 1 ]
  [ $((SECONDS - started)) -le 5 ]
  [ -z "$output" ]
  [[ "$stderr" == *"did not answer 2xx within 1s (last: 503)"* ]]
  logged "logs --tail 80 n-app"
  not_logged "logs --tail 80 n-pg"
  torn_down
}

@test "BOOT_EXPECT_VERSION: matching health version passes after the health poll" {
  BOOT_EXPECT_VERSION=ci-abc1234 FAKE_HEALTH_BODY='{"status":"ok","version":"ci-abc1234"}' run_boot up n
  [ "$status" -eq 0 ]
  [ "$output" = "BASE=http://127.0.0.1:48001" ]
  [[ "$stderr" == *"n-app reports version ci-abc1234"* ]]
  logged "curl-body http://127.0.0.1:48001/health/ready"
  [ "$(last_index 'curl ')" -lt "$(call_index 'curl-body ')" ]
}

@test "BOOT_EXPECT_VERSION: mismatch fails the boot, dumps logs and tears down" {
  BOOT_EXPECT_VERSION=ci-abc1234 FAKE_HEALTH_BODY='{"version":"dev"}' run_boot up n
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"/health/ready reports version 'dev', expected 'ci-abc1234'"* ]]
  [[ "$stderr" == *"app log line one"* ]]
  torn_down
}

@test "BOOT_EXPECT_VERSION: no version key, or a body that is not JSON, fails" {
  BOOT_EXPECT_VERSION=ci-abc1234 FAKE_HEALTH_BODY='{"status":"ok"}' run_boot up n
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reports version '<none>'"* ]]
  BOOT_EXPECT_VERSION=ci-abc1234 FAKE_HEALTH_BODY='ok' run_boot up n
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"reports version '<none>'"* ]]
}

@test "BOOT_EXPECT_VERSION unset: no body fetch" {
  FAKE_HEALTH_BODY='{"version":"dev"}' run_boot up n
  [ "$status" -eq 0 ]
  not_logged "curl-body"
}

@test "BOOT_EXPECT_VERSION: each parser (jq, python3, sed fallback) reads the version" {
  local body='{"status": "ok", "nested": {"x": 1}, "version": "ci-abc1234"}' tools path
  export BOOT_EXPECT_VERSION=ci-abc1234
  for tools in "jq" "python3" ""; do
    rm -rf "$TMP/sys"
    # shellcheck disable=SC2086  # tools is a word list
    path=$(restricted_path $tools)
    # Only the script sees the narrow PATH; bats itself needs the full one.
    FAKE_HEALTH_BODY=$body run --separate-stderr env PATH="$path" "$SCRIPT" up n
    [ "$status" -eq 0 ]
    FAKE_HEALTH_BODY='{"version":"dev"}' run --separate-stderr env PATH="$path" "$SCRIPT" up n
    [ "$status" -eq 1 ]
  done
}

@test "down with nothing running exits 0 silently" {
  run_boot down n
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  logged "rm -fv n-app"
  logged "network rm n-net"
}
