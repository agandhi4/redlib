# shellcheck shell=bash
# Sourced, never run. The root .gitattributes line every repo carries for its decisions log.
# Used by: docs_check.sh (rule 12 reports it missing), hooks_check.sh --fix (adds it; `make
# install`), templates/new/common/.gitattributes (the scaffold's copy, which a bats test holds to
# DECISIONS_UNION_LINE).
#
# Why: docs/decisions.md is append-only, newest last, so two PRs that each add an entry both
# touch its last lines and every rebase of the second conflicted (three on 2026-10-13). git's
# built-in union driver keeps both sides' added lines instead: the base branch's entry first,
# then the rebased PR's. It never leaves conflict markers, so the caveat is the other way round:
# an EDIT of the same lines on both sides merges silently into both versions, out of place. Such
# edits are rare in an append-only log; docs_check rule 8 (dated H2s in order, each with
# Why/Decision/Consequence) catches most mangles, and review the merged entry.
# Only local merges and rebases read .gitattributes drivers; GitHub's own merge button does not.
# shellcheck disable=SC2034  # read by the scripts that source this file
DECISIONS_UNION_LINE='docs/decisions.md merge=union'

# has_decisions_union <gitattributes file>: true when a line gives docs/decisions.md (or
# /docs/decisions.md) the union driver, whatever other attributes sit beside it.
has_decisions_union() {
  [ -f "$1" ] && awk '
    /^[[:space:]]*#/ { next }
    $1 == "docs/decisions.md" || $1 == "/docs/decisions.md" {
      for (i = 2; i <= NF; i++) if ($i == "merge=union") found = 1
    }
    END { exit !found }
  ' "$1"
}
