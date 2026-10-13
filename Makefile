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

.DEFAULT_GOAL := help
.PHONY: help ci-quick ci-unit test-live ci-image gate devkit-sync devkit-check toolchain-check workflows-check docs-check

help: ## list targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

ci-quick: devkit-check toolchain-check workflows-check docs-check ## format, lint and repo guards (Actions + gate)
	$(CARGO) fmt --all -- --check
	$(CARGO) clippy --locked --all-targets -- -D warnings

# Offline and deterministic: every test that calls live Reddit is #[ignore = "hits live reddit"]
# (Reddit rate-limits and blocks runner IPs, so they cannot gate a PR). Run those with test-live.
ci-unit: ## cargo test, offline (live-Reddit tests are #[ignore]d)
	$(CARGO) test --locked

# Not part of any gate. Serial on purpose: client::CLIENT is one process-wide pooled HTTP client,
# and every #[tokio::test] owns its own runtime. In parallel, a test's runtime shuts down while
# another test is using a pooled connection driven by it, and requests fail with "SendRequest".
test-live: ## the #[ignore]d tests that call live Reddit (needs outbound network)
	$(CARGO) test --locked -- --ignored --test-threads=1

# linux/amd64 like ghcr.yml: the builder cross-compiles to x86_64 musl, so an arm64 host's
# default platform would wrap that binary in an arm64 Alpine that cannot run it.
ci-image: ## build Dockerfile.alpine as $(CI_IMAGE)
	$(DOCKER) build --platform linux/amd64 -f Dockerfile.alpine -t $(CI_IMAGE) .

gate: ## make gate PR=<n> [GATE_ARGS=--no-post]
	@test -n "$(PR)" || { echo "usage: make gate PR=<number> [GATE_ARGS=--no-post]" >&2; exit 2; }
	devkit/bin/local_gate.sh "$(PR)" $(GATE_ARGS)

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
