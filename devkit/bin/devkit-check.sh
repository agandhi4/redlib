#!/usr/bin/env bash
# Guard: the vendored devkit/ tree is exactly what devkit-sync.sh recorded in .devkit-rev.
# Runs in ci-quick; offline, milliseconds. A diff means someone edited devkit/ in this repo.
# Usage: devkit/bin/devkit-check.sh        or: make devkit-check
#
# Also: a tree that matches .devkit-rev but holds paths outside its own VENDOR_PATHS was vendored
# whole by a devkit-sync older than the manifest (the first `make devkit-sync` after 2026-10-13
# runs the old script). Rerunning make devkit-sync, now the new script, slims it.
#
# Also: every tracked .swift-format must equal devkit/lint/swift-format.json byte for byte.
set -euo pipefail
# shellcheck source=bin/_vendor_paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/_vendor_paths.sh"
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
# Both sides come from the INDEX, not HEAD or the working copy. In CI the index equals HEAD; in
# the pre-commit hook it is exactly what is about to be committed. Comparing HEAD made the
# devkit-sync commit itself fail its own hook (new .devkit-rev vs the old committed tree), and
# let a staged local edit under devkit/ through. Reading .devkit-rev from disk let an unstaged
# edit to it vouch for a staged devkit/ tree it would never be committed with. Unstaged edits
# are the hooks' business.
rev=$(git show :.devkit-rev 2>/dev/null) || {
  echo "devkit-check: .devkit-rev missing from the index; run make devkit-sync" >&2
  exit 1
}
read -r _commit expected <<<"$rev"
actual=$(git write-tree --prefix=devkit/ 2>/dev/null) || {
  echo "devkit-check: cannot read devkit/ from the index (missing or unmerged); run make devkit-sync" >&2
  exit 1
}
if [ "$actual" != "$expected" ]; then
  echo "devkit-check: devkit/ (tree ${actual:0:7}) differs from the vendored ${expected:0:7}." >&2
  echo "  Change it upstream in agandhi4/devkit, then run: make devkit-sync" >&2
  exit 1
fi
if manifest=$(git show :devkit/VENDOR_PATHS 2>/dev/null); then
  slim=$(vendor_filter_tree "$actual" "$manifest") || exit 1
  if [ "$slim" != "$actual" ]; then
    echo "devkit-check: devkit/ holds paths outside devkit/VENDOR_PATHS (vendored whole by an older devkit-sync)." >&2
    echo "  Run: make devkit-sync   (again, if you just ran it: the new script is now in place)" >&2
    exit 1
  fi
fi
# swift-format has no `extends`, so a repo's .swift-format (root or nested, e.g. ios/) is a copy of
# devkit/lint/swift-format.json and this is what keeps the copies one base. Index blobs, like the
# tree check: equal blob ids are equal bytes.
base_blob=
copies=0
while IFS= read -r copy; do
  [ -n "$copy" ] || continue
  if [ -z "$base_blob" ]; then
    base_blob=$(git rev-parse -q --verify ":devkit/lint/swift-format.json" 2>/dev/null) || {
      echo "devkit-check: $copy exists but devkit/lint/swift-format.json does not; run make devkit-sync" >&2
      exit 1
    }
  fi
  if [ "$(git rev-parse ":$copy")" != "$base_blob" ]; then
    echo "devkit-check: $copy differs from devkit/lint/swift-format.json (swift-format has no extends; the repo file is a copy)." >&2
    echo "  Restore it: cp devkit/lint/swift-format.json $copy   A rule change goes upstream in agandhi4/devkit." >&2
    copies=$((copies + 1))
  fi
done <<<"$(swift_format_copies)"
[ "$copies" -eq 0 ] || exit 1
echo "devkit-check: ok (${_commit:0:7})"
