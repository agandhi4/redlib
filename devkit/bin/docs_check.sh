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
#      `%` pattern rule matches. No root Makefile, nothing to hold them to; a doc that means another
#      repo's target names it without `make ` (devkit's README: "its `devkit-sync` target").
#   10. Every relative Markdown link in README.md, the root AGENTS.md and docs/**/*.md resolves to
#      a tracked file or directory (the index, as above). URLs, `#anchors`, root-absolute and
#      links leaving the repo are skipped; links in code are not links.
#   12. The root .gitattributes gives docs/decisions.md the union merge driver
#      (`docs/decisions.md merge=union`), so two PRs that each append an entry rebase cleanly.
#      `devkit/bin/hooks_check.sh --fix` (`make install`) adds it; why and the caveat live in
#      bin/_gitattributes_lib.sh. Tracked file only: an untracked one helps nobody else.
#   13-16. The docs diet (decisions.md 2026-10-16): every agent session loads AGENTS.md, so it
#      stays navigation-sized and uniform; reference material lives in docs/, which nothing loads
#      unprompted.
#   13. Allowance sunset: from DIET_FAILS_FROM the caps are absolute. Until then every file over
#      its cap on a docs_oversize.txt allowance warns with its size and the cap (rule 2 keeps the
#      allowance shrink-only meanwhile).
#   14. The root AGENTS.md's H2s come from AGENTS_SECTIONS below and include AGENTS_REQUIRED (rule 5
#      owns Convention deltas). Any other H2 is reference material for docs/; a Conventions,
#      Guidelines, Patterns or Best practices heading is called out: it restates the conventions.
#   15. docs/ holds a fixed set: architecture.md, decisions.md, operations.md (deploy, backup and
#      restore, troubleshooting; runbook.md and deployment.md are old names to rename). Any other
#      docs/**/*.md is a dated one-off at docs/reports/<YYYY-MM-DD>-<slug>.md, or a living doc
#      linked from README's Documentation section. No AGENTS.md links into docs/reports/, so a
#      report never enters an agent's context.
#   16. No CONTRIBUTING.md (root, .github/ or docs/): AGENTS.md is the contributor guide, and
#      README's Documentation section says so in a "Contributors and agents: see AGENTS.md" line.
#   Rules 5-10 and 12-16 report through docs_rule: a warning before their FAILS_FROM date below, a
#   failure on and after it, so no consumer's ci-quick breaks on the sync that introduces a rule and
#   the flip needs no second PR. DOCS_CHECK_TODAY=YYYY-MM-DD overrides today (tests).
#   11. Optional scripts/ci/docs_rules.sh is sourced after the standard checks for repo extras. It
#      may read $ROOT and call `docs_fail <msg>` (fails the run) or `docs_warn <msg>` (prints only).
# Output: one `docs-check: <msg>` line per problem on stderr, then `docs-check: ok (<n> AGENTS.md
# files)` on stdout or `docs-check: FAIL` on stderr. Exit 0 ok, 1 fail, 2 usage.
# --report instead prints the numbers behind rules 2 and 13-16 as one `docs-report:` block on
# stdout (sizes against caps, allowances, docs outside the set, H2s outside the list) ending in a
# `docs-report: totals …` line, counts problems without printing them, and exits 0 (bar usage).
# The monthly audit and the docs-trim lanes read it.
# --fix does the mechanical half of the docs diet on a clean tree and exits 0 (2 when the tree is
# dirty or an action fails), one `docs-fix:` line per action, then the judgment items it left:
#   - a docs/**/*.md outside the set that is report-shaped (under archive/, plans/, blueprints/,
#     audits/, reviews/, history/, or named like a date, expert panel, audit, findings, plan,
#     design, review, retro, postmortem, triage, proposal, rfc, blueprint, step<n>), or sits
#     directly under docs/ with no link from any other Markdown file, is `git mv`ed to
#     docs/reports/<date>-<slug>.md (the date in its
#     name, else its first commit's author date; the slug is its path under docs/ minus
#     archive/reports dirs) and every link to it in another .md is rewritten, except from an
#     AGENTS.md (rule 15), which is printed as a judgment item instead;
#   - any other doc outside the set (linked from somewhere, or unlinked inside a named
#     subdirectory such as docs/architecture/, or a README.md) is linked from README's
#     Documentation section: structure someone chose is kept, and the reader decides;
#   - docs/runbook.md or docs/deployment.md becomes docs/operations.md when that is free;
#   - the "Contributors and agents" line is added to README's Documentation section.
#   It never deletes (CONTRIBUTING.md, oversize AGENTS.md sections) or edits an AGENTS.md: those
#   need a reader. Run docs_check again afterwards; review the diff like any other.
# Usage: devkit/bin/docs_check.sh [--report|--fix] [repo-root]      (part of ci-quick)
set -uo pipefail
# Before the cd: the script's own path may be relative.
# shellcheck source=bin/_makefile_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_makefile_lib.sh"
# shellcheck source=bin/_gitattributes_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_gitattributes_lib.sh"

