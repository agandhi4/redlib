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
#   is the repo's own tooling's). Exit 0 ok, 1 cannot provide (a download or install failure),
#   2 usage, 3 the tree's own fault (a package.json that is no JSON, two declarations that
#   disagree, a malformed or inexact one, a declared hash the tarball does not match):
#   check_tree.sh calls that commit red.
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
bad_decl() { echo "package_manager_toolchain: $*" >&2; exit 3; }

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
# Exit 3 only for a file that is no JSON object (the tree's); a Python that cannot run is the box's.
RC=0
DECLS=$(cd "$ROOT" && "$DEVKIT_PYTHON" -I -c '
import json, sys
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
    except ValueError as e:  # JSONDecodeError and UnicodeDecodeError are ValueErrors
        print(f"{path}: {e}", file=sys.stderr)
        sys.exit(3)
    value = data.get("packageManager")
    if isinstance(value, str) and value:
        print(f"{path}\t{value}")
' "${FILES[@]}") || RC=$?
case $RC in
  0) ;;
  3) bad_decl "cannot read packageManager from ${FILES[*]} (above)" ;;
  *) fail "cannot run $DEVKIT_PYTHON to read packageManager from ${FILES[*]} (exit $RC)" ;;
esac
[ -n "$DECLS" ] || exit 0
if [ "$(printf '%s\n' "$DECLS" | cut -f2 | sort -u | wc -l | tr -d ' ')" -gt 1 ]; then
  bad_decl "package.json files declare different package managers ($(printf '%s\n' "$DECLS" | tr '\t' ' ' | paste -sd, - | sed 's/,/, /g')); one version per toolchain per repo"
fi
FILE=$(printf '%s\n' "$DECLS" | head -n 1 | cut -f1)
DECL=$(printf '%s\n' "$DECLS" | head -n 1 | cut -f2)

[[ "$DECL" =~ ^([a-z]+)@([^+]*)(\+(sha1|sha224|sha256|sha384|sha512)\.([0-9a-f]+))?$ ]] \
  || bad_decl "$FILE packageManager '$DECL' is not <name>@<version>[+<algo>.<hex>]"
NAME=${BASH_REMATCH[1]} VERSION=${BASH_REMATCH[2]} ALGO=${BASH_REMATCH[4]} HASH=${BASH_REMATCH[5]}
# Another manager is the repo's own tooling's (npm comes with Node): provided by nothing here,
# and no failure, so a hook or job that never calls it still runs.
if [ "$NAME" != pnpm ]; then
  echo "package_manager_toolchain: $FILE declares $NAME; only pnpm is provided, so PATH's $NAME runs" >&2
  exit 0
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
  || bad_decl "$FILE packageManager must hold an exact version (got '$VERSION')"

# hash_ok <tarball>: true when it matches the declared +<algo>.<hex> (none declared passes);
# ACTUAL is its digest.
hash_ok() {
  [ -n "$ALGO" ] || return 0
  local bits=${ALGO#sha} digest
  if command -v "sha${bits}sum" >/dev/null; then digest=("sha${bits}sum"); else digest=(shasum -a "$bits"); fi
  ACTUAL=$("${digest[@]}" "$1" | awk '{print $1}')
  [ "$ACTUAL" = "$HASH" ]
}

STORE="${XDG_DATA_HOME:-$HOME/.local/share}/devkit/pnpm"
DEST="$STORE/$VERSION"
# The install keeps its tarball, so a hash declared after the cache was filled is still checked.
# A stored tarball that does not match is either side's fault: the registry's own tarball, which
# npm checks against the registry's integrity, decides (a damaged store is the box's, exit 1).
STORED=''
if [ -x "$DEST/bin/pnpm" ]; then
  if hash_ok "$DEST/pnpm.tgz"; then echo "$DEST/bin"; exit 0; fi
  STORED=$ACTUAL
  [ "${DEVKIT_OFFLINE:-0}" != 1 ] \
    || fail "the stored $DEST/pnpm.tgz is $ALGO.$STORED, not $FILE's $ALGO.$HASH, and DEVKIT_OFFLINE=1 cannot fetch the registry's to tell which is wrong"
fi

[ "${DEVKIT_OFFLINE:-0}" = 1 ] && fail "pnpm $VERSION not cached at $DEST and DEVKIT_OFFLINE=1"
command -v npm >/dev/null || fail "npm not found (it comes with the pinned Node)"
mkdir -p "$STORE"
# In the store, so the final mv is a rename on one filesystem.
TMP=$(mktemp -d "$STORE/.install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
[ -n "$STORED" ] || echo "package_manager_toolchain: installing pnpm $VERSION (declared in $FILE)" >&2
PACKED=$(cd "$TMP" && npm pack "pnpm@$VERSION" --pack-destination "$TMP" --json --silent) \
  || fail "npm pack pnpm@$VERSION failed"
TARBALL=$(printf '%s' "$PACKED" | "$DEVKIT_PYTHON" -I -c 'import json, sys; print(json.load(sys.stdin)[0]["filename"])') \
  || fail "npm pack pnpm@$VERSION printed no filename"
[ -f "$TMP/$TARBALL" ] || fail "npm pack pnpm@$VERSION wrote no $TARBALL"
hash_ok "$TMP/$TARBALL" \
  || bad_decl "checksum mismatch for pnpm $VERSION: $FILE declares $ALGO.$HASH, the registry's tarball is $ALGO.$ACTUAL"
[ -z "$STORED" ] \
  || fail "the stored $DEST/pnpm.tgz is damaged ($ALGO.$STORED; the registry's matches $FILE's $ALGO.$HASH): remove $DEST and rerun"
(cd "$TMP" && npm install --global --prefix "$TMP/pnpm" --offline --ignore-scripts --no-audit --no-fund --silent "./$TARBALL") \
  || fail "npm install of $TARBALL failed"
GOT=$(cd "$TMP" && "$TMP/pnpm/bin/pnpm" --version) || fail "the installed pnpm does not run"
[ "$GOT" = "$VERSION" ] || fail "installed pnpm reports $GOT, expected $VERSION"
mv "$TMP/$TARBALL" "$TMP/pnpm/pnpm.tgz"
# One rename, so DEST is absent or whole. Another install of this version may land first (a hook
# beside a check): its DEST is kept, never deleted under a running pnpm, and mv, finding a
# directory there, nests ours inside it, which is removed. A third finds that nest still there
# and fails to move (devkit #319): the install already in place is as good.
mv "$TMP/pnpm" "$DEST" 2>/dev/null || [ -x "$DEST/bin/pnpm" ] || fail "cannot move pnpm $VERSION into $DEST"
rm -rf "$DEST/pnpm"
[ -x "$DEST/bin/pnpm" ] || fail "$DEST holds no bin/pnpm; remove it and rerun"
echo "$DEST/bin"
