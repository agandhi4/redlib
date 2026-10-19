#!/usr/bin/env bash
# Run one command on the repo's pinned toolchains: the PATH the gate and the hooks build
# (toolchain_path.sh: Node from .nvmrc, Rust from rust-toolchain.toml), for a hand-run make.
# Usage: devkit/bin/toolchain_exec.sh <command> [args...]
#   CARGO ?= devkit/bin/toolchain_exec.sh cargo        (a Makefile's tool variable)
#
# Why (redlib, 2026-10-18): `make ci-quick` by hand failed "cargo: No such file or directory" on
# a Mac with no Rust, though the gate and the hooks passed: both prefix PATH before any target,
# a plain make does not. A Makefile that routes its toolchain calls through this script runs the
# same cargo in all three. The repo root is the vendored devkit/'s parent, not the current
# directory, so a recipe that has `cd backend` still reads the root's pins.
# Exit: the command's own status, or 2 when a declared toolchain cannot be provided (the
# provisioning script's reason is already on stderr).
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <command> [args...]" >&2; exit 2; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/toolchain_path.sh
. "$here/toolchain_path.sh"
root=$(cd "$here/../.." && pwd)
# Already on this tree's pins (the gate, a hook, a toolchain_shell.sh recipe): nothing to provide.
if [ "${DEVKIT_TOOLCHAIN_TREE:-}" != "$(cd "$root" && pwd -P)" ]; then
  toolchain_path "$root" || { echo "toolchain_exec: $TOOLCHAIN_ERROR" >&2; exit 2; }
fi
exec "$@"
