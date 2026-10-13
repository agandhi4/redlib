#!/usr/bin/env bash
# cargo on the toolchain rust-toolchain.toml pins, for every caller: the Makefile (so the hooks,
# the gate and Actions) and devkit new's lockfile step.
# Usage: scripts/ci/cargo.sh <cargo args...>      (the Makefile's $(CARGO))
#
# devkit/bin/rust_toolchain.sh prints the pinned toolchain's bin directory, installing it
# through rustup once, or nothing when PATH's cargo already matches. So a machine with no Rust
# (the Mac) and devkit's reusable quick-check (which sets up no Rust; ubuntu-latest ships
# rustup) compile with exactly the version the gate does. Override with `make CARGO=cargo`.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BIN=$("$ROOT/devkit/bin/rust_toolchain.sh" "$ROOT")
[ -z "$BIN" ] || export PATH="$BIN:$PATH"
exec cargo "$@"
