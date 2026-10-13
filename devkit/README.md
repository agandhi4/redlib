# devkit

Shared, executable delivery tooling for agandhi4's apps. One copy of each script, vendored
into every repo as a `git subtree` at `devkit/`, so a clone can reproduce "what must pass"
offline and worktrees, Actions and Docker build contexts see plain files.

Design: `~/projects/solo/standardization/PLAN.md` §1 (layer L5) and `docs/decisions.md`.

## Contents

| Path | What |
|---|---|
| `bin/local_gate.sh` | The PR gate skeleton: gates `<pr>` merged into `origin/main`, posts the `local-gate` status, emits the `GATE`/`VERDICT` lines the merge queues parse. The repo supplies `scripts/ci/gate_plan.sh` (contract in the script header). |
| `bin/devkit-sync.sh` | `git subtree pull` to a ref and record `<commit> <tree>` in the repo's `.devkit-rev`. |
| `bin/devkit-check.sh` | Offline guard for `ci-quick`: the committed `devkit/` tree equals `.devkit-rev`. Fails on in-repo edits. |
| `bin/node_toolchain.sh` | Provides the exact Node in the repo's `.nvmrc`: uses PATH's node when it matches, else a checksum-verified install cached under `~/.local/share/devkit/node`. The gate calls it; hooks can too. |
| `bin/rust_toolchain.sh` | Provides the exact Rust in `rust-toolchain.toml` (or `rust-toolchain`): uses PATH's cargo when it matches, else installs through rustup (PATH's, or a private one bootstrapped under `~/.local/share/devkit/rust`) and prints the toolchain's sysroot bin, so callers export PATH only. `--declared` prints the version. The gate calls it. |
| `bin/toolchain_check.sh` | Guard for `ci-quick`: `.nvmrc` is exact, every `FROM node:` major and every setup-node step agree with it; same for `.python-version` and `rust-toolchain.toml` (`FROM rust:` minor, `Cargo.toml` `rust-version` not above it, no inline `toolchain:`). |
| `bin/throwaway_pg.sh` | One throwaway Postgres container for tests and smoke boots: `up` prints `PG_PORT=<n>`, `url`, `down`. tmpfs on by default (the volume-leak fix), TCP readiness, loopback only; env-driven. |
| `bin/boot_image.sh` | Boots a built app image on a private network (optionally with `throwaway_pg.sh` Postgres as `<name>-pg`), waits for its health endpoint with early exit on container death, prints `BASE=<url>`; `down` removes everything. Post-boot assertions stay in each repo. Env-driven (`BOOT_*`); `BOOT_EXPECT_VERSION` also requires the health JSON `version` to equal it. |
| `bin/ship_tag.sh` | `<owner/repo> <sha> [--date YYYY-MM-DD]`: the deploying step marks a main commit shipped with the annotated tag `ship-<date>-<sha7>` via `gh api` (no clone). Idempotent for the same sha, refuses another, survives a create race; prints `SHIP_TAG=<tag>`. Needs `contents: write`. |
| `bin/release_check.sh` | Guard for `ci-quick`: the image is the only source of `APP_VERSION`. Dockerfile final stage has the ARG, ENV and OCI `image.version` LABEL; no compose file sets it under `environment:`; every workflow step that pushes an image passes it as a build arg. |
| `bin/workflows_check.sh`, `bin/_workflows_lib.sh` | Guard for `ci-quick`: Actions follows the minutes and supply-chain rules. Every `uses:` is a commit SHA with a `# vX.Y.Z` comment (devkit reusable workflows may float on `@main`). A `pull_request` workflow runs one job, skips drafts, cancels superseded runs and ignores `**.md`; more jobs need a top-level `# workflows-check: multi-job ok: <reason>`. A job pushing an image on main runs with `cancel-in-progress: false`. The lib's push-step detection is shared with `release_check.sh`. |
| `bin/playwright_browsers.sh` | Installs the Playwright browsers the lockfile pins (default `chromium`) with the lockfile's runner and the `.nvmrc` Node; idempotent via Playwright's cache. `--with-deps` is honoured on Linux, ignored on macOS. |
| `bin/docs_check.sh` | Guard for `ci-quick`: every `AGENTS.md` is the real file with `CLAUDE.md` symlinked to it, size caps (30 KB root, 16 KB nested, shrink-only allowlist in `scripts/ci/docs_oversize.txt`), `docs/decisions.md` exists, no retired-tool words; repo extras in `scripts/ci/docs_rules.sh`. |
| `bin/quiet_run.sh`, `bin/hook_steps.sh`, `bin/push_ranges.sh`, `bin/hooks_check.sh`, `templates/githooks/` | Git hooks: one line per step, 40-line tail on failure; per-repo steps in `scripts/ci/hooks.conf`; `hooks_check` asserts `core.hooksPath=.githooks` (a tool install silently repointed finplat's for two months) and `--fix` self-heals; LFS chained when the repo uses it. |
| `bin/metrics_ratchet.py` | The "never worse than main" gate: checks a metrics snapshot against the committed bounds in `docs/metrics/ratchet.json`; bounds tighten only on main; loosening needs the fail-closed `metrics-rebaseline` PR label. Collectors stay per repo. |
| `bin/own_commit_check.py` | Transaction-boundary guard: AST scan fails a raw `.commit()` on a session the function did not open itself (`with … as db` / `db = Session()`), and pins every `commit_now(…, reason=…)` call to a shrink-only `path::qualname` allow-list. Prints `own_commit_allowlist_entries=<n>` for `metrics_ratchet.py` (direction lower). Opener regex and excludes are per repo. |
| `bin/dead_alert_audit.py` | Monthly review of vmalert rules (not a gate, exit 0): statically flags missing `severity`/`runbook`, `outcome` values outside `success|failure`, names duplicated across files; with `--vm-url` asks VictoriaMetrics which alerts never fired and which selectors matched no series in `--since` (default 30d). One `dead-alert <high|medium|low> <alert> <reason>` line per finding. |
| `github/` | Fleet operations run from this checkout, not vendored: `labels.json` + `labels_sync.sh` (idempotent; `--prune` to delete), `repos.json` + `repo_settings.sh` (squash-only, PR_TITLE/PR_BODY, delete-branch; auto-merge only on public repos). |
| `renovate/default.json` | Shared Renovate preset (`github>agandhi4/devkit//renovate/default`): weekly grouped minors, pinned action digests, no automerge (Renovate PRs never get the Mac `local-gate`), `.nvmrc` + `FROM node` + `engines` bumped together, dashboard approval instead of hard ignores so security fixes still flow. |
| `.github/workflows/quick-check.yml` | Reusable `workflow_call` quick-check (checkout, Node from `.nvmrc`, optional Python + uv, `make ci-quick`); caller template in `templates/workflows/`. Needs devkit's Actions access set to "repositories owned by the user". |
| `lint/ruff.toml` | Shared ruff base (py313, 100 cols, E F I N W UP); consumers `extend` it. |
| `tests/` | bats contract tests (fake `gh`/`make`/`node`, temp bare repos). |

## Vendor into a repo (once)

```sh
git subtree add --prefix=devkit https://github.com/agandhi4/devkit.git main --squash
devkit/bin/devkit-sync.sh            # writes .devkit-rev
```

Then add to the Makefile (every repo uses the same three targets):

```make
gate:            ## make gate PR=<n> [GATE_ARGS=--no-post]
	@test -n "$(PR)" || { echo "usage: make gate PR=<number> [GATE_ARGS=--no-post]" >&2; exit 2; }
	devkit/bin/local_gate.sh "$(PR)" $(GATE_ARGS)
devkit-sync:     ## pull the latest devkit and record it
	devkit/bin/devkit-sync.sh
devkit-check:    ## part of ci-quick
	devkit/bin/devkit-check.sh
toolchain-check: ## part of ci-quick
	devkit/bin/toolchain_check.sh
docs-check:      ## part of ci-quick
	devkit/bin/docs_check.sh
hooks-check:     ## part of install
	devkit/bin/hooks_check.sh --fix
```

Declare Node once in `.nvmrc` (exact version, e.g. `22.23.3`). Workflows use
`node-version-file: .nvmrc`; the Dockerfile's `FROM node:<major>` must match; a bot bump to
either fails `toolchain-check` until `.nvmrc` moves with it, which is the point.

and write `scripts/ci/gate_plan.sh`. The three existing plans (finplat, Orbit, locus) are
the reference: scalar config at the top, a `gate_plan()` that maps changed paths to `job`
calls, an optional `gate_cleanup()`.

## Rules

- Never edit `devkit/` inside a consuming repo; `devkit-check` fails quick-check. Change it
  here, merge, then `make devkit-sync` in each repo.
- Output contracts (`GATE …`, `VERDICT …`, `.devkit-rev` format) are APIs: the merge queues,
  `worker.py` and the Mac stand-in parse them. Changing one is a coordinated change.
- Scripts run on macOS bash 3.2 and GNU bash, with BSD and GNU coreutils. shellcheck clean.

## Develop

```sh
shellcheck -s bash bin/*.sh tests/*.bats
bats tests/
```
