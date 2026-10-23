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
# Also: GATE_CODEX_REVIEW, if the plan sets it, is one literal line `GATE_CODEX_REVIEW=0` or `=1`
# (plan_literal_setting). pr_merge.sh reads that line without sourcing the plan, so any other
# form (`="1"`, `export`, `=yes`, a second line) would leave the opt-in silently off or ambiguous.
# Likewise GATE_CODEX_RUNNING_MAX_MIN, one `GATE_CODEX_RUNNING_MAX_MIN=<minutes>` line (pr_merge.sh).
# Likewise GATE_CODE_PATHS, one unquoted `GATE_CODE_PATHS=<prefix>[,<prefix>...]` line: the gate
# sources it, the hooks and pr_merge.sh read the literal, and they must classify alike.
#
# Also (a WARNING, exit 0): an alternative of the plan's GATE_IMAGE_EXCLUDE_PATHS whose every
# tracked path the root .dockerignore already excludes. The gate reads .dockerignore itself
# (_dockerignore.py), so such an alternative is a hand copy that drifts (redlib #23, locus #133).
# Read from a literal assignment, single-quoted or bare, the fleet's two forms.
#
# Also (a WARNING, exit 0): a repo tracking a tsconfig*.json and a .dockerignore whose build
# context would still see a tsbuildinfo beside a tsconfig (probed with _dockerignore.py, so any
# pattern that excludes it counts). A stale one copied into the image let `tsc -b` call the
# project up to date and skip the image's type-check (locus #145); the fix is `**/*.tsbuildinfo`.
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
#
# Also (WARNINGS, exit 0): a throwaway Postgres container name or host port, or a `docker run
# --name`, the Makefile fixes to a literal (makefile_fixed_pg): every worktree then shares one container, and concurrent
# lanes' `up` removed each other's databases mid-suite (2026-10-19). throwaway_pg.sh `name` and
# `port` derive both from the checkout. And a Makefile that does not run its recipes on the
# repo's pinned Node or Rust (no `SHELL := devkit/bin/toolchain_shell.sh` while .nvmrc or
# rust-toolchain.toml is tracked): a hand-run `make metrics-*` then used PATH's Node 25, which
# the gate never does (finplat, 2026-10-19).
# Likewise each recipe line that runs a bare `python3` (makefile_bare_python) in a Makefile
# without that SHELL: toolchain_shell.sh leads PATH with devkit's python3 (>= 3.11), and without
# it the line gets PATH's, Xcode's 3.9 under launchd (devkit decisions 2026-10-23).
#
# Also (WARNINGS, exit 0): the repo's Renovate config extends devkit's preset and automerges
# nothing beyond the declared digest hole (bin/_renovate.py, which the scorecard's `renovate`
# check shares). Renovate merges server-side, so this is the only place a self-merge that skips
# the gate is caught before it is live (homelab #109/#110, 2026-10-19).
#
# Also (WARNINGS, exit 0): a bats assertion errexit never sees (bin/bats_assert_check.py, which
# devkit's ci-lint fails on): `[[ ]]` mid-test passes untested on macOS bash 3.2, where lanes run
# bats (devkit #212). `bats_assert_check.py --fix` appends the `|| false` that fixes most.
# It reads the working tree even under --staged: a warning judges the files a lane edits next.
#
# Also (WARNINGS, exit 0): a tracked stylesheet whose Tailwind v4 `@import "tailwindcss"` has no
# source(...) scope that leaves devkit/ out, or a source()/@source path that reaches it
# (tailwind_unscoped). Unscoped, v4 scans every file
# git tracks, so a word in devkit's comments ("shadow") became a CSS class and moved rollcall's
# bundle bound with no src/ change (#81). Working tree, like the bats check.
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
# plan_literal_setting <plan, comments stripped> <NAME> <value ERE> <the form, for the message>:
# exit 1 unless every NAME assignment is the one literal line a reader that never sources the
# plan sees: GATE_CODEX_REVIEW and GATE_CODEX_RUNNING_MAX_MIN (gate_plan_literal, pr_merge.sh) and
# GATE_CODE_PATHS (devkit_load_code_paths, _paths_lib.sh).
plan_literal_setting() {
  local all literal
  all=$(grep -cE "(^|[^A-Za-z0-9_])$2=" <<<"$1" || true)
  literal=$(grep -cE "^$2=$3[[:space:]]*\$" <<<"$1" || true)
  [ "$all" != "$literal" ] || [ "$all" -gt 1 ] || return 0
  echo "devkit-check: scripts/ci/gate_plan.sh: $2 must be one literal line, $4 (read without sourcing the plan)" >&2
  exit 1
}
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
  plan_literal_setting "$plan" GATE_CODEX_REVIEW '[01]' 'GATE_CODEX_REVIEW=0 or GATE_CODEX_REVIEW=1'
  plan_literal_setting "$plan" GATE_CODEX_RUNNING_MAX_MIN '[1-9][0-9]{0,5}' \
    'GATE_CODEX_RUNNING_MAX_MIN=<whole minutes, 1-999999>, unquoted (45)'
  plan_literal_setting "$plan" GATE_CODE_PATHS '[A-Za-z0-9._/-]+(,[A-Za-z0-9._/-]+)*' \
    'GATE_CODE_PATHS=<prefix>[,<prefix>...], unquoted (plugins/,templates/)'
  exclude_re="^[[:space:]]*GATE_IMAGE_EXCLUDE_PATHS=('([^']*)'|([^[:space:]'\"]+))"
  while IFS= read -r line; do
    [[ "$line" =~ $exclude_re ]] || continue
    exclude=${BASH_REMATCH[2]}${BASH_REMATCH[3]}
    if redundant=$(git ls-files | "$(dirname "${BASH_SOURCE[0]}")/python.sh" -I "$(dirname "${BASH_SOURCE[0]}")/_dockerignore.py" redundant . "$exclude"); then
      while IFS= read -r alt; do
        [ -n "$alt" ] && echo "devkit-check: WARNING: GATE_IMAGE_EXCLUDE_PATHS '$alt' is already excluded by .dockerignore, which the gate reads itself; drop it from the ERE" >&2
      done <<<"$redundant"
    else
      echo "devkit-check: WARNING: could not hold GATE_IMAGE_EXCLUDE_PATHS to .dockerignore (above)" >&2
    fi
    break
  done <<<"$plan"
