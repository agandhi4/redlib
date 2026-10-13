#!/usr/bin/env bash
# Guard: the vendored devkit/ tree is exactly what devkit-sync.sh recorded in .devkit-rev.
# Runs in ci-quick; offline, milliseconds. A diff means someone edited devkit/ in this repo.
# Usage: devkit/bin/devkit-check.sh        or: make devkit-check
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
[ -f .devkit-rev ] || { echo "devkit-check: .devkit-rev missing; run make devkit-sync" >&2; exit 1; }
read -r _commit expected < .devkit-rev
# Compare the INDEX tree, not HEAD or the working copy. In CI the index equals HEAD; in the
# pre-commit hook it is exactly what is about to be committed. Comparing HEAD made the
# devkit-sync commit itself fail its own hook (new .devkit-rev vs the old committed tree), and
# let a staged local edit under devkit/ through. Unstaged edits are the hooks' business.
actual=$(git write-tree --prefix=devkit/ 2>/dev/null) || {
  echo "devkit-check: cannot read devkit/ from the index (missing or unmerged); run make devkit-sync" >&2
  exit 1
}
if [ "$actual" != "$expected" ]; then
  echo "devkit-check: devkit/ (tree ${actual:0:7}) differs from the vendored ${expected:0:7}." >&2
  echo "  Change it upstream in agandhi4/devkit, then run: make devkit-sync" >&2
  exit 1
fi
echo "devkit-check: ok (${_commit:0:7})"
