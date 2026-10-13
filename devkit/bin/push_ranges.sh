#!/usr/bin/env bash
# Turn git's pre-push stdin into the commit ranges being pushed, one per line, for
# `git log <range>` and `git log --name-only --format= <range>` (the changed files).
# Lifted from finplat's .githooks/pre-push so Orbit and locus do not grow their own copy.
#
# Usage: devkit/bin/push_ranges.sh [remote] < <pre-push stdin>
#   remote defaults to origin; the pre-push hook passes its own $1.
#   stdin lines: <local ref> <local sha> <remote ref> <remote sha>
#   Update:      <remote sha>..<local sha>
#   New branch:  <remote>/main..<local sha> when that ref exists, else the bare <local sha>.
#                The remote has no sha to diff against, so main is the best guess at "already
#                shipped"; with no main at all the whole history is the honest answer.
#   Deletion and tag pushes print nothing: there is no code to check.
#   An update whose remote sha is not in the local object store (a force push from another
#   machine, not yet fetched) is treated as a new branch rather than failing the diff.
# A bare sha means "everything reachable", so `git diff <range>` is wrong for it (that diffs
# against the work tree); use `git log --name-only --format= <range>` for file lists.
# Exit 0, or 2 on usage.
set -euo pipefail

[ $# -le 1 ] || { echo "usage: $0 [remote] < pre-push-stdin" >&2; exit 2; }
REMOTE=${1:-origin}

new_branch_range() { # <local sha>
  if git rev-parse --verify -q "refs/remotes/$REMOTE/main^{commit}" >/dev/null; then
    echo "$REMOTE/main..$1"
  else
    echo "$1"
  fi
}

while read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "${local_ref:-}" ] || continue
  # SHA-256 repos use 64 zeros; compare on the zero pattern, not the length.
  case "$local_sha" in *[!0]*) ;; *) continue ;; esac
  case "$remote_ref" in refs/tags/*) continue ;; esac
  case "$remote_sha" in
    *[!0]*)
      if git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
        echo "$remote_sha..$local_sha"
      else
        new_branch_range "$local_sha"
      fi
      ;;
    *) new_branch_range "$local_sha" ;;
  esac
done
