#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# Contract tests for bin/node_toolchain.sh, bin/rust_toolchain.sh and bin/toolchain_check.sh. No network: every test
# sets DEVKIT_OFFLINE=1, and "installed" Nodes are executable stubs under $XDG_DATA_HOME that
# only answer --version. A fake PATH node (fake_path_node) stands in for the machine's node.

NODE_TOOLCHAIN="$BATS_TEST_DIRNAME/../bin/node_toolchain.sh"
TOOLCHAIN_CHECK="$BATS_TEST_DIRNAME/../bin/toolchain_check.sh"
RUST_TOOLCHAIN="$BATS_TEST_DIRNAME/../bin/rust_toolchain.sh"
WANTED=22.23.3
PY_WANTED=3.13
RUST_WANTED=1.83.0

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/toolchain.XXXXXX")
  REPO=$TMP/repo
  BIN=$TMP/bin
  export XDG_DATA_HOME=$TMP/data
  export DEVKIT_OFFLINE=1
  export PATH=$BIN:$PATH
  STORE=$XDG_DATA_HOME/devkit/node
  mkdir -p "$REPO" "$BIN"
  # The PATH node differs from .nvmrc unless a test says otherwise (the Mac-runs-25 situation).
  fake_path_node 25.0.0
}

teardown() {
  rm -rf "$TMP"
}

write_node_stub() { # <path> <version>
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\necho v%s\n' "$2" >"$1"
  chmod +x "$1"
}
fake_path_node() { write_node_stub "$BIN/node" "$1"; }
cache_node() { write_node_stub "$STORE/v$1/bin/node" "$1"; }

# A consumer repo for toolchain_check: .nvmrc, Dockerfile, one workflow. Each test overwrites
# the pieces it is about.
make_repo() {
  git init -q "$REPO"
  printf '%s\n' "$WANTED" >"$REPO/.nvmrc"
  printf 'FROM node:22-alpine@sha256:abc AS web\nRUN npm ci\n' >"$REPO/Dockerfile"
  mkdir -p "$REPO/.github/workflows"
  write_workflow "node-version-file: .nvmrc"
}
write_workflow() { # <with-line for the setup-node step>
  cat >"$REPO/.github/workflows/x.yml" <<EOF
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          $1
      - run: npm test
EOF
}

# Adds the Python side to make_repo's repo: .python-version, a python stage in the Dockerfile,
# a backend/pyproject.toml one level down, and a setup-python workflow.
make_py_repo() {
  make_repo
  printf '%s\n' "$PY_WANTED" >"$REPO/.python-version"
  printf 'FROM python:3.13-slim-bookworm@sha256:def AS api\n' >>"$REPO/Dockerfile"
  mkdir -p "$REPO/backend"
  write_pyproject '>=3.13'
  write_py_workflow "python-version-file: .python-version"
}
write_pyproject() { # <requires-python spec>
  printf '[project]\nname = "api"\nrequires-python = "%s"\n' "$1" >"$REPO/backend/pyproject.toml"
}
write_py_workflow() { # <with-line for the setup-python step>
  cat >"$REPO/.github/workflows/py.yml" <<EOF
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          $1
      - run: pytest
EOF
}

run_toolchain() { run "$NODE_TOOLCHAIN" "$@"; }
run_check() { run "$TOOLCHAIN_CHECK" "$REPO"; }
last_line() { echo "${lines[${#lines[@]}-1]}"; }

# ---- node_toolchain.sh -----------------------------------------------------------------------

@test "node_toolchain: no args is usage, exit 2" {
  run_toolchain
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "node_toolchain: no .nvmrc, exit 1" {
  run_toolchain "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no .nvmrc"* ]]
}

@test "node_toolchain: a major alone is rejected, exit 1" {
  echo 22 >"$REPO/.nvmrc"
  run_toolchain "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exact version"* ]]
}

