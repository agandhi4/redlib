.PHONY: help install ci-deps ci-quick ci-drift ci-unit ci-db ci-e2e ci-build ci-image ci-smoke \
        ci-metrics gate devkit-sync devkit-check toolchain-check docs-check hooks-check \
        release-check workflows-check

# ---------------------------------------------------------------------------------------
# CI jobs: the ONE definition of each check. The PR gate (devkit/bin/local_gate.sh, driven by
# scripts/ci/gate_plan.sh), the git hooks (scripts/ci/hooks.conf) and .github/workflows/ all
# call these targets, so none of them can drift. Change a check here, never in a caller.
# Node is .nvmrc's: the gate provisions it; elsewhere prepend `$(devkit/bin/node_toolchain.sh .)`
# to PATH when your node differs.
#
#   ci-quick     guards + next typegen + tsc + eslint + ci-drift  (Actions, every ready PR; pre-commit)
#   ci-drift     drizzle/ matches src/db/schema.ts                 (part of ci-quick)
#   ci-unit      vitest tests/unit, hermetic                       (gate; pre-push)
#   ci-db        vitest tests/db on a migrated throwaway Postgres  (gate; needs Docker)
#   ci-e2e       Playwright on a migrated throwaway Postgres       (gate; needs Docker, :3000)
#   ci-build     production `next build`, what Vercel runs         (gate)
#   ci-image, ci-smoke, ci-metrics  stubs: Vercel builds the app (no image), and there is no
#   metrics collector yet. They exit 2 and say so; the gate plan skips them. Never alias.
# ---------------------------------------------------------------------------------------

help:
	@echo "make install         — npm ci, then point git at .githooks/ (once per checkout)"
	@echo "make ci-quick        — devkit, toolchain, docs, release, workflows guards; next typegen, tsc, eslint, migration drift"
	@echo "make ci-unit         — vitest tests/unit (hermetic)"
	@echo "make ci-db           — vitest tests/db on a fresh, migrated throwaway Postgres (needs Docker)"
	@echo "make ci-e2e          — Playwright on a fresh, migrated throwaway Postgres (needs Docker and a free :3000)"
	@echo "make ci-build        — production next build with a placeholder DATABASE_URL (never connects)"
	@echo "make gate PR=<n>     — the PR gate: every job above on PR <n> merged into origin/main"
	@echo "make devkit-sync     — pull the latest agandhi4/devkit into devkit/ and record it in .devkit-rev"

ci-%: export NEXT_TELEMETRY_DISABLED = 1

# For code that reads DATABASE_URL but must never connect (drizzle-kit generate, next build):
# port 1 refuses, so anything that does try fails loudly.
OFFLINE_DATABASE_URL = postgres://offline:offline@127.0.0.1:1/offline

# Frozen to the lockfile; skipped when node_modules is newer than it.
ci-deps:
	@[ node_modules/.package-lock.json -nt package-lock.json ] || npm ci --no-audit --no-fund

# Guards first: an in-repo edit to devkit/, a disagreeing Node pin, a misshapen agent doc, a
# broken release identity or an unpinned action must fail before anything slower runs.
# `next typegen` is load-bearing: .next/types and next-env.d.ts are gitignored, and tsc needs
# them on a fresh checkout (route PageProps, typed routes).
ci-quick: devkit-check toolchain-check docs-check release-check workflows-check ci-deps ci-drift
	npm run typegen
	npm run typecheck
	npm run lint

# drizzle-kit has no `check` that compares the schema with the committed migrations, so
# generate offline and fail on anything it wrote. `git status`, not `git diff`: a new
# migration is an untracked file. Index-only entries (`A `, `M `) are dropped: in the
# pre-commit hook, a migration staged with its schema change is what is being committed, not
# drift. stdin is /dev/null so a rename prompt fails instead of hanging the job.
ci-drift: ci-deps
	DATABASE_URL=$(OFFLINE_DATABASE_URL) npm run db:generate < /dev/null
	@drift=$$(git status --porcelain -- drizzle/ | grep -v '^[^ ?] '); \
	if [ -n "$$drift" ]; then \
	  echo "ci-drift: drizzle/ does not match src/db/schema.ts (run npm run db:generate and commit the result):" >&2; \
	  echo "$$drift" >&2; exit 1; \
	fi

ci-unit: ci-deps
	npm test

# One throwaway Postgres per run (scripts/ci/with_test_pg.sh); the gate passes
# PG_CONTAINER=<name>-gate-<pr>-pg so concurrent gates never share one.
PG_CONTAINER ?= __NAME__-test-pg
ci-db: ci-deps
	PG_CONTAINER="$(PG_CONTAINER)" scripts/ci/with_test_pg.sh npm run test:db

# CI=1: playwright.config.ts reuses a server already on :3000 unless CI is set.
ci-e2e: ci-deps
	devkit/bin/playwright_browsers.sh --project-dir . chromium
	CI=1 PG_CONTAINER="$(PG_CONTAINER)" scripts/ci/with_test_pg.sh npm run test:e2e

# What Vercel runs. Route modules are imported but nothing connects, so the placeholder holds.
ci-build: ci-deps
	DATABASE_URL=$(OFFLINE_DATABASE_URL) npm run build

ci-image:
	@echo "ci-image: __NAME__ publishes no image: Vercel builds it (make ci-build is the local equivalent)" >&2; exit 2

ci-smoke:
	@echo "ci-smoke: __NAME__ publishes no image: Vercel builds it (make ci-build is the local equivalent)" >&2; exit 2

ci-metrics:
	@echo "ci-metrics: __NAME__ has no metrics collector yet (stub from devkit new; devkit/bin/metrics_ratchet.py)" >&2; exit 2

# Usage: make gate PR=<n> [GATE_ARGS=--no-post]
gate:
	@test -n "$(PR)" || { echo "usage: make gate PR=<number> [GATE_ARGS=--no-post]" >&2; exit 2; }
	devkit/bin/local_gate.sh "$(PR)" $(GATE_ARGS)

devkit-sync:     ## pull the latest devkit and record it in .devkit-rev
	devkit/bin/devkit-sync.sh

devkit-check:    ## part of ci-quick: the committed devkit/ tree must equal .devkit-rev
	devkit/bin/devkit-check.sh

toolchain-check: ## part of ci-quick: .nvmrc is the one Node declaration; workflows must agree
	devkit/bin/toolchain_check.sh

docs-check:      ## part of ci-quick: AGENTS.md real + CLAUDE.md symlink, size caps, docs/decisions.md
	devkit/bin/docs_check.sh

# No Dockerfile, so this reports "nothing to check"; it is here so adding one is held to the
# APP_VERSION contract from its first commit.
release-check:   ## part of ci-quick: APP_VERSION baked into an image once (ARG/ENV/LABEL)
	devkit/bin/release_check.sh

workflows-check: ## part of ci-quick: actions SHA-pinned, PR-workflow rules
	devkit/bin/workflows_check.sh

# Reports only; `make install` heals. Not in the gate: it reads the invoking checkout's git config.
hooks-check:     ## core.hooksPath must be .githooks
	devkit/bin/hooks_check.sh

# --fix rewrites core.hooksPath, so a tool that repointed it is undone by the next install.
install: devkit-check ci-deps ## once per checkout/worktree: dependencies + git hooks
	devkit/bin/hooks_check.sh --fix
