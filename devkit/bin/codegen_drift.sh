#!/usr/bin/env bash
# Codegen drift: a generated file (OpenAPI spec, typed client) as committed equals what its
# generator writes now. A server schema change shipped without regenerated types keeps
# compiling against stale ones and surfaces only at runtime. One mechanism for the fleet's
# copies (finplat ci-drift, locus web codegen:check), so a repo's target is one line.
#
#   devkit/bin/codegen_drift.sh [--ref <rev> | --index] [--regen '<cmd>'] -- '<generator>' <path>...
#     e.g. devkit/bin/codegen_drift.sh -- '(cd backend && uv run python -m scripts.dump_openapi
#          "$DRIFT_OUT/openapi.json") && (cd frontend && pnpm exec openapi-typescript
#          "$DRIFT_OUT/openapi.json" -o "$DRIFT_OUT/frontend/src/api/schema.d.ts")'
#          openapi.json frontend/src/api/schema.d.ts
#
# <generator> is ONE shell string, run by bash from the current directory with DRIFT_OUT set to
# an absolute, empty temp dir (each <path>'s parent already made): it writes $DRIFT_OUT/<path>
# for every <path>, never the working tree, so a developer's uncommitted edits survive a hook
# run (DRIFT_OUT is absolute even under a relative TMPDIR, since a generator may cd). The same
# string run by `bash -c` with DRIFT_OUT="$PWD" regenerates in place; that line, quoted, is the
# default regenerate hint, run from the same directory (--regen names the repo's own target
# instead, e.g. 'make openapi'). Not `DRIFT_OUT=. <generator>`: a subshell cannot follow an
# assignment, the assignment reaches only the first command of a list, and `.` moves with a cd.
#
# Each <path> (relative to the current directory) is compared with its committed bytes at
# --ref (default $DRIFT_REF, else HEAD; the gate's worktree has HEAD at the merged tree), or the
# staged bytes with --index (pre-commit). Output: per drifted path
# `codegen-drift: <path>: <why>` and up to 20 diff lines on stderr, then
# `codegen-drift: FAIL (<n> of <m> drifted) at <ref>; regenerate with: <cmd>` on stderr, or
# `codegen-drift: ok (<m> files match <ref>)` on stdout. Exit 0 ok, 1 drift, 2 a bad call (a
# --ref that names no revision too, which no regeneration fixes), a generator that failed (its
# last 20 lines shown) or did not write a <path>.
#
# --index and unstaged edits: the generator reads the working tree, so with a file other than a
# <path> modified and not staged, or untracked and not ignored, it would judge a tree that is not
# the commit (a valid commit fails, or staged output made from unstaged inputs passes). That run
# prints `codegen-drift: SKIP (--index: unstaged changes to <file>...; …)` on stdout and exits 0
# without running the generator: the gate's --ref run judges the commit. Not an index checkout
# instead: generators need the ignored trees (node_modules, .venv) a checkout of the index lacks.
set -euo pipefail

usage() {
  echo "usage: codegen_drift.sh [--ref <rev> | --index] [--regen '<cmd>'] -- '<generator>' <path>..." >&2
  exit 2
}

# <path>...: exit 2 unless each is relative and stays below the current directory.
require_relative() {
  local path
  for path in "$@"; do
    case "$path" in
      /* | ../* | */../* | *.. | "")
        echo "codegen-drift: $path: must be a relative path below the current directory" >&2
        exit 2 ;;
    esac
  done
}

# <string>: it, single-quoted for a shell (each ' as '\'').
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# <path>: 0 when $out/<path> equals its committed bytes at $ref, else 1 with the why.
matches_committed() {
  local path="$1"
  if [ ! -f "$out/$path" ]; then
    echo "codegen-drift: $path: the generator did not write \$DRIFT_OUT/$path" >&2
    exit 2
  fi
  if ! git show "$ref:./$path" >"$tmp/committed" 2>/dev/null; then
    echo "codegen-drift: $path: missing at $label" >&2
    return 1
  fi
  cmp -s "$tmp/committed" "$out/$path" && return 0
  echo "codegen-drift: $path: differs from $label" >&2
  diff -u "$tmp/committed" "$out/$path" | sed -n '3,22p' >&2 || true
  return 1
}

ref="${DRIFT_REF:-HEAD}"
regen=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) [ $# -ge 2 ] || usage; ref="$2"; shift 2 ;;
    --index) ref=""; shift ;;
    --regen) [ $# -ge 2 ] || usage; regen="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ $# -ge 2 ] || usage
generator="$1"
shift
# `git show <ref>:./<path>` resolves against the current directory; an empty ref is the index.
label="${ref:-the index}"
# shellcheck disable=SC2016  # $PWD is for the shell the hint is pasted into
[ -n "$regen" ] || regen='DRIFT_OUT="$PWD" bash -c '"$(shell_quote "$generator")"

# unstaged_inputs <path>...: up to three files outside the <path>s that the generator would read
# but the commit lacks: tracked with unstaged changes, or untracked and not ignored (a new schema
# left out of `git add`). Paths are repo-root relative. The exclusions are literal, so an output
# named gen/[ab].txt excludes itself and never gen/a.txt (devkit#188).
unstaged_inputs() {
  local path
  local -a pathspec=(":(top)")
  for path in "$@"; do pathspec+=(":(exclude,literal)$path"); done
  # awk, not head: it drains the list, so git never dies of SIGPIPE under pipefail.
  { git diff --name-only -- "${pathspec[@]}"
    git ls-files --others --exclude-standard --full-name -- "${pathspec[@]}"
  } | awk 'NR <= 3 { printf "%s ", $0 }'
}

# preflight <path>...: refuse a bad call (exit 2) before any generator runs, and skip (exit 0)
# an --index run whose inputs have unstaged edits (header). A function so the script's top level
# stays one straight line of steps.
preflight() {
  local unstaged
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "codegen-drift: $(pwd) is not inside a git work tree" >&2; exit 2; }
  require_relative "$@"
  if [ -n "$ref" ] && ! git rev-parse --verify --quiet "$ref^{tree}" >/dev/null; then
    echo "codegen-drift: --ref $ref: not a revision" >&2
    exit 2
  fi
  [ -z "$ref" ] || return 0
  unstaged=$(unstaged_inputs "$@")
  if [ -n "$unstaged" ]; then
    echo "codegen-drift: SKIP (--index: unstaged changes to ${unstaged% }; the generator would read them, not the commit; the gate judges it)"
    exit 0
  fi
}
preflight "$@"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/codegen_drift.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"  # absolute: the generator may cd before writing $DRIFT_OUT
out="$tmp/out"
for path in "$@"; do mkdir -p "$out/$(dirname "$path")"; done

if ! DRIFT_OUT="$out" bash -c "$generator" >"$tmp/generator.log" 2>&1; then
  tail -n 20 "$tmp/generator.log" >&2
  echo "codegen-drift: the generator failed (last 20 lines above): $generator" >&2
  exit 2
fi

drifted=0
for path in "$@"; do matches_committed "$path" || drifted=$((drifted + 1)); done
if [ "$drifted" -gt 0 ]; then
  echo "codegen-drift: FAIL ($drifted of $# drifted) at $label; regenerate with: $regen" >&2
  exit 1
fi
echo "codegen-drift: ok ($# files match $label)"