@test "node_toolchain: PATH node already matches, exit 0 with no output" {
  echo "$WANTED" >"$REPO/.nvmrc"
  fake_path_node "$WANTED"
  run_toolchain "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "node_toolchain: PATH node differs and the cache has it, prints the bin dir" {
  echo "$WANTED" >"$REPO/.nvmrc"
  cache_node "$WANTED"
  run_toolchain "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$STORE/v$WANTED/bin" ]
}

@test "node_toolchain: cold cache while offline fails loudly, exit 1" {
  echo "$WANTED" >"$REPO/.nvmrc"
  run_toolchain "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not cached"* ]]
  [[ "$output" == *"DEVKIT_OFFLINE"* ]]
  [ ! -e "$STORE" ]
}

@test "node_toolchain: v-prefix and trailing newline in .nvmrc are accepted" {
  printf 'v%s\n' "$WANTED" >"$REPO/.nvmrc"
  cache_node "$WANTED"
  run_toolchain "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$STORE/v$WANTED/bin" ]
}

# ---- toolchain_check.sh ----------------------------------------------------------------------

@test "toolchain_check: no declaration file at all means nothing to check, exit 0" {
  make_repo
  rm "$REPO/.nvmrc"
  run_check
  [ "$status" -eq 0 ]
  [ "$output" = "toolchain-check: no .nvmrc, .python-version, rust-toolchain.toml or .swift-version; nothing to check" ]
}

@test "toolchain_check: consistent Node-only repo passes and skips python" {
  make_repo
  run_check
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "toolchain-check: no .python-version; python not checked" ]
  [ "$(last_line)" = "toolchain-check: ok (node $WANTED)" ]
}

@test "toolchain_check: Dockerfile on another major fails and names the tag" {
  make_repo
  printf 'FROM node:26-alpine\n' >"$REPO/Dockerfile"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Dockerfile uses node:26-alpine"* ]]
  [[ "$output" == *"(major 22)"* ]]
  [[ "$output" == *"toolchain-check: FAIL"* ]]
}

@test "toolchain_check: setup-node with inline node-version fails with file:line" {
  make_repo
  write_workflow "node-version: 22"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".github/workflows/x.yml:7: setup-node pins node-version inline"* ]]
  [[ "$output" == *"node-version-file"* ]]
}

@test "toolchain_check: node-version in a non-setup-node step is not flagged" {
  make_repo
  cat >>"$REPO/.github/workflows/x.yml" <<'EOF'
      - run: echo "node-version: 26 is what the image used to say"
EOF
  run_check
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "toolchain-check: ok (node $WANTED)" ]
}

@test "toolchain_check: .nvmrc holding only a major fails" {
  make_repo
  echo 22 >"$REPO/.nvmrc"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"exact version"* ]]
}

@test "toolchain_check: FROM --platform=... node:22-slim matches major 22" {
  make_repo
  printf 'FROM --platform=linux/amd64 node:22-slim\n' >"$REPO/Dockerfile"
  run_check
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "toolchain-check: ok (node $WANTED)" ]
}

# ---- toolchain_check.sh: python --------------------------------------------------------------

@test "toolchain_check: consistent node+python repo passes and names both" {
  make_py_repo
  run_check
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "toolchain-check: ok (node $WANTED, python $PY_WANTED)" ]
}

@test "toolchain_check: MAJOR.MINOR.PATCH in .python-version is accepted" {
  make_py_repo
  echo 3.13.7 >"$REPO/.python-version"
  run_check
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "toolchain-check: ok (node $WANTED, python 3.13.7)" ]
}

@test "toolchain_check: .python-version holding only a major fails" {
  make_py_repo
  echo 3 >"$REPO/.python-version"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".python-version must hold MAJOR.MINOR"* ]]
}

