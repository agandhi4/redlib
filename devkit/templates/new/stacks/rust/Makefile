.PHONY: help install ci-quick ci-unit ci-db ci-e2e ci-image ci-smoke ci-metrics gate \
        devkit-sync devkit-check toolchain-check docs-check hooks-check release-check workflows-check

# ---------------------------------------------------------------------------------------
# CI jobs: the ONE definition of each check. The PR gate (devkit/bin/local_gate.sh, driven by
# scripts/ci/gate_plan.sh), the git hooks (scripts/ci/hooks.conf) and .github/workflows/ all
# call these targets, so none of them can drift. Change a check here, never in a caller.
#
#   ci-quick     guards + cargo fmt --check + clippy -D warnings  (Actions, every ready PR; pre-commit)
#   ci-unit      cargo test, hermetic                             (gate; pre-push)
#   ci-image     build the image, then ci-smoke                   (gate; publish.yml builds via buildx)
#   ci-db, ci-e2e, ci-metrics  stubs: no database, browser or metrics tier yet. They exit 2
#   and say so; the gate plan skips them with a note. Replace, never alias.
# ---------------------------------------------------------------------------------------

help:
	@echo "make install         — the pinned Rust + crates, then point git at .githooks/ (once per checkout)"
	@echo "make ci-quick        — devkit, toolchain, docs, release, workflows guards; cargo fmt --check, clippy -D warnings"
	@echo "make ci-unit         — cargo test (hermetic)"
	@echo "make ci-image        — build the production image and smoke-boot it (needs Docker)"
	@echo "make ci-smoke        — smoke-boot an already built image (CI_IMAGE=<tag> CI_BUILD_VERSION=<its APP_VERSION>)"
	@echo "make gate PR=<n>     — the PR gate: every job above on PR <n> merged into origin/main"
	@echo "make devkit-sync     — pull the latest agandhi4/devkit into devkit/ and record it in .devkit-rev"

# Every cargo call runs on the toolchain rust-toolchain.toml pins, provisioned on first use
# (scripts/ci/cargo.sh header); nothing here picks a version. --locked everywhere: a stale
# Cargo.lock must fail, not silently re-resolve.
CARGO ?= scripts/ci/cargo.sh

# Guards first: an in-repo edit to devkit/, a disagreeing Rust pin, a misshapen agent doc, a
# broken release identity or an unpinned action must fail before anything compiles.
ci-quick: devkit-check toolchain-check docs-check release-check workflows-check
	$(CARGO) fmt --all -- --check
	$(CARGO) clippy --locked --all-targets -- -D warnings

ci-unit:
	$(CARGO) test --locked

ci-db:
	@echo "ci-db: __NAME__ has no database tier yet (stub from devkit new; devkit/bin/throwaway_pg.sh)" >&2; exit 2

ci-e2e:
	@echo "ci-e2e: __NAME__ has no browser tier yet (stub from devkit new; see AGENTS.md Commands)" >&2; exit 2

#@image
# Plain `docker build` locally; publish.yml builds with buildx + the GHA layer cache and then
# calls ci-smoke on the result, so the boot check is shared. CI_BUILD_VERSION is the image's
# APP_VERSION and what ci-smoke expects /health/ready to report.
CI_IMAGE ?= __NAME__:ci
CI_BUILD_VERSION ?= ci-$(shell git rev-parse --short=7 HEAD)
ci-image:
	docker build -t "$(CI_IMAGE)" --build-arg APP_VERSION="$(CI_BUILD_VERSION)" .
	$(MAKE) --no-print-directory ci-smoke CI_IMAGE="$(CI_IMAGE)" CI_BUILD_VERSION="$(CI_BUILD_VERSION)"

ci-smoke:
	scripts/ci/smoke_image.sh "$(CI_IMAGE)" "$(CI_BUILD_VERSION)"
#@end
#@no-image
ci-image:
	@echo "ci-image: __NAME__ publishes no image (devkit new --no-image; see AGENTS.md)" >&2; exit 2

ci-smoke:
	@echo "ci-smoke: __NAME__ publishes no image (devkit new --no-image; see AGENTS.md)" >&2; exit 2
#@end

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

toolchain-check: ## part of ci-quick: rust-toolchain.toml is the one Rust declaration; FROM rust: and rust-version must agree
	devkit/bin/toolchain_check.sh

docs-check:      ## part of ci-quick: AGENTS.md real + CLAUDE.md symlink, size caps, docs/decisions.md
	devkit/bin/docs_check.sh

release-check:   ## part of ci-quick: APP_VERSION baked into the image once (ARG/ENV/LABEL), never set by compose
	devkit/bin/release_check.sh

workflows-check: ## part of ci-quick: actions SHA-pinned, PR-workflow rules, publish never cancelled
	devkit/bin/workflows_check.sh

# Reports only; `make install` heals. Not in the gate: it reads the invoking checkout's git config.
hooks-check:     ## core.hooksPath must be .githooks
	devkit/bin/hooks_check.sh

# --fix rewrites core.hooksPath, so a tool that repointed it is undone by the next install.
install: devkit-check ## once per checkout/worktree: the pinned toolchain, crates, git hooks
	$(CARGO) fetch --locked
	devkit/bin/hooks_check.sh --fix
