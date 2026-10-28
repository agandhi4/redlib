# The repo's check API: the PR gate (scripts/ci/gate_plan.sh), the git hooks and linux-box's
# publisher (`make publish`) call these targets and nothing else, so a check changes here, once.
#
# Rust comes from rust-toolchain.toml. make's SHELL puts the same pinned toolchain first on PATH
# for every recipe line and $(shell …) that the gate and the hooks use, so a hand-run
# `make ci-quick` works on a machine with no Rust and no recipe can be the one left out
# (devkit decisions 2026-10-19 "Lanes own their Postgres port; recipes run on the pins"). Under the
# gate or a hook the PATH is already built and the line skips it.
SHELL := devkit/bin/toolchain_shell.sh
CARGO ?= cargo
CI_IMAGE ?= redlib:ci
# The image's APP_VERSION, and what ci-smoke asserts the binary and the OCI label report: the bare
# 7-char sha, as publish.sh passes it; the gate passes gate-<pr> (scripts/ci/gate_plan.sh) because
# it builds a merge commit that never ships.
CI_BUILD_VERSION ?= $(shell git rev-parse --short=7 HEAD)

.DEFAULT_GOAL := help
.PHONY: help ci-quick ci-guards ci-lint ci-typecheck ci-unit test-live ci-image ci-smoke publish gate merge install hooks-check devkit-sync devkit-check toolchain-check workflows-check docs-check release-check secrets-check secrets-staged upstream-review pr ci-metrics metrics-snapshot metrics-tighten metrics-rebaseline

help: ## list targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

# The union recipe: the gate runs ci-quick; the two git hooks run its parts
# (scripts/ci/hooks.conf, devkit README "Git hooks"): pre-commit the seconds-long ci-guards,
# secrets-staged and ci-lint, pre-push ci-typecheck and ci-unit. A new quick check goes into a
# part, and a new part into both ci-quick and one hook, or the hooks stop covering the gate.
# Guards first: an in-repo devkit/ edit, a disagreeing Rust pin or an unpinned action fails
# before anything compiles.
ci-quick: ci-guards secrets-check ci-lint ci-typecheck ## guards, secrets, fmt and clippy (the gate's quick job)

ci-guards: devkit-check toolchain-check workflows-check docs-check release-check ## pre-commit: the repo guards, no compile

# rustfmt parses without compiling, so it stays seconds.
ci-lint: ## pre-commit: cargo fmt --check
	$(CARGO) fmt --all -- --check

# clippy is `cargo check` plus its lints: the compile is the cost, so it is pre-push's typecheck.
# It denies cognitive_complexity over clippy.toml's threshold (15): the ratchet key
# complexity.app.cognitive_over_15 graduated to this lint (docs/decisions.md 2026-10-17).
ci-typecheck: ## pre-push: clippy -D warnings, cognitive complexity 15
	$(CARGO) clippy --locked --all-targets -- -D warnings -D clippy::cognitive_complexity

# Offline and deterministic: every test that calls live Reddit is #[ignore = "hits live reddit"]
# (Reddit rate-limits and blocks runner IPs, so they cannot gate a PR). Run those with test-live.
#
# Under devkit's tier guard (docs/decisions.md 2026-10-13, devkit 4f5f282). The budget is the
# whole command's wall time, compile included, so a cold target/ (the gate's fresh worktree)
# counts. The floor is the tests that RAN (ignored ones excluded) and moves only in the PR that
# removes tests, saying why in docs/decisions.md. Both feed build/metrics/tier-unit.json.
UNIT_BUDGET_SECONDS ?= 60
UNIT_MIN_TESTS ?= 78
# The unit tier produces line coverage (devkit docs/decisions.md 2026-10-18): cargo llvm-cov runs
# the same `cargo test` instrumented and writes build/coverage.json, which metrics.conf's cov-app
# converts. cargo-llvm-cov is no rustup component, so COV_TOOL is its one pin, installed once per
# machine by cargo_tool.sh (llvm-tools comes from rust-toolchain.toml). The install runs before
# the guard, so it is not the tier's time. llvm-cov writes into an existing directory only.
COV_TOOL ?= devkit/bin/cargo_tool.sh cargo-llvm-cov@0.9.1 --
ci-unit: ## cargo test with line coverage, offline (live-Reddit tests are #[ignore]d), under the tier guard
	@mkdir -p build
	$(COV_TOOL) devkit/bin/tier_guard.sh unit --budget $(UNIT_BUDGET_SECONDS) --floor cargo=$(UNIT_MIN_TESTS) \
	  -- $(CARGO) llvm-cov --locked --json --summary-only --output-path build/coverage.json

# Not part of any gate. Serial on purpose: client::CLIENT is one process-wide pooled HTTP client,
# and every #[tokio::test] owns its own runtime. In parallel, a test's runtime shuts down while
# another test is using a pooled connection driven by it, and requests fail with "SendRequest".
test-live: ## the #[ignore]d tests that call live Reddit (needs outbound network)
	$(CARGO) test --locked -- --ignored --test-threads=1