@test "toolchain_check: FROM python:3.14-slim against 3.13 fails and names the tag" {
  make_py_repo
  printf 'FROM --platform=linux/amd64 python:3.14-slim AS api\n' >>"$REPO/Dockerfile"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Dockerfile uses python:3.14-slim"* ]]
  [[ "$output" == *"(python 3.13)"* ]]
  [[ "$output" == *"toolchain-check: FAIL"* ]]
}

@test "toolchain_check: uv image on python3.14 fails" {
  make_py_repo
  printf 'FROM ghcr.io/astral-sh/uv:python3.14-bookworm AS build\n' >"$REPO/backend/Dockerfile"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"backend/Dockerfile uses ghcr.io/astral-sh/uv:python3.14-bookworm"* ]]
}

@test "toolchain_check: uv image on python3.13 passes" {
  make_py_repo
  printf 'FROM ghcr.io/astral-sh/uv:python3.13-bookworm AS build\n' >"$REPO/backend/Dockerfile"
  run_check
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "toolchain-check: ok (node $WANTED, python $PY_WANTED)" ]
}

@test "toolchain_check: requires-python lower bound on another minor fails" {
  make_py_repo
  write_pyproject '>=3.12'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"backend/pyproject.toml requires-python '>=3.12' has lower bound 3.12"* ]]
}

@test "toolchain_check: requires-python >=3.13,<3.14 passes" {
  make_py_repo
  write_pyproject '>=3.13, <3.14'
  run_check
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "toolchain-check: ok (node $WANTED, python $PY_WANTED)" ]
}

@test "toolchain_check: requires-python ==3.13.* and ~=3.13 pass" {
  make_py_repo
  write_pyproject '==3.13.*'
  printf '[project]\nrequires-python = "~=3.13"\n' >"$REPO/pyproject.toml"
  run_check
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "toolchain-check: ok (node $WANTED, python $PY_WANTED)" ]
}

@test "toolchain_check: requires-python form the parser does not understand warns and passes" {
  make_py_repo
  write_pyproject '>=3.13,!=3.13.1'
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: backend/pyproject.toml requires-python '>=3.13,!=3.13.1' is not a form"* ]]
  [ "$(last_line)" = "toolchain-check: ok (node $WANTED, python $PY_WANTED)" ]
}

@test "toolchain_check: setup-python with inline python-version fails with file:line" {
  make_py_repo
  write_py_workflow "python-version: '3.13'"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".github/workflows/py.yml:7: setup-python pins python-version inline"* ]]
  [[ "$output" == *"python-version-file: .python-version"* ]]
}

@test "toolchain_check: python-only repo checks python without .nvmrc" {
  make_py_repo
  rm "$REPO/.nvmrc"
  run_check
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "toolchain-check: no .nvmrc; node not checked" ]
  [ "$(last_line)" = "toolchain-check: ok (python $PY_WANTED)" ]
}

# ---- rust_toolchain.sh -----------------------------------------------------------------------
# PATH is rebuilt from scratch (fakes + symlinks to the coreutils the script needs) so a real
# rustup or cargo on the machine running the tests can never answer for a fake. The fake rustup
# keeps its installed toolchains/components in $RUSTUP_STATE and logs every call to $RUSTUP_LOG.

