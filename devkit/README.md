# devkit

Shared, executable delivery tooling for agandhi4's apps. One copy of each script, vendored
into every repo as a `git subtree` at `devkit/`, so a clone can reproduce "what must pass"
offline and worktrees, Actions and Docker build contexts see plain files.

Design: `~/projects/solo/standardization/PLAN.md` §1 (layer L5) and `docs/decisions.md`.

## Contents

| Path | What |
|---|---|
| `bin/local_gate.sh` | The PR gate skeleton: gates `<pr>` merged into `origin/main`, posts the `local-gate` status, emits the `GATE`/`VERDICT` lines the merge queues parse. The repo supplies `scripts/ci/gate_plan.sh` (contract in the script header). |
| `bin/devkit-sync.sh` | Fetch upstream, replace `devkit/` with its tree, record `<commit> <tree>` in `.devkit-rev`, commit. Conflict-free by construction. `--stage` leaves it in the index for the caller's own commit. |
| `bin/devkit-new.sh`, `templates/new/` | `devkit new <name> --stack <stack> [--dir <parent>] [--no-image]`: a new repo that passes every guard on its first commit, which is made through the hooks. Stacks: `python-fastapi`, `node-service`; each is a directory under `templates/new/stacks/` (how to add one: `templates/new/README.md`). See "New project". |
| `bin/devkit-check.sh` | Offline guard for `ci-quick` and pre-commit: the staged `devkit/` tree equals the staged `.devkit-rev` (both read from the index). Fails on in-repo edits. |
| `bin/node_toolchain.sh` | Provides the exact Node in the repo's `.nvmrc`: uses PATH's node when it matches, else a checksum-verified install cached under `~/.local/share/devkit/node`. The gate calls it; hooks can too. |
| `bin/rust_toolchain.sh` | Provides the exact Rust in `rust-toolchain.toml` (or `rust-toolchain`): uses PATH's cargo when it matches, else installs through rustup (PATH's, or a private one bootstrapped under `~/.local/share/devkit/rust`) and prints the toolchain's sysroot bin, so callers export PATH only. `--declared` prints the version. The gate calls it. |
| `bin/toolchain_check.sh` | Guard for `ci-quick`: `.nvmrc` is exact, every `FROM node:` major and every setup-node step agree with it; same for `.python-version` and `rust-toolchain.toml` (`FROM rust:` minor, `Cargo.toml` `rust-version` not above it, no inline `toolchain:`). |
| `bin/throwaway_pg.sh` | One throwaway Postgres container for tests and smoke boots: `up` prints `PG_PORT=<n>`, `url`, `down`. tmpfs on by default (the volume-leak fix), TCP readiness, loopback only; env-driven. |
| `bin/boot_image.sh` | Boots a built app image on a private network (optionally with `throwaway_pg.sh` Postgres as `<name>-pg`), waits for its health endpoint with early exit on container death, prints `BASE=<url>`; `down` removes everything. Post-boot assertions stay in each repo. Env-driven (`BOOT_*`); `BOOT_EXPECT_VERSION` also requires the health JSON `version` to equal it. |
| `bin/contract_probe.sh` | `<base> --live P --health P --request-id P --json-log FILE\|CONTAINER --metrics P --require-metric NAME --proxy-404 URL`: the observability contract asserted against a booted app, each assertion opt-in so repos switch them on as they comply. Called from a smoke after `boot_image.sh up`; `BOOT_EXPECT_VERSION` is checked in health, logs and `app_info`. One `probe <name> PASS\|FAIL` line each, every assertion runs. |
| `bin/ship_tag.sh` | `<owner/repo> <sha> [--date YYYY-MM-DD]`: the deploying step marks a main commit shipped with the annotated tag `ship-<date>-<sha7>` via `gh api` (no clone). Idempotent for the same sha, refuses another, survives a create race; prints `SHIP_TAG=<tag>`. Needs `contents: write`. |
| `bin/release_check.sh` | Guard for `ci-quick`: the image is the only source of `APP_VERSION`. Dockerfile final stage has the ARG, ENV and OCI `image.version` LABEL; no compose file sets it under `environment:`; every workflow step that pushes an image passes it as a build arg. |
| `bin/workflows_check.sh`, `bin/_workflows_lib.sh` | Guard for `ci-quick`: Actions follows the minutes and supply-chain rules. Every `uses:` is a commit SHA with a `# vX.Y.Z` comment (devkit reusable workflows may float on `@main`). A `pull_request` workflow runs one job, skips drafts, cancels superseded runs and ignores `**.md`; more jobs need a top-level `# workflows-check: multi-job ok: <reason>`. A job pushing an image on main runs with `cancel-in-progress: false`. The lib's push-step detection is shared with `release_check.sh`. |
| `bin/playwright_browsers.sh` | Installs the Playwright browsers the lockfile pins (default `chromium`) with the lockfile's runner and the `.nvmrc` Node; idempotent via Playwright's cache. `--with-deps` is honoured on Linux, ignored on macOS. |
| `bin/docs_check.sh` | Guard for `ci-quick`: every `AGENTS.md` is the real file with `CLAUDE.md` symlinked to it, size caps (30 KB root, 16 KB nested, shrink-only allowlist in `scripts/ci/docs_oversize.txt`), `docs/decisions.md` exists, no retired-tool words; repo extras in `scripts/ci/docs_rules.sh`. |
| `bin/quiet_run.sh`, `bin/hook_steps.sh`, `bin/push_ranges.sh`, `bin/hooks_check.sh`, `templates/githooks/` | Git hooks: one line per step, 40-line tail on failure; per-repo steps in `scripts/ci/hooks.conf`; `hooks_check` asserts `core.hooksPath=.githooks` (a tool install silently repointed finplat's for two months) and `--fix` self-heals; LFS chained when the repo uses it. |
| `bin/metrics_ratchet.py` | The "never worse than main" gate. `check` holds a snapshot to `docs/metrics/ratchet.json` and that file to main's copy (`git show origin/main:…`), so a PR cannot loosen its own bounds; `tighten` locks in BETTER numbers in the improving PR; `merge` joins `build/metrics/*.json` into one flat snapshot. Loosening needs the fail-closed `metrics-rebaseline` PR label. Wiring below. |
| `templates/metrics/ratchet.json`, `docs/metrics-keys.md` | Starter bounds (all `null` until `rebaseline` fills them, so `check` refuses a raw copy) and the flat `<domain>.<scope>.<stat>` key shape every collector emits. |
| `bin/own_commit_check.py` | Transaction-boundary guard: AST scan fails a raw `.commit()` on a session the function did not open itself (`with … as db` / `db = Session()`), and pins every `commit_now(…, reason=…)` call to a shrink-only `path::qualname` allow-list. Prints `own_commit_allowlist_entries=<n>` for `metrics_ratchet.py` (direction lower). Opener regex and excludes are per repo. |
| `bin/dead_alert_audit.py` | Monthly review of vmalert rules (not a gate, exit 0): statically flags missing `severity`/`runbook`, `outcome` values outside `success|failure`, names duplicated across files; with `--vm-url` asks VictoriaMetrics which alerts never fired and which selectors matched no series in `--since` (default 30d). One `dead-alert <high|medium|low> <alert> <reason>` line per finding. |
| `bin/monthly_audit.sh` | Monthly fleet audit, run from this checkout (not vendored). Per active vendoring repo, in a fresh shallow clone: the guards `ci-quick` does not already reach, `.devkit-rev` skew, the ratchet, and a re-invention diff (`reinvent <repo> <path> <kind> <devkit equivalent>`; naming the file under AGENTS.md "Convention deltas" silences it). Fleet: labels/settings dry-runs, `dead_alert_audit.py`, gate-ledger digest. Writes `report.md`, `summary.tsv`, `findings.json`; one read-only `claude -p` proposes ≤ 3 structural findings, which the script files as `fleet-audit` issues (none while 3 are open; off for the first two runs) and PRs the report to homelab `docs/audits/`. Kill switch `~/.config/devkit/audit.off`. Schedule (owner step, install by hand): fill `__DEVKIT__`/`__HOME__` in `templates/launchd/com.agandhi4.devkit.monthly-audit.plist`, `mkdir -p ~/Library/Logs/devkit`, `cp` it to `~/Library/LaunchAgents/`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.agandhi4.devkit.monthly-audit.plist`. |
| `github/` | Fleet operations run from this checkout, not vendored: `labels.json` + `labels_sync.sh` (idempotent; `--prune` to delete), `repos.json` + `repo_settings.sh` (squash-only, PR_TITLE/PR_BODY, delete-branch; auto-merge only on public repos). |
| `renovate/default.json` | Shared Renovate preset (`github>agandhi4/devkit//renovate/default`): weekly grouped minors, pinned action digests, no automerge (Renovate PRs never get the Mac `local-gate`), `.nvmrc` + `FROM node` + `engines` bumped together, dashboard approval instead of hard ignores so security fixes still flow. |
| `.github/workflows/quick-check.yml` | Reusable `workflow_call` quick-check (checkout, Node from `.nvmrc`, optional Python + uv, `make ci-quick`); caller template in `templates/workflows/`. Needs devkit's Actions access set to "repositories owned by the user". |
| `lint/ruff.toml` | Shared ruff base (py313, 100 cols, E F I N W UP); consumers `extend` it. |
| `tests/` | bats contract tests (fake `gh`/`make`/`node`, temp bare repos). |

## New project

```sh
~/projects/solo/devkit/bin/devkit-new.sh <name> --stack python-fastapi   # or node-service; --no-image for a repo that publishes nothing
```

Run it from an up-to-date devkit checkout (`--list` prints the stacks). It needs git, make
and the stack's package tool (`uv` or `npm`) on PATH, and makes `<cwd>/<name>` (`--dir`
chooses the parent) as a git repo with one commit holding: the vendored `devkit/` +
`.devkit-rev`; a Makefile with the full standard target set (tiers the stack lacks are
`exit 2` stubs that say so); `scripts/ci/gate_plan.sh`; `.githooks/` + `scripts/ci/hooks.conf`
(pre-commit `ci-quick`, pre-push `ci-unit`); `.github/workflows/quick-check.yml` calling the
reusable workflow, and for image stacks `publish.yml` (build, `ci-smoke`, push `sha-<7>` +
`latest`, ship tag, never cancelled) with a Dockerfile carrying the `APP_VERSION` trio;
`renovate.json` on the shared preset; `.claude/settings.json` (claude-kit plugins); `AGENTS.md`
(the project delta only: Stack + `Conventions:`, Architecture placeholder, Convention deltas,
Commands, Workflow) with `CLAUDE.md` symlinked; `docs/decisions.md` with its first entry; the
toolchain pin; the stack's lockfile; the smallest app that serves `/health/live` and
`/health/ready`, with a test per tier. The first commit runs through pre-commit, so
`make ci-quick` (devkit-check, toolchain-check, docs-check, release-check, workflows-check,
own-commit-check for Python, then lint/format/typecheck) has passed on it before you see it.
`tests/new_contract.bats` holds every stack to this.

