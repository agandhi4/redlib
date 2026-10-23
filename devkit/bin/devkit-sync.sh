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
# current, the recovery for a repo synced by a copy older than the re-exec below.
#
# Re-exec: this script and the libs it sourced are the PREVIOUS vendored copy, so a new base
# rule or hook template (base_copies) used to land only on the second sync: eight repos needed
# two syncs for .githooks/commit-msg (2026-10-18/19). So once devkit/ is replaced, the script
# execs the freshly vendored devkit/bin/devkit-sync.sh with the same arguments and
# DEVKIT_SYNC_REEXEC=<upstream commit>, which does everything after the fetch with the new code:
# it uses that commit instead of fetching again, and never re-execs a second time. A vendored
# copy older than this rule ignores the variable and syncs again from scratch, which is
# idempotent and does not re-exec either.
#
# A hook copy the repo lacks is created when it already tracks another .githooks/ copy of a
# template (a repo that adopted the hooks gets every hook devkit adds: commit-msg, 2026-10-18),
# executable when its base is; a repo with no .githooks/ gets none.
#
# Merge driver: after vendoring, every path below runs metrics_driver_heal
# (bin/_gitattributes_lib.sh) with the new devkit/bin, so this clone's merge.devkit-metrics.driver
# matches the vendored command without another `make install` (rollcall #78).
#
# Hooks: the sync's commit only vendors (devkit/ at .devkit-rev's tree, base copies), so the
# repo's pre-commit runs none of its steps for it (hook_steps.sh _hook_vendoring_only) and the
# sync commits in a fresh worktree before any install (closet, 2026-10-19).
#
# Trailer: both commits end with devkit_commit_trailer (bin/_trailer_lib.sh: DEVKIT_COMMIT_TRAILER,
# set even empty wins, else `git config devkit.trailer`, else the model-agnostic
# `Co-Authored-By: Claude <noreply@anthropic.com>`). An agent sets the env to the trailer naming
# its own model; the commit-msg hook accepts any Claude trailer, so the default passes it too.
set -euo pipefail
# shellcheck source=bin/_vendor_paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/_vendor_paths.sh"
# shellcheck source=bin/_trailer_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_trailer_lib.sh"
# shellcheck source=bin/_gitattributes_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_gitattributes_lib.sh"
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
TRAILER=$(devkit_commit_trailer)
# commit_sync <message> [-- <paths>...]: the sync's one way to commit, trailer appended.
commit_sync() {
  local message=$1
  shift
  [ -z "$TRAILER" ] || message+=$'\n\n'"$TRAILER"
  git commit -q -m "$message" "$@"
}
if [ -n "${DEVKIT_SYNC_REEXEC:-}" ]; then
  UPSTREAM=$(git rev-parse -q --verify "$DEVKIT_SYNC_REEXEC^{commit}") \
    || { echo "devkit-sync: DEVKIT_SYNC_REEXEC='$DEVKIT_SYNC_REEXEC' is not a commit here" >&2; exit 2; }
else
  git fetch -q "$DEVKIT_URL" "$REF"
  UPSTREAM=$(git rev-parse FETCH_HEAD)
fi
UPSTREAM_TREE=$(vendor_tree_of "$UPSTREAM") || exit 2
CURRENT=0
if [ -f .devkit-rev ] && [ "$(cut -d' ' -f1 .devkit-rev)" = "$UPSTREAM" ] && [ "$(git rev-parse HEAD:devkit 2>/dev/null)" = "$UPSTREAM_TREE" ]; then
  CURRENT=1
else
  # -f: staged leftovers of an interrupted sync are replaced like everything else under devkit/.
  if [ -e devkit ] || git ls-files --error-unmatch devkit >/dev/null 2>&1; then git rm -r -q -f devkit; fi
  git read-tree --prefix=devkit/ -u "$UPSTREAM_TREE"
  printf '%s %s\n' "$UPSTREAM" "$UPSTREAM_TREE" > .devkit-rev
  git add .devkit-rev devkit
  if [ -z "${DEVKIT_SYNC_REEXEC:-}" ] && [ -f devkit/bin/devkit-sync.sh ]; then
    echo "devkit-sync: continuing with the vendored devkit/bin/devkit-sync.sh at ${UPSTREAM:0:7}"
    exec env DEVKIT_SYNC_REEXEC="$UPSTREAM" bash devkit/bin/devkit-sync.sh "$@"
  fi
fi
# The base comes from upstream's tree, not the index: on the CURRENT path devkit/ may hold
# uncommitted edits, which a sync never vouches for. A copy is its base's bytes AND mode, as
# vendoring_only holds it (a chmod -x of a hook copy disables it): a base whose mode changed
# upstream is refreshed too, or the sync it makes was no vendoring-only PR (rollcall #83 Codex).
REFRESHED=()
while IFS=' ' read -r base copy; do
  [ -n "$base" ] || continue
  entry=$(_vendor_entry "$UPSTREAM_TREE" "$base")
  [ -n "$entry" ] || continue # base not in this ref
  [ "$(_vendor_entry "" "$copy")" != "$entry" ] || continue
  verb=refreshed
  [ -e "$copy" ] || verb=created
  git cat-file blob "${entry#* }" >"$copy"
  if [ "${entry%% *}" = 100755 ]; then chmod +x "$copy"; else chmod -x "$copy"; fi
  git add -- "$copy"
  echo "devkit-sync: $verb $copy from devkit/$base"
  REFRESHED+=("$copy")
done <<<"$(base_copies)"
metrics_driver_heal "$ROOT" "$ROOT/devkit/bin" devkit-sync \
  || echo "devkit-sync: cannot set merge.devkit-metrics.driver (git above); make install sets it" >&2
if [ "$CURRENT" = 1 ]; then
  [ "${#REFRESHED[@]}" -gt 0 ] || { echo "devkit at ${UPSTREAM:0:7} (tree ${UPSTREAM_TREE:0:7}), already current"; exit 0; }
  [ "$STAGE" = 1 ] || commit_sync "Refresh devkit base copies to ${UPSTREAM:0:7}" -- "${REFRESHED[@]}"
  echo "devkit at ${UPSTREAM:0:7} (tree ${UPSTREAM_TREE:0:7}), already current; base copies refreshed"; exit 0
fi
if [ "$STAGE" = 1 ]; then
  echo "devkit at ${UPSTREAM:0:7} (tree ${UPSTREAM_TREE:0:7}), staged"; exit 0
fi
NOTE=
[ "${#REFRESHED[@]}" -eq 0 ] || NOTE=$'\n'"Refreshed from the vendored bases: ${REFRESHED[*]}."
commit_sync "Update devkit to ${UPSTREAM:0:7}

Vendored tree ${UPSTREAM_TREE:0:7} from $DEVKIT_URL $REF (replaced wholesale; see devkit/bin/devkit-sync.sh).$NOTE"
TREE=$(git rev-parse HEAD:devkit)
[ "$TREE" = "$UPSTREAM_TREE" ] || { echo "devkit-sync: vendored tree $TREE != upstream $UPSTREAM_TREE" >&2; exit 1; }
echo "devkit at ${UPSTREAM:0:7} (tree ${TREE:0:7})"
