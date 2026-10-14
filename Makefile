# The repo's check API: the PR gate (scripts/ci/gate_plan.sh) and Actions (quick-check.yml) call
# these targets and nothing else, so a check changes here, once.
#
# Rust comes from rust-toolchain.toml. This Makefile never picks a toolchain: rustup's proxy
# resolves the file, the gate puts devkit/bin/rust_toolchain.sh's toolchain first on PATH, and
# Actions installs it with setup-rust-toolchain. On a machine without Rust:
#   PATH="$(devkit/bin/rust_toolchain.sh .):$PATH" make ci-quick
CARGO ?= cargo
DOCKER ?= docker
CI_IMAGE ?= redlib:ci
# The image's APP_VERSION, and what ci-image then asserts its ENV and OCI label carry: the bare
# 7-char sha, as ghcr.yml passes it; the gate passes gate-<pr> (scripts/ci/gate_plan.sh) because
# it builds a merge commit that never ships.
CI_BUILD_VERSION ?= $(shell git rev-parse --short=7 HEAD)

.DEFAULT_GOAL := help
.PHONY: help ci-quick ci-unit test-live ci-image gate install hooks-check devkit-sync devkit-check toolchain-check workflows-check docs-check release-check

help: ## list targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

ci-quick: devkit-check toolchain-check workflows-check docs-check release-check ## format, lint and repo guards (Actions + gate)
	$(CARGO) fmt --all -- --check
	$(CARGO) clippy --locked --all-targets -- -D warnings

# Offline and deterministic: every test that calls live Reddit is #[ignore = "hits live reddit"]
# (Reddit rate-limits and blocks runner IPs, so they cannot gate a PR). Run those with test-live.
#
# Under devkit's tier guard (docs/decisions.md 2026-10-13, devkit 4f5f282). The budget is the
# whole command's wall time, compile included, so a cold target/ (the gate's fresh worktree)
# counts. The floor is the tests that RAN (ignored ones excluded) and moves only in the PR that
# removes tests, saying why in docs/decisions.md. Both feed build/metrics/tier-unit.json.
UNIT_BUDGET_SECONDS ?= 60
UNIT_MIN_TESTS ?= 78
ci-unit: ## cargo test, offline (live-Reddit tests are #[ignore]d), under the tier guard
	devkit/bin/tier_guard.sh unit --budget $(UNIT_BUDGET_SECONDS) --floor cargo=$(UNIT_MIN_TESTS) \
	  -- $(CARGO) test --locked

# Not part of any gate. Serial on purpose: client::CLIENT is one process-wide pooled HTTP client,
# and every #[tokio::test] owns its own runtime. In parallel, a test's runtime shuts down while
# another test is using a pooled connection driven by it, and requests fail with "SendRequest".
test-live: ## the #[ignore]d tests that call live Reddit (needs outbound network)
	$(CARGO) test --locked -- --ignored --test-threads=1

# Builds for the host's platform (the Dockerfile picks its builder by TARGETARCH), so the gate on
# the arm64 Mac compiles natively instead of under QEMU (issue #7). ghcr.yml publishes linux/amd64
# from the same Dockerfile; the two differ only in which builder stage runs.
#
# No boot: the listener opens only after OAuth bootstrap against live Reddit (AGENTS.md "Startup
# order"), so devkit's boot_image.sh BOOT_EXPECT_VERSION cannot run here. The build arg is checked
# where it lands instead: the image's ENV (what the app reads) and its OCI version label.
ci-image: ## build Dockerfile as $(CI_IMAGE) with APP_VERSION=$(CI_BUILD_VERSION), then assert ENV + label carry it
	$(DOCKER) build --build-arg APP_VERSION="$(CI_BUILD_VERSION)" -t $(CI_IMAGE) .
	@env=$$($(DOCKER) image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $(CI_IMAGE) | sed -n 's/^APP_VERSION=//p'); \
	label=$$($(DOCKER) image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' $(CI_IMAGE)); \
	if [ "$$env" = "$(CI_BUILD_VERSION)" ] && [ "$$label" = "$(CI_BUILD_VERSION)" ]; then \
	  echo "ci-image: APP_VERSION and image.version label are $(CI_BUILD_VERSION)"; \
	else \
	  echo "ci-image: expected $(CI_BUILD_VERSION), image has APP_VERSION='$$env' label='$$label'" >&2; exit 1; \
	fi

gate: ## make gate PR=<n> [GATE_ARGS=--no-post]
	@test -n "$(PR)" || { echo "usage: make gate PR=<number> [GATE_ARGS=--no-post]" >&2; exit 2; }
	devkit/bin/gate.sh "$(PR)" $(GATE_ARGS)

# --fix rewrites core.hooksPath, so a tool that repointed it is undone by the next install.
install: devkit-check ## one-time per checkout/worktree: install the git hooks (.githooks, steps in scripts/ci/hooks.conf)
	devkit/bin/hooks_check.sh --fix

hooks-check: ## core.hooksPath must be .githooks, with executable pre-commit and pre-push
	devkit/bin/hooks_check.sh

devkit-sync: ## pull the latest devkit and record it in .devkit-rev
	devkit/bin/devkit-sync.sh

devkit-check: ## part of ci-quick: devkit/ is unedited
	devkit/bin/devkit-check.sh

toolchain-check: ## part of ci-quick: one Rust version string
	devkit/bin/toolchain_check.sh

workflows-check: ## part of ci-quick: SHA pins, draft skip, one PR job, uncancellable pushes
	devkit/bin/workflows_check.sh

docs-check: ## part of ci-quick: AGENTS.md real, CLAUDE.md symlink, decisions.md
	devkit/bin/docs_check.sh

release-check: ## part of ci-quick: APP_VERSION baked into the image (ARG/ENV/LABEL), never set by compose
	devkit/bin/release_check.sh