fi
if git ls-files --error-unmatch .dockerignore >/dev/null 2>&1; then
  # One probe per tsconfig: where `tsc -b` writes its tsbuildinfo by default, named after the
  # config (tsconfig.build.json -> tsconfig.build.tsbuildinfo), so an ignore line naming only
  # tsconfig.tsbuildinfo still warns (Codex, orbit #116).
  probes=$(git ls-files -- 'tsconfig*.json' '**/tsconfig*.json' \
    | awk '{ sub(/\.json$/, ".tsbuildinfo"); print }' | sort -u)
  if [ -n "$probes" ]; then
    if seen=$("$(dirname "${BASH_SOURCE[0]}")/python.sh" -I "$(dirname "${BASH_SOURCE[0]}")/_dockerignore.py" keep . <<<"$probes"); then
      [ -z "$seen" ] || echo "devkit-check: WARNING: .dockerignore lets the image build see $(head -n 1 <<<"$seen"): a stale tsbuildinfo makes tsc -b skip the image's type-check (locus #145); add: **/*.tsbuildinfo" >&2
    else
      echo "devkit-check: WARNING: could not hold .dockerignore to **/*.tsbuildinfo (above)" >&2
    fi
  fi
fi
while IFS= read -r raw; do
  [ -z "$raw" ] || echo "devkit-check: WARNING: ${raw%%: *}: docker runs unbounded (no daemon probe, no per-call timeout); use devkit/bin/docker_bounded.sh: ${raw#*: }" >&2
