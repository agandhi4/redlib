#!/usr/bin/env bash
# Run one command with a pinned cargo subcommand on PATH (cargo-llvm-cov for the rust unit tier's
# coverage), on the repo's pinned toolchains as toolchain_exec.sh does.
# Usage: devkit/bin/cargo_tool.sh <crate>@<version> -- <command> [args...]
#   COV_TOOL ?= devkit/bin/cargo_tool.sh cargo-llvm-cov@0.9.1 --     (a Makefile's tool variable)
#
# Why: a cargo subcommand is no rustup component, so rust-toolchain.toml cannot pin it, and an
# unpinned `cargo install` resolves a different version on two machines. The repo's Makefile
# names the exact version once; this script installs it (`cargo install --locked`, the crate's
# own lockfile, built by the pinned cargo) once per machine into
# $XDG_DATA_HOME/devkit/cargo-tools/<crate>-<version>, shared by every worktree and gate slot.
# PATH's own `cargo <sub> --version` reporting the version is used as-is.
# Gotcha: two gate slots may install at once; each builds into its own temporary root and only
# a slot that finds no store entry renames its root into place, so a half-built tool is never
# on PATH (a loser's root is deleted on exit).
# DEVKIT_OFFLINE=1 refuses to download and fails loudly when the store is cold.
# Exit: the command's own status, or 2 when the toolchain or the tool cannot be provided (the
# reason on stderr) or the call is malformed.
set -euo pipefail

usage() { echo "usage: $0 <cargo-crate>@<exact version> -- <command> [args...]" >&2; exit 2; }
die() { echo "cargo_tool: $*" >&2; exit 2; }
[ $# -ge 3 ] && [ "$2" = -- ] || usage
SPEC=$1
shift 2
CRATE=${SPEC%@*} VERSION=${SPEC#*@}
[[ "$CRATE" =~ ^cargo-[a-z0-9_-]+$ ]] || die "'$CRATE' is not a cargo subcommand crate (cargo-<name>)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$CRATE needs an exact version like 0.9.1 (got '$VERSION')"
SUB=${CRATE#cargo-}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/toolchain_path.sh
. "$here/toolchain_path.sh"
root=$(cd "$here/../.." && pwd)
toolchain_path "$root" || die "$TOOLCHAIN_ERROR"
command -v cargo >/dev/null || die "cargo is not on PATH and $root declares no rust-toolchain.toml"

# reports <PATH>: true when that PATH's `cargo <sub> --version` names VERSION.
reports() {
  [ "$(PATH=$1 cargo "$SUB" --version 2>/dev/null | awk '{print $2}')" = "$VERSION" ]
}
reports "$PATH" && exec "$@"

STORE="${XDG_DATA_HOME:-$HOME/.local/share}/devkit/cargo-tools"
DEST="$STORE/$CRATE-$VERSION"
if ! reports "$DEST/bin:$PATH"; then
  [ "${DEVKIT_OFFLINE:-0}" != 1 ] || die "$CRATE $VERSION is not installed in $DEST and DEVKIT_OFFLINE=1"
  mkdir -p "$STORE"
  TMP=$(mktemp -d "$STORE/.$CRATE-$VERSION.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  echo "cargo_tool: installing $CRATE $VERSION into $DEST (once per machine)" >&2
  cargo install --locked --quiet --root "$TMP" --version "$VERSION" "$CRATE" >&2 \
    || die "cargo install $CRATE@$VERSION failed (network, or the pinned toolchain is below its rust-version)"
  rm -f "$TMP/.crates.toml" "$TMP/.crates2.json"
  [ -e "$DEST" ] || mv "$TMP" "$DEST" || die "cannot move $TMP to $DEST"
  rm -rf "$TMP"  # a lost race's copy: exec below skips the EXIT trap
  reports "$DEST/bin:$PATH" || die "$DEST/bin/$CRATE does not report $VERSION"
fi
export PATH="$DEST/bin:$PATH"
exec "$@"
