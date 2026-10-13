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
#   5. The root AGENTS.md has a `## Convention deltas` heading: every convention file says a
#      project deviates only by a line there, so the heading must exist before anyone can comply.
#   6-10. The standard docs set (devkit README.md, "Standard docs"; decisions.md 2026-10-13,
#      "Standard docs set, kept honest by docs-check"). Skeletons: devkit's templates/new/common/.
#   6. Required files: README.md, and architecture written down in docs/architecture.md or under
#      an `## Architecture` heading in the root AGENTS.md (either is the one home; not both rules).
#   7. README.md has an H2 for each entry of README_SECTIONS below, matched case-insensitively
#      against the canonical name or one of its aliases (the first name is canonical).
#   8. docs/decisions.md: every H2 is a dated entry `## YYYY-MM-DD — title` (em dash), dates
#      never go backwards (newest last), and each entry has Why, Decision and Consequence lines
#      (`**Why:**`, `**Why**:` or `Why:`, optionally as a `- ` bullet).
#   9. Every `make <target>` in README.md or the root AGENTS.md (a code span starting `make `,
#      or a fenced line starting `make ` / `$ make `) names a target of the root Makefile.
#      `-C`/`-f` invocations, VAR=value words and placeholders (`<`, `$`, `*`) are skipped; a
#      `%` pattern rule matches. No root Makefile (devkit itself), nothing to hold them to.
#   10. Every relative Markdown link in README.md, the root AGENTS.md and docs/*.md resolves to
#      a tracked file or directory (the index, as above). URLs, `#anchors`, root-absolute and
#      links leaving the repo are skipped; links in code are not links.
#   Rules 5-10 report through docs_rule: a warning before their FAILS_FROM date below, a failure
#   on and after it, so no consumer's ci-quick breaks on the sync that introduces a rule and the
#   flip needs no second PR. DOCS_CHECK_TODAY=YYYY-MM-DD overrides today (tests).
#   11. Optional scripts/ci/docs_rules.sh is sourced after the standard checks for repo extras. It
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

# When each rule stops warning and starts failing; the one place these dates live.
DELTAS_FAILS_FROM=2026-11-01
DOCS_SET_FAILS_FROM=2026-11-15
TODAY=${DOCS_CHECK_TODAY:-$(date +%F)}
# README.md's required H2 sections: "Canonical|alias|alias…" (devkit/README.md, "Standard docs"
# says what each holds). Aliases are names the fleet already used for the same content; add one
# only when it means exactly the canonical section, never to excuse a missing one.
README_SECTIONS=(
  "Getting started|Quick start|Quickstart|Setup|Installation|Install|Run locally|Running locally"
  "Commands|Development|Develop"
  "Architecture|Layout|Repository layout|Project structure|Structure|How it works"
  "Deploy|Deployment|Release|Releases|Deploy and release|Deploy & release"
  "Documentation|Docs"
)

rc=0
# docs_fail and docs_warn are also the API for scripts/ci/docs_rules.sh.
docs_fail() { echo "docs-check: $*" >&2; rc=1; }
# shellcheck disable=SC2329  # called by the sourced docs_rules.sh
docs_warn() { echo "docs-check: warning: $*" >&2; }
# docs_rule <fails-from YYYY-MM-DD> <msg>: warn before the date, fail on and after it.
docs_rule() {
  local from=$1; shift
  if [[ "$TODAY" < "$from" ]]; then docs_warn "$* (fails from $from)"; else docs_fail "$*"; fi
}

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

# ---- 5. convention deltas heading -----------------------------------------------------------
if [ -f AGENTS.md ] && ! grep -qE '^## Convention deltas[[:space:]]*$' AGENTS.md; then
  docs_rule "$DELTAS_FAILS_FROM" "AGENTS.md: no '## Convention deltas' heading; add it (list deviations from ~/.claude/conventions, or 'None.')"
fi

