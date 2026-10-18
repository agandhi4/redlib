#!/usr/bin/env bash
# Install the devkit gh shim on this machine: a `gh` ahead of the real one on PATH that refuses
# `gh pr merge` unless DEVKIT_MERGE_VERIFIED equals its --match-head-commit value, and passes
# every other call to the real gh unchanged.
#
# Why (owner, 2026-10-18): no paid GitHub features, so nothing on GitHub requires the gate.
# `make merge PR=<n>` (bin/pr_merge.sh) checks the head's local-gate success and sets
# DEVKIT_MERGE_VERIFIED=<head> for its one `gh pr merge --match-head-commit <head>` call; the
# shim makes that the only merge that works from this machine. The scorecard's WIRED reads
# `gh_shim` from the marker line below in the first gh on PATH.
#
# Usage: bin/install_gh_shim.sh [--dir DIR] | --check
#   --check  exit 0 when the first gh on PATH is the shim, else 1; one line either way (the
#            scorecard's WIRED gh_shim reads it, so the marker has one definition)
#   Writes DIR/gh (default: ~/.local/bin when it is on PATH ahead of the real gh, else the first
#   writable PATH directory ahead of it) and prints what it did. Rewrites an existing shim;
#   never overwrites any other file. Exit 0 installed, 1 refused, 2 usage or no real gh.
# The real gh is found at run time (`type -ap gh`, bash's `command -v -a`), skipping the shim
# itself and any other file carrying the marker, so a brew upgrade that moves gh needs no
# reinstall and the shim can never exec itself.
set -euo pipefail

readonly MARKER="# devkit-gh-shim: refuses unverified pr merge (devkit bin/install_gh_shim.sh)"

usage() { echo "usage: $0 [--dir DIR] | --check"; }
DIR=""
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || { usage >&2; exit 2; }; DIR=$2; shift ;;
    --check) CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

is_shim() { [ -f "$1" ] && head -n 3 "$1" 2>/dev/null | grep -qF "$MARKER"; }

real_gh() { # the first gh on PATH that is not a shim
  local c
  while IFS= read -r c; do
    is_shim "$c" || { printf '%s\n' "$c"; return 0; }
  done < <(type -ap gh)
  return 1
}

if [ "$CHECK" = 1 ]; then
  first=$(type -P gh) || { echo "gh-shim: no gh on PATH"; exit 1; }
  if is_shim "$first"; then echo "gh-shim: installed at $first"; exit 0; fi
  echo "gh-shim: the first gh on PATH is $first, not the shim (bin/install_gh_shim.sh)"
  exit 1
fi

REAL=$(real_gh) || { echo "install_gh_shim: no real gh on PATH (brew install gh)" >&2; exit 2; }
REAL_DIR=$(cd "$(dirname "$REAL")" && pwd -P)

current=$(type -P gh)
if [ -z "$DIR" ] && is_shim "$current"; then
  DIR=$(dirname "$current")  # reinstall in place
fi
if [ -z "$DIR" ]; then
  # The first PATH directory ahead of the real gh's: ~/.local/bin when it is one, else the first
  # writable one. None means PATH must change, which this script will not do for you.
  local_bin=$HOME/.local/bin
  first=""
  candidates=()
  IFS=: read -r -a candidates <<<"$PATH"
  for d in ${candidates[@]+"${candidates[@]}"}; do
    [ -n "$d" ] || continue
    if [ -d "$d" ] && [ "$(cd "$d" && pwd -P)" = "$REAL_DIR" ]; then break; fi
    if [ "$d" = "$local_bin" ]; then first=$d; break; fi
    if [ -z "$first" ] && [ -d "$d" ] && [ -w "$d" ]; then first=$d; fi
  done
  [ -n "$first" ] || {
    echo "install_gh_shim: no writable PATH directory ahead of $REAL; put ~/.local/bin first in PATH, or pass --dir" >&2
    exit 1
  }
  DIR=$first
fi

TARGET=$DIR/gh
if [ -e "$TARGET" ] && ! is_shim "$TARGET"; then
  echo "install_gh_shim: refused: $TARGET exists and is not the devkit shim (the real gh?); pass --dir" >&2
  exit 1
fi
mkdir -p "$DIR"
tmp=$(mktemp "$DIR/.gh.XXXXXX")
cat >"$tmp" <<SHIM
#!/usr/bin/env bash
$MARKER
# Generated; edit bin/install_gh_shim.sh in devkit and reinstall instead.
set -uo pipefail
self=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd -P)/\$(basename "\${BASH_SOURCE[0]}")
real=""
while IFS= read -r c; do
  [ "\$c" -ef "\$self" ] && continue
  head -n 3 "\$c" 2>/dev/null | grep -qF "$MARKER" && continue
  real=\$c; break
done < <(type -ap gh)
[ -n "\$real" ] || { echo "gh (devkit shim): no real gh on PATH (brew install gh)" >&2; exit 127; }
if [ "\${1:-}" = pr ] && [ "\${2:-}" = merge ]; then
  head_arg=""
  prev=""
  for a in "\$@"; do
    case "\$a" in --match-head-commit=*) head_arg=\${a#--match-head-commit=} ;; esac
    [ "\$prev" = --match-head-commit ] && head_arg=\$a
    prev=\$a
  done
  if [ -z "\$head_arg" ] || [ "\${DEVKIT_MERGE_VERIFIED:-}" != "\$head_arg" ]; then
    echo "gh (devkit shim): refused \\\`gh pr merge\\\`: merge with \\\`make merge PR=<n>\\\`, which checks the head's local-gate success (DEVKIT_MERGE_VERIFIED must equal --match-head-commit)" >&2
    exit 1
  fi
fi
exec "\$real" "\$@"
SHIM
chmod 755 "$tmp"
mv -f "$tmp" "$TARGET"
echo "install_gh_shim: wrote $TARGET (real gh: $REAL)"
resolved=$(type -P gh)
if [ "$resolved" != "$TARGET" ]; then
  echo "install_gh_shim: WARNING: \`gh\` on this PATH resolves to $resolved, not the shim; put $DIR ahead of it" >&2
fi
