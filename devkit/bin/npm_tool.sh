#!/usr/bin/env bash
# Print the path of a devkit-pinned npm tool's executable, installing it first (jscpd for
# metrics/jscpd.mjs, which calls this when the conf line passes no --bin), the way
# release_tool.sh provides a pinned release binary.
# Usage: devkit/bin/npm_tool.sh <tool> --path
#
# Why devkit holds the pin, not the repo: jscpd measures shell, Python, Swift and Rust repos that
# have no node project of their own, and each such repo had copied a tools/metrics package.json
# and lockfile to pin it (homelab, claude-kit, kitchen, redlib, two scaffolds). The pin is
# metrics/tools/package.json and its package-lock.json, beside the collectors (vendored with
# them; Renovate updates devkit's copy). `npm ci` of that lockfile runs once per machine into
# $XDG_DATA_HOME/devkit/npm-tools/<lockfile sha>-<platform> (default ~/.local/share), shared by
# every worktree and gate slot; a lockfile change is a new directory, never an in-place upgrade.
# The platform is in the key because jscpd 5 ships one native optional package per platform.
# Gotcha: two gate slots may install at once; each runs `npm ci` in its own temporary directory
# and only a slot that finds no store entry renames it into place, so a half-installed tool is
# never run. DEVKIT_OFFLINE=1 refuses to install and fails loudly when the store is cold. npm
# is PATH's: metrics_collect.sh has put the repo's pinned node first.
# Exit: 0 with the path on stdout, or 2 when the tool cannot be provided (the reason on stderr)
# or the call is malformed.
set -euo pipefail

die() { echo "npm_tool: $*" >&2; exit 2; }
[ $# -eq 2 ] && [ "$2" = --path ] || die "usage: $0 <tool> --path"
TOOL=$1
PINS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../metrics/tools" && pwd) || die "no metrics/tools beside bin/"
for f in package.json package-lock.json; do [ -f "$PINS/$f" ] || die "$PINS/$f is missing"; done
grep -Eq "^[[:space:]]*\"$TOOL\"[[:space:]]*:" "$PINS/package.json" \
  || die "no pin for '$TOOL' in $PINS/package.json (its dependencies are the pinned tools)"

if command -v sha256sum >/dev/null; then SHA256=sha256sum; else SHA256="shasum -a 256"; fi
LOCK_SHA=$($SHA256 "$PINS/package-lock.json" | cut -c1-12)
STORE="${XDG_DATA_HOME:-$HOME/.local/share}/devkit/npm-tools"
DEST="$STORE/$LOCK_SHA-$(uname -s)-$(uname -m)"
EXE="$DEST/node_modules/.bin/$TOOL"

# install: `npm ci` of the pinned lock in a temporary directory of the store, renamed to DEST
# unless another slot got there first.
install() {
  [ "${DEVKIT_OFFLINE:-0}" != 1 ] || die "$TOOL is not installed in $DEST and DEVKIT_OFFLINE=1"
  command -v npm >/dev/null || die "npm is not on PATH; it installs $TOOL from $PINS/package-lock.json"
  mkdir -p "$STORE"
  TMP=$(mktemp -d "$STORE/.$LOCK_SHA.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  cp "$PINS/package.json" "$PINS/package-lock.json" "$TMP/"
  echo "npm_tool: installing $PINS/package-lock.json into $DEST (once per machine)" >&2
  # stdout to stderr: this script's stdout is the path alone.
  npm ci --prefix "$TMP" --no-audit --no-fund >&2 || die "npm ci of $PINS/package-lock.json failed"
  [ -x "$TMP/node_modules/.bin/$TOOL" ] || die "npm ci installed no node_modules/.bin/$TOOL"
  [ -e "$DEST" ] || mv "$TMP" "$DEST" || die "cannot move $TMP to $DEST"
  [ -x "$EXE" ] || die "$EXE is missing after the install"
}
[ -x "$EXE" ] || install
echo "$EXE"
