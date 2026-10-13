.PHONY: help install ci-guards ci-quick ci-swift-lint ci-swift ci-unit ci-db ci-e2e ci-image ci-smoke ci-metrics gate \
        devkit-sync devkit-check toolchain-check docs-check hooks-check release-check workflows-check

# ---------------------------------------------------------------------------------------
# CI jobs: the ONE definition of each check. The PR gate (devkit/bin/local_gate.sh, driven by
# scripts/ci/gate_plan.sh), the git hooks (scripts/ci/hooks.conf) and .github/workflows/ all
# call these targets, so none of them can drift. Change a check here, never in a caller.
#
#   ci-guards      devkit, toolchain, docs, release, workflows guards  (Actions: the only Linux tier)
#   ci-quick       ci-guards + ci-swift-lint                           (pre-commit; gate on a Mac)
#   ci-swift-lint  xcrun swift-format lint --strict                    (pre-push; part of ci-quick)
#   ci-swift       xcodegen + xcodebuild build for the iOS Simulator   (gate only; Mac)
#   ci-unit        __PASCAL_NAME__Tests (Swift Testing) on the newest iPhone simulator (gate only; Mac)
#   ci-db, ci-e2e, ci-image, ci-smoke, ci-metrics  stubs: no database, UI-test, image or
#   metrics tier. They exit 2 and say so; the gate plan skips them. Replace, never alias.
# xcodebuild never runs in a hook: it takes minutes.
# ---------------------------------------------------------------------------------------

help:
	@echo "make install         — check for xcodegen, then point git at .githooks/ (once per checkout)"
	@echo "make ci-guards       — devkit, toolchain, docs, release, workflows guards (runs anywhere)"
	@echo "make ci-quick        — ci-guards, then swift-format lint --strict (Mac)"
	@echo "make ci-swift-lint   — xcrun swift-format lint --strict (config: .swift-format)"
	@echo "make ci-swift        — xcodegen generate + xcodebuild build for the iOS Simulator (Mac, slow)"
	@echo "make ci-unit         — __PASCAL_NAME__Tests on the newest iPhone simulator; SIMULATOR_ID=<udid> overrides (Mac, slow)"
	@echo "make gate PR=<n>     — the PR gate: every job above on PR <n> merged into origin/main"
	@echo "make devkit-sync     — pull the latest agandhi4/devkit into devkit/ and record it in .devkit-rev"

# Guards first: an in-repo edit to devkit/, a Swift that disagrees with .swift-version, a
# misshapen agent doc or an unpinned action fails before anything slower runs. hooks-check is
# not here: it reads the invoking checkout's git config (see below).
ci-guards: devkit-check toolchain-check docs-check release-check workflows-check

ci-quick: ci-guards ci-swift-lint

# swift-format ships with Xcode: nothing to install or pin beyond .swift-version. Repo style
# lives in .swift-format.
SWIFT_SOURCES = Sources Tests

ci-swift-lint:
	xcrun swift-format lint --strict --recursive --parallel $(SWIFT_SOURCES)

# The generic simulator destination needs no installed runtime and no signing identity;
# CODE_SIGNING_ALLOWED=NO keeps every target independent of the team certificate. DerivedData
# stays inside the checkout (gitignored) so parallel worktrees never share one.
PROJECT = __PASCAL_NAME__.xcodeproj
SCHEME = __PASCAL_NAME__
XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath DerivedData -quiet CODE_SIGNING_ALLOWED=NO

ci-swift:
	@[ "$$(uname)" = Darwin ] || { echo "ci-swift: needs macOS with Xcode" >&2; exit 1; }
	xcodegen generate --quiet
	$(XCODEBUILD) -destination 'generic/platform=iOS Simulator' build

# Tests need a concrete simulator (the generic destination only builds): the last available
# iPhone in simctl's list, which is on the newest installed runtime, so an Xcode upgrade needs
# no edit here. Override with SIMULATOR_ID=<udid>. -quiet prints failures only, so the result
# bundle's summary is echoed, and zero tests run (the target dropped from the scheme) fails
# rather than passing vacuously.
SWIFT_TEST_RESULT = DerivedData/ci-unit.xcresult

