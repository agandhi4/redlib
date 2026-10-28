#!/usr/bin/env bash
# make upstream-review: what upstream redlib has that this fork has not decided yet:
#   1. the commits on upstream main after the sha in .upstream-rev, and
#   2. the open upstream PRs updated after the UTC time in .upstream-pr-rev. Fixes wait in
#      open PRs for months (both thread-comment fixes did, 2026-10), so commits alone miss them;
#      a PR that gets new commits after its review is listed again.
# Deciding each one (port or skip) and moving both marks is a PR; the policy and the record of
# picks live in docs/fork.md "Upstream sync". The PR list needs an authenticated gh.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=redlib-org/redlib
url="https://github.com/$repo.git"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$url"
git fetch --quiet upstream

reviewed=$(tr -d '[:space:]' < .upstream-rev)
count=$(git rev-list --count --no-merges "$reviewed..upstream/main")
echo "upstream-review: $count commit(s) after ${reviewed:0:9} (oldest first)"
git log --reverse --no-merges --format='%h %ad %s' --date=short --shortstat "$reviewed..upstream/main"

prs_since=$(tr -d '[:space:]' < .upstream-pr-rev)
prs=$(gh pr list -R "$repo" --state open --limit 200 --search "updated:>$prs_since" \
	--json number,updatedAt,title --jq '.[] | "#\(.number) \(.updatedAt[0:10]) \(.title)"')
echo "upstream-review: $(grep -c . <<<"$prs" || true) open PR(s) updated after $prs_since"
[ -z "$prs" ] || echo "$prs"

echo "upstream-review: after deciding each, record both marks:"
echo "  git rev-parse upstream/main > .upstream-rev && date -u +%Y-%m-%dT%H:%M:%SZ > .upstream-pr-rev"
