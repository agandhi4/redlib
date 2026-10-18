#!/usr/bin/env bash
# Guard: the vendored devkit/ tree is exactly what devkit-sync.sh recorded in .devkit-rev.
# Runs in ci-quick; offline, milliseconds. A diff means someone edited devkit/ in this repo.
# Usage: devkit/bin/devkit-check.sh [--staged]        or: make devkit-check
#
# Also: a tree that matches .devkit-rev but holds paths outside its own VENDOR_PATHS was vendored
# whole by a devkit-sync older than the manifest (the first `make devkit-sync` after 2026-10-13
# runs the old script). Rerunning make devkit-sync, now the new script, slims it.
#
# Also: every tracked .swift-format must equal devkit/lint/swift-format.json byte for byte.
#
# Also: scripts/ci/gate_plan.sh sets none of the plan variables this devkit retired
# (DEVKIT_RETIRED_PLAN_VARS, bin/_paths_lib.sh). The gate sources main's _paths_lib.sh, so the
# sync PR that retires one would pass its own gate and break the next PR's; this check, run
# from the merged tree, fails the sync PR instead. The plan is read from the WORKING TREE, where a
# fix is made: reading the staged copy kept a manual run failing on a plan already fixed on disk
# (closet #410). --staged reads the index instead, as secrets_check.sh --staged does, for a hook
# that must judge exactly what is about to be committed. CI and the gate see one tree either way.
#
# Also (a WARNING, exit 0): an alternative of the plan's GATE_IMAGE_EXCLUDE_PATHS whose every
# tracked path the root .dockerignore already excludes. The gate reads .dockerignore itself
# (_dockerignore.py), so such an alternative is a hand copy that drifts (redlib #23, locus #133).
# Read from a literal assignment, single-quoted or bare, the fleet's two forms.
#
# Also (a WARNING, exit 0): a Makefile recipe line that runs `docker` itself (makefile_raw_docker,
# bin/_makefile_lib.sh), naming the line. It bypasses the daemon probe and per-call bound, so a
# wedged daemon hangs the job until the watchdog; route it through devkit/bin/docker_bounded.sh.
#
# Also (WARNINGS, exit 0): a repo that gates through devkit merges through it (bin/pr_merge.sh,
# which refuses a head without a local-gate success). A Makefile with a `gate` target and no
# `merge` target is named, and so is each line of AGENTS.md's `## Workflow` section that tells
# the reader to run `gh pr merge`: lanes do what that text says, so the text moves with the
# target. Only an instruction counts (workflow_merge_lines): the line starts with the command, it
# sits in a code fence, or `run`/`then` leads into it. A ban ("never `gh pr merge --auto`",
# closet) is the rule this enforces, not a breach. AGENTS.md is read like the plan: the working
# tree, or the index under --staged.
set -euo pipefail
STAGED=0
case "${1:-}" in
  --staged) STAGED=1 ;;
  '') ;;
  *) echo "usage: devkit-check.sh [--staged]" >&2; exit 2 ;;
esac
# shellcheck source=bin/_vendor_paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/_vendor_paths.sh"
# shellcheck source=bin/_paths_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_paths_lib.sh"
# shellcheck source=bin/_makefile_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_makefile_lib.sh"
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
# The vendored tree, .devkit-rev and the .swift-format copies: both sides come from the INDEX,
# not HEAD or the working copy, with or without --staged (devkit-sync stages all of them). In CI the index equals HEAD; in
# the pre-commit hook it is exactly what is about to be committed. Comparing HEAD made the
# devkit-sync commit itself fail its own hook (new .devkit-rev vs the old committed tree), and
# let a staged local edit under devkit/ through. Reading .devkit-rev from disk let an unstaged
# edit to it vouch for a staged devkit/ tree it would never be committed with. Unstaged edits
# are the hooks' business.
rev=$(git show :.devkit-rev 2>/dev/null) || {
  echo "devkit-check: .devkit-rev missing from the index; run make devkit-sync" >&2
  exit 1
}
read -r _commit expected <<<"$rev"
actual=$(git write-tree --prefix=devkit/ 2>/dev/null) || {
  echo "devkit-check: cannot read devkit/ from the index (missing or unmerged); run make devkit-sync" >&2
  exit 1
}
if [ "$actual" != "$expected" ]; then
  echo "devkit-check: devkit/ (tree ${actual:0:7}) differs from the vendored ${expected:0:7}." >&2
  echo "  Change it upstream in agandhi4/devkit, then run: make devkit-sync" >&2
  exit 1
fi
if manifest=$(git show :devkit/VENDOR_PATHS 2>/dev/null); then
  slim=$(vendor_filter_tree "$actual" "$manifest") || exit 1
  if [ "$slim" != "$actual" ]; then
    echo "devkit-check: devkit/ holds paths outside devkit/VENDOR_PATHS (vendored whole by an older devkit-sync)." >&2
    echo "  Run: make devkit-sync   (again, if you just ran it: the new script is now in place)" >&2
    exit 1
  fi