# Tracked paths, one per line, for rules 6 and 10 (one git call; awk resolves links against it).
TRACKED=$(git ls-files)
# Here-strings, not `printf | grep -q`: under pipefail grep's early exit SIGPIPEs printf and a
# match on a large index reads as a miss.
is_tracked() { grep -qxF -- "$1" <<<"$TRACKED"; }
# h2_of <file>: the file's H2 headings, outside fenced code, trailing space trimmed.
h2_of() {
  awk '/^[[:space:]]*(```|~~~)/ { fence = !fence; next }
       !fence && /^## / { sub(/^## /, ""); sub(/[[:space:]]+$/, ""); print }' "$1"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---- 6. required files -----------------------------------------------------------------------
is_tracked README.md || docs_rule "$DOCS_SET_FAILS_FROM" "README.md is missing; start from devkit's templates/new/common/README.md (devkit/README.md, 'Standard docs')"
if ! is_tracked docs/architecture.md && ! { [ -f AGENTS.md ] && grep -qix architecture <<<"$(h2_of AGENTS.md)"; }; then
  docs_rule "$DOCS_SET_FAILS_FROM" "no architecture doc: add docs/architecture.md (skeleton in devkit's templates/new/common/docs/) or an '## Architecture' section in AGENTS.md"
fi

# ---- 7. README sections ----------------------------------------------------------------------
if is_tracked README.md && [ -f README.md ]; then
  readme_h2=$(lower "$(h2_of README.md)")
  for spec in "${README_SECTIONS[@]}"; do
    found=0 rest=$spec
    while [ -n "$rest" ]; do
      name=${rest%%|*}
      if grep -qxF -- "$(lower "$name")" <<<"$readme_h2"; then found=1; break; fi
      case "$rest" in *'|'*) rest=${rest#*|} ;; *) rest= ;; esac
    done
    if [ $found = 0 ]; then
      aliases=${spec#*|}; [ "$aliases" = "$spec" ] && aliases=
      docs_rule "$DOCS_SET_FAILS_FROM" "README.md: no '## ${spec%%|*}' section${aliases:+ (or one of: ${aliases//|/, })}"
    fi
  done
fi

# ---- 8. decisions entries --------------------------------------------------------------------
# One problem per output line, `<line>: <msg>`; fenced code is skipped (an entry may quote one).
if [ -f docs/decisions.md ]; then
  while IFS= read -r problem; do
    [ -n "$problem" ] && docs_rule "$DOCS_SET_FAILS_FROM" "docs/decisions.md:$problem"
  done < <(awk '
    function marker(name) { return "^(- )?(\\*\\*)?" name "(:\\*\\*|\\*\\*:|:)" }
    function close_entry() {
      if (!open) return
      miss = ""
      if (!why) miss = miss " Why"; if (!dec) miss = miss " Decision"; if (!con) miss = miss " Consequence"
      if (miss != "") printf "%d: entry \"%s\" has no%s line\n", line, title, miss
      open = 0
    }
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^## / {
      close_entry()
      if ($0 ~ /^## [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9] — [^[:space:]]/) {
        date = substr($0, 4, 10)
        if (prev != "" && date < prev) printf "%d: %s is older than the entry above it (%s); entries are newest last\n", NR, date, prev
        prev = date; open = 1; line = NR; title = substr($0, 4); why = dec = con = 0
      } else {
        printf "%d: \"%s\" is not a dated entry (## YYYY-MM-DD — title)\n", NR, $0
      }
      next
    }
    open && $0 ~ marker("Why") { why = 1 }
    open && $0 ~ marker("Decision") { dec = 1 }
    open && $0 ~ marker("Consequence") { con = 1 }
    END { close_entry() }
  ' docs/decisions.md)
fi

# ---- 9. make targets named in docs ---------------------------------------------------------
if [ -f Makefile ]; then
  # Rule targets of the root Makefile and of the files it includes by literal path.
  makefiles=Makefile
  while IFS= read -r inc; do
    case "$inc" in *'$'*) continue ;; esac
    [ -f "$inc" ] && makefiles="$makefiles $inc"
  done < <(awk '/^-?include[[:space:]]/ { for (i = 2; i <= NF; i++) print $i }' Makefile)
  # shellcheck disable=SC2086  # word-split on purpose: a list of plain file names
  targets=" $(awk '
    /^\t/ || /^[[:space:]]*#/ { next }
    {
      i = index($0, ":"); if (i < 2) next
      if (substr($0, i + 1, 1) == "=") next             # := assignment
      head = substr($0, 1, i - 1)
      if (head ~ /[=?+!]/ || head ~ /^(export|override|define|ifeq|ifneq|ifdef|ifndef) /) next
      n = split(head, t, /[[:space:]]+/)
      for (k = 1; k <= n; k++) if (t[k] != "" && t[k] !~ /^\./) printf "%s ", t[k]
    }' $makefiles)"
  for doc in README.md AGENTS.md; do
    if [ ! -f "$doc" ] || ! is_tracked "$doc"; then continue; fi
    while IFS=' ' read -r lineno target; do
      [ -n "$target" ] || continue
      case "$targets" in *" $target "*) continue ;; esac
      matched=0
      for t in $targets; do
        case "$t" in *%*) case "$target" in ${t%%\%*}*${t#*%}) matched=1; break ;; esac ;; esac
      done
      [ $matched = 1 ] || docs_rule "$DOCS_SET_FAILS_FROM" "$doc:$lineno: 'make $target' is not a Makefile target; fix the doc or the Makefile"
    done < <(awk -v q="'" '
      # Print "<line> <target>" for each target word of one `make …` command line.
      function targets_of(cmd,   n, w, k) {
        gsub(/"[^"]*"/, "\"\"", cmd); gsub(q "[^" q "]*" q, q q, cmd)   # msg="a b" is one word
        n = split(cmd, w, /[[:space:]]+/)
        for (k = 2; k <= n; k++) {
          if (w[k] ~ /^(\||&&|;|#|>|\))/) break
          if (w[k] ~ /^-[Cf]/) return                 # another Makefile; not ours to judge
          if (w[k] ~ /^-/ || w[k] ~ /=/ || w[k] ~ /[<>$*{}…]/ || w[k] == "") continue
          gsub(/[,.:;)]+$/, "", w[k])
          if (w[k] ~ /^[A-Za-z0-9_.\/-]+$/) print NR, w[k]
        }
      }
      /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
      fence { line = $0; sub(/^[[:space:]]*(\$[[:space:]]+)?/, "", line); if (line ~ /^make[[:space:]]/) targets_of(line); next }
      {
        rest = $0
        while (match(rest, /`make [^`]*`/)) {
          targets_of(substr(rest, RSTART + 1, RLENGTH - 2))
          rest = substr(rest, RSTART + RLENGTH)
        }
      }' "$doc")
  done
fi

# ---- 10. relative links ----------------------------------------------------------------------
link_docs=()
for doc in README.md AGENTS.md; do is_tracked "$doc" && [ -f "$doc" ] && link_docs+=("$doc"); done
while IFS= read -r doc; do
  [ -f "$doc" ] && link_docs+=("$doc")
done < <(printf '%s\n' "$TRACKED" | grep -E '^docs/[^/]+\.md$' || true)
if [ ${#link_docs[@]} -gt 0 ]; then
  while IFS= read -r problem; do
    [ -n "$problem" ] && docs_rule "$DOCS_SET_FAILS_FROM" "$problem"
  done < <(printf '%s\n' "$TRACKED" | awk -v q="'" '
    # Normalise <dir>/<target> to a repo-relative path; "" when it leaves the repo.
    function resolve(dir, target,   parts, n, out, depth, k, p) {
      p = (dir == "" ? target : dir "/" target)
      n = split(p, parts, "/"); depth = 0
      for (k = 1; k <= n; k++) {
        if (parts[k] == "" || parts[k] == ".") continue
        if (parts[k] == "..") { if (depth == 0) return ""; depth--; continue }
        out[++depth] = parts[k]
      }
      p = ""; for (k = 1; k <= depth; k++) p = p (k > 1 ? "/" : "") out[k]
      return p
    }
    function check(target,   dir, path) {
      sub(/^[[:space:]]+/, "", target); sub("[[:space:]]+(\"[^\"]*\"|" q "[^" q "]*" q ")?[[:space:]]*$", "", target)
      if (target ~ /^</) { sub(/^</, "", target); sub(/>.*$/, "", target) }
      if (target == "" || target ~ /^#/ || target ~ /^\// || target ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) return
      sub(/[#?].*$/, "", target); gsub(/%20/, " ", target)
      if (target == "") return
      dir = FILENAME; if (dir ~ /\//) sub(/\/[^\/]*$/, "", dir); else dir = ""
      path = resolve(dir, target)
      sub(/\/$/, "", path)
      if (path == "" && target ~ /^\.\./) return       # leaves the repo: not verifiable here
      if (path == "" || path in tracked || path in dirs) return
      printf "%s:%d: link to " q "%s" q " does not resolve to a tracked file\n", FILENAME, FNR, target
    }
    FILENAME == "-" {
      tracked[$0] = 1
      p = $0; while (sub(/\/[^\/]*$/, "", p)) dirs[p] = 1
      next
    }
    FNR == 1 { fence = 0 }
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      line = $0; gsub(/`[^`]*`/, "", line)
      if (match(line, /^[[:space:]]*\[[^]]+\]:[[:space:]]*/)) { check(substr(line, RSTART + RLENGTH)); next }
      while (match(line, /\]\([^)]*\)/)) {
        check(substr(line, RSTART + 2, RLENGTH - 3))
        line = substr(line, RSTART + RLENGTH)
      }
    }' - "${link_docs[@]}")
fi

# ---- 11. repo extras -------------------------------------------------------------------------
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
