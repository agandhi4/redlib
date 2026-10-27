#!/usr/bin/env bash
# `make pr`: push this branch and open its PR on origin's repo, never on gh's default (in a fork,
# its parent: redlib-org/redlib#605, 2026-10-26; bin/_gh_repo_lib.sh). Every repo's Makefile
# calls this one line, as it calls pr_merge.sh:
#
#   pr: ; devkit/bin/pr_create.sh
#
# Usage: make pr BODY_FILE=<file> [TITLE='<title>'] [DRAFT=1]
#    or: devkit/bin/pr_create.sh --body-file <file> [--title <title>] [--draft]
#   A flag wins over its make variable (make exports command-line variables to the recipe).
#   The title defaults to the subject of HEAD's commit. The body is a file (`-` reads stdin),
#   never a make value: make expands `$` in one (`$x` is lost; a TITLE writes it `$$`) and a
#   shell would run its backticks.
# Refused (exit 1, one `pr: refused: …` line) before anything is pushed: a detached HEAD or main,
# an empty body. An agent's body (devkit_is_agent, bin/_trailer_lib.sh) gets PR_FOOTER, the
# harness attribution line, appended when no line of it is that line; a person's is left as it
# is. The commits' Claude trailer is the commit-msg hook's rule, not this one's.
# Then gh's default repo is made origin (gh_default_heal, so later bare gh calls here are safe
# too), the branch is pushed to origin with upstream tracking (through the pre-push hook; never
# --no-verify) and `gh pr create --repo <origin> --base main --head <branch>` prints the URL.
# Exit: 0 opened, 1 refused, 2 usage or environment (no gh, origin not on GitHub), else git's or
# gh's own code.
set -uo pipefail

readonly PR_FOOTER='🤖 Generated with [Claude Code](https://claude.com/claude-code)'

usage() { echo "usage: $0 --body-file <file|-> [--title <title>] [--draft]   (make pr BODY_FILE=<file> [TITLE=…] [DRAFT=1])"; }
refuse() { echo "pr: refused: $*" >&2; exit 1; }

# parse_args <args...>: set title, body_file and draft from the flags over the make variables.
parse_args() {
  title=${TITLE:-} body_file=${BODY_FILE:-} draft=${DRAFT:-0}
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) [ $# -ge 2 ] || { usage >&2; exit 2; }; title=$2; shift ;;
      --body-file) [ $# -ge 2 ] || { usage >&2; exit 2; }; body_file=$2; shift ;;
      --draft) draft=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$draft" in 0|1) ;; *) echo "pr: DRAFT must be 1 or unset (got '$draft')" >&2; exit 2 ;; esac
  [ -n "$body_file" ] || { echo "pr: no body: write it to a file and pass BODY_FILE=<file> (or --body-file -, stdin)" >&2; usage >&2; exit 2; }
}

# write_body <source> <dest>: the body as gh gets it (header: refused when empty, an agent's footer).
write_body() {
  if [ "$1" = - ]; then cat >"$2"; else cat -- "$1" >"$2"; fi \
    || { echo "pr: cannot read the body from $1" >&2; exit 2; }
  grep -q '[^[:space:]]' "$2" || refuse "the body in $1 is empty"
  devkit_is_agent || return 0
  ! tr -d '\r' <"$2" | sed 's/[[:space:]]*$//' | grep -qxF -- "$PR_FOOTER" || return 0
  [ -z "$(tail -c 1 "$2")" ] || echo >>"$2"
  printf '\n%s\n' "$PR_FOOTER" >>"$2"
}

parse_args "$@"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gh_repo_lib.sh  # origin_slug, gh_default_heal
. "$HERE/_gh_repo_lib.sh"
# shellcheck source=bin/_trailer_lib.sh  # devkit_is_agent: whose body gets the footer
. "$HERE/_trailer_lib.sh"
command -v gh >/dev/null || { echo "pr: gh not found (brew install gh && gh auth login)" >&2; exit 2; }
ROOT=$(git rev-parse --show-toplevel) || exit 2
SLUG=$(origin_slug "$ROOT") \
  || { echo "pr: origin ($(git -C "$ROOT" config --get remote.origin.url || echo none)) is not a GitHub repo" >&2; exit 2; }
branch=$(git -C "$ROOT" symbolic-ref -q --short HEAD) || refuse "HEAD is detached; check out the PR's branch"
[ "$branch" != main ] || refuse "HEAD is main; commit on a branch"
[ -n "$title" ] || title=$(git -C "$ROOT" log -1 --format=%s) || exit 2
BODY=$(mktemp "${TMPDIR:-/tmp}/devkit-pr.XXXXXX") || exit 2
trap 'rm -f "$BODY"' EXIT
write_body "$body_file" "$BODY"

gh_default_heal "$ROOT" pr || echo "pr: cannot make origin gh's default repo (git above); this PR names it anyway" >&2
git -C "$ROOT" push -q -u origin "HEAD:refs/heads/$branch" || exit
args=(pr create --repo "$SLUG" --base main --head "$branch" --title "$title" --body-file "$BODY")
[ "$draft" = 0 ] || args+=(--draft)
echo "pr: opening $branch on $SLUG"
gh "${args[@]}"
