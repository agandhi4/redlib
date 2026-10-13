#!/usr/bin/env bash
# Guard: agent docs stay in one shape across every repo. Reads the git index (`git ls-files -s`),
# so untracked trees (node_modules, DerivedData, .claude/worktrees) never count and Actions sees
# what a laptop sees.
#   1. Every directory holding AGENTS.md or CLAUDE.md has AGENTS.md as a regular file and
#      CLAUDE.md as a symlink whose target is exactly `AGENTS.md`. Owner decision 2026-10-12:
#      AGENTS.md is canonical (every agent reads it); CLAUDE.md exists only so Claude Code loads it.
#      A CLAUDE.md-only dir or a reversed pair fails, naming the directory. The root needs a pair.
#   2. Size caps keep the context every agent loads small: root AGENTS.md <= 30 KB, any other
#      <= 16 KB (KB = 1024 bytes). scripts/ci/docs_oversize.txt (`<path> <max-bytes>` per line,
#      `#` comments) grants a larger cap to a named file. The allowance only shrinks: a file over
#      its cap fails, and a file under 90% of its cap fails with "tighten docs_oversize.txt to
#      <size>", so every trim is locked in. An entry for a file now within the default cap fails.
#   3. docs/decisions.md exists at the root.
#   4. No AGENTS.md names a retired tool (case-insensitive whole word). The default list is the
#      tools the 2026 standardization scan retired; DOCS_CHECK_BANNED (space-separated) replaces
#      it. Only AGENTS.md is scanned: history docs may name dead tools, live instructions may not.
#   5. Optional scripts/ci/docs_rules.sh is sourced after the standard checks for repo extras. It
#      may read $ROOT and call `docs_fail <msg>` (fails the run) or `docs_warn <msg>` (prints only).
# Output: one `docs-check: <msg>` line per problem on stderr, then `docs-check: ok (<n> AGENTS.md
# files)` on stdout or `docs-check: FAIL` on stderr. Exit 0 ok, 1 fail, 2 usage.
# Usage: devkit/bin/docs_check.sh [repo-root]      (part of ci-quick)
set -uo pipefail

usage() { echo "usage: docs_check.sh [repo-root]" >&2; exit 2; }
[ $# -le 1 ] || usage
case "${1:-}" in -h|--help) usage ;; esac
cd "${1:-.}" 2>/dev/null || usage
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "docs-check: not a git repository: ${1:-.}" >&2; usage; }
cd "$ROOT" || exit 2

ROOT_CAP=$((30 * 1024))
AREA_CAP=$((16 * 1024))
ALLOWLIST=scripts/ci/docs_oversize.txt
EXTRAS=scripts/ci/docs_rules.sh
BANNED=${DOCS_CHECK_BANNED-graphify repomix serena nexus graphiti engram}

rc=0
# docs_fail and docs_warn are also the API for scripts/ci/docs_rules.sh.
docs_fail() { echo "docs-check: $*" >&2; rc=1; }
# shellcheck disable=SC2329  # called by the sourced docs_rules.sh
docs_warn() { echo "docs-check: warning: $*" >&2; }