ci-unit:
	@[ "$$(uname)" = Darwin ] || { echo "ci-unit: needs macOS with Xcode" >&2; exit 1; }
	xcodegen generate --quiet
	@sim="$${SIMULATOR_ID:-$$(xcrun simctl list devices available | grep iPhone | tail -1 \
	  | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}')}"; \
	[ -n "$$sim" ] || { echo "ci-unit: no iPhone simulator (Xcode > Settings > Components)" >&2; exit 1; }; \
	echo "ci-unit: simulator $$sim"; \
	rm -rf $(SWIFT_TEST_RESULT); \
	$(XCODEBUILD) -destination "id=$$sim" -resultBundlePath $(SWIFT_TEST_RESULT) test; \
	status=$$?; summary=DerivedData/ci-unit.json; \
	xcrun xcresulttool get test-results summary --path $(SWIFT_TEST_RESULT) > $$summary 2>/dev/null || exit $$status; \
	passed=$$(plutil -extract passedTests raw $$summary); failed=$$(plutil -extract failedTests raw $$summary); \
	echo "ci-unit: $$passed passed, $$failed failed"; \
	[ "$$failed" -eq 0 ] || { plutil -extract testFailures json -o - $$summary; echo; }; \
	[ "$$status" -eq 0 ] && [ "$$passed" -gt 0 ] && [ "$$failed" -eq 0 ]

ci-db:
	@echo "ci-db: __NAME__ has no database tier (stub from devkit new; an iOS app)" >&2; exit 2

ci-e2e:
	@echo "ci-e2e: __NAME__ has no UI-test tier yet (stub from devkit new; an XCUITest target in project.yml)" >&2; exit 2

ci-image:
	@echo "ci-image: __NAME__ publishes no image (an iOS app ships through Xcode and TestFlight; see AGENTS.md)" >&2; exit 2

ci-smoke:
	@echo "ci-smoke: __NAME__ publishes no image (an iOS app ships through Xcode and TestFlight; see AGENTS.md)" >&2; exit 2

ci-metrics:
	@echo "ci-metrics: __NAME__ has no metrics collector yet (stub from devkit new; devkit/bin/metrics_ratchet.py)" >&2; exit 2

# Usage: make gate PR=<n> [GATE_ARGS=--no-post]
gate:
	@test -n "$(PR)" || { echo "usage: make gate PR=<number> [GATE_ARGS=--no-post]" >&2; exit 2; }
	devkit/bin/local_gate.sh "$(PR)" $(GATE_ARGS)

devkit-sync:     ## pull the latest devkit and record it in .devkit-rev
	devkit/bin/devkit-sync.sh

devkit-check:    ## part of ci-guards: the committed devkit/ tree must equal .devkit-rev
	devkit/bin/devkit-check.sh

toolchain-check: ## part of ci-guards: on macOS, swift --version must match .swift-version
	devkit/bin/toolchain_check.sh

docs-check:      ## part of ci-guards: AGENTS.md real + CLAUDE.md symlink, size caps, docs/decisions.md
	devkit/bin/docs_check.sh

release-check:   ## part of ci-guards: no Dockerfile, so nothing to check until one exists
	devkit/bin/release_check.sh

workflows-check: ## part of ci-guards: actions SHA-pinned, PR-workflow rules
	devkit/bin/workflows_check.sh

# Reports only; `make install` heals. Not in the gate: it reads the invoking checkout's git config.
hooks-check:     ## core.hooksPath must be .githooks
	devkit/bin/hooks_check.sh

# --fix rewrites core.hooksPath, so a tool that repointed it is undone by the next install.
install: devkit-check ## once per checkout/worktree: xcodegen present, git hooks
	@command -v xcodegen >/dev/null || { echo "install: xcodegen not found (brew install xcodegen)" >&2; exit 1; }
	devkit/bin/hooks_check.sh --fix
