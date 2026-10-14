#!/usr/bin/env bash
# Guard: per-area halves of the standard ci-* targets are named tier first, `ci-<tier>-<area>`
# (ci-unit-backend, ci-quick-web), the order of the standard names they split (ci-quick ci-unit
# ci-db ci-image ci-e2e ci-smoke). The fleet standard never fixed the order, so finplat grew
# ci-backend-unit beside Orbit's ci-unit-backend; one order lets gate plans, hooks.conf and
# workflows be read across repos without a lookup (devkit decisions 2026-10-13, "Three guards").
#   - Reports every root-Makefile target (and its literal includes) shaped
#     `ci-<area>-<tier>[-<rest>]`, naming the expected `ci-<tier>-<area>[-<rest>]`.
#     area: backend frontend server web e2e ios swift
#     tier: quick unit db image e2e smoke drift lint static
#     Targets outside both lists (ci-backend-deps, ci-swift-test) are not judged.
#   - Warns before FAILS_FROM below, fails on and after it (the same warn-then-fail scheme as
#     docs_check's docs_rule), so the sync that brings the rule breaks no consumer's ci-quick.
#     CI_TARGETS_CHECK_TODAY=YYYY-MM-DD overrides today (tests).
# Renaming a target also means its callers: scripts/ci/gate_plan.sh, hooks.conf, workflows,
# AGENTS.md and README. devkit's hook scoping (hook_steps.sh) already matches both orders.
# No root Makefile (devkit itself), nothing to check.
# Output: one `ci-targets-check: …` line per target on stderr, then `ci-targets-check: ok` on
# stdout or `ci-targets-check: FAIL` on stderr. Exit 0 ok, 1 fail.
# Usage: devkit/bin/ci_targets_check.sh [repo-root]      (run by toolchain_check.sh, so ci-quick)
set -uo pipefail
# Before the cd: the script's own path may be relative.
# shellcheck source=bin/_makefile_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_makefile_lib.sh"
ROOT=${1:-$(git rev-parse --show-toplevel)}
cd "$ROOT" || exit 2

FAILS_FROM=2026-11-15
TODAY=${CI_TARGETS_CHECK_TODAY:-$(date +%F)}
AREAS='backend|frontend|server|web|e2e|ios|swift'
TIERS='quick|unit|db|image|e2e|smoke|drift|lint|static'

if [ ! -f Makefile ]; then
  echo "ci-targets-check: no Makefile; nothing to check"; exit 0
fi

rc=0
for target in $(makefile_targets); do
  [[ "$target" =~ ^ci-($AREAS)-($TIERS)(-.*)?$ ]] || continue
  expected="ci-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
  msg="Makefile target '$target' is area-first; rename it '$expected' (ci-<tier>-<area>) and its callers"
  if [[ "$TODAY" < "$FAILS_FROM" ]]; then
    echo "ci-targets-check: warning: $msg (fails from $FAILS_FROM)" >&2
  else
    echo "ci-targets-check: $msg" >&2; rc=1
  fi
done

if [ $rc = 0 ]; then echo "ci-targets-check: ok"; else echo "ci-targets-check: FAIL" >&2; fi
exit $rc
