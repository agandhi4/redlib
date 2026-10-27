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
# Only local merges and rebases read .gitattributes drivers; GitHub's own merge button does not,
# so `make merge` resolves that conflict itself (bin/_merge_carry.sh, decisions_merge.py, which
# also keeps the blank line between entries that this driver's zealous merge drops). A hand
# rebase still goes through union: check the blank line before the rebased entry.
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

# The committed metrics files merge key by key (metrics_ratchet.py merge-driver: why, and the
# rules), not as text: every lane's tighten rewrites them, so parallel lanes conflicted on rebase.
# A driver is per-clone git config, never committed, so hooks_check.sh --fix sets both halves:
# these lines and merge.devkit-metrics.driver (metrics_driver_heal, which the hooks and
# devkit-sync also run). A clone without the config merges them as text.
# shellcheck disable=SC2034  # read by the scripts that source this file
METRICS_MERGE_LINES='docs/metrics/ratchet.json merge=devkit-metrics
docs/metrics/report-only.json merge=devkit-metrics
docs/metrics/scorecard.json merge=devkit-metrics'

# metrics_merge_driver <bin dir, relative to the worktree top>: the driver command. git runs it
# from the worktree's top level; a missing or failing driver (an older devkit in that tree, two
# sides that changed one key's direction) falls back to git's own text merge.
metrics_merge_driver() {
  echo "$1/python.sh -I $1/metrics_ratchet.py merge-driver %O %A %B %P || git merge-file -q %A %O %B"
}

# metrics_driver_wanted <worktree top> <bin dir>: the driver command this clone needs for <bin
# dir> (relative to the top when inside it, so each worktree runs its own copy), or exit 1 when
# the top's .gitattributes names no merge=devkit-metrics.
metrics_driver_wanted() {
  local top bin
  grep -qs 'merge=devkit-metrics' "$1/.gitattributes" || return 1
  # CDPATH= : an exported CDPATH would resolve a relative <bin dir> elsewhere and print it.
  top=$(CDPATH='' cd -P "$1" && pwd) && bin=$(CDPATH='' cd -P "$2" && pwd) || return 1
  metrics_merge_driver "${bin#"$top"/}"
}

# metrics_driver_heal <worktree top> <bin dir> <label>: set this clone's merge.devkit-metrics
# config to metrics_driver_wanted when it is unset or differs; one "<label>: set ..." line when it
# changed, nothing otherwise. Used by: hooks_check.sh --fix, every hook (hook_steps.sh) and
# devkit-sync.sh. Why all three (rollcall #78): the config is per clone, so a clone installed
# before the driver existed, or before its command changed, text-merged docs/metrics/*.json
# until someone reran `make install`; a commit or a sync now heals it.
metrics_driver_heal() {
  local want
  want=$(metrics_driver_wanted "$1" "$2") || return 0
  [ "$(git -C "$1" config --get merge.devkit-metrics.driver || true)" != "$want" ] || return 0
  # The driver first: it is what git runs; a run stopped between the two still merges per key.
  git -C "$1" config merge.devkit-metrics.driver "$want" &&
    git -C "$1" config merge.devkit-metrics.name "devkit metrics bounds, per key" &&
    echo "$3: set merge.devkit-metrics.driver (docs/metrics/*.json merge per key)"
}