rust_sandbox() {
  local tool
  # Per run, not per test: bats itself runs rm with the test's PATH after teardown removes $TMP.
  SANDBOX=${BATS_RUN_TMPDIR:-$TMP}/rust-sandbox
  mkdir -p "$SANDBOX"
  for tool in bash env awk grep sed tr head tail cut cat mkdir mktemp rm chmod dirname uname; do
    ln -sf "$(command -v "$tool")" "$SANDBOX/$tool"
  done
  rm -f "$BIN/node"
  export PATH=$BIN:$SANDBOX
  export RUSTUP_STATE=$TMP/rustup-state RUSTUP_LOG=$TMP/rustup.log
  mkdir -p "$RUSTUP_STATE"
  : >"$RUSTUP_STATE/toolchains"; : >"$RUSTUP_STATE/components"
  RUST_STORE=$XDG_DATA_HOME/devkit/rust
}
write_cargo_stub() { # <path> <version>
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\necho "cargo %s (0000000 2024-11-28)"\n' "$2" >"$1"
  chmod +x "$1"
}
write_rustup_stub() { # <path>
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "rustup $* RUSTUP_HOME=${RUSTUP_HOME:-}" >>"$RUSTUP_LOG"
case "$1 $2" in
  "toolchain list") cat "$RUSTUP_STATE/toolchains" ;;
  "component list") cat "$RUSTUP_STATE/components" ;;
  "toolchain install")
    echo "$3-x86_64-unknown-linux-gnu" >>"$RUSTUP_STATE/toolchains"
    shift 3
    while [ $# -gt 0 ]; do [ "$1" = --component ] && echo "$2-x86_64-unknown-linux-gnu" >>"$RUSTUP_STATE/components"; shift; done
    sysroot=$RUSTUP_STATE/toolchains-dir/$(tail -n1 "$RUSTUP_STATE/toolchains")
    mkdir -p "$sysroot/bin"
    printf '#!/bin/sh\necho "cargo %s (0000000 2024-11-28)"\n' "${sysroot##*/}" | sed 's/-x86_64-unknown-linux-gnu//' >"$sysroot/bin/cargo"
    chmod +x "$sysroot/bin/cargo" ;;
  "run "*) echo "$RUSTUP_STATE/toolchains-dir/$2-x86_64-unknown-linux-gnu" ;;
esac
EOF
  chmod +x "$1"
}
write_rust_toml() { # <channel> [components line]
  printf '[toolchain]\nchannel = "%s"\n%s\n' "$1" "${2:-}" >"$REPO/rust-toolchain.toml"
}
run_rust() { run "$RUST_TOOLCHAIN" "$@"; }
SYSROOT_BIN() { echo "$RUSTUP_STATE/toolchains-dir/$RUST_WANTED-x86_64-unknown-linux-gnu/bin"; }

@test "rust_toolchain: no args is usage, exit 2" {
  run_rust
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "rust_toolchain: PATH cargo already matches, exit 0 with no output" {
  rust_sandbox
  write_rust_toml "$RUST_WANTED"
  write_cargo_stub "$BIN/cargo" "$RUST_WANTED"
  run_rust "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rust_toolchain: rustup on PATH installs the declared version and prints its sysroot bin" {
  rust_sandbox
  write_rust_toml "$RUST_WANTED" 'components = ["rustfmt", "clippy"]'
  write_cargo_stub "$BIN/cargo" 1.80.0
  write_rustup_stub "$BIN/rustup"
  DEVKIT_OFFLINE=0 run "$RUST_TOOLCHAIN" "$REPO"
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "$(SYSROOT_BIN)" ]
  grep -q "^rustup toolchain install $RUST_WANTED --profile minimal --no-self-update --component rustfmt --component clippy " "$RUSTUP_LOG"
}

@test "rust_toolchain: installed toolchain with its components needs no install, even offline" {
  rust_sandbox
  write_rust_toml "$RUST_WANTED" 'components = ["clippy"]'
  write_rustup_stub "$BIN/rustup"
  DEVKIT_OFFLINE=0 "$BIN/rustup" toolchain install "$RUST_WANTED" --component clippy
  : >"$RUSTUP_LOG"
  run_rust "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$(SYSROOT_BIN)" ]
  run grep -c "toolchain install" "$RUSTUP_LOG"
  [ "$output" = 0 ]
}

@test "rust_toolchain: rustup on PATH, toolchain missing, offline fails naming the file" {
  rust_sandbox
  write_rust_toml "$RUST_WANTED"
  write_rustup_stub "$BIN/rustup"
  run_rust "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rust $RUST_WANTED from rust-toolchain.toml is not installed"* ]]
  [[ "$output" == *"DEVKIT_OFFLINE=1"* ]]
}

