#!/usr/bin/env bash
# `make review PR=<n>`: one local review round on PR <n> (bin/review_rules.sh, whose header is
# the contract), run from origin/main's copy like `make merge` (pr_merge.sh header). Every repo's
# Makefile calls this one line:
#
#   review: ; devkit/bin/pr_review.sh "$(PR)"
set -uo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr_merge.sh" --rules review_rules.sh "$@"
