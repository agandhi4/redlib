#!/usr/bin/env bash
# make's SHELL: run each recipe line (and each $(shell …)) on the repo's pinned toolchains, the
# PATH the gate's jobs and the hooks build (toolchain_path.sh: Node from .nvmrc, Rust from
# rust-toolchain.toml), then hand the line to /bin/sh exactly as make would have.
# Usage, in a consumer's Makefile:   SHELL := devkit/bin/toolchain_shell.sh
#
# Why (finplat pass 9, 2026-10-19): a hand-run `make metrics-tighten` ran its install
# prerequisites, and finplat's own metrics script, on Homebrew's Node 25, which dependency-cruiser
# refuses; only the collectors (metrics_collect.sh) and the gate's jobs were on the pin. A SHELL
# covers every target at once, so no recipe can be the one left out.
# Gotcha: setting PATH in the Makefile (`export PATH := …`) is not enough on macOS's make 3.81:
# a line with no shell syntax is exec'd directly on make's own PATH, and $(shell …) never sees
# exported variables. A SHELL that is not /bin/sh disables that fast path, so this sees every line.
# Cost: nothing under the gate, the hooks or a make they start (toolchain_path exports
# DEVKIT_TOOLCHAIN_TREE, and a line whose tree matches skips it); a hand-run make pays
# toolchain_path once per line (~0.1 s with Node, measured in finplat 2026-10-19).
# Exit: the line's own status, or 2 when a declared toolchain cannot be provided (the
# provisioning script's reason is already on stderr).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)
if [ "${DEVKIT_TOOLCHAIN_TREE:-}" != "$root" ]; then
  # shellcheck source=bin/toolchain_path.sh
  . "$here/toolchain_path.sh"
  toolchain_path "$root" || { echo "toolchain_shell: $TOOLCHAIN_ERROR" >&2; exit 2; }
fi
exec /bin/sh "$@"