@test "rust_toolchain: no rustup anywhere and offline fails loudly, exit 1" {
  rust_sandbox
  write_rust_toml "$RUST_WANTED"
  run_rust "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rust-toolchain.toml"* ]]
  [[ "$output" == *"no rustup on PATH"* ]]
  [[ "$output" == *"DEVKIT_OFFLINE=1"* ]]
  [ ! -e "$RUST_STORE" ]
}

@test "rust_toolchain: without PATH rustup the cached private rustup is used with its own homes" {
  rust_sandbox
  write_rust_toml "$RUST_WANTED"
  write_rustup_stub "$RUST_STORE/cargo/bin/rustup"
  DEVKIT_OFFLINE=0 run "$RUST_TOOLCHAIN" "$REPO"
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "$(SYSROOT_BIN)" ]
  grep -q "^rustup toolchain install $RUST_WANTED .*RUSTUP_HOME=$RUST_STORE/rustup$" "$RUSTUP_LOG"
}

@test "rust_toolchain: stable, nightly and MAJOR.MINOR channels are rejected, exit 1" {
  local ch
  for ch in stable nightly 1.83; do
    write_rust_toml "$ch"
    run_rust "$REPO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must pin an exact channel"*"got '$ch'"* ]]
  done
}

@test "rust_toolchain: plain rust-toolchain file with a bare version is accepted" {
  rust_sandbox
  printf '%s\n' "$RUST_WANTED" >"$REPO/rust-toolchain"
  write_cargo_stub "$BIN/cargo" "$RUST_WANTED"
  run_rust "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_rust --declared "$REPO"
  [ "$output" = "$RUST_WANTED" ]
}

@test "rust_toolchain: no declaration, exit 1" {
  run_rust "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no rust-toolchain.toml or rust-toolchain"* ]]
}

# ---- toolchain_check.sh: rust ----------------------------------------------------------------

make_rust_repo() {
  git init -q "$REPO"
  write_rust_toml "$RUST_WANTED"
  printf '[package]\nname = "app"\nrust-version = "1.81"\n' >"$REPO/Cargo.toml"
  printf 'FROM rust:1.83-slim AS build\nFROM docker.io/library/rust:1.83.0-alpine@sha256:abc\nFROM messense/rust-musl-cross:x86_64-musl\n' >"$REPO/Dockerfile"
  mkdir -p "$REPO/.github/workflows"
  write_rust_workflow "cache: true"
}
write_rust_workflow() { # <with-line for the setup-rust-toolchain step>
  cat >"$REPO/.github/workflows/rs.yml" <<EOF
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
      - uses: actions-rust-lang/setup-rust-toolchain@9d7e65c320fdb52dcd45ffaa68deb6c02c8754d9
        with:
          $1
      - run: cargo test --locked
EOF
}

@test "toolchain_check: consistent rust-only repo passes and names rust" {
  make_rust_repo
  run_check
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "toolchain-check: ok (rust $RUST_WANTED)" ]
}

@test "toolchain_check: FROM rust on another minor or untagged fails and names the tag" {
  make_rust_repo
  printf 'FROM rust:1.84-slim\nFROM rust AS floating\n' >"$REPO/Dockerfile"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Dockerfile uses rust:1.84-slim; rust-toolchain.toml says $RUST_WANTED (rust 1.83)"* ]]
  [[ "$output" == *"Dockerfile uses rust; rust-toolchain.toml"* ]]
}

@test "toolchain_check: Cargo.toml rust-version above the channel fails" {
  make_rust_repo
  printf '[package]\nname = "app"\nrust-version = "1.84"\n' >"$REPO/Cargo.toml"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cargo.toml rust-version 1.84 is above the pinned toolchain $RUST_WANTED"* ]]
}

@test "toolchain_check: rust-version equal to the channel passes" {
  make_rust_repo
  printf '[package]\nrust-version = "1.83.0"\n' >"$REPO/Cargo.toml"
  run_check
  [ "$status" -eq 0 ]
}

