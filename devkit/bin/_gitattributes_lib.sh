# shellcheck shell=bash
# Sourced, never run. The root .gitattributes lines that give devkit's merge drivers their paths,
# and the per-clone config that makes git run them. Used by: docs_check.sh (rule 12 reports the
# decisions line missing), hooks_check.sh (--fix adds the lines and sets the config; `make
# install`), merge_drivers_heal's callers (below), templates/new/common/.gitattributes (the
# scaffold's copy, which a bats test holds to these lines).
#
# A driver is per-clone git config, never committed: the lines alone make an unconfigured clone
# merge those paths as text (conflict markers). So every hook (hook_steps.sh), `make install`,
# devkit-sync, devkit-check and the gate (before its merge) set it where it is unset or stale
# (merge_drivers_heal). Why all of them (rollcall #78): a clone installed before a driver existed,
# or before its command changed, text-merged until someone reran `make install`.
# Only local merges and rebases read drivers; GitHub's own merge button does not, so `make merge`
# resolves a decisions conflict itself (bin/_merge_carry.sh), with the same decisions_merge.py.

# docs/decisions.md is append-only, newest last, so two PRs that each add an entry both touch its
# last lines and every rebase of the second conflicted (three on 2026-10-13). Its driver is
# decisions_merge.py --driver: base entries in order, an entry one side edited in its new
# version, both sides' new entries by date, one blank line each. An entry removed, reordered or
# edited on both sides is a person's: the driver exits 1 naming it, and git's text merge leaves
# conflict markers. Why not git's union (its driver 2026-10-13 to
# 2026-10-27): xdiff's zealous merge drops the blank line between two rebased entries (finplat,
# twice), it orders by side, not date, and it merges an edit silently into both versions.
# shellcheck disable=SC2034  # read by the scripts that source this file
DECISIONS_MERGE_LINE='docs/decisions.md merge=devkit-decisions'

# The committed metrics files merge key by key (metrics_ratchet.py merge-driver: why, and the
# rules), not as text: every lane's tighten rewrites them, so parallel lanes conflicted on rebase.
# shellcheck disable=SC2034  # read by the scripts that source this file
METRICS_MERGE_LINES='docs/metrics/ratchet.json merge=devkit-metrics
docs/metrics/report-only.json merge=devkit-metrics
docs/metrics/scorecard.json merge=devkit-metrics'

DEVKIT_MERGE_DRIVERS=(devkit-metrics devkit-decisions)

# decisions_merge_attr <gitattributes file>: the merge= value its lines give docs/decisions.md (or
# /docs/decisions.md), the last one winning as in git; nothing when none does.
decisions_merge_attr() {
  [ -f "$1" ] && awk '
    /^[[:space:]]*#/ { next }
    $1 == "docs/decisions.md" || $1 == "/docs/decisions.md" {
      for (i = 2; i <= NF; i++) if ($i ~ /^merge=/) value = substr($i, 7)
    }
    END { if (value != "") print value }
  ' "$1"
}

# merge_driver_command <driver> <bin dir, relative to the worktree top>: the command. git runs it
# from the worktree's top level and reads the result from %A; a missing or failing driver (an
# older devkit in that tree, a conflict the driver will not settle) falls back to git's own text
# merge.
merge_driver_command() {
  case $1 in
    devkit-metrics) echo "$2/python.sh -I $2/metrics_ratchet.py merge-driver %O %A %B %P || git merge-file -q %A %O %B" ;;
    devkit-decisions) echo "$2/python.sh -I $2/decisions_merge.py --driver %O %A %B || git merge-file -q %A %O %B" ;;
  esac
}

# merge_driver_purpose <driver>: what it does, for its git config name and the heal's line.
merge_driver_purpose() {
  case $1 in
    devkit-metrics) echo "docs/metrics/*.json merge per key" ;;
    devkit-decisions) echo "docs/decisions.md entries merge by date" ;;
  esac
}

# merge_driver_wanted <worktree top> <bin dir> <driver>: the command this clone needs for <bin
# dir> (relative to the top when inside it, so each worktree runs its own copy), or exit 1 when
# no uncommented line of the top's .gitattributes names merge=<driver>.
merge_driver_wanted() {
  local top bin
  [ -f "$1/.gitattributes" ] && awk -v want="merge=$3" '
    /^[[:space:]]*#/ { next }
    { for (i = 2; i <= NF; i++) if ($i == want) found = 1 }
    END { exit !found }
  ' "$1/.gitattributes" || return 1
  # CDPATH= : an exported CDPATH would resolve a relative <bin dir> elsewhere and print it.
  top=$(CDPATH='' cd -P "$1" && pwd) && bin=$(CDPATH='' cd -P "$2" && pwd) || return 1
  merge_driver_command "$3" "${bin#"$top"/}"
}

# merge_drivers_heal <worktree top> <bin dir> <label>: set this clone's merge.<driver> config to
# merge_driver_wanted for every driver its .gitattributes names, where unset or different; one
# "<label>: set ..." line per change, nothing otherwise. Exit 1 when git could not write one.
merge_drivers_heal() {
  local driver want rc=0
  for driver in "${DEVKIT_MERGE_DRIVERS[@]}"; do
    want=$(merge_driver_wanted "$1" "$2" "$driver") || continue
    [ "$(git -C "$1" config --get "merge.$driver.driver" || true)" != "$want" ] || continue
    # The driver first: it is what git runs; a run stopped between the two still merges.
    if git -C "$1" config "merge.$driver.driver" "$want" &&
      git -C "$1" config "merge.$driver.name" "devkit: $(merge_driver_purpose "$driver")"; then
      echo "$3: set merge.$driver.driver ($(merge_driver_purpose "$driver"))"
    else
      rc=1
    fi
  done
  return "$rc"
}
