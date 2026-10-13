#!/usr/bin/env bash
# Update the vendored devkit/ to upstream and record what was vendored.
# Usage: devkit/bin/devkit-sync.sh [ref]      (default: main)      or: make devkit-sync
#
# How: fetch the upstream ref and REPLACE the devkit/ tree with upstream's tree (read-tree), then
# write .devkit-rev = "<upstream commit> <tree>". No `git subtree pull`: squash-merged PRs drop the
# git-subtree-split trailers it needs to find its base, so every repo's second sync either
# conflicted on byte-identical files or failed with "devkit was never added" (finplat #626,
# Orbit #48, rollcall #38, locus #98, 2026-10-13). Local edits are forbidden anyway
# (devkit-check compares the tree hash), so replacement loses nothing and can never conflict.
# First vendoring works the same way: run this script in a repo without devkit/.
set -euo pipefail
readonly DEVKIT_URL=${DEVKIT_URL:-https://github.com/agandhi4/devkit.git}
REF=${1:-main}
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "devkit-sync: commit or stash first; the sync makes its own commit" >&2; exit 2
fi
git fetch -q "$DEVKIT_URL" "$REF"
UPSTREAM=$(git rev-parse FETCH_HEAD)
UPSTREAM_TREE=$(git rev-parse "FETCH_HEAD^{tree}")
if [ -f .devkit-rev ] && [ "$(cut -d' ' -f1 .devkit-rev)" = "$UPSTREAM" ] && [ "$(git rev-parse HEAD:devkit 2>/dev/null)" = "$UPSTREAM_TREE" ]; then
  echo "devkit at ${UPSTREAM:0:7} (tree ${UPSTREAM_TREE:0:7}), already current"; exit 0
fi
[ -e devkit ] && git rm -r -q devkit
git read-tree --prefix=devkit/ -u "$UPSTREAM_TREE"
printf '%s %s\n' "$UPSTREAM" "$UPSTREAM_TREE" > .devkit-rev
git add .devkit-rev devkit
git commit -q -m "Update devkit to ${UPSTREAM:0:7}

Vendored tree ${UPSTREAM_TREE:0:7} from $DEVKIT_URL $REF (replaced wholesale; see devkit/bin/devkit-sync.sh)."
TREE=$(git rev-parse HEAD:devkit)
[ "$TREE" = "$UPSTREAM_TREE" ] || { echo "devkit-sync: vendored tree $TREE != upstream $UPSTREAM_TREE" >&2; exit 1; }
echo "devkit at ${UPSTREAM:0:7} (tree ${TREE:0:7})"