fi
# swift-format has no `extends`, so a repo's .swift-format (root or nested, e.g. ios/) is a copy of
# devkit/lint/swift-format.json and this is what keeps the copies one base. Index blobs, like the
# tree check: equal blob ids are equal bytes.
base_blob=
copies=0
while IFS= read -r copy; do
  [ -n "$copy" ] || continue
  if [ -z "$base_blob" ]; then
    base_blob=$(git rev-parse -q --verify ":devkit/lint/swift-format.json" 2>/dev/null) || {
      echo "devkit-check: $copy exists but devkit/lint/swift-format.json does not; run make devkit-sync" >&2
      exit 1
    }
  fi
  if [ "$(git rev-parse ":$copy")" != "$base_blob" ]; then
    echo "devkit-check: $copy differs from devkit/lint/swift-format.json (swift-format has no extends; the repo file is a copy)." >&2
    echo "  Restore it: cp devkit/lint/swift-format.json $copy   A rule change goes upstream in agandhi4/devkit." >&2
    copies=$((copies + 1))
  fi
done <<<"$(swift_format_copies)"
[ "$copies" -eq 0 ] || exit 1
# Assignments only: a comment naming a retired variable is history, not a setting.
if [ "$STAGED" = 1 ]; then
  plan_src=$(git show :scripts/ci/gate_plan.sh 2>/dev/null) || plan_src=""
else
  plan_src=$(cat scripts/ci/gate_plan.sh 2>/dev/null) || plan_src=""
fi
if [ -n "$plan_src" ]; then
  plan=$(awk '{ sub(/#.*/, "") } 1' <<<"$plan_src")
  retired_set=0
  for var in $DEVKIT_RETIRED_PLAN_VARS; do
    if grep -qE "(^|[^A-Za-z0-9_])$var=" <<<"$plan"; then
      echo "devkit-check: scripts/ci/gate_plan.sh sets $var; $DEVKIT_RETIRED_PLAN_ADVICE" >&2
      retired_set=1
    fi
  done
  [ "$retired_set" -eq 0 ] || exit 1
  exclude_re="^[[:space:]]*GATE_IMAGE_EXCLUDE_PATHS=('([^']*)'|([^[:space:]'\"]+))"
  while IFS= read -r line; do
    [[ "$line" =~ $exclude_re ]] || continue
    exclude=${BASH_REMATCH[2]}${BASH_REMATCH[3]}
    if redundant=$(git ls-files | python3 -I "$(dirname "${BASH_SOURCE[0]}")/_dockerignore.py" redundant . "$exclude"); then
      while IFS= read -r alt; do
        [ -n "$alt" ] && echo "devkit-check: WARNING: GATE_IMAGE_EXCLUDE_PATHS '$alt' is already excluded by .dockerignore, which the gate reads itself; drop it from the ERE" >&2
      done <<<"$redundant"
    else
      echo "devkit-check: WARNING: could not hold GATE_IMAGE_EXCLUDE_PATHS to .dockerignore (above)" >&2
    fi
    break
  done <<<"$plan"
fi
while IFS= read -r raw; do
  [ -z "$raw" ] || echo "devkit-check: WARNING: ${raw%%: *}: docker runs unbounded (no daemon probe, no per-call timeout); use devkit/bin/docker_bounded.sh: ${raw#*: }" >&2
done <<<"$(makefile_raw_docker)"
targets=$(makefile_targets)
if [[ "$targets" == *" gate "* && "$targets" != *" merge "* ]]; then
  # shellcheck disable=SC2016  # $(PR) is make's variable, printed literally
  echo 'devkit-check: WARNING: the Makefile has a gate target but no merge target; add: merge: ; devkit/bin/pr_merge.sh "$(PR)"' >&2
fi
if [ "$STAGED" = 1 ]; then
  agents_src=$(git show :AGENTS.md 2>/dev/null) || agents_src=""
else
  agents_src=$(cat AGENTS.md 2>/dev/null) || agents_src=""
fi
# The line numbers of the Workflow section's lines that instruct `gh pr merge`, from stdin.
workflow_merge_lines() {
  awk '
    /^## / { wf = ($0 ~ /^## Workflow/); fence = 0; next }
    !wf { next }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    {
      l = tolower($0)
      if (l !~ /gh pr merge/) next
      if (fence || l ~ /^[ \t]*([-*+]|[0-9]+\.)?[ \t]*`?gh pr merge/) { print NR; next }
      if (l ~ /(^|[^a-z])(run|then)[ \t]+`?gh pr merge/ && l !~ /(never|not|n.t)[ \t]+(run|then)[ \t]+`?gh pr merge/) print NR
    }'
}
while IFS= read -r line; do
  [ -z "$line" ] || echo "devkit-check: WARNING: AGENTS.md:$line: the Workflow section merges with gh pr merge; say make merge PR=<n> (it refuses a head without a local-gate success)" >&2
done <<<"$(workflow_merge_lines <<<"$agents_src")"
echo "devkit-check: ok (${_commit:0:7})"
