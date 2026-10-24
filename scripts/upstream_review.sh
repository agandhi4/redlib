#!/usr/bin/env bash
# make upstream-review: the upstream redlib commits not yet reviewed, i.e. everything after the
# sha in .upstream-rev. Deciding each one (port or skip) and moving .upstream-rev is a PR; the
# policy and the record of picks live in docs/fork.md "Upstream sync".
set -euo pipefail
cd "$(dirname "$0")/.."

url=https://github.com/redlib-org/redlib.git
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$url"
git fetch --quiet upstream

reviewed=$(tr -d '[:space:]' < .upstream-rev)
count=$(git rev-list --count --no-merges "$reviewed..upstream/main")
echo "upstream-review: $count commit(s) after ${reviewed:0:9} (oldest first)"
git log --reverse --no-merges --format='%h %ad %s' --date=short --shortstat "$reviewed..upstream/main"
if [ "$count" -gt 0 ]; then
	echo "upstream-review: after deciding each, record the head: git rev-parse upstream/main > .upstream-rev"
fi