usage() { echo "usage: docs_check.sh [--report|--fix] [repo-root]" >&2; exit 2; }
REPORT=0
FIX=0
case "${1:-}" in -h|--help) usage ;; --report) REPORT=1; shift ;; --fix) FIX=1; shift ;; esac
[ $# -le 1 ] || usage
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
DIET_FAILS_FROM=2026-11-15
TODAY=${DOCS_CHECK_TODAY:-$(date +%F)}
# README.md's required H2 sections: "Canonical|alias|alias…" (devkit/README.md, "Standard docs"
# says what each holds). Aliases are names the fleet already used for the same content; add one
# only when it means exactly the canonical section, never to excuse a missing one.
DOCS_SECTION="Documentation|Docs"
README_SECTIONS=(
  "Getting started|Quick start|Quickstart|Setup|Installation|Install|Run locally|Running locally"
  "Commands|Development|Develop"
  "Architecture|Layout|Repository layout|Project structure|Structure|How it works"
  "Deploy|Deployment|Release|Releases|Deploy and release|Deploy & release"
  "$DOCS_SECTION"
)
# The root AGENTS.md's only H2s (rule 14), same "Canonical|alias" shape; the scaffold's are a
# subset. AGENTS_REQUIRED must be present too (Convention deltas is rule 5's, with its own date).
AGENTS_SECTIONS=(
  "Stack" "Architecture" "Where things live|Navigation|TL;DR" "Convention deltas" "Commands"
  "CI and the PR gate" "Workflow" "Deliberate exceptions" "Documentation"
)
AGENTS_REQUIRED=(Stack Commands Workflow)

rc=0 nfail=0 nwarn=0
# docs_fail and docs_warn are also the API for scripts/ci/docs_rules.sh. --report counts, never prints.
quiet() { [ "$REPORT" = 1 ] || [ "$FIX" = 1 ]; }
docs_fail() { rc=1; nfail=$((nfail + 1)); quiet || echo "docs-check: $*" >&2; }
docs_warn() { nwarn=$((nwarn + 1)); quiet || echo "docs-check: warning: $*" >&2; }
# report <kind> <detail>: one row of the --report block (rules 13-16 call it in every mode).
report_rows=()
report() { report_rows+=("$(printf '%-16s %s' "$1" "$2")"); }
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
cap_of() { if [ "$1" = AGENTS.md ]; then echo "$ROOT_CAP"; else echo "$AREA_CAP"; fi; }
size_of() { if [ -f "$1" ]; then wc -c <"$1" | tr -d '[:space:]'; else echo 0; fi; }

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
  size=$(size_of "$f")
  cap=$(cap_of "$f")
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
# spec_names <spec>...: every name in each "Canonical|alias" spec, lowercased, one per line.
spec_names() { printf '%s\n' "$@" | tr '|' '\n' | tr '[:upper:]' '[:lower:]'; }
# section_bounds <file> <spec>: "<first> <last>" line numbers of the first H2 section whose
# heading is one of the spec's names (case-insensitive, outside fenced code); nothing if none.
section_bounds() {
  awk -v names="|$(spec_names "$2" | tr '\n' '|')" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence || !/^## / { next }
    start { print start, NR - 1; done = 1; exit }
    { h = tolower($0); sub(/^## /, "", h); sub(/[[:space:]]+$/, "", h); if (index(names, "|" h "|")) start = NR }
    END { if (start && !done) print start, NR }' "$1"
}
# md_links <file>...: "<file>\t<line>\t<target>\t<path>" per relative Markdown link outside code,
# <path> repo-relative with no trailing slash. URLs, `#anchors`, root-absolute links and links
# leaving the repo are not rows. Rules 10 and 15 read it.
md_links() {
  awk -v q="'" '
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
    function emit(target,   dir, path) {
      sub(/^[[:space:]]+/, "", target); sub("[[:space:]]+(\"[^\"]*\"|" q "[^" q "]*" q ")?[[:space:]]*$", "", target)
      if (target ~ /^</) { sub(/^</, "", target); sub(/>.*$/, "", target) }
      if (target == "" || target ~ /^#/ || target ~ /^\// || target ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) return
      sub(/[#?].*$/, "", target); gsub(/%20/, " ", target)
      if (target == "") return
      dir = FILENAME; if (dir ~ /\//) sub(/\/[^\/]*$/, "", dir); else dir = ""
      path = resolve(dir, target)
      sub(/\/$/, "", path)
      if (path != "") printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, target, path
    }
    FNR == 1 { fence = 0 }
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      line = $0; gsub(/`[^`]*`/, "", line)
      if (match(line, /^[[:space:]]*\[[^]]+\]:[[:space:]]*/)) { emit(substr(line, RSTART + RLENGTH)); next }
      while (match(line, /\]\([^)]*\)/)) {
        emit(substr(line, RSTART + 2, RLENGTH - 3))
        line = substr(line, RSTART + RLENGTH)
      }
    }' "$@"
}

# ---- 6. required files -----------------------------------------------------------------------
is_tracked README.md || docs_rule "$DOCS_SET_FAILS_FROM" "README.md is missing; start from devkit's templates/new/common/README.md (devkit/README.md, 'Standard docs')"
if ! is_tracked docs/architecture.md && ! { [ -f AGENTS.md ] && grep -qix architecture <<<"$(h2_of AGENTS.md)"; }; then
  docs_rule "$DOCS_SET_FAILS_FROM" "no architecture doc: add docs/architecture.md (skeleton in devkit's templates/new/common/docs/) or an '## Architecture' section in AGENTS.md"
fi

# ---- 7. README sections ----------------------------------------------------------------------
if is_tracked README.md && [ -f README.md ]; then
  readme_h2=$(lower "$(h2_of README.md)")
  for spec in "${README_SECTIONS[@]}"; do
    grep -qxFf <(spec_names "$spec") <<<"$readme_h2" && continue
    aliases=${spec#*|}; [ "$aliases" = "$spec" ] && aliases=
    docs_rule "$DOCS_SET_FAILS_FROM" "README.md: no '## ${spec%%|*}' section${aliases:+ (or one of: ${aliases//|/, })}"
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
  targets=$(makefile_targets)
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
done < <(grep -E '^docs/.+\.md$' <<<"$TRACKED" || true)
if [ ${#link_docs[@]} -gt 0 ]; then
  while IFS= read -r problem; do
    [ -n "$problem" ] && docs_rule "$DOCS_SET_FAILS_FROM" "$problem"
  done < <(md_links "${link_docs[@]}" | awk -F'\t' -v q="'" '
    FILENAME != "-" { tracked[$0] = 1; p = $0; while (sub(/\/[^\/]*$/, "", p)) dirs[p] = 1; next }
    !($4 in tracked || $4 in dirs) { printf "%s:%d: link to " q "%s" q " does not resolve to a tracked file\n", $1, $2, $3 }
  ' <(printf '%s\n' "$TRACKED") -)
fi

# ---- 12. decisions log merges by union -------------------------------------------------------
if ! is_tracked .gitattributes || ! has_decisions_union .gitattributes; then
  docs_rule "$DOCS_SET_FAILS_FROM" ".gitattributes: no '$DECISIONS_UNION_LINE', so two PRs that each append a decisions entry conflict on rebase (fix: devkit/bin/hooks_check.sh --fix, then commit .gitattributes)"
fi

# ---- 13. allowance sunset --------------------------------------------------------------------
rule_allowance_sunset() {
  local f size cap allowed
  for f in ${agents_files[@]+"${agents_files[@]}"}; do
    [ -f "$f" ] || continue
    size=$(size_of "$f") cap=$(cap_of "$f") allowed=$(allowance_of "$f")
    if [ "$size" -le "$cap" ]; then report agents "$f $size/$cap"; continue; fi
    report agents "$f $size/$cap OVER${allowed:+ (allowance $allowed)}"
    # Without an allowance rule 2 already failed it.
    [ -z "$allowed" ] || docs_rule "$DIET_FAILS_FROM" "$f: $size bytes on a $ALLOWLIST allowance; allowances end and the $cap-byte cap becomes absolute: move reference material to docs/, then delete the entry"
  done
}

# ---- 14. AGENTS.md sections ------------------------------------------------------------------
rule_agents_sections() {
  if ! is_tracked AGENTS.md || [ ! -f AGENTS.md ]; then return 0; fi
  local h2 allowed name h
  h2=$(lower "$(h2_of AGENTS.md)")
  allowed=$(spec_names "${AGENTS_SECTIONS[@]}")
  for name in "${AGENTS_REQUIRED[@]}"; do
    grep -qxF -- "$(lower "$name")" <<<"$h2" \
      || docs_rule "$DIET_FAILS_FROM" "AGENTS.md: no '## $name' section (devkit/README.md, 'Standard docs')"
  done
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    grep -qxF -- "$(lower "$h")" <<<"$allowed" && continue
    report h2-outside "$h"
    if grep -qiwE 'conventions?|guidelines|patterns|best practices' <<<"$h"; then
      docs_rule "$DIET_FAILS_FROM" "AGENTS.md: '## $h' restates the convention files; keep only deviations, one line each under '## Convention deltas'"
    else
      docs_rule "$DIET_FAILS_FROM" "AGENTS.md: '## $h' is not a standard section; move reference material to docs/ (sections: devkit/README.md, 'Standard docs')"
    fi
  done < <(h2_of AGENTS.md)
}

# ---- 15. fixed docs set ----------------------------------------------------------------------
# readme_doc_links: repo paths linked from README's Documentation section, one per line.
readme_doc_links() {
  if ! is_tracked README.md || [ ! -f README.md ]; then return 0; fi
  local first last
  read -r first last <<<"$(section_bounds README.md "$DOCS_SECTION")"
  [ -n "$first" ] || return 0
  md_links README.md | awk -F'\t' -v a="$first" -v b="$last" '$2 >= a && $2 <= b { print $4 }'
}
# --fix inputs, filled by rules 15 and 16: docs outside the set, old operations names,
# AGENTS.md links into reports, and whether README lacks the contributors line.
fix_outside=() fix_old_names=() fix_agents_report_links=() fix_contrib_line_missing=0
rule_docs_set() {
  local chosen f size n=0 total=0 report_re='^docs/reports/[0-9]{4}-[0-1][0-9]-[0-3][0-9]-[^/]+\.md$'
  chosen=$(readme_doc_links)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    size=$(size_of "$f") n=$((n + 1)) total=$((total + size))
    case "$f" in
      docs/architecture.md|docs/decisions.md|docs/operations.md) ;;
      docs/CONTRIBUTING.md) ;; # rule 16's
      docs/runbook.md|docs/deployment.md)
        fix_old_names+=("$f")
        report docs-outside "$f $size (old name of docs/operations.md)"
        docs_rule "$DIET_FAILS_FROM" "$f: the operations doc is docs/operations.md (deploy, backup and restore, troubleshooting); rename it" ;;
      docs/reports/*)
        [[ $f =~ $report_re ]] && continue
        fix_outside+=("$f")
        report docs-outside "$f $size (report name)"
        docs_rule "$DIET_FAILS_FROM" "$f: a report is docs/reports/<YYYY-MM-DD>-<slug>.md; rename it" ;;
      *)
        grep -qxF -- "$f" <<<"$chosen" && continue
        fix_outside+=("$f")
        report docs-outside "$f $size"
        docs_rule "$DIET_FAILS_FROM" "$f: not in the docs set; move a dated one-off to docs/reports/<YYYY-MM-DD>-<slug>.md, or link a living doc from README's Documentation section" ;;
    esac
  done < <(grep -E '^docs/.+\.md$' <<<"$TRACKED" || true)
  report docs-total "$n Markdown files, $total bytes"
  [ ${#agents_files[@]} -gt 0 ] || return 0
  while IFS=$'\t' read -r f n _ _; do
    fix_agents_report_links+=("$f:$n")
    docs_rule "$DIET_FAILS_FROM" "$f:$n: links into docs/reports/; reports stay out of agent context (link them from README or docs/ instead)"
  done < <(md_links "${agents_files[@]}" | awk -F'\t' '$4 == "docs/reports" || index($4, "docs/reports/") == 1')
}

# ---- 16. no CONTRIBUTING.md ------------------------------------------------------------------
rule_contributing() {
  local f first last
  for f in CONTRIBUTING.md .github/CONTRIBUTING.md docs/CONTRIBUTING.md; do
    is_tracked "$f" || continue
    report contributing "$f $(size_of "$f")"
    docs_rule "$DIET_FAILS_FROM" "$f: AGENTS.md is the contributor guide; fold anything it lacks into AGENTS.md and delete $f"
  done
  if ! is_tracked README.md || [ ! -f README.md ]; then return 0; fi
  read -r first last <<<"$(section_bounds README.md "$DOCS_SECTION")"
  [ -n "$first" ] || return 0 # rule 7 reports the missing section
  awk -v a="$first" -v b="$last" 'NR >= a && NR <= b' README.md | grep -qiE 'contributors and agents: see .*agents\.md' \
    || { fix_contrib_line_missing=1
         docs_rule "$DIET_FAILS_FROM" "README.md: the Documentation section has no 'Contributors and agents: see [AGENTS.md](AGENTS.md).' line"; }
}

rule_allowance_sunset
rule_agents_sections
rule_docs_set
rule_contributing

# ---- 11. repo extras -------------------------------------------------------------------------
if [ -f "$EXTRAS" ]; then
  # shellcheck source=/dev/null
  . "./$EXTRAS"
fi


# ---- --fix: the mechanical half of the docs diet -------------------------------------------
REPORT_SHAPED_DIR='(^|/)(archive|archives|plans|blueprints|audits|reviews|history|old)(/|$)'
REPORT_SHAPED_NAME='(^[0-9]{4}-[0-1][0-9]-[0-3][0-9]|expert-panel|deep-review|audit|findings|-plan|plan-|design|review|retro|postmortem|triage|proposal|rfc|blueprint|step[0-9]+)'
nfix=0 njudg=0
fix_did() { nfix=$((nfix + 1)); echo "docs-fix: $*"; }
fix_judgment() { njudg=$((njudg + 1)); echo "docs-fix: judgment: $*"; }
# fix_rewrite_line <file> <line> <old> <new>: on that line, replace the link TARGET <old>
# (`](old)`, `](old#anchor)`, `](old "title")` or a `[ref]: old` definition), never link text
# that happens to spell the same name.
fix_rewrite_line() {
  awk -v n="$2" -v old="$3" -v new="$4" '
    NR == n {
      i = index($0, "](" old)
      while (i) {
        c = substr($0, i + 2 + length(old), 1)
        if (c == ")" || c == "#" || c == " " || c == "\t") { $0 = substr($0, 1, i + 1) new substr($0, i + 2 + length(old)); break }
        j = index(substr($0, i + 1), "](" old); i = j ? i + j : 0
      }
      if (!i && match($0, /^[[:space:]]*\[[^]]+\]:[[:space:]]*/) && substr($0, RSTART + RLENGTH, length(old)) == old)
        $0 = substr($0, 1, RSTART + RLENGTH - 1) new substr($0, RSTART + RLENGTH + length(old))
    }
    { print }' "$1" >"$1.docsfix" && mv "$1.docsfix" "$1"
}
# fix_relative <from-file> <to-path>: the shortest relative link target from the file's
# directory (docs/architecture.md -> docs/reports/x.md is reports/x.md, not ../docs/reports/x.md).
fix_relative() {
  local dir=$1 to=$2 up=""
  case "$dir" in */*) dir=${dir%/*}/ ;; *) dir="" ;; esac
  while [ -n "$dir" ] && [ "${dir%%/*}" = "${to%%/*}" ] && [ "${to%%/*}" != "$to" ]; do
    dir=${dir#*/}; to=${to#*/}
  done
  while [ -n "$dir" ]; do up="../$up"; dir=${dir#*/}; done
  echo "$up$to"
}
# fix_md_files: the tracked Markdown files as they are now (every move changes the list).
fix_md_files() { git ls-files -- '*.md' | while IFS= read -r f; do [ -f "$f" ] && echo "$f"; done; }
# fix_links_to <path>: md_links rows from other files whose target resolves to <path>.
fix_links_to() {
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(fix_md_files)
  [ ${#files[@]} -gt 0 ] || return 0
  md_links "${files[@]}" | awk -F'\t' -v p="$1" '$4 == p && $1 != p'
}
# fix_relink <old-path> <new-path>: rewrite every link to the old path in the tracked .md files,
# except from an AGENTS.md when the new home is docs/reports/ (rule 15): a judgment item.
fix_relink() {
  local old=$1 new=$2 file line target _path
  while IFS=$'\t' read -r file line target _path; do
    [ "$file" != "$old" ] || continue
    case "$file" in
      AGENTS.md|*/AGENTS.md)
        case "$new" in docs/reports/*)
          fix_judgment "$file:$line links to $old, now $new; an AGENTS.md never links into docs/reports/ (drop it, or link from README)"
          continue ;;
        esac ;;
    esac
    fix_rewrite_line "$file" "$line" "$target" "$(fix_relative "$file" "$new")"
    git add -- "$file"
  done < <(fix_links_to "$old")
}
# fix_date_of <path>: the YYYY-MM-DD its name starts with, else its first commit's author date.
fix_date_of() {
  local base=${1##*/} d
  if [[ "$base" =~ ^([0-9]{4}-[0-1][0-9]-[0-3][0-9]) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  d=$(git log --diff-filter=A --follow --format=%as -- "$1" | tail -1)
  echo "${d:-$TODAY}"
}
# fix_report_name <path>: docs/reports/<date>-<slug>.md; the slug is the path under docs/ minus
# archive/reports directories and a leading date, lowercased, non [a-z0-9.] runs as one dash.
fix_report_name() {
  local rel=${1#docs/} slug
  slug=$(printf '%s' "${rel%.md}" | awk -F/ '{
    out = ""
    for (i = 1; i <= NF; i++) {
      if (i < NF && $i ~ /^(archive|archives|reports|old)$/) continue
      out = out (out == "" ? "" : "-") $i
    }
    print out }' | tr '[:upper:]' '[:lower:]' | sed -E 's/^[0-9]{4}-[0-1][0-9]-[0-3][0-9][-_ ]*//; s/[^a-z0-9.]+/-/g; s/^-+//; s/-+$//')
  echo "docs/reports/$(fix_date_of "$1")-${slug:-report}.md"
}
# fix_readme_append <line>: add a line at the end of README's Documentation section.
fix_readme_append() {
  local first last end
  read -r first last <<<"$(section_bounds README.md "$DOCS_SECTION")"
  [ -n "$first" ] || { fix_judgment "README.md has no Documentation section to hold '$1'"; return 1; }
  end=$(awk -v a="$first" -v b="$last" 'NR >= a && NR <= b && NF { e = NR } END { print e }' README.md)
  awk -v n="$end" -v add="$1" '{ print } NR == n { print add }' README.md >README.md.docsfix && mv README.md.docsfix README.md
  git add README.md
}
fix_docs() {
  local f new inbound
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "docs-fix: the tree has uncommitted changes; commit or stash them first so the fix is one reviewable diff" >&2
    exit 2
  fi
  for f in ${fix_old_names[@]+"${fix_old_names[@]}"}; do
    if is_tracked docs/operations.md; then
      fix_judgment "$f and docs/operations.md both exist; merge $f into docs/operations.md"
      continue
    fi
    git mv -- "$f" docs/operations.md && fix_did "renamed $f -> docs/operations.md" && fix_relink "$f" docs/operations.md
    TRACKED=$(git ls-files)
  done
  for f in ${fix_outside[@]+"${fix_outside[@]}"}; do
    inbound=$(fix_links_to "$f" | cut -f1 | sort -u)
    # Report-shaped by directory or name, or an unlinked one-off directly under docs/. An
    # unlinked file inside a named subdirectory (docs/architecture/x.md) is structure someone
    # chose, so it is linked, not archived; the reader decides what to do with the folder.
    if [[ "${f%/*}" =~ $REPORT_SHAPED_DIR ]] || [[ "${f##*/}" =~ $REPORT_SHAPED_NAME ]] \
        || { [ -z "$inbound" ] && [ "${f%/*}" = docs ]; }; then
      new=$(fix_report_name "$f")
      if is_tracked "$new" || [ -e "$new" ]; then
        fix_judgment "$f: its report name $new is taken; move it by hand"
        continue
      fi
      mkdir -p docs/reports
      git mv -- "$f" "$new" || { fix_judgment "$f: git mv to $new failed"; continue; }
      fix_did "moved $f -> $new${inbound:+ (links rewritten in: $(tr '\n' ' ' <<<"$inbound"| sed 's/ $//'))}"
      fix_relink "$f" "$new"
    else
      fix_readme_append "- [$f]($f)" && fix_did "linked $f from README's Documentation section"
    fi
  done
  if [ "$fix_contrib_line_missing" = 1 ]; then
    fix_readme_append "- Contributors and agents: see [AGENTS.md](AGENTS.md)." && fix_did "added the contributors line to README's Documentation section"
  fi
  for f in CONTRIBUTING.md .github/CONTRIBUTING.md docs/CONTRIBUTING.md; do
    is_tracked "$f" && fix_judgment "$f: fold what AGENTS.md lacks into AGENTS.md, then git rm it"
  done
  for f in ${fix_agents_report_links[@]+"${fix_agents_report_links[@]}"}; do
    fix_judgment "$f links into docs/reports/; drop it or link from README"
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      'agents '*' OVER'*) fix_judgment "${f#agents } : move reference material to docs/ (an AGENTS.md needs a reader)" ;;
      'h2-outside '*) fix_judgment "AGENTS.md '## ${f#h2-outside }' is not a standard section; move it to docs/ or fold it into Convention deltas" ;;
    esac
  done < <(printf '%s\n' ${report_rows[@]+"${report_rows[@]}"} | sed 's/  */ /g')
  echo "docs-fix: $nfix actions, $njudg judgment items; run docs_check.sh --report to see where the repo stands now"
  exit 0
}
[ "$FIX" = 1 ] && fix_docs

if [ "$REPORT" = 1 ]; then
  echo "docs-report: $(basename "$ROOT"): caps root $ROOT_CAP, area $AREA_CAP bytes; allowances end and rules 13-16 fail from $DIET_FAILS_FROM"
  for row in ${report_rows[@]+"${report_rows[@]}"}; do echo "docs-report:   $row"; done
  count() { printf '%s\n' ${report_rows[@]+"${report_rows[@]}"} | grep -c "$1"; }
  echo "docs-report: totals agents=${#agents_files[@]} over-cap=$(count ' OVER') docs-outside=$(count '^docs-outside ') h2-outside=$(count '^h2-outside ') contributing=$(count '^contributing ') failures=$nfail warnings=$nwarn"
  exit 0
fi
if [ $rc = 0 ]; then
  echo "docs-check: ok (${#agents_files[@]} AGENTS.md files)"
else
  echo "docs-check: FAIL" >&2
fi
exit $rc
