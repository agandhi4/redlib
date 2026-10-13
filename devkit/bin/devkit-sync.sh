#!/usr/bin/env bash
# Update the vendored devkit/ subtree to upstream and record what was vendored.
# Usage: devkit/bin/devkit-sync.sh [ref]      (default: main)      or: make devkit-sync
#
# Writes .devkit-rev at the repo root: "<upstream commit> <upstream tree>". devkit-check.sh
# compares the vendored tree against it offline, so an in-repo edit to devkit/ fails
# quick-check and must be made upstream instead (standardization rule: nothing lives in only
# one repo). First vendoring: `git subtree add --prefix=devkit $DEVKIT_URL main --squash`, then
# run this script once to write .devkit-rev.
set -euo pipefail
readonly DEVKIT_URL=${DEVKIT_URL:-https://github.com/agandhi4/devkit.git}
REF=${1:-main}
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
[ -d devkit ] || { echo "devkit-sync: no devkit/ subtree here; vendor it first (see header)" >&2; exit 2; }
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "devkit-sync: commit or stash first; subtree pull needs a clean tree" >&2; exit 2
fi
git subtree pull --prefix=devkit "$DEVKIT_URL" "$REF" --squash -m "Update devkit subtree to $REF"
# The vendored commit is the `git-subtree-split` trailer of the newest squash commit for this
# prefix, which is what the pull actually merged. A second ls-remote here recorded a commit the
# tree did not contain when upstream moved mid-run (finplat #609).
UPSTREAM=$(git log -1 --grep='^git-subtree-dir: devkit$' --format=%B | sed -n 's/^git-subtree-split: //p')
[ -n "$UPSTREAM" ] || { echo "devkit-sync: no git-subtree-split trailer found for devkit/" >&2; exit 1; }
TREE=$(git rev-parse HEAD:devkit)
printf '%s %s\n' "$UPSTREAM" "$TREE" > .devkit-rev
git add .devkit-rev
git commit -q -m "Record devkit ${UPSTREAM:0:7} in .devkit-rev" || true
echo "devkit at ${UPSTREAM:0:7} (tree ${TREE:0:7})"
