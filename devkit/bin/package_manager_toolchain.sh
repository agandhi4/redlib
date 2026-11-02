#!/usr/bin/env bash
# Provide the exact package manager a tree's package.json `packageManager` field declares
# (pnpm@10.32.1, optionally +sha512.<hex>), so a recipe's bare `pnpm` is that version on every
# machine. Why (2026-11-02, finplat #737): Node 25 and later ship no corepack, and node_toolchain.sh
# installs nodejs.org's tarball, so `corepack pnpm` worked on the Mac only through Homebrew's
# corepack and failed on linux-box (exit 127) in every frontend job. packageManager is the one pin.
#
# Usage: devkit/bin/package_manager_toolchain.sh <repo-root>
#   Prints the bin directory to prepend to PATH (holding pnpm and pnpx), or nothing when no tracked
#   package.json declares packageManager, or it names another manager (one stderr line: that
#   is the repo's own tooling's). Exit 0 ok, 1 cannot provide (two declarations that disagree, an
#   inexact version, a download or checksum failure), 2 usage.
#
# Called by toolchain_path.sh after Node, so the npm that installs it is the pinned Node's. Installs
# land in $XDG_DATA_HOME/devkit/pnpm/<ver> (default ~/.local/share/devkit/pnpm): `npm pack`
# fetches the registry tarball (npm checks it against the registry's integrity), a declared
# +<algo>.<hex> is checked against the tarball as corepack would, and `npm install --global
# --prefix` from that tarball, offline and without scripts, lays out bin/pnpm. The tarball is kept
# (<ver>/pnpm.tgz), so a hash declared after the cache was filled is checked on every use. A PATH pnpm is never
# used: it may be a corepack shim or another version, and the store answers without running one.
# Declarations are read from tracked package.json files outside devkit/ (git ls-files), with
# devkit's python3; a tree with none costs one git call and a grep.
# DEVKIT_OFFLINE=1 refuses to download and fails loudly when the cache is cold.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <repo-root>" >&2; exit 2; }
ROOT=$1
HERE=$(dirname "${BASH_SOURCE[0]}")
fail() { echo "package_manager_toolchain: $*" >&2; exit 1; }

FILES=()
while IFS= read -r f; do
  case "$f" in devkit/* | node_modules/* | */node_modules/*) continue ;; esac
  grep -q '"packageManager"' "$ROOT/$f" 2>/dev/null && FILES+=("$f")
done < <(git -C "$ROOT" ls-files -- package.json '*/package.json' 2>/dev/null)
[ ${#FILES[@]} -gt 0 ] || exit 0

# shellcheck source=bin/_toolchain_lib.sh
. "$HERE/_toolchain_lib.sh"
devkit_python || fail "$DEVKIT_PYTHON_ERROR"

# "<file>\t<declaration>" per file that declares one; json decides, the grep above only narrows.
DECLS=$(cd "$ROOT" && "$DEVKIT_PYTHON" -I -c '
import json, sys
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        value = json.load(f).get("packageManager")
    if isinstance(value, str) and value:
        print(f"{path}\t{value}")
' "${FILES[@]}") || fail "cannot read packageManager from ${FILES[*]}"
[ -n "$DECLS" ] || exit 0
if [ "$(printf '%s\n' "$DECLS" | cut -f2 | sort -u | wc -l | tr -d ' ')" -gt 1 ]; then
  fail "package.json files declare different package managers ($(printf '%s\n' "$DECLS" | tr '\t' ' ' | paste -sd, - | sed 's/,/, /g')); one version per toolchain per repo"
fi
FILE=$(printf '%s\n' "$DECLS" | head -n 1 | cut -f1)
DECL=$(printf '%s\n' "$DECLS" | head -n 1 | cut -f2)

[[ "$DECL" =~ ^([a-z]+)@([^+]*)(\+(sha1|sha224|sha256|sha384|sha512)\.([0-9a-f]+))?$ ]] \
  || fail "$FILE packageManager '$DECL' is not <name>@<version>[+<algo>.<hex>]"
NAME=${BASH_REMATCH[1]} VERSION=${BASH_REMATCH[2]} ALGO=${BASH_REMATCH[4]} HASH=${BASH_REMATCH[5]}
# Another manager is the repo's own tooling's (npm comes with Node): provided by nothing here,
# and no failure, so a hook or job that never calls it still runs.
if [ "$NAME" != pnpm ]; then
  echo "package_manager_toolchain: $FILE declares $NAME; only pnpm is provided, so PATH's $NAME runs" >&2
  exit 0
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
  || fail "$FILE packageManager must hold an exact version (got '$VERSION')"

# check_hash <tarball>: fail unless it matches the declared +<algo>.<hex>; none declared passes.
check_hash() {
  [ -n "$ALGO" ] || return 0
  local bits=${ALGO#sha} digest actual
  if command -v "sha${bits}sum" >/dev/null; then digest=("sha${bits}sum"); else digest=(shasum -a "$bits"); fi
  actual=$("${digest[@]}" "$1" | awk '{print $1}')
  [ "$actual" = "$HASH" ] || fail "checksum mismatch for pnpm $VERSION: $FILE declares $ALGO.$HASH, the tarball is $ALGO.$actual"
}

STORE="${XDG_DATA_HOME:-$HOME/.local/share}/devkit/pnpm"
DEST="$STORE/$VERSION"
# The install keeps its tarball, so a hash declared after the cache was filled is still checked.
if [ -x "$DEST/bin/pnpm" ]; then
  check_hash "$DEST/pnpm.tgz"
  echo "$DEST/bin"; exit 0
fi

[ "${DEVKIT_OFFLINE:-0}" = 1 ] && fail "pnpm $VERSION not cached at $DEST and DEVKIT_OFFLINE=1"
command -v npm >/dev/null || fail "npm not found (it comes with the pinned Node)"
mkdir -p "$STORE"
# In the store, so the final mv is a rename on one filesystem.
TMP=$(mktemp -d "$STORE/.install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
echo "package_manager_toolchain: installing pnpm $VERSION (declared in $FILE)" >&2
PACKED=$(cd "$TMP" && npm pack "pnpm@$VERSION" --pack-destination "$TMP" --json --silent) \
  || fail "npm pack pnpm@$VERSION failed"
TARBALL=$(printf '%s' "$PACKED" | "$DEVKIT_PYTHON" -I -c 'import json, sys; print(json.load(sys.stdin)[0]["filename"])') \
  || fail "npm pack pnpm@$VERSION printed no filename"
[ -f "$TMP/$TARBALL" ] || fail "npm pack pnpm@$VERSION wrote no $TARBALL"
check_hash "$TMP/$TARBALL"
(cd "$TMP" && npm install --global --prefix "$TMP/pnpm" --offline --ignore-scripts --no-audit --no-fund --silent "./$TARBALL") \
  || fail "npm install of $TARBALL failed"
GOT=$(cd "$TMP" && "$TMP/pnpm/bin/pnpm" --version) || fail "the installed pnpm does not run"
[ "$GOT" = "$VERSION" ] || fail "installed pnpm reports $GOT, expected $VERSION"
mv "$TMP/$TARBALL" "$TMP/pnpm/pnpm.tgz"
# One rename, so DEST is absent or whole. Another install of this version may land first (a hook
# beside a check): its DEST is kept, never deleted under a running pnpm, and mv, finding a
# directory there, nests ours inside it, which is removed.
mv "$TMP/pnpm" "$DEST"
rm -rf "$DEST/pnpm"
[ -x "$DEST/bin/pnpm" ] || fail "$DEST holds no bin/pnpm; remove it and rerun"
echo "$DEST/bin"