# Build only (devkit-check's publish contract): the gate runs ci-image then ci-smoke as two jobs,
# and devkit/bin/publish.sh runs both on linux-box before it pushes. Builds for the host's
# platform (the Dockerfile picks its builder by TARGETARCH), so the gate on the arm64 Mac compiles
# natively instead of under QEMU (issue #7), and linux-box builds the amd64 image it ships.
ci-image: ## build Dockerfile as $(CI_IMAGE) with APP_VERSION=$(CI_BUILD_VERSION)
	DOCKER_CALL_TIMEOUT=900 devkit/bin/docker_bounded.sh build --build-arg APP_VERSION="$(CI_BUILD_VERSION)" -t $(CI_IMAGE) .

# The boot cannot reach a listener offline, so scripts/ci/smoke_image.sh runs the binary's
# --version instead (its header says why). tier_guard is the budget boot_image.sh would have been.
SMOKE_BUDGET_SECONDS ?= 30
ci-smoke: ## run $(CI_IMAGE)'s binary offline; it and the OCI version label must report $(CI_BUILD_VERSION)
	devkit/bin/tier_guard.sh smoke --budget $(SMOKE_BUDGET_SECONDS) -- scripts/ci/smoke_image.sh "$(CI_IMAGE)" "$(CI_BUILD_VERSION)"

# Run by homelab's devkit-publish@redlib.timer on linux-box every 5 min, never by hand on a Mac
# (it refuses anything but native amd64). devkit README "Publish".
publish: ## move ghcr.io/agandhi4/redlib:latest to a gated main (linux-box only)
	devkit/bin/publish.sh .

# devkit/bin/metrics_collect.sh runs the collectors in scripts/ci/metrics.conf and compares the
# snapshot with docs/metrics/ratchet.json as committed on origin/main (devkit README "Metrics
# ratchet"). The collectors are python3 and the pinned toolchain's clippy, which
# metrics_collect.sh puts on PATH itself, plus jscpd: devkit's npm pin on the .nvmrc node,
# installed on first use (devkit/bin/npm_tool.sh), never in the image.
ci-metrics: ## the metrics ratchet: collect, then check against docs/metrics/ratchet.json (gate's last job)
	devkit/bin/metrics_collect.sh check
metrics-snapshot: ## collect the metrics into build/metrics.json, no check
	devkit/bin/metrics_collect.sh snapshot
metrics-tighten: ## collect, then lock the better numbers into docs/metrics/ratchet.json; SEED=1 bounds new keys
	devkit/bin/metrics_collect.sh tighten
# KEYS=<key>[,<key>] loosens only the named bounds and leaves scorecard.json alone (make hands
# command-line variables to the recipe's environment, where metrics_collect.sh reads KEYS).
metrics-rebaseline: ## collect, then overwrite every bound, or only KEYS=a,b (label the PR metrics-rebaseline)
	devkit/bin/metrics_collect.sh rebaseline

gate: ## make gate PR=<n> [GATE_ARGS=--no-post]
	@test -n "$(PR)" || { echo "usage: make gate PR=<number> [GATE_ARGS=--no-post]" >&2; exit 2; }
	devkit/bin/gate.sh "$(PR)" $(GATE_ARGS)

pr: ## make pr BODY_FILE=<file> [TITLE=…] [DRAFT=1]; push, open the PR on origin (never a fork's parent)
	devkit/bin/pr_create.sh

merge: ## make merge PR=<n>; refused unless the head has local-gate success
	@test -n "$(PR)" || { echo "usage: make merge PR=<number>" >&2; exit 2; }
	devkit/bin/pr_merge.sh "$(PR)"

# --fix rewrites core.hooksPath, so a tool that repointed it is undone by the next install.
install: devkit-check ## one-time per checkout/worktree: install the git hooks (.githooks, steps in scripts/ci/hooks.conf)
	devkit/bin/hooks_check.sh --fix

hooks-check: ## core.hooksPath must be .githooks, with executable pre-commit and pre-push
	devkit/bin/hooks_check.sh

devkit-sync: ## pull the latest devkit and record it in .devkit-rev
	devkit/bin/devkit-sync.sh

devkit-check: ## part of ci-quick: devkit/ is unedited
	devkit/bin/devkit-check.sh

upstream-review: ## the upstream redlib commits after .upstream-rev, to port or skip (docs/fork.md "Upstream sync")
	scripts/upstream_review.sh

toolchain-check: ## part of ci-quick: one Rust version string
	devkit/bin/toolchain_check.sh

workflows-check: ## part of ci-quick: SHA pins, draft skip, one PR job, uncancellable pushes
	devkit/bin/workflows_check.sh

docs-check: ## part of ci-quick: AGENTS.md real, CLAUDE.md symlink, decisions.md
	devkit/bin/docs_check.sh

secrets-check: ## part of ci-quick: no committed credentials (fixtures in scripts/ci/secrets_allow.txt)
	devkit/bin/secrets_check.sh .

secrets-staged: ## pre-commit's half of secrets-check: the staged paths only (the gate scans the tree)
	devkit/bin/secrets_check.sh --staged .

release-check: ## part of ci-quick: APP_VERSION baked into the image (ARG/ENV/LABEL), never set by compose
	devkit/bin/release_check.sh
