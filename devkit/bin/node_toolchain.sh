#!/usr/bin/env bash
# Provide the exact Node version a repo declares in .nvmrc, for gates and hooks on machines
# whose PATH node differs (the Mac runs 25, CI and the images run 22; Node 25's default
# Web Storage stub broke every vitest suite in Orbit #40 / locus #91).
#
# Usage: devkit/bin/node_toolchain.sh <repo-root>
#   Prints the bin directory to prepend to PATH, or nothing when PATH's node already matches.
#   Exit 0 ok, 1 cannot provide (no .nvmrc, bad version, download or checksum failure), 2 usage.
#
# Installs land in $XDG_DATA_HOME/devkit/node/v<ver> (default ~/.local/share/devkit/node),
# downloaded from nodejs.org over HTTPS and verified against that release's SHASUMS256.txt.
# .nvmrc must hold an exact version (22.23.3 or v22.23.3): a major alone would make two
# machines resolve two different Nodes, which is the drift this script exists to end.
# DEVKIT_OFFLINE=1 refuses to download and fails loudly when the cache is cold.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <repo-root>" >&2; exit 2; }
ROOT=$1
NVMRC="$ROOT/.nvmrc"
[ -f "$NVMRC" ] || { echo "node_toolchain: no .nvmrc in $ROOT" >&2; exit 1; }
VERSION=$(tr -d '[:space:]' < "$NVMRC"); VERSION=${VERSION#v}
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "node_toolchain: .nvmrc must hold an exact version (got '$VERSION')" >&2; exit 1 ;;
esac

if command -v node >/dev/null && [ "$(node --version 2>/dev/null)" = "v$VERSION" ]; then
  exit 0
fi

case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) echo "node_toolchain: unsupported OS $(uname -s)" >&2; exit 1 ;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; x86_64) ARCH=x64 ;; *) echo "node_toolchain: unsupported arch $(uname -m)" >&2; exit 1 ;; esac

STORE="${XDG_DATA_HOME:-$HOME/.local/share}/devkit/node"
DEST="$STORE/v$VERSION"
if [ -x "$DEST/bin/node" ] && [ "$("$DEST/bin/node" --version)" = "v$VERSION" ]; then
  echo "$DEST/bin"; exit 0
fi

[ "${DEVKIT_OFFLINE:-0}" = 1 ] && { echo "node_toolchain: node v$VERSION not cached at $DEST and DEVKIT_OFFLINE=1" >&2; exit 1; }
command -v curl >/dev/null || { echo "node_toolchain: curl not found" >&2; exit 1; }
if command -v sha256sum >/dev/null; then SHA256=sha256sum; else SHA256="shasum -a 256"; fi

TARBALL="node-v$VERSION-$OS-$ARCH.tar.gz"
BASE="${DEVKIT_NODE_DIST:-https://nodejs.org/dist}/v$VERSION"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/devkit-node.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
echo "node_toolchain: downloading $TARBALL" >&2
curl -fsSL --retry 3 -o "$TMP/$TARBALL" "$BASE/$TARBALL"
curl -fsSL --retry 3 -o "$TMP/SHASUMS256.txt" "$BASE/SHASUMS256.txt"
EXPECTED=$(awk -v f="$TARBALL" '$2 == f {print $1}' "$TMP/SHASUMS256.txt")
[ -n "$EXPECTED" ] || { echo "node_toolchain: $TARBALL not listed in SHASUMS256.txt" >&2; exit 1; }
ACTUAL=$($SHA256 "$TMP/$TARBALL" | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED" ] || { echo "node_toolchain: checksum mismatch for $TARBALL" >&2; exit 1; }
mkdir -p "$STORE"
tar -xzf "$TMP/$TARBALL" -C "$TMP"
rm -rf "$DEST"
mv "$TMP/node-v$VERSION-$OS-$ARCH" "$DEST"
[ "$("$DEST/bin/node" --version)" = "v$VERSION" ] || { echo "node_toolchain: installed node reports $("$DEST/bin/node" --version), expected v$VERSION" >&2; exit 1; }
echo "$DEST/bin"
