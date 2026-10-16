# devkit

Shared, executable delivery tooling for agandhi4's apps. One copy of each script, vendored
into every repo at `devkit/` (the paths in `VENDOR_PATHS`, by `devkit-sync.sh`), so a clone can reproduce "what must pass"
offline and worktrees, Actions and Docker build contexts see plain files.

Design: `~/projects/solo/standardization/PLAN.md` §1 (layer L5) and `docs/decisions.md`.

## Getting started

- A new repo: `devkit-new.sh`, below in "New project". It passes every guard on its first commit.
- An existing repo: "Vendor into a repo (once)", then its `devkit-sync` target for every update.
- Changing devkit itself: "Commands" below, and [AGENTS.md](AGENTS.md) for the invariants.

## Architecture

What each path is; [AGENTS.md](AGENTS.md) holds the invariants that tie them together.

| Path | What |
|---|---|
| `bin/local_gate.sh` | The PR gate skeleton: gates `<pr>` merged into `origin/main`, posts the `local-gate` status, emits the `GATE`/`VERDICT` lines the merge queues parse, holds jobs to their time budgets and writes their seconds to `build/metrics/gate.json` (`docs/metrics-keys.md`). The repo supplies `scripts/ci/gate_plan.sh` (contract in the script header), usually declarations plus `devkit_default_gate_plan`. |
| `bin/_paths_lib.sh` | Sourced: the one path classification (`devkit_classify_path`: docs, backend, frontend, native, tooling, other) shared by the hooks and the gate, which prints `GATE areas: …` and exports `GATE_AREAS`/`GATE_HAS_<AREA>` before the plan; and `devkit_default_gate_plan`, the plan body a repo calls after declaring `GATE_JOBS_<GROUP>`. A devkit-only change (tooling) gates as quick, plus the image when a boot script changed. |
| `bin/gate.sh` | What `make gate` calls: `remote_gate.sh` when this machine names a gate host, else `local_gate.sh`. See "Remote gate". |
| `bin/remote_gate.sh` | Runs the repo's gate on the gate host over ssh (clone if absent, reset to `origin/main`, `local_gate.sh` there); same output, exit code and `local-gate` status. |
| `bin/devkit-sync.sh` | Fetch upstream, replace `devkit/` with its tree filtered to `VENDOR_PATHS`, record `<commit> <filtered tree>` in `.devkit-rev`, commit. Conflict-free by construction. `--stage` leaves it in the index for the caller's own commit. |
| `bin/devkit-new.sh`, `templates/new/` | `devkit new <name> --stack <stack> [--dir <parent>] [--no-image]`: a new repo that passes every guard on its first commit, which is made through the hooks. Stacks: `python-fastapi`, `node-service`, `rust`, `next-vercel`, `swift-app`; each is a directory under `templates/new/stacks/` (how to add one: `templates/new/README.md`). See "New project". |
| `bin/devkit-check.sh` | Offline guard for `ci-quick` and pre-commit: the staged `devkit/` tree equals the staged `.devkit-rev` (both read from the index). Fails on in-repo edits, and on a tree holding paths outside its own `VENDOR_PATHS` (vendored whole by a pre-manifest sync: rerun the repo's `devkit-sync`). |
| `bin/node_toolchain.sh` | Provides the exact Node in the repo's `.nvmrc`: uses PATH's node when it matches, else a checksum-verified install cached under `~/.local/share/devkit/node`. The gate and the hooks call it through `toolchain_path.sh`. |
| `bin/rust_toolchain.sh` | Provides the exact Rust in `rust-toolchain.toml` (or `rust-toolchain`): uses PATH's cargo when it matches, else installs through rustup (PATH's, or a private one bootstrapped under `~/.local/share/devkit/rust`) and prints the toolchain's sysroot bin, so callers export PATH only. `--declared` prints the version. The gate and the hooks call it through `toolchain_path.sh`. |
| `bin/toolchain_path.sh` | Sourced: `toolchain_path <tree>` puts the tree's pinned Node (`.nvmrc`) and Rust (`rust-toolchain.toml`) first on PATH through the two scripts above, or fails naming the pin. The one provisioning path for `local_gate.sh` (merged worktree) and `hook_steps.sh` (the hook's checkout), so a hook runs the gate's node and cargo on a machine with none. Python needs nothing: uv reads `.python-version`. |
| `bin/toolchain_check.sh` | Guard for `ci-quick`: `.nvmrc` is exact, every `FROM node:` major and every setup-node step agree with it; same for `.python-version` (plus a regular-file copy beside every one-level-down `pyproject.toml`, because uv stops pin discovery at the project boundary) and `rust-toolchain.toml` (`FROM rust:` minor, `Cargo.toml` `rust-version` not above it, no inline `toolchain:`); `.swift-version` against `swift --version` on macOS only (Xcode's compiler; skipped elsewhere). Runs `ci_targets_check.sh` first. |
| `bin/ci_targets_check.sh` | Guard for `ci-quick`, run by `toolchain_check.sh`: per-area halves of the standard targets are named tier first, `ci-<tier>-<area>` (`ci-unit-backend`, not `ci-backend-unit`). Warns naming the expected name until 2026-11-15, then fails. |
| `bin/_makefile_lib.sh`, `bin/_dockerfile_lib.sh`, `bin/_gitattributes_lib.sh` | Sourced readers the guards share: root Makefile targets (with literal includes), Dockerfile list and final stage, the decisions-log `.gitattributes` line. |
| `bin/throwaway_pg.sh` | One throwaway Postgres container for tests and smoke boots: `up` prints `PG_PORT=<n>`, `url`, `down`. tmpfs on by default (the volume-leak fix), TCP readiness, loopback only; env-driven. |
| `bin/boot_image.sh` | Boots a built app image on a private network (optionally with `throwaway_pg.sh` Postgres as `<name>-pg`), waits for its health endpoint with early exit on container death, prints `BASE=<url>`; `down` removes everything. Post-boot assertions stay in each repo. Env-driven (`BOOT_*`); `BOOT_EXPECT_VERSION` also requires the health JSON `version` to equal it. |
| `bin/contract_probe.sh` | `<base> --live P --health P --request-id P --json-log FILE\|CONTAINER --metrics P --require-metric NAME --proxy-404 URL`: the observability contract asserted against a booted app, each assertion opt-in so repos switch them on as they comply. Called from a smoke after `boot_image.sh up`; `BOOT_EXPECT_VERSION` is checked in health, logs and `app_info`. One `probe <name> PASS\|FAIL` line each, every assertion runs. |
| `bin/ship_tag.sh` | `<owner/repo> <sha> [--date YYYY-MM-DD]`: the deploying step marks a main commit shipped with the annotated tag `ship-<date>-<sha7>` via `gh api` (no clone). Idempotent for the same sha, refuses another, survives a create race; prints `SHIP_TAG=<tag>`. Needs `contents: write`. |
| `bin/release_check.sh` | Guard for `ci-quick`: the image is the only source of `APP_VERSION`. Dockerfile final stage has the ARG, ENV and OCI `image.version` LABEL; no compose file sets it under `environment:`; every workflow step that pushes an image passes it as a build arg. Every Dockerfile (root and one level down): a non-root final `USER` may `EXPOSE` and health-check only ports >= 1024 (the NAS kernel refuses a privileged bind; Orbit was down 16 h on 2026-10-13). |
| `bin/workflows_check.sh`, `bin/_workflows_lib.sh` | Guard for `ci-quick`: Actions follows the minutes and supply-chain rules. Every `uses:` is a commit SHA with a `# vX.Y.Z` comment (devkit reusable workflows may float on `@main`). A `pull_request` workflow runs one job, skips drafts, cancels superseded runs and ignores `**.md`; more jobs need a top-level `# workflows-check: multi-job ok: <reason>`. A job pushing an image on main runs with `cancel-in-progress: false`. The lib's push-step detection is shared with `release_check.sh`. |
| `bin/playwright_browsers.sh` | Installs the Playwright browsers the lockfile pins (default `chromium`) with the lockfile's runner and the `.nvmrc` Node; idempotent via Playwright's cache. `--with-deps` is honoured on Linux, ignored on macOS. |
| `bin/docs_check.sh` | Guard for `ci-quick`: every `AGENTS.md` is the real file with `CLAUDE.md` symlinked to it, size caps (30 KB root, 16 KB nested; the shrink-only allowlist in `scripts/ci/docs_oversize.txt` ends 2026-11-15), `docs/decisions.md` exists, no retired-tool words, and the standard docs set ("Standard docs" below: required files and README sections, the root AGENTS.md's H2 list, the fixed `docs/` set with dated `docs/reports/`, no CONTRIBUTING.md, dated decisions entries, `make` targets and relative links that resolve, `docs/decisions.md merge=union` in `.gitattributes`; warnings until their date, then failures); repo extras in `scripts/ci/docs_rules.sh`. `--report` prints the numbers (sizes vs caps, allowances, docs outside the set, H2s outside the list) for trims and the monthly audit. |
| `bin/quiet_run.sh`, `bin/hook_steps.sh`, `bin/push_ranges.sh`, `bin/hooks_check.sh`, `templates/githooks/` | Git hooks: one line per step, 40-line tail on failure; per-repo steps in `scripts/ci/hooks.conf`, scoped by changed paths by default from one fleet layout table (docs, backend, frontend, native, tooling, other: `devkit_classify_path` in `_paths_lib.sh`, which the gate uses too; tooling runs every hook step, like other) and each step's target name, so a docs-only change runs docs-check alone, a frontend-only one skips backend steps and a native-only one (ios/, OrbitAgent/) runs nothing, with `:unless=<globs>`, `:only=<globs>` or `:always` per step only where a repo's layout deviates; `hooks_check` asserts `core.hooksPath=.githooks` (a tool install silently repointed finplat's for two months) and `--fix` self-heals it and adds the decisions-log union line to `.gitattributes`; it rejects a malformed step override; LFS chained when the repo uses it. Before the first step the pinned Node and Rust go first on PATH, as in the gate (`toolchain_path.sh`), so `hooks.conf` lists steps only. A passing cargo step's summary sums every `test result:` line (the last one is the doctests). Every run appends step and total wall seconds to `$XDG_STATE_HOME/devkit/hooks/<repo>.tsv`, the per-machine hooks ledger the scorecard reads (T8: pre-commit p90 ≤ 30 s, pre-push ≤ 60 s). |
| `bin/tier_guard.sh` | `<tier> --budget <s> [--floor <runner>=<min>]... -- <cmd...>`: one test tier under a wall-clock budget (the whole command's wall time; it fails over budget even when every test passed, `TIER_BUDGET_ENFORCE=0` only reports) and per-runner floors on the tests that RAN (skipped ones do not count), read from the runner's own summary line: `pytest`, `vitest`, `playwright`, `cargo`. Streams the command's output, exits with its code, prints `TIER <tier>: …` / `FAIL` / `FLOOR` / `OVERBUDGET` lines and writes `build/metrics/tier-<tier>.json` at the git top level (`tier.<tier>.seconds`, `tests.<tier>.<runner>`). Every `devkit new` stack's test tiers run through it. |
| `bin/metrics_collect.sh` | `<snapshot\|check\|tighten\|rebaseline>`: the `ci-metrics` mechanism. Reads `scripts/ci/metrics.conf` (`<name> <area> <command...>`), runs each collector from the repo root into `build/metrics/<name>.json`, skips those whose area no changed path touched (in the gate; `tooling`/`other` and `repo` collectors run regardless), merges with the gate's and tiers' files, then runs the ratchet. A repo's Makefile holds three one-line targets and nothing else. "Metrics ratchet" below. |
| `metrics/` | The shared collectors a `metrics.conf` line calls, one per stack, each `--scope <name> [--out FILE]`, deterministic, exit 2 naming a missing dev dependency: `python.py --root <dir> --src <subdir|module.py>... [--python <interp>] [--mccabe] [--cognitive] [--vulture [--vulture-ignore-declarative] [--vulture-base <set,...>]] [--cycles]` (ruff C901, complexipy, vulture, AST import cycles; run under the repo's interpreter, `uv run --frozen --project backend python devkit/metrics/python.py …`, so the tools resolve); `ts.mjs --root <dir> --src <subdir> [--tsconfig F] [--test-glob G]... [--cyclomatic] [--cognitive] [--knip [--knip-base]] [--cycles] [--bundle [--bundle-entry index.html]]` (eslint `complexity`, sonarjs cognitive, knip, dependency-cruiser cycles, vite bundle KiB; tools from `<root>/node_modules/.bin`); `jscpd.mjs --scope repo [--min-tokens 50] [--min-lines 5] [--bin <jscpd>] [--base] <paths...>`; `coverage.py --scope <s> (--coverage-json F \| --istanbul-summary F)` (the tier writes the report; "run make ci-unit-<s> first" when it is missing). Keys per collector: `docs/metrics-keys.md`. The `--*base` flags merge `lint/`'s knip, jscpd and vulture bases under the repo's own config (`lint/README.md`). |
| `bin/metrics_ratchet.py` | The "never worse than main" gate. `check` holds a snapshot to `docs/metrics/ratchet.json` and that file to main's copy (`git show origin/main:…`), so a PR cannot loosen its own bounds; `tighten` locks in BETTER numbers in the improving PR; `merge` joins `build/metrics/*.json` into one snapshot that records each key's collector and the collectors skipped, so a key whose collector did not run is SKIPPED, not a failure. Loosening needs the fail-closed `metrics-rebaseline` PR label. |
| `templates/metrics/ratchet.json`, `docs/metrics-keys.md` | Starter bounds (all `null` until `rebaseline` fills them, so `check` refuses a raw copy; `{}` is the other valid start) and the flat `<domain>.<scope>.<stat>` key shape every collector emits. |
| `bin/own_commit_check.py` | Transaction-boundary guard: AST scan fails a raw `.commit()` on a session the function did not open itself (`with … as db` / `db = Session()`), and pins every `commit_now(…, reason=…)` call to a shrink-only `path::qualname` allow-list. Prints `own_commit_allowlist_entries=<n>` for `metrics_ratchet.py` (direction lower). Opener regex and excludes are per repo. |
| `bin/layer_check.py` | Dependency-direction guard for `ci-quick` (the consumer's `layer-check` target): the repo's `scripts/ci/layers.conf` declares, per source tree (`[section]`, the ratchet scope), its layers bottom-first by path glob, plus `peer` (same rank, neither imports the other), `entry` (composition root), `leaf` (imports nothing of ours), sanctioned `allow` edges, `deny` for a skipped layer and the shrink-only `known` violations. An import from a lower rank to a higher one fails, as does a file in no layer or a `known` line that is no longer refused. Python reads `metrics/python.py`'s runtime import graph (the one `coupling.<scope>.cycles` counts); TypeScript reads import statements (aliases from the conf, type-only imports erased). Prints `layer_violations=<n>`; `--metrics-out` writes `coupling.<section>.layer_violations` (direction lower), so a scaffold's `metrics.conf` runs it as the `layers` collector. Stdlib only. |
| `bin/dead_alert_audit.py` | Monthly review of vmalert rules (not a gate, exit 0): statically flags missing `severity`/`runbook`, `outcome` values outside `success|failure`, names duplicated across files; with `--vm-url` asks VictoriaMetrics which alerts never fired and which selectors matched no series in `--since` (default 30d). One `dead-alert <high|medium|low> <alert> <reason>` line per finding. |
| `bin/monthly_audit.sh` | Monthly fleet audit, run from this checkout (not vendored). Per active vendoring repo, in a fresh shallow clone: the guards `ci-quick` does not already reach, `.devkit-rev` skew, the ratchet, and a re-invention diff (`reinvent <repo> <path> <kind> <devkit equivalent>`; naming the file under AGENTS.md "Convention deltas" silences it). Fleet: labels/settings dry-runs, `dead_alert_audit.py`, gate-ledger digest. Writes `report.md`, `summary.tsv`, `findings.json`; one read-only `claude -p` proposes ≤ 3 structural findings, which the script files as `fleet-audit` issues (none while 3 are open; off for the first two runs) and PRs the report to homelab `docs/audits/`. Kill switch `~/.config/devkit/audit.off`. Schedule (owner step, install by hand): fill `__DEVKIT__`/`__HOME__` in `templates/launchd/com.agandhi4.devkit.monthly-audit.plist`, `mkdir -p ~/Library/Logs/devkit`, `cp` it to `~/Library/LaunchAgents/`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.agandhi4.devkit.monthly-audit.plist`. |
| `github/` | Fleet operations run from this checkout, not vendored: `labels.json` + `labels_sync.sh` (idempotent; `--prune` to delete), `repos.json` + `repo_settings.sh` (squash-only, PR_TITLE/PR_BODY, delete-branch; auto-merge only on public repos). |
| `renovate/default.json` | Shared Renovate preset (`github>agandhi4/devkit//renovate/default`): weekly grouped minors, pinned action digests, no automerge (Renovate PRs never get the Mac `local-gate`), `.nvmrc` + `FROM node` + `engines` bumped together, dashboard approval instead of hard ignores so security fixes still flow. |
| `.github/workflows/quick-check.yml` | Reusable `workflow_call` quick-check (checkout, Node from `.nvmrc`, optional Python + uv, `make ci-quick`); caller template in `templates/workflows/`. Needs devkit's Actions access set to "repositories owned by the user". |
| `lint/ruff.toml` | Shared ruff base (py313, 100 cols, E F I N W UP); consumers `extend` it. |
| `metrics/size.py` | File-size collector for any language: `size.<scope>.max_lines` and `size.<scope>.over_600` over the production files (tests, fixtures, generated paths excluded). A file that keeps growing is the first symptom of a missing abstraction (scorecard T2). One conf line per area. |
| `bin/secrets_check.sh` | Guard for `ci-quick` (scorecard T11): no credential in the tracked files. gitleaks' high-confidence shapes (private keys, AWS, GitHub, Slack, Google, Stripe, Anthropic/OpenAI, age) everywhere, and long literals assigned to secret-named variables outside tests and placeholders; `scripts/ci/secrets_allow.txt` names a fixture's fake key with its reason. The matched text is never printed. |
| `bin/migration_check.py` | Guard for `ci-quick` (scorecard T5, data.md 12 and 14): no shipped migration is modified or deleted (the `migration-contract` label, or `--allow-shipped-edits`, makes a deliberate one pass), and no alembic `downgrade()` is a `pass` body (write it, or raise with the reason; merge revisions are exempt). `--versions <dir>` per migrations directory; drizzle dirs get the edit check only. |
| `metrics/vuln.py` | Vulnerability collector for any stack (scorecard T11): the locked production dependencies (`uv export`, package-lock.json, Cargo.lock) asked of OSV in one batch, each hit fetched once for severity; `vuln.<scope>.critical|high|total`, report-only (a new advisory is not a code regression, so the ratchet never tracks it). No audit tool needs installing. |
| `metrics/statements.py` | The statements collector (decision H): the db tier's statement fixture writes `{"<METHOD>:/<route>": <max statements>}` to a file outside `build/metrics/`; one `statements job:db …` line in `metrics.conf` validates and copies it into the snapshot as `statements.<METHOD>:/<route>` keys at tolerance 0. closet's `test/support/statement-budgets.ts` and finplat's `count_statements` are the two fixtures to copy. |
| `bin/agent_cost.py`, `docs/agent-cost.tsv` | The agent-cost ledger (scorecard T9): one row per (repo, PR, agent) from the Claude Code session transcripts (API calls, tool calls, output and cache-read tokens attributed to the PR the agent was on, gate rounds, `GATE … FAIL` lines seen, merged) joined with the gate state dir's seconds. Append-only; `--summary` prints per-repo medians, which the scorecard grades. Run it after a wave of lanes (`make agent-cost`). Transcripts are data: only counts and PR URLs leave them. |
| `bin/scorecard.py`, `scorecard.conf` | The fleet scorecard (standardization/scorecard-design.md): one letter per track (docs, code quality, dead code, architecture, database load, observability, runtime, gate speed, agent cost, process, security, operations, frontend, domain, currency) per repo, from the metrics snapshot or bounds, `docs_check --report`, the read-only guards, config files and the gate state dir; `UNMEASURED` names the devkit mechanism that would measure a check and the fleet table ranks that backlog by repos unblocked. Thresholds are fleet-wide in `scorecard.conf`; a repo declares a check n/a only with `scorecard: <id>` under its Convention deltas. `make scorecard REPOS='…'`; the monthly audit runs it over fresh clones. |
| `tests/` | bats contract tests (fake `gh`/`make`/`node`, temp bare repos). |

## New project

```sh
~/projects/solo/devkit/bin/devkit-new.sh <name> --stack python-fastapi   # or node-service, rust, next-vercel, swift-app; --no-image for a repo that publishes nothing
```

Run it from an up-to-date devkit checkout (`--list` prints the stacks; the table in
`templates/new/README.md` says which repo each was extracted from). It needs git, make
and the stack's package tool (`uv` or `npm`; for `rust`, curl or rustup, since the scaffold
provisions the pinned toolchain itself; for `swift-app`, Xcode, plus `xcodegen` from
`ci-swift` on) on PATH, and makes `<cwd>/<name>` (`--dir` chooses the parent) as a git repo with one commit holding: the vendored `devkit/` +
`.devkit-rev`; a Makefile with the full standard target set (tiers the stack lacks are
`exit 2` stubs that say so); `scripts/ci/gate_plan.sh`; `.githooks/` + `scripts/ci/hooks.conf`
(pre-commit `ci-quick`, pre-push `ci-unit`; `ci-lint-swift` for swift-app, whose tests take
minutes); `.github/workflows/quick-check.yml` calling the reusable workflow (swift-app's runs
the `ci-guards` target, the only tier that runs off a Mac), and for image stacks `publish.yml`
(build, `ci-smoke`, push `sha-<7>` + `latest`, ship tag, never cancelled) with a Dockerfile carrying the `APP_VERSION` trio;
`renovate.json` on the shared preset; `.claude/settings.json` (claude-kit plugins); `AGENTS.md`
(the project delta only: Stack + `Conventions:`, Architecture placeholder, Convention deltas,
Commands, Workflow) with `CLAUDE.md` symlinked; `docs/decisions.md` with its first entry; the
toolchain pin; the stack's lockfile; the smallest app that serves `/health/live` and
`/health/ready` (swift-app: shows its build identity), with a test per tier. The first commit runs through pre-commit, so
`make ci-quick` (devkit-check, toolchain-check, docs-check, release-check, workflows-check,
layer-check outside rust and swift-app, own-commit-check for Python, then lint/format/typecheck) has passed on it before you see it.
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

Updates are the consumer's `devkit-sync` target. The sync fetches upstream and replaces `devkit/` wholesale
(`git read-tree`), so it never conflicts; `devkit-check` compares the tree hash. There is no
`git subtree` involved any more: squash merges drop the trailers subtree needs.

Only what consumers run is vendored: `VENDOR_PATHS` at this repo's root lists it (`bin/`, the
hook, workflow and metrics templates, `lint/`, `renovate/`, the docs consumers read). Stack
scaffolds (`templates/new/`), `tests/`, `.github/` and `github/` stay here; `devkit new` and the
monthly audit read them from a full checkout. Adding a path a consumer needs is a one-line
manifest change.

Then add to the Makefile (every repo uses the same three targets):

```make
gate:            ## make gate PR=<n> [GATE_ARGS=--no-post]; local or the gate host
	devkit/bin/gate.sh "$(PR)" $(GATE_ARGS)
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

and write `scripts/ci/gate_plan.sh`: scalar config at the top, an optional `gate_cleanup()`,
and a `gate_plan()` that declares jobs per group and calls `devkit_default_gate_plan`
(`bin/_paths_lib.sh`), so which jobs run for which paths is devkit's, not the repo's:

```bash
GATE_JOBS_QUICK="quick ci-quick"                       # required; ci-quick runs docs-check
GATE_JOBS_DOCS="docs docs-check"                       # required
GATE_JOBS_BACKEND="unit ci-unit-backend|db ci-db TEST_DB_PORT=$DB_PORT"
GATE_JOBS_FRONTEND="unit-fe ci-unit-frontend"
GATE_JOBS_IMAGE="image ci-image CI_IMAGE=$IMAGE|smoke ci-smoke CI_IMAGE=$IMAGE"
GATE_JOBS_E2E="e2e ci-e2e"
GATE_JOBS_METRICS="metrics ci-metrics"                 # optional; always the last job
GATE_IMAGE_PATHS='^(Dockerfile|uv\.lock)$'             # paths that also run the image group
gate_plan() { devkit_default_gate_plan; }
gate_plan_extra() { ...; }                             # optional: the repo's own rules
```

Each changed path gets one area from the table the hooks use (docs, backend, frontend,
native, tooling, other). Docs-only runs docs; tooling (`devkit/`, `.devkit-rev`, hooks.conf,
`.githooks/`; a devkit sync) runs quick, plus the image group when `boot_image.sh` or
`contract_probe.sh` changed; native-only runs nothing; backend and frontend run their groups
plus quick and e2e; other runs everything (`docs/metrics/ratchet.json` and
`scripts/ci/metrics.conf` are other, so a bounds-only PR meets the ratchet and its label).
The metrics group runs for backend, frontend and other, after `gate_plan_extra`, so
`ci-metrics` sees every earlier job's seconds; when the PR
carries the `metrics-rebaseline` label (read through `gh`, fail-closed) its jobs get
`METRICS_REBASELINE=1`. `GATE_AREAS_<GROUP>="..."` overrides a group's areas. The table and
defaults: the `_paths_lib.sh` header. A plan may still be hand-written against the
skeleton's helpers, reading `GATE_AREAS` and `GATE_HAS_<AREA>`.

Gate environment (full contract in the script header):

| Variable | Default | What |
|---|---|---|
| `GATE_SLOTS` | `1` | How many gates may run at once on this machine, across repos. `1` keeps the single lock file `GATE_LOCK`; `N` > 1 uses `GATE_LOCK.1` … `GATE_LOCK.N`. The merge queues and linux-box keep `1`; raising it on a laptop accepts load-induced timing-test failures (2026-10-05). |
| `GATE_SILENT_MINUTES` | `15` | Watchdog: a job whose log has not grown for this long is stopped, status `error`, exit 2. `0` disables. |
| `GATE_JOB_BUDGET_MINUTES` | `5` | Per-job budget (owner directive 2026-10-13). An over-budget job runs to completion, then `GATE <job> OVERBUDGET (<n>s > <b>s)` and VERDICT FAIL naming it. Decimals allowed; `0` disables. |
| `GATE_BUDGET_MINUTES` | `10` | Whole-gate budget, counted once a slot is held: `GATE total OVERBUDGET (...)` and FAIL. |
| `GATE_BUDGET_ENFORCE` | `1` | `0` keeps the OVERBUDGET lines (plus one `GATE note`) but the verdict PASSes: for a queue adopting budgets before its suites fit. |
| `GATE_LOAD_MAX` | unset (no check) | Before taking a slot, wait while the 1- **or** 5-minute load average exceeds this, one `GATE waiting: load 1m=<x> 5m=<y> > <max>` line per minute. Lanes use `12`. Never fails a gate. |
| `GATE_LOAD_WAIT_MINUTES` | `30` | After this long over `GATE_LOAD_MAX`, the gate proceeds anyway with a `GATE note`. |
| `~/.config/devkit/gate.env` | absent | Per-machine defaults for every `GATE_*` row above (`KEY=value` lines, honours `XDG_CONFIG_HOME`); an explicit environment variable wins; any other line is exit 2. The queues and linux-box do not create this file. |

## Remote gate

`make gate` runs where the machine says, not where the repo says. With `GATE_REMOTE_HOST` set
(environment, or `~/.config/devkit/gate.env`; the environment wins), `gate.sh` hands the PR to
`remote_gate.sh`. It sshes to the host, keeps one checkout per repo under `GATE_REMOTE_ROOT`,
forces it to `origin/main` (the plan is read from that checkout), and runs
`devkit/bin/local_gate.sh <pr>` there. The `GATE`/`VERDICT` lines stream back unchanged, the
exit code passes through, and the host posts the `local-gate` status. Interrupting this side
stops the host's gate through its own cleanup (status `error`). Contract: the script headers.

| Variable | Default | What |
|---|---|---|
| `GATE_REMOTE_HOST` | unset (local) | `[user@]host` of the gate host. |
| `GATE_REMOTE_ROOT` | `~/gates` | Checkouts live at `<root>/<repo>`; state and logs at `<root>/.state/<GATE_STATE_NAME>/`, apart from the host queue's checkout. `~` expands on the host. |
| `GATE_REMOTE_SSH_OPTS` | none | Extra ssh options, word-split, before the defaults (`BatchMode=yes`, keepalives). |
| `GATE_REMOTE` | unset | `0` keeps this run (env) or machine (gate.env) local; `1` without a host is exit 2. |

A repo whose gate can only run here puts a literal `GATE_REMOTE=0` line in its plan (the
swift-app template does: on Linux its Xcode jobs skip and the verdict would pass untested
Swift). Nothing else in a repo changes; the host's own `gate.env` sets its `GATE_SLOTS` and
`GATE_LOAD_MAX`. On an ssh failure (exit 2, no `VERDICT`), `remote_gate.sh` says whether the host
was unreachable (off its LAN, VPN or Tailscale) or refused the key, from ssh's last error line.

**Switching finplat, Orbit and locus to linux-box.** Each repo's `gate` target becomes the
one line above (after its `devkit-sync`), then on the Mac:

```sh
mkdir -p ~/.config/devkit
echo 'GATE_REMOTE_HOST=aakash@192.168.8.174' >> ~/.config/devkit/gate.env
```

Real-run checklist (owner, once):

1. Authorize this Mac's key on linux-box: `ssh-copy-id aakash@192.168.8.174`, then
   `ssh -o BatchMode=yes aakash@192.168.8.174 true` must succeed without a prompt.
2. On linux-box, `gh auth status` shows a token with `repo` scope (clones and statuses use it),
   and `command -v git gh flock make docker` finds all five.
3. First gate per repo prints `no checkout of <slug> at ~/gates/<repo> …; cloning`. A second run
   must not clone again.
4. Logs land on the host in `~/gates/.state/<GATE_STATE_NAME>/logs/<pr>/`. The host queue's
   gates keep `~/.local/state`; both share `/tmp/linux-box-local-gate.lock`, so one gate runs at
   a time across both.
5. `make gate PR=<n> GATE_ARGS=--no-post` from the Mac shows `GATE note: remote aakash-ser8 …`
   and the same `VERDICT` line a run on linux-box prints.

## Metrics ratchet (ci-metrics)

A repo declares its collectors in `scripts/ci/metrics.conf`, one per line, and its Makefile
holds three one-line targets. Everything else (which collectors a PR runs, the merge, the
comparison with main, the label) is devkit's.

```make
ci-metrics:       ## gate job: no metric worse than main
	devkit/bin/metrics_collect.sh check
metrics-snapshot: ## run the collectors; build/metrics.json is the report
	devkit/bin/metrics_collect.sh snapshot
metrics-tighten:  ## lock in BETTER numbers; commit docs/metrics/ratchet.json in the same PR
	devkit/bin/metrics_collect.sh tighten
```

```sh
# scripts/ci/metrics.conf: <name> <area> <command...>   (# comments and blank lines ignored)
py-backend  backend  uv run --frozen --project backend python devkit/metrics/python.py --root backend --src app --scope backend --mccabe --cycles --out build/metrics/py-backend.json
cov-backend job:unit-backend python3 -I devkit/metrics/coverage.py --scope backend --coverage-json backend/build/coverage.json --out build/metrics/cov-backend.json
dup         repo     node devkit/metrics/jscpd.mjs --scope repo --out build/metrics/dup.json backend/app frontend/src
```

`<name>` names the output file `build/metrics/<name>.json` and is recorded as each key's
`source`. `<area>` is the fleet area (docs, backend, frontend, native, tooling, other) whose
paths can move the collector's numbers, `repo` for a whole-repo tool, or `job:<gate job>`
for a collector that reads that gate job's output (coverage from `unit-backend`) rather than
the tree. The command runs with
`bash -c` from the repo root under the repo's own dev dependencies (`uv run …`,
`node_modules/.bin/…`) and must write its file in the `docs/metrics-keys.md` shape. The shared
collectors in `devkit/metrics/` (`python.py`, `ts.mjs`, `jscpd.mjs`, `coverage.py`; CLIs in the
Architecture table, keys in `docs/metrics-keys.md`) cover the fleet's stacks, so one
implementation measures a thing fleet-wide (owner decision B, 2026-10-13); a repo-specific
collector (finplat's reinvention registry) is any script that writes the file.

In the gate, `ci-metrics` is the last job (`GATE_JOBS_METRICS`, above). An area collector runs
when a changed path is in its area or when an `other` path changed; `repo` collectors always
run; `tooling` widens nothing (devkit's collectors and ratchet classify as `other`, so a
devkit sync that changes one still runs everything, and a tooling-only PR runs no tier); a
`job:<name>` collector runs only when `build/metrics/gate.json` records that job's seconds,
which `local_gate.sh` writes after each job, so exactly when the job ran in this gate (a job
the plan skipped, for any reason, leaves no entry). The rest are skipped, and the snapshot
says so: `check` reports their tracked keys as `SKIPPED (collector <name> did not run)`
rather than failing. Why: a frontend-only PR cannot have changed backend coverage, and the
backend unit job that produces that coverage did not run either. Outside the gate every
collector runs, on the pinned toolchain (`toolchain_path`, as the gate and the hooks).

**Coverage** is produced by the unit tier, not by a collector: each `ci-unit-<area>` runs with
coverage on and writes the tool's report (coverage.py JSON, an istanbul summary);
`devkit/metrics/coverage.py` converts it to `coverage.<area>.lines|branches`, declared with
`job:<the tier's gate job>` so it runs only when that job ran. Outside the gate
a missing report fails the collector with "run make ci-unit-<area> first". A tier whose budget
coverage would break says so in its PR rather than dropping the budget.

**Never track `gate.*`, `tier.*` or `tests.*`** in `ratchet.json`: jobs and tiers are
area-scoped, so those keys are absent on narrow PRs, and the seconds are noisy. They stay in
the snapshot as untracked, for the report.

**Gate-only.** Collectors need the dev dependencies and take tens of seconds (target under
60 s; the job budget is 5 min), so `ci-metrics` is neither a hook step nor an Actions job.
`check` reads main's bounds through `git show origin/main:docs/metrics/ratchet.json`; an
unresolvable base ref is an error, never "no guard".

Adoption: start `docs/metrics/ratchet.json` from `{}` (or from
`devkit/templates/metrics/ratchet.json`, every shared-collector key at `null`), write
`scripts/ci/metrics.conf`, then `devkit/bin/metrics_collect.sh rebaseline` fills every bound
from today's numbers, seeds every untracked key the collectors emit (never `gate.*`,
`tier.*`, `tests.*`; a repo-specific domain is added by hand with its direction) and records
each key's collector. Commit both files; the devkit-sync commit itself needs no change, the
adoption PR carries the attribution trailer. From then on a PR
that improves a number runs the repo's `metrics-tighten` target and commits the bounds; a PR that must
loosen one (a tool knob moved the numbers) produces the looser file with `rebaseline` and
carries the `metrics-rebaseline` label.

## Rules

- Never edit `devkit/` inside a consuming repo; `devkit-check` fails quick-check. Change it
  here, merge, then `devkit-sync` in each repo.
- Output contracts (`GATE …`, `VERDICT …`, `.devkit-rev` format) are APIs: the merge queues,
  `worker.py` and the Mac stand-in parse them. Changing one is a coordinated change.
- Scripts run on macOS bash 3.2 and GNU bash, with BSD and GNU coreutils. shellcheck clean.

## Standard docs

Every repo carries the same docs set, and `make docs-check` (in `ci-quick`) keeps it present and
honest. `devkit new` emits all of it from `templates/new/common/`. The new rules warn until
2026-11-15 and fail from then; the dates live at the top of `bin/docs_check.sh`.
`docs_check.sh --report` prints where a repo stands (the monthly audit records it), and
`docs_check.sh --fix` does the mechanical half on a clean tree: report-shaped or unlinked one-off
docs move to `docs/reports/<first-commit-date>-<slug>.md` with their links rewritten, living docs
get their README link, old operations names are renamed, the contributors line is added; what
needs a reader (oversize AGENTS.md, non-standard sections, CONTRIBUTING.md) is listed as judgment
items. One reviewable diff, then `docs_check.sh --report` again.

AGENTS.md is in every agent session's context, so it stays a navigation-sized map and reference
material lives in `docs/`, which nothing loads unprompted. The caps are absolute from 2026-11-15:
root `AGENTS.md` ≤ 30 KB, any other ≤ 16 KB (`docs_oversize.txt` allowances end that day).

| File | Holds | Checked |
|---|---|---|
| `README.md` | For a human arriving cold. One intro paragraph, then five H2 sections (aliases in `README_SECTIONS`): **Getting started** (install, run locally), **Commands** (the everyday `make` targets), **Architecture** (a short map, linking the full one), **Deploy** (how a change reaches users; "not deployed" is an answer), **Documentation** (an index of the other docs, with the line "Contributors and agents: see AGENTS.md"). | sections present; the contributors line; every `make <target>` it names exists |
| `AGENTS.md` + `CLAUDE.md -> AGENTS.md` | For every agent session: rules, commands, deviations. The root file's H2s come only from: **Stack**, **Architecture**, **Where things live** (or Navigation, TL;DR), **Convention deltas**, **Commands**, **CI and the PR gate**, **Workflow**, **Deliberate exceptions**, **Documentation**. Stack, Convention deltas, Commands and Workflow are required. A Conventions, Guidelines, Patterns or Best practices section restates the convention files: keep only the deltas. It is also the contributor guide: no `CONTRIBUTING.md`. | pair shape, size cap, retired tools, the H2 list, `make` targets, no links into `docs/reports/` |
| `docs/decisions.md` | Dated entries, newest last: `## YYYY-MM-DD — title`, then Why / Decision / Consequence lines (`**Why:**`, `**Why**:` or `Why:`), at most eight lines. The root `.gitattributes` gives it `merge=union`, so two PRs that each append an entry rebase without a conflict (`hooks_check.sh --fix` adds the line). | exists; every H2 dated, in order, all three lines; the union line |
| `docs/architecture.md`, or `## Architecture` in the root `AGENTS.md` | Components, data flow, runtime. One home: a repo whose AGENTS.md already maps itself needs no second copy. | one of the two exists |
| `docs/operations.md` (when there is something to operate) | Deploy, backup and restore, troubleshooting. `docs/runbook.md` and `docs/deployment.md` are old names: rename. | the old names |
| `docs/reports/<YYYY-MM-DD>-<slug>.md` | Dated one-offs: expert panels, audits, history, perf notes. Never linked from any AGENTS.md, so they stay out of agent context. | the name; no AGENTS.md link into it |

Any other `docs/**/*.md` is a living doc the repo chose and must be linked from README's
Documentation section; otherwise it is a report and moves to `docs/reports/`. Every relative link
in `README.md`, `AGENTS.md` and `docs/**/*.md` must resolve to a tracked file.

Recommended, not checked (the fleet has no common shape for these yet): `docs/observability.md`
or an Observability section for a running service, testing notes per tier. A repo's own extra
rules go in `scripts/ci/docs_rules.sh`.

## Scorecard

`bin/scorecard.py <repo>` prints `score <track> <check> PASS|FAIL|D|UNMEASURED|NA <evidence>`
lines, one `track <id> <letter> …` line per track and a `grade <repo> <letter>` line;
`--fleet <repo>...` prints the table every repo is raised against. The design and the track list
are in `standardization/scorecard-design.md` (solo); the flywheel: an UNMEASURED check is a
devkit mechanism to build, a FAIL is a repo lane, and a track share never drops below main's
once the ratchet over it ships. Letters: A ≥ 95 % of a track's checks pass, B ≥ 85, C ≥ 70,
D ≥ 50, else F; unmeasured counts as fail on purpose.

The ratchet: a repo commits `docs/metrics/scorecard.json` (`bin/scorecard.py . --mode rebaseline`
once) and from then on its `ci-metrics` target fails a PR whose share on a ratcheted track (T1-T6, T10,
T12-T14: the tracks only a code change can move) drops below the committed one; its `metrics-tighten` target
raises the committed shares; the `metrics-rebaseline` label allows a drop. T7, T8, T9, T11 and T15
move without a code change (live metrics, seconds, the ledger, new advisories, devkit itself) and
stay graded, not gated.

## Deploy

devkit itself is not deployed. A squash-merge to `main` is the release; each consumer takes it
with its `devkit-sync` target in its own PR, which runs that repo's gate against the new tree.

## Commands

Every check is a Makefile target; `scripts/ci/gate_plan.sh` and `.github/workflows/ci.yml` call
the same ones. `make gate PR=<n>` is the merge signal (it posts `local-gate` on the PR head);
Actions is a second opinion that the account's billing has blocked before.

```sh
make ci-quick        # shellcheck 0.11, python unit tests, docs/toolchain/workflows guards on devkit itself
make ci-unit         # bats tests/
make gate PR=<n>     # both, on PR <n> merged into origin/main
```

## Documentation

- Contributors and agents: see [AGENTS.md](AGENTS.md).
- [docs/decisions.md](docs/decisions.md): every decision, dated, newest last.
- [docs/metrics-keys.md](docs/metrics-keys.md): the metrics snapshot key shape.
- [templates/new/README.md](templates/new/README.md): what `devkit new` renders and how to add a stack.