Then, by hand, in this order:

1. `gh repo create agandhi4/<name> --private --source <dir>/<name> --push`
2. Add `"<name>": {}` to `github/repos.json`; run `github/repo_settings.sh <name>` (squash-only,
   PR title/body) and `github/labels_sync.sh <name>`.
3. Give the Mend Renovate app access to the repo (its `renovate.json` extends this preset);
   devkit's Actions access must already be "repositories owned by the user" for the
   quick-check caller.
4. Write the Architecture section of `AGENTS.md`; every deviation from a convention is a line
   under Convention deltas plus a `docs/decisions.md` entry.
5. When it deploys: a homelab `stacks/<name>/` compose stack (healthcheck on `/health/ready`,
   memory limit, `logging: "true"`, never `APP_VERSION` in `environment:`), and the
   `latest`-mover documented in AGENTS.md.

## Vendor into a repo (once)

```sh
~/projects/solo/devkit/bin/devkit-sync.sh     # creates devkit/ from upstream main, writes .devkit-rev, commits
```

Updates are `make devkit-sync`. The sync fetches upstream and replaces `devkit/` wholesale
(`git read-tree`), so it never conflicts; `devkit-check` compares the tree hash. There is no
`git subtree` involved any more: squash merges drop the trailers subtree needs.

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
workflows-check: ## part of ci-quick
	devkit/bin/workflows_check.sh
