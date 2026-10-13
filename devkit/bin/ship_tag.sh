#!/usr/bin/env bash
# Mark a commit as shipped: create the annotated git tag `ship-<YYYY-MM-DD>-<sha7>` on GitHub.
# The deploying step calls it right after it moves `latest` (Orbit/locus CI after the push;
# finplat's deploy function after prod /health/ready reports the sha). Design:
# ~/projects/solo/standardization/release-identity-design.md §2.
#
# Usage: devkit/bin/ship_tag.sh <owner/repo> <sha> [--date YYYY-MM-DD]
#   <sha>   full 40-hex commit sha; it must be reachable from main
#   --date  the ship date in the tag name; default today in UTC
#   On success prints exactly one stdout line, SHIP_TAG=<tag>, whether the tag was created now
#   or already pointed at <sha>. Progress goes to stderr.
#   Exit 0 ok, 1 refused or failed (sha not on main, tag points at another commit, gh error),
#   2 usage.
#
# Why it is shaped this way:
# - `gh api` only: no clone, no push credential, so it runs the same in Actions (GH_TOKEN with
#   `contents: write`) and on linux-box. `--jq` is gh's built-in, so jq is not needed either.
# - Idempotent by comparing commits, not by "tag exists": the queue and the timer can ship the
#   same sha on the same day, and a rerun of a deploy job must not fail. A tag of that name on a
#   different commit (a sha7 collision, or a hand-made tag) is refused, never moved.
# - The tag object is created before the ref. If another shipper wins the race, the ref POST
#   answers 422 and the ref is re-read and judged by the same rule; the orphaned tag object is
#   unreferenced and GitHub garbage-collects it.
# - The main check uses compare/main...<sha>: `identical` or `behind` means <sha> is main's tip
#   or an ancestor of it. A PR-branch or force-pushed-away sha would mark something never merged.
set -uo pipefail

usage() { echo "usage: $0 <owner/repo> <sha> [--date YYYY-MM-DD]" >&2; exit 2; }
die() { echo "ship_tag: $*" >&2; exit 1; }

REPO=
SHA=
DATE=
while [ $# -gt 0 ]; do
  case "$1" in
    --date) [ $# -ge 2 ] || usage; DATE=$2; shift ;;
    -h|--help) usage ;;
    -*) echo "ship_tag: unknown option $1" >&2; usage ;;
    *)
      if [ -z "$REPO" ]; then REPO=$1
      elif [ -z "$SHA" ]; then SHA=$1
      else usage
      fi ;;
  esac
  shift
done
[ -n "$REPO" ] && [ -n "$SHA" ] || usage
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "ship_tag: repo must be owner/name (got '$REPO')" >&2; usage; }
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "ship_tag: sha must be a full 40-hex lowercase commit sha (got '$SHA')" >&2; usage; }
DATE=${DATE:-$(date -u +%F)}
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ship_tag: --date must be YYYY-MM-DD (got '$DATE')" >&2; usage; }

command -v gh >/dev/null || die "gh not found (brew install gh && gh auth login)"

SHA7=${SHA:0:7}
TAG="ship-$DATE-$SHA7"
ERR=$(mktemp "${TMPDIR:-/tmp}/ship_tag.XXXXXX") || die "mktemp failed"
trap 'rm -f "$ERR"' EXIT

# api <gh api args...>: stdout is the --jq result; gh's stderr is kept in $ERR so callers can
# tell a 404/422 from any other failure.
api() { gh api "$@" 2>"$ERR"; }
api_status_is() { grep -q "HTTP $1" "$ERR"; }
api_error() { tr '\n' ' ' <"$ERR"; }

succeed() {
  echo "SHIP_TAG=$TAG"
  exit 0
}

# Sets TARGET to the commit refs/tags/$TAG points at (peeling annotated tags). Returns 1 when the
# ref does not exist; any other failure is fatal.
read_tag() {
  local kind_sha kind sha depth=0
  if ! kind_sha=$(api "repos/$REPO/git/ref/tags/$TAG" --jq '.object.type + " " + .object.sha'); then
    api_status_is 404 && return 1
    die "reading refs/tags/$TAG failed: $(api_error)"
  fi
  kind=${kind_sha%% *}; sha=${kind_sha#* }
  # A tag of a tag is legal git; peel a few levels, then give up rather than loop.
  while [ "$kind" = tag ] && [ $depth -lt 5 ]; do
    kind_sha=$(api "repos/$REPO/git/tags/$sha" --jq '.object.type + " " + .object.sha') \
      || die "reading tag object $sha failed: $(api_error)"
    kind=${kind_sha%% *}; sha=${kind_sha#* }
    depth=$((depth + 1))
  done
  [ "$kind" = commit ] || die "refs/tags/$TAG does not resolve to a commit (got $kind $sha)"
  TARGET=$sha
}

# The tag exists: same commit is success, anything else is a refusal.
judge_existing() {
  [ "$TARGET" = "$SHA" ] || die "$TAG already points at ${TARGET:0:7}, not $SHA7; refusing to move it"
  echo "ship_tag: $TAG already at $SHA7" >&2
  succeed
}

status=$(api "repos/$REPO/compare/main...$SHA" --jq .status) \
  || die "cannot compare $SHA7 with main in $REPO: $(api_error)"
case "$status" in
  identical|behind) echo "ship_tag: $SHA7 is on main of $REPO ($status)" >&2 ;;
  *) die "$SHA7 is not reachable from main of $REPO (compare: $status); only merged commits ship" ;;
esac

if read_tag; then judge_existing; fi

tag_sha=$(api -X POST "repos/$REPO/git/tags" -f tag="$TAG" -f message="Shipped $SHA on $DATE" \
  -f object="$SHA" -f type=commit --jq .sha) || die "creating tag object $TAG failed: $(api_error)"

if api -X POST "repos/$REPO/git/refs" -f ref="refs/tags/$TAG" -f sha="$tag_sha" --jq .ref >/dev/null; then
  echo "ship_tag: created $TAG -> $SHA7 in $REPO" >&2
  succeed
fi
api_status_is 422 || die "creating refs/tags/$TAG failed: $(api_error)"
echo "ship_tag: refs/tags/$TAG appeared concurrently; re-reading" >&2
read_tag || die "creating refs/tags/$TAG answered 422 but the ref does not exist: $(api_error)"
judge_existing
