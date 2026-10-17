#!/usr/bin/env bash
# Update the vendored devkit/ to upstream and record what was vendored.
# Usage: devkit/bin/devkit-sync.sh [--stage] [ref]      (default: main)      or: make devkit-sync
#   --stage  replace the tree and stage it with .devkit-rev, but make no commit: the caller's
#            own commit carries the vendoring (devkit-new.sh, whose first commit must hold the
#            whole scaffold and go through the hooks). devkit-check reads the index, so that
#            commit passes its own pre-commit.
#
# How: fetch the upstream ref and REPLACE the devkit/ tree with upstream's tree (read-tree), then
# write .devkit-rev = "<upstream commit> <tree>". No `git subtree pull`: squash-merged PRs drop the
# git-subtree-split trailers it needs to find its base, so every repo's second sync either
# conflicted on byte-identical files or failed with "devkit was never added" (finplat #626,
# Orbit #48, rollcall #38, locus #98, 2026-10-13). Local edits are forbidden anyway
# (devkit-check compares the tree hash), so replacement loses nothing and can never conflict.
# First vendoring works the same way: run this script in a repo without devkit/.
#
# What: only the paths upstream's VENDOR_PATHS lists (bin/, the hook/workflow/metrics templates,
# the docs consumers read), never templates/new/ or tests/ (closet's typecheck compiled the
# scaffolds' .ts sources, #382). The filter is bin/_vendor_paths.sh, shared with devkit-check, and
# .devkit-rev records the FILTERED tree. An upstream ref without VENDOR_PATHS (before
# 2026-10-13) is vendored whole, as before.
#
# Uncommitted changes under devkit/ or to .devkit-rev do not block a sync: it replaces exactly
# those paths. That is the recovery when an older devkit-sync vendored a full tree and the
# pre-commit devkit-check refused its commit: run make devkit-sync again.
#
# Base copies: a file the repo must hold as a byte copy of a vendored base (base_copies in
# bin/_vendor_paths.sh: every tracked .swift-format, and .githooks/<hook> for each template) is
# refreshed from upstream's tree when the repo tracks it and it differs; never created. Without
# this a base change made every consumer's sync commit fail its own devkit-check (or the audit's
# hook-differs) until someone copied the file by hand. It also runs when devkit/ is already
# current, because the first sync to a new base runs the previous, vendored copy of this script.
set -euo pipefail
# shellcheck source=bin/_vendor_paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/_vendor_paths.sh"
readonly DEVKIT_URL=${DEVKIT_URL:-https://github.com/agandhi4/devkit.git}
STAGE=0
REF=
for arg in "$@"; do
  case "$arg" in
    --stage) STAGE=1 ;;
    -*) echo "usage: $0 [--stage] [ref]" >&2; exit 2 ;;
    *) [ -z "$REF" ] || { echo "usage: $0 [--stage] [ref]" >&2; exit 2; }; REF=$arg ;;
  esac
done
REF=${REF:-main}
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
# --stage leaves the sync in the index, so the index may already hold the caller's files; a
# committing sync must start clean or its commit would sweep unrelated staged changes along.
OWN=(-- . ':(exclude)devkit' ':(exclude).devkit-rev')
if [ "$STAGE" = 0 ] && { ! git diff --quiet "${OWN[@]}" || ! git diff --cached --quiet "${OWN[@]}"; }; then
  echo "devkit-sync: commit or stash first; the sync makes its own commit" >&2; exit 2
fi
git fetch -q "$DEVKIT_URL" "$REF"
UPSTREAM=$(git rev-parse FETCH_HEAD)
UPSTREAM_TREE=$(git rev-parse "FETCH_HEAD^{tree}")
if MANIFEST=$(git show FETCH_HEAD:VENDOR_PATHS 2>/dev/null); then
  UPSTREAM_TREE=$(vendor_filter_tree "$UPSTREAM_TREE" "$MANIFEST") || exit 2
fi
CURRENT=0
if [ -f .devkit-rev ] && [ "$(cut -d' ' -f1 .devkit-rev)" = "$UPSTREAM" ] && [ "$(git rev-parse HEAD:devkit 2>/dev/null)" = "$UPSTREAM_TREE" ]; then
  CURRENT=1
else
  # -f: staged leftovers of an interrupted sync are replaced like everything else under devkit/.
  if [ -e devkit ] || git ls-files --error-unmatch devkit >/dev/null 2>&1; then git rm -r -q -f devkit; fi
  git read-tree --prefix=devkit/ -u "$UPSTREAM_TREE"
  printf '%s %s\n' "$UPSTREAM" "$UPSTREAM_TREE" > .devkit-rev
  git add .devkit-rev devkit
fi
# The base comes from upstream's tree, not the index: on the CURRENT path devkit/ may hold
# uncommitted edits, which a sync never vouches for.
REFRESHED=()
while IFS=' ' read -r base copy; do
  [ -n "$base" ] || continue
  blob=$(git rev-parse -q --verify "$UPSTREAM_TREE:$base") || continue # base not in this ref
  [ "$(git rev-parse -q --verify ":$copy")" != "$blob" ] || continue
  git cat-file blob "$blob" >"$copy" # rewrites in place: the file's mode (hooks: +x) is kept
  git add -- "$copy"
  echo "devkit-sync: refreshed $copy from devkit/$base"
  REFRESHED+=("$copy")
done <<<"$(base_copies)"
if [ "$CURRENT" = 1 ]; then
  [ "${#REFRESHED[@]}" -gt 0 ] || { echo "devkit at ${UPSTREAM:0:7} (tree ${UPSTREAM_TREE:0:7}), already current"; exit 0; }
  [ "$STAGE" = 1 ] || git commit -q -m "Refresh devkit base copies to ${UPSTREAM:0:7}" -- "${REFRESHED[@]}"
  echo "devkit at ${UPSTREAM:0:7} (tree ${UPSTREAM_TREE:0:7}), already current; base copies refreshed"; exit 0
fi
if [ "$STAGE" = 1 ]; then
  echo "devkit at ${UPSTREAM:0:7} (tree ${UPSTREAM_TREE:0:7}), staged"; exit 0
fi
NOTE=
[ "${#REFRESHED[@]}" -eq 0 ] || NOTE=$'\n'"Refreshed from the vendored bases: ${REFRESHED[*]}."
git commit -q -m "Update devkit to ${UPSTREAM:0:7}

Vendored tree ${UPSTREAM_TREE:0:7} from $DEVKIT_URL $REF (replaced wholesale; see devkit/bin/devkit-sync.sh).$NOTE"
TREE=$(git rev-parse HEAD:devkit)
[ "$TREE" = "$UPSTREAM_TREE" ] || { echo "devkit-sync: vendored tree $TREE != upstream $UPSTREAM_TREE" >&2; exit 1; }
echo "devkit at ${UPSTREAM:0:7} (tree ${TREE:0:7})"