@test "toolchain_check: setup-rust-toolchain with inline toolchain fails with file:line" {
  make_rust_repo
  write_rust_workflow "toolchain: 1.83.0"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".github/workflows/rs.yml:7: setup-rust-toolchain pins toolchain inline"* ]]
}

@test "toolchain_check: dtolnay/rust-toolchain fails because it cannot read the file" {
  make_rust_repo
  printf '      - uses: dtolnay/rust-toolchain@4f647fc679bcd3b11499ccb42104547c83dabe96\n' >>"$REPO/.github/workflows/rs.yml"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"rs.yml:9: dtolnay/rust-toolchain cannot read rust-toolchain.toml"* ]]
}

@test "toolchain_check: inexact rust channel fails with the parser's message" {
  make_rust_repo
  write_rust_toml stable
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"rust-toolchain.toml must pin an exact channel"* ]]
}

@test "toolchain_check: node + python + rust + swift ok line lists all four" {
  make_py_repo
  write_rust_toml "$RUST_WANTED"
  make_swift_repo Darwin "6.2.4"
  run_check
  [ "$status" -eq 0 ]
  [ "$output" = "toolchain-check: ok (node $WANTED, python $PY_WANTED, rust $RUST_WANTED, swift $SWIFT_WANTED)" ]
}

# ---- swift (.swift-version) ---------------------------------------------------------------------
# uname and swift are PATH stubs, so the macOS branch runs on the Linux CI runner too.
SWIFT_WANTED=6.2
make_swift_repo() { # <uname> <swift version, or "" for no swift on PATH>
  mkdir -p "$REPO"
  printf '%s\n' "$SWIFT_WANTED" >"$REPO/.swift-version"
  printf '#!/bin/sh\necho %s\n' "$1" >"$BIN/uname"
  chmod +x "$BIN/uname"
  if [ -n "$2" ]; then
    printf '#!/bin/sh\necho "swift-driver version: 1.127.15 Apple Swift version %s (swiftlang-%s.1.4 clang-1700.6.4.2)"\necho "Target: arm64-apple-macosx26.0"\n' "$2" "$2" >"$BIN/swift"
    chmod +x "$BIN/swift"
  fi
}

@test "toolchain_check: swift on macOS matching .swift-version on its precision passes" {
  make_swift_repo Darwin 6.2.4
  run_check
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "toolchain-check: ok (swift $SWIFT_WANTED)" ]
  # Apple prints a .0 patch as MAJOR.MINOR; an exact pin still matches it.
  make_swift_repo Darwin 6.2
  printf '6.2.0\n' >"$REPO/.swift-version"
  run_check
  [ "$status" -eq 0 ]
}

@test "toolchain_check: swift on macOS that disagrees fails, and 6.2 never matches 6.20" {
  make_swift_repo Darwin 6.1.2
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"swift is 6.1.2; .swift-version says $SWIFT_WANTED"* ]]
  make_swift_repo Darwin 6.20.1
  run_check
  [ "$status" -eq 1 ]
}

@test "toolchain_check: .swift-version off macOS is skipped, not failed; no swift on macOS fails" {
  make_swift_repo Linux ""
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"not macOS; swift $SWIFT_WANTED (Xcode's) not checked"* ]]
  make_swift_repo Darwin ""
  run env PATH="$BIN:/usr/bin:/bin" "$TOOLCHAIN_CHECK" "$REPO"
  if command -v /usr/bin/swift >/dev/null; then skip "this machine has /usr/bin/swift"; fi
  [ "$status" -eq 1 ]
  [[ "$output" == *"swift is not on PATH"* ]]
}

@test "toolchain_check: malformed .swift-version fails" {
  make_swift_repo Darwin 6.2.4
  printf 'latest\n' >"$REPO/.swift-version"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".swift-version must hold MAJOR.MINOR"* ]]
}
