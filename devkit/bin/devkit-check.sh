#!/usr/bin/env bash
# Guard: the vendored devkit/ tree is exactly what devkit-sync.sh recorded in .devkit-rev.
# Runs in ci-quick; offline, milliseconds. A diff means someone edited devkit/ in this repo.
# Usage: devkit/bin/devkit-check.sh        or: make devkit-check
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
[ -f .devkit-rev ] || { echo "devkit-check: .devkit-rev missing; run make devkit-sync" >&2; exit 1; }
read -r _commit expected < .devkit-rev
# Compare the committed tree, not the working copy: a dirty working tree is the hooks' business.
actual=$(git rev-parse HEAD:devkit)
if [ "$actual" != "$expected" ]; then
  echo "devkit-check: devkit/ (tree ${actual:0:7}) differs from the vendored ${expected:0:7}." >&2
  echo "  Change it upstream in agandhi4/devkit, then run: make devkit-sync" >&2
  exit 1
fi
echo "devkit-check: ok (${_commit:0:7})"