done <<<"$(makefile_raw_docker)"
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  kind=${raw#*: }; value=${kind#* }; kind=${kind%% *}
  what="throwaway Postgres $kind"
  [ "$kind" != container ] || { what="docker run container name"; kind=name; }
  echo "devkit-check: WARNING: ${raw%%: *}: $what $value is fixed, so every worktree shares it and concurrent lanes break each other; derive it: \$(shell devkit/bin/throwaway_pg.sh $kind <base name>)" >&2
done <<<"$(makefile_fixed_pg)"
mk_files=()
while IFS= read -r f; do mk_files+=("$f"); done < <(makefile_files)
if [ "${#mk_files[@]}" -gt 0 ] \
  && ! grep -qE '^SHELL[[:space:]]*:?=[[:space:]]*devkit/bin/toolchain_shell\.sh[[:space:]]*$' "${mk_files[@]}"; then
  [ -z "$(git ls-files .nvmrc rust-toolchain.toml rust-toolchain)" ] \
    || echo "devkit-check: WARNING: Makefile: a hand-run make uses PATH's node/cargo, not the repo's pins; add: SHELL := devkit/bin/toolchain_shell.sh" >&2
  while IFS= read -r raw; do
    [ -z "$raw" ] || echo "devkit-check: WARNING: ${raw%%: *}: a bare python3 is PATH's (Xcode's 3.9 under launchd), not devkit's >= 3.11; add: SHELL := devkit/bin/toolchain_shell.sh (or call devkit/bin/python.sh): ${raw#*: }" >&2
  done <<<"$(makefile_bare_python)"
fi
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
renovate_args=(audit)
[ "$STAGED" = 0 ] || renovate_args+=(--staged)
while IFS= read -r issue; do
  [ -z "$issue" ] || echo "devkit-check: WARNING: $issue (README \"Renovate\": every Renovate PR waits for make merge)" >&2
done <<<"$("$(dirname "${BASH_SOURCE[0]}")/python.sh" -I "$(dirname "${BASH_SOURCE[0]}")/_renovate.py" "${renovate_args[@]}")"
while IFS= read -r issue; do
  [ -z "$issue" ] || echo "devkit-check: WARNING: $issue (devkit/bin/bats_assert_check.py --fix)" >&2
done <<<"$("$(dirname "${BASH_SOURCE[0]}")/python.sh" -I "$(dirname "${BASH_SOURCE[0]}")/bats_assert_check.py" --root .)"
# tailwind_unscoped: "<css>:<line>" for each place a tracked stylesheet (outside devkit/) has
# Tailwind v4 scan devkit/: an `@import "tailwindcss"` with no source(...), or a source() or
# `@source` path (source(none)'s explicit list) that tw_reaches_devkit. A path that does not
# resolve is Tailwind's own error, not this check's.
# tw_reaches_devkit <top> <css> <path>: the directory <path> names from <css>'s (a glob's part
# before its first wildcard; a file's directory) is <top>, above it or inside <top>/devkit/.
tw_reaches_devkit() {
  local d dir
  d=$(dirname "$2")/${3%%[\*\?\{\[]*}
  [ -d "$d" ] || d=$(dirname "$d")
  dir=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  case "$dir/" in "$1/devkit/"*) return 0 ;; "$1/"?*) return 1 ;; esac
  return 0
}
tailwind_unscoped() {
  local css hit top
  top=$(pwd -P)
  while IFS= read -r css; do
    [ -f "$css" ] || continue
    hit=$(grep -nE "^[[:space:]]*@import[[:space:]]+[\"']tailwindcss(/utilities(\\.css)?)?[\"']" "$css" | head -n 1) || hit=""
    if [ -n "$hit" ] && [[ ! "$hit" =~ source\([[:space:]]*none[[:space:]]*\) ]]; then
      if [[ ! "$hit" =~ source\([[:space:]]*[\"\']([^\"\']*)[\"\'] ]] || tw_reaches_devkit "$top" "$css" "${BASH_REMATCH[1]}"; then
        echo "$css:${hit%%:*}"
      fi
    fi
    # `@source not "<path>"` excludes and `@source inline(...)` names classes: neither matches.
    while IFS= read -r hit; do
      [[ "$hit" =~ @source[[:space:]]+[\"\']([^\"\']*)[\"\'] ]] || continue
      ! tw_reaches_devkit "$top" "$css" "${BASH_REMATCH[1]}" || echo "$css:${hit%%:*}"
    done < <(grep -nE "^[[:space:]]*@source[[:space:]]+[\"']" "$css" || true)
  done < <(git ls-files -- '*.css' ':!:devkit/')
}
while IFS= read -r raw; do
  [ -z "$raw" ] || echo "devkit-check: WARNING: $raw: Tailwind v4 scans devkit/ from here (an unscoped @import \"tailwindcss\", or a source() or @source path reaching the repo root or devkit/), and a word in its comments becomes a CSS class (rollcall #81: .shadow); scope it to the app's sources: @import \"tailwindcss\" source(\"<dir>\")" >&2
done <<<"$(tailwind_unscoped)"
echo "devkit-check: ok (${_commit:0:7})"