release-check:   ## part of ci-quick (repos that publish an image)
	devkit/bin/release_check.sh
hooks-check:     ## part of install
	devkit/bin/hooks_check.sh --fix
```

Declare Node once in `.nvmrc` (exact version, e.g. `22.23.3`). Workflows use
`node-version-file: .nvmrc`; the Dockerfile's `FROM node:<major>` must match; a bot bump to
either fails `toolchain-check` until `.nvmrc` moves with it, which is the point.

and write `scripts/ci/gate_plan.sh`. The three existing plans (finplat, Orbit, locus) are
the reference: scalar config at the top, a `gate_plan()` that maps changed paths to `job`
calls, an optional `gate_cleanup()`.

## Metrics ratchet (ci-metrics)

Collectors write `build/metrics/<collector>.json` in the `docs/metrics-keys.md` shape. Copy
`devkit/templates/metrics/ratchet.json` to `docs/metrics/ratchet.json`, keep the keys you
collect, run `make metrics-snapshot` and fill the bounds with `metrics_ratchet.py rebaseline`.

```make
METRICS_RATCHET := python3 -I devkit/bin/metrics_ratchet.py
METRICS_BOUNDS  := docs/metrics/ratchet.json
metrics-snapshot: ## run the collectors; build/metrics.json is the report-only snapshot
	rm -rf build/metrics && mkdir -p build/metrics
	# <repo collectors here, each writing build/metrics/<name>.json>
	$(METRICS_RATCHET) merge --out build/metrics.json build/metrics/*.json
ci-metrics: metrics-snapshot ## gate job: never worse than main (needs origin/main fetched)
	$(METRICS_RATCHET) check --snapshot build/metrics.json --bounds $(METRICS_BOUNDS) $(if $(METRICS_REBASELINE),--rebaseline-ok)
metrics-tighten: metrics-snapshot ## lock in BETTER numbers; commit the bounds in the same PR
	$(METRICS_RATCHET) tighten --snapshot build/metrics.json --bounds $(METRICS_BOUNDS)
```

In `scripts/ci/gate_plan.sh` (the label is read fail-closed, from the invoking checkout):

```bash
if pr_has_label metrics-rebaseline; then job metrics ci-metrics METRICS_REBASELINE=1
else job metrics ci-metrics; fi
```

An Actions caller needs `git fetch --depth=1 origin main` first: an unresolvable base ref
fails the check rather than skipping the comparison.

## Rules

- Never edit `devkit/` inside a consuming repo; `devkit-check` fails quick-check. Change it
  here, merge, then `make devkit-sync` in each repo.
- Output contracts (`GATE …`, `VERDICT …`, `.devkit-rev` format) are APIs: the merge queues,
  `worker.py` and the Mac stand-in parse them. Changing one is a coordinated change.
- Scripts run on macOS bash 3.2 and GNU bash, with BSD and GNU coreutils. shellcheck clean.

## Develop

devkit's CI runs its own guards (`docs_check`, `toolchain_check`, `workflows_check`) on
itself, and a PR touching only `AGENTS.md`, `CLAUDE.md` or `docs/decisions.md` still runs it:
devkit has no local gate, so CI is the only check before consumers vendor a change.

```sh
shellcheck -s bash bin/*.sh tests/*.bats
bats tests/
```
