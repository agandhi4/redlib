#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# Contract tests for bin/playwright_browsers.sh. No network, no real Playwright: fake runners
# (playwright, corepack, npx) log their argv and the node they see to $PW_LOG, answer --version
# with "Version 1.63.0", and exit $FAKE_INSTALL_STATUS for install.

PW="$BATS_TEST_DIRNAME/../bin/playwright_browsers.sh"

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/playwright.XXXXXX")
  TMP=$(cd "$TMP" && pwd -P)
  PROJ=$TMP/proj
  BIN=$TMP/bin
  FAKE=$TMP/fake
  export PW_LOG=$TMP/pw.log
  export FAKE_INSTALL_STATUS=0
  export XDG_DATA_HOME=$TMP/data
  export DEVKIT_OFFLINE=1
  export GIT_CONFIG_GLOBAL=$TMP/gitconfig
  export PATH=$BIN:$PATH
  unset PLAYWRIGHT_RUNNER
  mkdir -p "$PROJ" "$BIN" "$FAKE"
  : >"$GIT_CONFIG_GLOBAL"
  write_node_stub "$BIN/node" 25.0.0
  fake_runner "$FAKE/playwright"
}

teardown() {
  rm -rf "$TMP"
}

write_node_stub() { # <path> <version>
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\necho v%s\n' "$2" >"$1"
  chmod +x "$1"
}

fake_runner() { # <path>
  cat >"$1" <<'SH'
#!/bin/sh
echo "argv: $*" >>"$PW_LOG"
echo "node: $(node --version)" >>"$PW_LOG"
case " $* " in
  *" --version "*) echo "Version 1.63.0" ;;
  *" install "*) echo "fake install output"; exit "$FAKE_INSTALL_STATUS" ;;
esac
SH
  chmod +x "$1"
}

use_fake_playwright() { touch "$PROJ/package-lock.json"; export PLAYWRIGHT_RUNNER=$FAKE/playwright; }
first_argv() { sed -n 's/^argv: //p' "$PW_LOG" | head -n 1; }
run_pw() { run "$PW" --project-dir "$PROJ" "$@"; }

@test "no lockfile: exit 2 and the message names the dir" {
  run_pw
  [ "$status" -eq 2 ]
  [[ "$output" == *"no lockfile"* ]]
  [[ "$output" == *"$PROJ"* ]]
}

@test "pnpm-lock.yaml: runs corepack pnpm exec playwright install chromium" {
  touch "$PROJ/pnpm-lock.yaml"
  fake_runner "$BIN/corepack"
  run_pw
  [ "$status" -eq 0 ]
  [ "$(first_argv)" = "pnpm exec playwright install chromium" ]
}

@test "package-lock.json: runs npx --no-install playwright install chromium" {
  touch "$PROJ/package-lock.json"
  fake_runner "$BIN/npx"
  run_pw
  [ "$status" -eq 0 ]
  [ "$(first_argv)" = "--no-install playwright install chromium" ]
}

@test "explicit browsers pass through in order" {
  use_fake_playwright
  run_pw chromium firefox
  [ "$status" -eq 0 ]
  [ "$(first_argv)" = "install chromium firefox" ]
  [ "${lines[${#lines[@]}-1]}" = "playwright_browsers: chromium firefox ready (playwright 1.63.0)" ]
}

@test "PLAYWRIGHT_RUNNER is used verbatim as a word-split prefix" {
  touch "$PROJ/pnpm-lock.yaml"
  export PLAYWRIGHT_RUNNER="$FAKE/playwright --runner-flag"
  run_pw
  [ "$status" -eq 0 ]
  [ "$(first_argv)" = "--runner-flag install chromium" ]
  [ ! -e "$BIN/corepack" ]
}

@test "--with-deps: honoured on Linux, warned about and dropped on macOS" {
  use_fake_playwright
  run_pw --with-deps
  [ "$status" -eq 0 ]
  if [ "$(uname -s)" = Darwin ]; then
    [[ "$output" == *"playwright_browsers: --with-deps ignored on macOS (no system deps to install)"* ]]
    [ "$(first_argv)" = "install chromium" ]
  else
    [[ "$output" != *"ignored on macOS"* ]]
    [ "$(first_argv)" = "install --with-deps chromium" ]
  fi
}

@test "install failure: exit 1 and no ready line" {
  use_fake_playwright
  export FAKE_INSTALL_STATUS=1
  run_pw
  [ "$status" -eq 1 ]
  [[ "$output" == *"install' failed"* ]]
  [[ "$output" != *"ready"* ]]
}

@test "success: install output passes through and the ready line is last" {
  use_fake_playwright
  run_pw
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake install output"* ]]
  [ "${lines[${#lines[@]}-1]}" = "playwright_browsers: chromium ready (playwright 1.63.0)" ]
}

@test "unknown option: usage, exit 2" {
  use_fake_playwright
  run_pw --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
  [ ! -e "$PW_LOG" ]
}

@test ".nvmrc at the repo root: playwright runs under the provisioned node, not PATH's" {
  git init -q "$TMP/repo"
  echo 22.23.3 >"$TMP/repo/.nvmrc"
  write_node_stub "$XDG_DATA_HOME/devkit/node/v22.23.3/bin/node" 22.23.3
  PROJ=$TMP/repo/web
  mkdir -p "$PROJ"
  use_fake_playwright
  run_pw
  [ "$status" -eq 0 ]
  [ "$(sed -n 's/^node: //p' "$PW_LOG" | sort -u)" = "v22.23.3" ]
}

@test ".nvmrc the toolchain cannot provide: exit 1 before any install" {
  git init -q "$TMP/repo"
  echo 22.23.3 >"$TMP/repo/.nvmrc"
  PROJ=$TMP/repo
  use_fake_playwright
  run_pw
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot provide node 22.23.3"* ]]
  [ ! -e "$PW_LOG" ]
}