# Index entries for both file names, as parallel arrays. Mode 120000 is a symlink; 100644/100755
# are regular files.
dirs=() names=() modes=()
while IFS= read -r -d '' entry; do
  mode=${entry%% *}
  path=${entry#*$'\t'}
  name=${path##*/}
  case "$name" in AGENTS.md|CLAUDE.md) ;; *) continue ;; esac
  dir=.; case "$path" in */*) dir=${path%/*} ;; esac
  dirs+=("$dir"); names+=("$name"); modes+=("$mode")
done < <(git ls-files -s -z)

# mode_of <dir> <name> -> index mode, or empty when the dir has no such entry
mode_of() {
  local i
  for i in ${dirs[@]+"${!dirs[@]}"}; do
    if [ "${dirs[$i]}" = "$1" ] && [ "${names[$i]}" = "$2" ]; then echo "${modes[$i]}"; return; fi
  done
}
is_regular() { case "$1" in 100644|100755) return 0 ;; *) return 1 ;; esac; }

# allowance_of <path> -> max-bytes from the allowlist, or empty
allowance_of() {
  [ -f "$ALLOWLIST" ] || return 0
  awk -v p="$1" '$1 == p { print $2; exit }' "$ALLOWLIST"
}

# ---- 1. pair shape ---------------------------------------------------------------------------
agents_files=()
seen=" "
for dir in ${dirs[@]+"${dirs[@]}"}; do
  case "$seen" in *" $dir "*) continue ;; esac
  seen="$seen$dir "
  where=$dir; [ "$dir" = . ] && where="repo root"
  am=$(mode_of "$dir" AGENTS.md)
  cm=$(mode_of "$dir" CLAUDE.md)
  prefix=; [ "$dir" = . ] || prefix=$dir/
  if [ -z "$am" ]; then
    docs_fail "$where: CLAUDE.md without AGENTS.md; make it AGENTS.md and symlink CLAUDE.md -> AGENTS.md"
    continue
  fi
  if ! is_regular "$am"; then
    if [ "$am" = 120000 ]; then
      docs_fail "$where: AGENTS.md is a symlink (reversed pair); make AGENTS.md the real file and CLAUDE.md -> AGENTS.md"
    else
      docs_fail "$where: AGENTS.md is not a regular file (mode $am)"
    fi
    continue
  fi
  agents_files+=("${prefix}AGENTS.md")
  if [ -z "$cm" ]; then
    docs_fail "$where: AGENTS.md has no CLAUDE.md; add it with: ln -s AGENTS.md ${prefix}CLAUDE.md"
  elif [ "$cm" != 120000 ]; then
    docs_fail "$where: CLAUDE.md is a regular file; it must be a symlink to AGENTS.md"
  else
    target=$(readlink "${prefix}CLAUDE.md" 2>/dev/null || true)
    [ "$target" = AGENTS.md ] || docs_fail "$where: CLAUDE.md points to '${target}'; it must point to AGENTS.md"
  fi
done
# A root with either file was judged above; a root with neither has no agent instructions at all.
[ -n "$(mode_of . AGENTS.md)$(mode_of . CLAUDE.md)" ] || docs_fail "repo root: no AGENTS.md"

# ---- 2. size caps ----------------------------------------------------------------------------
for f in ${agents_files[@]+"${agents_files[@]}"}; do
  [ -f "$f" ] || { docs_fail "$f: tracked but missing from the working tree"; continue; }
  size=$(wc -c < "$f" | tr -d '[:space:]')
  cap=$AREA_CAP; [ "$f" = AGENTS.md ] && cap=$ROOT_CAP
  allowed=$(allowance_of "$f")
  if [ -z "$allowed" ]; then
    [ "$size" -le "$cap" ] || docs_fail "$f: $size bytes, over the $cap-byte cap; trim it (or list it in $ALLOWLIST)"
  elif [ "$size" -le "$cap" ]; then
    docs_fail "$f: $size bytes is within the $cap-byte cap; remove it from $ALLOWLIST"
  elif [ "$size" -gt "$allowed" ]; then
    docs_fail "$f: $size bytes, over its $allowed-byte allowance in $ALLOWLIST; trim it"
  elif [ $((size * 10)) -lt $((allowed * 9)) ]; then
    docs_fail "$f: $size bytes, under 90% of its $allowed-byte allowance; tighten $ALLOWLIST to $size"
  fi
done

if [ -f "$ALLOWLIST" ]; then
  while read -r path bytes extra; do
    case "$path" in ''|'#'*) continue ;; esac
    case "$bytes" in ''|*[!0-9]*) docs_fail "$ALLOWLIST: '$path' needs a byte count: <path> <max-bytes>"; continue ;; esac
    [ -z "${extra:-}" ] || docs_fail "$ALLOWLIST: '$path' has trailing fields; expected <path> <max-bytes>"
    listed=0
    for f in ${agents_files[@]+"${agents_files[@]}"}; do [ "$f" = "$path" ] && listed=1; done
    [ $listed = 1 ] || docs_fail "$ALLOWLIST: '$path' is not a tracked AGENTS.md; remove the stale entry"
  done < "$ALLOWLIST"
fi

# ---- 3. decisions log ------------------------------------------------------------------------
[ -n "$(git ls-files -- docs/decisions.md)" ] || docs_fail "docs/decisions.md is missing; every repo records decisions there"

# ---- 4. retired tools ------------------------------------------------------------------------
for f in ${agents_files[@]+"${agents_files[@]}"}; do
  [ -f "$f" ] || continue
  for word in $BANNED; do
    while IFS= read -r hit; do
      docs_fail "$f:${hit%%:*}: names retired tool '$word'"
    done < <(grep -niwF -- "$word" "$f" || true)
  done
done

# ---- 5. repo extras --------------------------------------------------------------------------
if [ -f "$EXTRAS" ]; then
  # shellcheck source=/dev/null
  . "./$EXTRAS"
fi

if [ $rc = 0 ]; then
  echo "docs-check: ok (${#agents_files[@]} AGENTS.md files)"
else
  echo "docs-check: FAIL" >&2
fi
exit $rc
