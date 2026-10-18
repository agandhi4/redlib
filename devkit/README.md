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
| `bin/devkit-sync.sh` | Fetch upstream, replace `devkit/` with its tree filtered to `VENDOR_PATHS`, record `<commit> <filtered tree>` in `.devkit-rev`, commit. Refreshes tracked copies of vendored bases (`.swift-format`, `.githooks/*`) in the same commit. Conflict-free by construction. `--stage` leaves it in the index for the caller's own commit. |
| `bin/devkit-new.sh`, `templates/new/` | `devkit new <name> --stack <stack> [--dir <parent>] [--no-image]`: a new repo that passes every guard on its first commit, which is made through the hooks. Stacks: `python-fastapi`, `node-service`, `rust`, `next-vercel`, `swift-app`; each is a directory under `templates/new/stacks/` (how to add one: `templates/new/README.md`). See "New project". |
| `bin/devkit-check.sh` | Offline guard for `ci-quick` and pre-commit: the staged `devkit/` tree equals the staged `.devkit-rev` (both read from the index). Fails on in-repo edits, and on a tree holding paths outside its own `VENDOR_PATHS` (vendored whole by a pre-manifest sync: rerun the repo's `devkit-sync`), and on any tracked `.swift-format` that is not byte-equal to `lint/swift-format.json`. |
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
| `bin/workflows_check.sh`, `bin/_workflows_lib.sh` | Guard for `ci-quick`: Actions follows the minutes and supply-chain rules. Every `uses:` is a commit SHA with a `# vX.Y.Z` comment (devkit reusable workflows may float on `@main`). A `pull_request` workflow runs one job, skips drafts, cancels superseded runs and ignores `**.md`; more jobs need a top-level `# workflows-check: multi-job ok: <reason>`. A job pushing an image on main runs with `cancel-in-progress: false`. Every `runs-on:` names a versioned image (`ubuntu-24.04`), never a `-latest` label. The lib's push-step detection is shared with `release_check.sh`. |
| `bin/playwright_browsers.sh` | Installs the Playwright browsers the lockfile pins (default `chromium`) with the lockfile's runner and the `.nvmrc` Node; idempotent via Playwright's cache. `--with-deps` is honoured on Linux, ignored on macOS. |
| `bin/docs_check.sh` | Guard for `ci-quick`: every `AGENTS.md` is the real file with `CLAUDE.md` symlinked to it, size caps (30 KB root, 16 KB nested; the shrink-only allowlist in `scripts/ci/docs_oversize.txt` ends 2026-11-15), `docs/decisions.md` exists, no retired-tool words, and the standard docs set ("Standard docs" below: required files and README sections, the root AGENTS.md's H2 list, the fixed `docs/` set with dated `docs/reports/`, no CONTRIBUTING.md, dated decisions entries, `make` targets and relative links that resolve, `docs/decisions.md merge=union` in `.gitattributes`; warnings until their date, then failures); repo extras in `scripts/ci/docs_rules.sh`. `--report` prints the numbers (sizes vs caps, allowances, docs outside the set, H2s outside the list) for trims and the monthly audit. |
| `bin/quiet_run.sh`, `bin/hook_steps.sh`, `bin/push_ranges.sh`, `bin/hooks_check.sh`, `templates/githooks/` | Git hooks: one line per step, 40-line tail on failure; per-repo steps in `scripts/ci/hooks.conf`, scoped by changed paths by default from one fleet layout table (docs, backend, frontend, native, tooling, other: `devkit_classify_path` in `_paths_lib.sh`, which the gate uses too; tooling runs every hook step, like other) and each step's target name, so a docs-only change runs docs-check alone, a frontend-only one skips backend steps and a native-only one (ios/, OrbitAgent/) runs nothing, with `:unless=<globs>`, `:only=<globs>` or `:always` per step only where a repo's layout deviates; `hooks_check` asserts `core.hooksPath=.githooks` (a tool install silently repointed finplat's for two months) and `--fix` self-heals it and adds the decisions-log union line to `.gitattributes`; it rejects a malformed step override and warns on a typecheck or unit step at pre-commit ("Git hooks"); LFS chained when the repo uses it. Before the first step the pinned Node and Rust go first on PATH, as in the gate (`toolchain_path.sh`), so `hooks.conf` lists steps only. A passing cargo step's summary sums every `test result:` line (the last one is the doctests). Every run appends step and total wall seconds to `$XDG_STATE_HOME/devkit/hooks/<repo>.tsv` (`<repo>` = the origin remote's repository name, lowercased, so worktree lanes share the repo's file), the per-machine hooks ledger the scorecard reads (T8: pre-commit p90 ≤ 30 s, pre-push ≤ 60 s). Steps run without the GIT_DIR git exports to a worktree's hooks (a step's `git init` would otherwise set core.bare=true in the shared config), and a step that still changes core.bare is named on stderr and in its ledger row, then undone (#48). |
| `bin/tier_guard.sh` | `<tier> --budget <s> [--floor <runner>=<min>]... -- <cmd...>`: one test tier under a wall-clock budget (the whole command's wall time; it fails over budget even when every test passed, `TIER_BUDGET_ENFORCE=0` only reports) and per-runner floors on the tests that RAN (skipped ones do not count), read from the runner's own summary line: `pytest`, `vitest`, `playwright`, `cargo`. Streams the command's output, exits with its code, prints `TIER <tier>: …` / `FAIL` / `FLOOR` / `OVERBUDGET` lines and writes `build/metrics/tier-<tier>.json` at the git top level (`tier.<tier>.seconds`, `tests.<tier>.<runner>`). Every `devkit new` stack's test tiers run through it. |
| `bin/metrics_collect.sh` | `<snapshot\|check\|tighten\|rebaseline>`: the `ci-metrics` mechanism. Reads `scripts/ci/metrics.conf` (`<name> <area> <command...>`), runs each collector from the repo root into `build/metrics/<name>.json`, skips those whose area no changed path touched (in the gate; `tooling`/`other` and `repo` collectors run regardless), merges with the gate's and tiers' files, then runs the ratchet. A repo's Makefile holds four one-line targets and nothing else. "Metrics ratchet" below. |
| `metrics/` | The shared collectors a `metrics.conf` line calls, one per stack, each `--scope <name> [--out FILE]`, deterministic, exit 2 naming a missing dev dependency: `python.py --root <dir> --src <subdir|module.py>... [--python <interp>] [--mccabe] [--cognitive] [--vulture [--vulture-ignore-declarative] [--vulture-base <set,...>]] [--cycles]` (ruff C901, complexipy, vulture, AST import cycles; run under the repo's interpreter, `uv run --frozen --project backend python devkit/metrics/python.py …`, so the tools resolve); `ts.mjs --root <dir> --src <subdir> [--tsconfig F] [--test-glob G]... [--cyclomatic] [--cognitive] [--knip [--knip-base]] [--cycles] [--bundle [--bundle-entry index.html]]` (eslint `complexity`, sonarjs cognitive, knip, dependency-cruiser cycles, vite bundle KiB; tools from `<root>/node_modules/.bin`); `rust.py --root <workspace> [--cognitive] [--dead]` (clippy `cognitive_complexity` scoring every function, rustc's unused-code warnings; one `cargo clippy`/`check --workspace --locked` on PATH's cargo, which the gate provisions from `rust-toolchain.toml`); `jscpd.mjs --scope repo [--min-tokens 50] [--min-lines 5] [--bin <jscpd>] [--base] [--list-out FILE] <paths...>`; `coverage.py --scope <s> (--coverage-json F \| --istanbul-summary F)` (the tier writes the report; "run make ci-unit-<s> first" when it is missing). Keys per collector: `docs/metrics-keys.md`. The `--*base` flags merge `lint/`'s knip, jscpd and vulture bases under the repo's own config (`lint/README.md`). |
| `bin/metrics_ratchet.py` | The "never worse than main" gate. `check` holds a snapshot to `docs/metrics/ratchet.json` and that file to main's copy (`git show origin/main:…`), so a PR cannot loosen its own bounds; `tighten` locks in BETTER numbers in the improving PR and prints every WORSE or MISSING key as `check` would, exiting 1, so the author sees the gate's refusal first; report-only keys (`vuln.*`, `coupling.*.fan_in_max`) are printed, never gated, and `tighten`/`rebaseline` commit their values to `docs/metrics/report-only.json` for the scorecard; `merge` joins `build/metrics/*.json` into one snapshot that records each key's collector and the collectors skipped, so a key whose collector did not run is SKIPPED, not a failure. Committing a looser bound needs the fail-closed `metrics-rebaseline` PR label; no label admits a value past the committed bound. |
| `templates/metrics/ratchet.json`, `docs/metrics-keys.md` | Starter bounds (all `null` until `rebaseline` fills them, so `check` refuses a raw copy; `{}` is the other valid start) and the flat `<domain>.<scope>.<stat>` key shape every collector emits. |
| `bin/own_commit_check.py` | Transaction-boundary guard: AST scan fails a raw `.commit()` on a session the function did not open itself (`with … as db` / `db = Session()`), and pins every `commit_now(…, reason=…)` call to a shrink-only `path::qualname` allow-list. Prints `own_commit_allowlist_entries=<n>` for `metrics_ratchet.py` (direction lower). Opener regex and excludes are per repo. A TS repo holds the same boundary with guard_check's `own-transaction` kind. |
| `bin/layer_check.py` | Dependency-direction guard for `ci-quick` (the consumer's `layer-check` target): the repo's `scripts/ci/layers.conf` declares, per source tree (`[section]`, the ratchet scope), its layers bottom-first by path glob, plus `peer` (same rank, neither imports the other), `entry` (composition root), `leaf` (imports nothing of ours), sanctioned `allow` edges, `deny` for a skipped layer and the shrink-only `known` violations. An import from a lower rank to a higher one fails, as does a file in no layer or a `known` line that is no longer refused. Python reads `metrics/python.py`'s runtime import graph (the one `coupling.<scope>.cycles` counts), its import-statement edges only (the package-initializer edges the cycle count adds run beneath every layer); TypeScript reads import statements (aliases from the conf, type-only imports erased). Prints `layer_violations=<n>`; `--metrics-out` writes `coupling.<section>.layer_violations` (direction lower), so a scaffold's `metrics.conf` runs it as the `layers` collector. Stdlib only. |
| `bin/guard_check.py` | Code-structure guard for `ci-quick` (the consumer's `guard-check` target): the repo's `scripts/ci/guards.conf` declares import, call and semantic rules per source tree (the catalogue in "Guards (guard-check)" below), with `except` sites and shrink-only per-file `known` debt. `--metrics-out` writes `guards.<section>.known`, so a scaffold's `metrics.conf` runs it as the `guards` collector. Stdlib only; the predicates are `bin/_guard_rules.py`, and it shares `bin/_source_tree.py` (the conf's section keys, globs, file walks) and `bin/_ts_lex.py` (the TS lexer) with `layer_check.py`. |
| `bin/dead_alert_audit.py` | Monthly review of vmalert rules (not a gate, exit 0): statically flags missing `severity`/`runbook`, `outcome` values outside `success|failure`, names duplicated across files; with `--vm-url` asks VictoriaMetrics which alerts never fired and which selectors matched no series in `--since` (default 30d). One `dead-alert <high|medium|low> <alert> <reason>` line per finding. |
| `bin/monthly_audit.sh` | Monthly fleet audit, run from this checkout (not vendored). Per active vendoring repo, in a fresh shallow clone: the guards `ci-quick` does not already reach, `.devkit-rev` skew, the ratchet, and a re-invention diff (`reinvent <repo> <path> <kind> <devkit equivalent>`; naming the file under AGENTS.md "Convention deltas" silences it). Fleet: labels/settings dry-runs, `dead_alert_audit.py`, gate-ledger digest. Writes `report.md`, `summary.tsv`, `findings.json`; one read-only `claude -p` proposes ≤ 3 structural findings, which the script files as `fleet-audit` issues (none while 3 are open; off for the first two runs) and PRs the report to homelab `docs/audits/`. Kill switch `~/.config/devkit/audit.off`. Schedule (owner step, install by hand): fill `__DEVKIT__`/`__HOME__` in `templates/launchd/com.agandhi4.devkit.monthly-audit.plist`, `mkdir -p ~/Library/Logs/devkit`, `cp` it to `~/Library/LaunchAgents/`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.agandhi4.devkit.monthly-audit.plist`. |
| `github/` | Fleet operations run from this checkout, not vendored: `labels.json` + `labels_sync.sh` (idempotent; `--prune` to delete), `repos.json` + `repo_settings.sh` (squash-only, PR_TITLE/PR_BODY, delete-branch; auto-merge only on public repos). |
| `renovate/default.json` | Shared Renovate preset (`github>agandhi4/devkit//renovate/default`): weekly grouped minors, pinned action digests, no automerge (Renovate PRs never get the Mac `local-gate`), `.nvmrc` + `FROM node` + `engines` bumped together, dashboard approval instead of hard ignores so security fixes still flow. |
| `.github/workflows/quick-check.yml` | Reusable `workflow_call` quick-check (checkout, Node from `.nvmrc`, optional Python + uv, `make ci-quick`); caller template in `templates/workflows/`. Needs devkit's Actions access set to "repositories owned by the user". |
| `lint/ruff.toml` | Shared ruff base (py313, 100 cols, E F I N W UP T20 PLC0415); consumers `extend` it. |
| `lint/eslint.base.mjs` | Import-free flat-config array of core rules (no-console, no-eval, no-implied-eval, HTML-sink properties); consumers spread it first. |
| `lint/swift-format.json` | The swift-format config; a repo's `.swift-format` is a byte copy that `devkit-check` holds. |
| `metrics/size.py` | File-size collector for any language: `size.<scope>.max_lines` and `size.<scope>.over_600` over the production files (tests, fixtures, generated paths excluded). The ratchet holds them never-worse; the scorecard prints them on its T2 complexity line, never as a check (size alone never justifies a split). One conf line per area. |
| `bin/secrets_check.sh` | Guard for `ci-quick` (scorecard T11): no credential in the tracked files (~1 s per 1,000 files; `--staged` scans only the staged paths, for pre-commit). gitleaks' high-confidence shapes (private keys, AWS, GitHub, Slack, Google, Stripe, Anthropic/OpenAI, age) everywhere, and long literals assigned to secret-named variables outside tests and placeholders; `scripts/ci/secrets_allow.txt` names a fixture's fake key with its reason. The matched text is never printed. |
| `bin/migration_check.py` | Guard for `ci-quick` (scorecard T5, data.md 12 and 14): no shipped migration is modified or deleted (the `migration-contract` label, or `--allow-shipped-edits`, makes a deliberate one pass), and no alembic `downgrade()` is a `pass` body (write it, or raise with the reason; merge revisions are exempt). `--versions <dir>` per migrations directory; drizzle dirs get the edit check only, and a `meta/_journal.json` change that only appends entries (every other key and every shipped entry unchanged) is not an edit: each new migration appends one. |
| `metrics/vuln.py` | Vulnerability collector for any stack (scorecard T11): the locked production dependencies (`uv export`, package-lock.json, pnpm-lock.yaml, Cargo.lock) asked of OSV in one batch, each hit fetched once for severity; `vuln.<scope>.critical|high|total`, report-only (a new advisory is not a code regression, so the ratchet never tracks it). No audit tool needs installing. |
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
(the split in "Git hooks" below; swift-app's pre-commit is `ci-quick` and its pre-push
`ci-lint-swift`, since its tests take minutes); `.github/workflows/quick-check.yml` calling the reusable workflow (swift-app's runs
the `ci-guards` target, the only tier that runs off a Mac), and for image stacks `publish.yml`
(build, `ci-smoke`, push `sha-<7>` + `latest`, ship tag, never cancelled) with a Dockerfile carrying the `APP_VERSION` trio;
`renovate.json` on the shared preset; `.claude/settings.json` (claude-kit plugins); `AGENTS.md`
(the project delta only: Stack + `Conventions:`, Architecture placeholder, Convention deltas,
Commands, Workflow) with `CLAUDE.md` symlinked; `docs/decisions.md` with its first entry; the
toolchain pin; the stack's lockfile; the smallest app that serves `/health/live` and
`/health/ready` (swift-app: shows its build identity), with a test per tier. The first commit runs through pre-commit, so `ci-guards`
(devkit-check, toolchain-check, docs-check, release-check, workflows-check, layer-check and
guard-check outside rust and swift-app, own-commit-check for Python), the staged secrets scan
and lint/format have passed on it before you see it.
`tests/new_contract.bats` holds every stack to this.

### Browser logger

next-vercel ships the fleet's browser logger: `src/lib/log.ts` (`logger(domain)`, named
`<app>.web.<domain>`; console in dev; in prod debug dropped, info into a 50-entry ring buffer,
warn a breadcrumb, error a capture tagged with `logger` and `request_id`, through
`setErrorSdk`; console fallback without the SDK) and its contract test `log.contract.test.ts`,
plus `server-log.ts` for server code (JSON lines carrying `ts`, `level`, `logger`, `msg`,
`version`, the string `/health` reports from `version.ts`, and `request_id` inside a request). Those two modules are the only
console callers (guards.conf, the eslint override). A React repo copies `log.ts`,
`error-fields.ts`, `redact.ts` and the contract test, wires its SDK loader, its `beforeSend`
(`recentLogs()` as `contexts.logs`) and its API client (`setLastRequestId`), and keeps the test
green. A browser-only copy (no `server-log.ts`) leaves no unused export: `redact` sits in its
own module because `errorFields` reaches it in both sets, and template-tests run knip over
both. A service worker loads no SDK and nothing reads its buffer, so worker code logs warn and
error only: those reach the console, and nothing else of a prod worker is seen.

A caught error is logged as `errorFields(err)`, whole as a level's fields or spread beside the
caller's, never its text: `src/lib/error-fields.ts`, re-exported by both loggers and copied
with `log.ts`, returns flat `error_class`,
`error_message` (query strings, URL credentials, `Bearer` values and secret-named `key=value`
pairs redacted, cut at 200), `error_status` and `error_code` when the error has them, and
`error_cause` in the same shape, three deep. A network error (a Node system error, an undici
`UND_ERR_*`) logs its syscall and code, never its text; a non-Error logs its type alone. The
browser `error()` puts these fields on the buffered entry and the capture's `extra`, and the
server line formatter runs the same `redact` over `msg` and any `stack` or `*_traceback` field,
so a call site that splices `err.message` in still writes no query string. The scaffold's
guards.conf holds call sites to it (`no-raw-error-text`), seeing each logger by the name it is
bound to: bind every one `const log = logger("domain")`. The contract test pins the shape, and
template-tests' tsc holds `ErrorFields` to a type a logger's fields accept whole.

`error()` takes `unknown`, as a strict catch clause and a rejection reason are: a string is the
message, an Error a capture, any other value a message naming its type. A failed request goes
through `logFailure(log, err, fields)`, whose `failureLevel(status)` is the policy: a 4xx is a
warn (a breadcrumb; a wrong password opens no issue), a 5xx, the network or no status an error.
Both spread errorFields first and the caller's fields after, so a caller's key wins: one whose
error text carries detail it must not log passes a replacement (`{ error_message: "HTTP 403" }`),
which is also the entry's message.

The API client's one failure hook is `src/lib/api-failure.ts`: `logRequestFailure(log, err,
failure, fields)`, called once for every failed request (TanStack Query's `QueryCache` and
`MutationCache` `onError`; the module header has the two lines), never at call sites. The app
maps its client's error onto `failure` (`cancelled`, `offline`, `status`), since only its
client knows which is which: a cancelled request logs nothing, offline is a warn carrying the
error's class, a status replaces the error's text (`HTTP 404`) and picks the level through
`logFailure`, and no status is an error. The client records `X-Request-ID` before it throws, so
the entry names the failed request. Its test is `api-failure.test.ts`.

A Python repo keeps the same shape in its logging module (orbit's `utils/logging.py` is the
reference): `error_fields(err: BaseException) -> dict` with the keys above (status from
`status_code` or `response.status_code`; the cause is `__cause__`, else `__context__` unless
suppressed; an `OSError`, which requests' `ConnectionError` is, logs its class and `errno` name,
never its text), and its JSON formatter runs `redact` over `record.getMessage()` and the
formatted `exc_info`/`stack_info`, so `logger.exception()` cannot leak a query string. The
python-fastapi scaffold has no logging module yet; the first one it ships carries both.

The file names are the app's; the exported API and the contract test are the contract. An app
whose server logger already owns `log.ts` names the browser module otherwise (rollcall:
`src/lib/browser-log.ts`), and a repo that keeps tests under `tests/` moves the test there. Either
way the app edits one line of the test, the literal `import("./log")` in `load()`, and names its
chosen files in the guards.conf `only-call console.*` lines and the eslint override. It stays a
literal: knip follows no constant specifier and counts the whole API as unused exports
(devkit's template-tests run knip over the scaffold to hold it).

A Vite app changes two lines, because Vite replaces `import.meta.env.DEV` where Next inlines
`NODE_ENV` (vitest's `stubEnv` sets `DEV` as a boolean):

```diff
 // log.ts
-const DEV = process.env.NODE_ENV !== "production";
+const DEV = import.meta.env.DEV;
 // log.contract.test.ts, in load()
-  vi.stubEnv("NODE_ENV", mode);
+  vi.stubEnv("DEV", mode === "development");
```

The contract is `standardization/browser-logger-design.md`. There is no `devkit-check` byte
comparison, by design: apps differ in how the SDK loads, and the test holds what must not.
`make ci-quick` runs the scaffold's hermetic tests, the contract test and `tests/unit`
(`template-tests`, under the vitest pinned in `tests/templates/`), then knip over the logger
modules (`tests/templates/knip.jsonc`).

### Request id

`src/proxy.ts` (Next 16's proxy, formerly middleware) mints every request's id, 12 lowercase
hex, replacing any inbound `X-Request-ID` (observability.md: never trust one). It forwards the
id to server code as a request header and returns it on the response. A route handler or server
action opens the scope once, `inRequest(request.headers, fn)` or `inRequest(await headers(), fn)`
(`src/lib/request-context.ts`, an AsyncLocalStorage), and every `server-log.ts` line inside
carries `request_id`; `/health/ready` is the scaffold's example. `src/lib/request-id.ts` imports
nothing, so the API client imports `REQUEST_ID_HEADER` from it and records the response's id
with `setLastRequestId`. Its contract test is `request-id.contract.test.ts`. An app with its own
proxy (rollcall first) copies `request-id.ts` and `request-context.ts`, mints at the top of its
proxy and returns every branch, redirects included, through `stampResponse`, adds `request_id:
currentRequestId()` to its server logger's reserved keys, and wraps its handlers and actions in
`inRequest`. The proxy's matcher must cover every route that calls `inRequest`.

A browser cannot read a server action's response headers (rollcall found it), so an app whose
only server calls are server actions has no client-side request id. The server-side id still
lands on every log line, but in the action's thrown error only if the action puts it there. The
recommended pattern, not yet built: the action's error/result envelope carries `requestId`, and
the client logger's `setLastRequestId` is fed from the envelope.

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

## Git hooks

`templates/githooks/` run `bin/hook_steps.sh` over the repo's `scripts/ci/hooks.conf` (format,
path scoping and the ledger: its header). What goes in which hook follows the scorecard's T8
budgets, read from the hooks ledger: pre-commit p90 at most 30 s, pre-push at most 60 s.

- **pre-commit** runs the parts of ci-quick that take seconds: `ci-guards` (the stdlib guards),
  `secrets-staged` (`secrets_check.sh --staged`; the full-tree scan stays in ci-quick),
  `ci-lint` (cached eslint, then `prettier --check`; ruff; rustfmt) and `ci-drift` where the
  stack has migrations.
- **pre-push** runs `ci-typecheck` (tsc, clippy) and `ci-unit`.
- **ci-quick is the union of its parts**, so the gate and Actions still run all of it. A new
  quick check goes into a part, and a new part into ci-quick and one hook.
- **hooks_check.sh warns** when a pre-commit step's target names typecheck or unit.

Why: closet and rollcall ran all of ci-quick at pre-commit (tsc, the full secrets scan, an
uncached eslint), so every commit by every lane paid p90 33 s and 51 s. After the split
closet's warm pre-commit is 3 s (closet #407, rollcall #56). Caches stay per checkout under
`node_modules/.cache/`: a location shared by a repo's worktrees never hits (lint/README
"Caches").

Existing repos adopt the split by hand. `devkit-sync` refreshes `devkit/` only and never
rewrites a repo's Makefile or `scripts/ci/hooks.conf`. A repo whose hooks.conf still says
`PRE_COMMIT_STEPS=("quick=ci-quick")` (on 2026-10-17: finplat, orbit, locus, instalite,
redlib) needs the named ci-quick parts as Makefile targets, then those parts at pre-commit and
`ci-typecheck` beside its unit steps at pre-push. rollcall and closet are the worked examples.

## Vendor into a repo (once)

```sh
~/projects/solo/devkit/bin/devkit-sync.sh     # creates devkit/ from upstream main, writes .devkit-rev, commits
```

Updates are the consumer's `devkit-sync` target. The sync fetches upstream and replaces `devkit/` wholesale
(`git read-tree`), so it never conflicts; `devkit-check` compares the tree hash. There is no
`git subtree` involved any more: squash merges drop the trailers subtree needs. The sync also refreshes the repo's tracked byte copies of vendored bases (every `.swift-format`, `.githooks/pre-commit` and `pre-push`) when they differ, printing one line each; it never creates one.

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
GATE_IMAGE_EXCLUDE_PATHS='^(tests/|\.github/)'          # app paths outside the image (.dockerignore)
GATE_IMAGE_PATHS='^scripts/ci/smoke_image\.sh$'        # paths that also run the image group
gate_plan() { devkit_default_gate_plan; }
gate_plan_extra() { ...; }                             # optional: the repo's own rules
```

Each changed path gets one area from the table the hooks use (docs, backend, frontend,
native, tooling, other). Docs-only runs docs; tooling (`devkit/`, `.devkit-rev`, hooks.conf,
`.githooks/`; a devkit sync) runs quick, plus the image group when `boot_image.sh` or
`contract_probe.sh` changed; native-only runs nothing; backend and frontend run their groups
plus quick, image and e2e; other runs everything (`docs/metrics/ratchet.json` and
`scripts/ci/metrics.conf` are other, so a bounds-only PR meets the ratchet and its label).
The metrics group runs for backend, frontend and other, after `gate_plan_extra`, so
`ci-metrics` sees every earlier job's seconds; when the PR
carries the `metrics-rebaseline` label (read through `gh`, fail-closed) its jobs get
`METRICS_REBASELINE=1`. `GATE_AREAS_<GROUP>="..."` overrides a group's areas, except IMAGE and
E2E: every app path runs them, and a plan setting `GATE_AREAS_IMAGE` or `GATE_AREAS_E2E` is
exit 2 at the gate and a devkit-check failure in ci-quick. The table and
defaults: the `_paths_lib.sh` header. A plan may still be hand-written against the
skeleton's helpers, reading `GATE_AREAS` and `GATE_HAS_<AREA>`.

Gate environment (full contract in the script header):

| Variable | Default | What |
|---|---|---|
| `GATE_SLOTS` | `1` | How many gates may run at once on this machine, across repos. `1` keeps the single lock file `GATE_LOCK`; `N` > 1 uses `GATE_LOCK.1` … `GATE_LOCK.N`. The merge queues and linux-box keep `1`; raising it on a laptop accepts load-induced timing-test failures (2026-10-05). |
| `GATE_SILENT_MINUTES` | `15` | Watchdog: a job whose log has not grown for this long is stopped, status `error`, exit 2. `0` disables. |
| `GATE_CLEANUP_SECONDS` | `120` | The plan's `gate_cleanup` (EXIT trap) is stopped after this long, with one stderr line; a hung docker daemon once held a slot there for 12+ min. `throwaway_pg.sh` and `boot_image.sh` also probe the daemon (`DOCKER_PROBE_TIMEOUT`, 15 s) and bound each docker call (`DOCKER_CALL_TIMEOUT`, 180 s). |
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

**Stale heads.** Run from a checkout of the PR's branch, `gate.sh` passes the tip as
`--expect-head <sha>` (local or remote alike), and the gate re-polls GitHub's pull ref for up
to 60 s before planning, printing one `GATE waiting:` line, instead of gating the commit before
your push (Orbit #80, finplat #657). A head that never arrives is `GATE head FAIL`, no status.

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
holds four one-line targets. Everything else (which collectors a PR runs, the merge, the
comparison with main, the label) is devkit's.

```make
ci-metrics:       ## gate job: no metric worse than main
	devkit/bin/metrics_collect.sh check
metrics-snapshot: ## run the collectors; build/metrics.json is the report
	devkit/bin/metrics_collect.sh snapshot
metrics-tighten:  ## lock in BETTER numbers; commit docs/metrics/ratchet.json in the same PR
	devkit/bin/metrics_collect.sh tighten
metrics-rebaseline: ## KEYS=<key>[,<key>] loosens only those; commit, label metrics-rebaseline
	devkit/bin/metrics_collect.sh rebaseline
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

**Findings.** A count says how much to fix, not what. `metrics_collect.sh` passes
`--list-out build/metrics/<name>.findings.txt` to every `python.py`, `ts.mjs` and `rust.py` line and ends
the run with `findings: <files>`, pass or fail. Each file holds a `# <key>` header per key
with findings and one line per finding: functions over the complexity threshold worst first
(`backend/server/x.py:120 sync_all cognitive=52`), every dead-code finding
(`web/src/a.ts:3 Id type`), one line per import cycle naming its files, and the top 10 modules
by fan-in and fan-out. The ratchet and the scorecard never read it; formats in
`docs/metrics-keys.md`.

**Rust.** `rust.py` measures complexity and dead code; jscpd already reads `.rs`, so
duplication is `jscpd.mjs` over the source dirs; there is no cycles key (a module cycle inside
one crate is legal, and cargo refuses one between crates). A Rust repo (redlib) adds, beside
its `size-app` line:

```sh
# scripts/ci/metrics.conf
rust-app other python3 -I devkit/metrics/rust.py --root . --scope app --cognitive --dead --out build/metrics/rust-app.json
dup      other node devkit/metrics/jscpd.mjs --scope app --base --out build/metrics/dup.json src
```

then `devkit/bin/metrics_collect.sh rebaseline` (on the pinned toolchain: `PATH="$(devkit/bin/rust_toolchain.sh .):$PATH"`
outside the gate). `rust-app` needs `clippy` in `rust-toolchain.toml` components. `dup` needs a
pinned jscpd: a root `package.json` with `"jscpd": "5.4.0"` in devDependencies, its
`package-lock.json`, `node_modules/` git-ignored, an `.nvmrc`, and `npm ci` in the gate before
`ci-metrics`; until that is worth a Node toolchain, leave `dup` out. redlib on 2026-10-17:
`complexity.app.cognitive_max` 23, `cognitive_over_15` 5, `dead.app.rustc` 0 (its two
`#![allow(dead_code)]` files), jscpd 2.76% and 18 clones over `src`.

**Coverage** is produced by the unit tier, not by a collector: each `ci-unit-<area>` runs with
coverage on and writes the tool's report (coverage.py JSON, an istanbul summary);
`devkit/metrics/coverage.py` converts it to `coverage.<area>.lines|branches`, declared with
`job:<the tier's gate job>` so it runs only when that job ran. Outside the gate
a missing report fails the collector with "run make ci-unit-<area> first". A tier whose budget
coverage would break says so in its PR rather than dropping the budget.

**Never track `gate.*`, `tier.*` or `tests.*`** in `ratchet.json`: jobs and tiers are
area-scoped, so those keys are absent on narrow PRs, and the seconds are noisy. They stay in
the snapshot as untracked, for the report.

**Report-only keys** (`vuln.*`, `coupling.<scope>.fan_in_max`) are collected and never gated,
even when `ratchet.json` still holds a bound for one: `check` prints it as REPORT-ONLY, a PR
may drop it without the label, and `rebaseline` drops it. `tighten` and `rebaseline` write their values to
`docs/metrics/report-only.json`, committed with the bounds, which the scorecard reads from a
fresh clone (`check` never touches it). A hub module's fan-in is
architecture, not drift (finplat #659); fan-out (a god module) stays gated.

**Gate-only.** Collectors need the dev dependencies and take tens of seconds (target under
60 s; the job budget is 5 min), so `ci-metrics` is neither a hook step nor an Actions job.
`check` reads main's bounds through `git show origin/main:docs/metrics/ratchet.json`; an
unresolvable base ref is an error, never "no guard".

Adoption: start `docs/metrics/ratchet.json` from `{}` (or from
`devkit/templates/metrics/ratchet.json`, every shared-collector key at `null`), write
`scripts/ci/metrics.conf`, then `devkit/bin/metrics_collect.sh rebaseline` fills every bound
from today's numbers, seeds every untracked key the collectors emit (never `gate.*`,
`tier.*`, `tests.*` or a report-only key; a repo-specific domain is added by hand with its direction) and records
each key's collector. Commit both files; the devkit-sync commit itself needs no change, the
adoption PR carries the attribution trailer. From then on a PR
that improves a number runs the repo's `metrics-tighten` target and commits the bounds.

The `metrics-rebaseline` label permits a PR to COMMIT bounds looser than main's; it never
permits a measured value past the committed bound. A PR whose numbers moved for a legitimate
reason (a tool knob, a deliberate trade) runs `make metrics-rebaseline KEYS=<key>[,<key>]`,
which loosens only the named bounds to today's numbers (a named key that is not worse is left
and reported; an unknown one is exit 2), and commits `docs/metrics/ratchet.json` with the label.
The gate's fix lines name that command with the WORSE keys filled in. Without `KEYS` the target
rewrites every bound and `docs/metrics/scorecard.json`, which is for first adoption and a
tool change that moves everything; it then warns, naming each bound it loosened. The gate then holds every key to that committed file exactly as in
check mode; the only difference is that the LOOSENED, REMOVED and DIRECTION bound lines are
accepted. A key that is worse than its committed bound fails even under the label, with a line
naming the fix (Orbit #78 merged a coverage drop under a label meant for two size bounds, and
the next PR failed on it):

```
metrics-rebaseline: coverage.backend.lines 49.24 is past its bound 49.45; set the bound in docs/metrics/ratchet.json or fix the regression
```

## Guards (guard-check)

A repo's code-structure rules (only the API client calls `fetch`, no query constructor
outside the queries package, every logger is `app.<domain>`, every query takes its user) are
one line each in `scripts/ci/guards.conf`, judged by `bin/guard_check.py` in ci-quick (the
repo's `guard-check` target, seconds). The walk, the predicates (`bin/_guard_rules.py`) and
their fixture self-tests are devkit's (`tests/guard_check_test.py`: every violation shape
fires, every lookalike does not), so a repo writes no test for a rule it declares. The full
grammar is the script header.

```sh
# scripts/ci/guards.conf: the section keys of layers.conf, then rules, then known lines
[backend]
lang  python                      # python | ts
root  backend                     # globs below are relative to it
src   server
exclude server/**/test_*.py       # alias PREFIX DIR too, for ts

only-import stripe,server.integrations server/integrations    # only these files import it
ban-import server/services sqlalchemy:select,update,text except server/_cron.py:select,update
only-call fetch src/api/client.ts                             # only this file calls it
ban-call print,os.system server except server/cli.py
logger-name finplat except server/core/logging.py
outbound-timeout
utc-today
single-writer balance_drift server/services/ledger.py server/models
@user-scope scoped-exports server/queries user_id,TransactionFilters marker cross-user:
@rate-limit decorated-with server/api/routes limiter.limit when post,put,patch,delete
known server/services/billing.py ban-call:print,os.system 2  paid down in #123

[web]                             # the route auth pack (ts)
lang  ts
root  web
src   src
@route-auth calls-one-of src/app/api/**/route.ts requireSession,withAuth except src/app/api:maxDuration
@no-raw-error-text call-arg-ban logger.*,log.* String(err),err.message,${err},err.stack src/**
@action-auth calls-one-of src/app requireSession,requireAdmin functions-only server-only except src/app/login/actions.ts:loginAction
@signal-writes single-writer signals src/db/queries/signals.ts:updateOwnSignal,upsertSignal src/db/queries/admin.ts
@destination only-text "for: Type.Optional(Type.String())" src/web/outfits/destination.tsx
```

| Rule | Lang | Fires on |
|---|---|---|
| `only-import MODULE[,MODULE] GLOB...` | both | an import of the module (segment prefix: `sqlalchemy` holds `sqlalchemy.orm`, `drizzle-orm` holds `drizzle-orm/pg-core`) outside the globs |
| `ban-import GLOB... MODULE[:NAME,...] [except GLOB[:NAME,...]...]` | both | under the globs, an import of the module, or of those names from it (`from M import NAME`, `import { NAME } from 'M'`, a re-export); `except GLOB:NAME` sanctions only those names there. The names follow the first colon that is not a TS scheme's (`node:`, `bun:`): `node:http` is the module, `node:http:STATUS_CODES` its name |
| `only-call NAME GLOB...` | both | a call to NAME, the dotted callee as written (`prefetch(`, `x.fetchQuery(`, `api.fetch(` are not `fetch(`), outside the globs |
| `ban-call NAME[,NAME] GLOB... [except GLOB...]` | both | under the globs, a call to NAME |
| `call-arg-ban CALLEE[,CALLEE] ARG-SHAPE[,ARG-SHAPE] GLOB... [except GLOB...]` | both | under the globs, a call to CALLEE (as written, dotted suffix: `log.error` names `this.log.error`; `logger.*` any method of `logger`) with an argument holding a shape at any depth (object values, spreads, nested calls, template and f-string parts). Shapes, a closed set: `String(err)`, `${err}` (ts), `str(err)`, `repr(err)`, f-string `{err}` (python), `err.message`, `err.stack`, and `err` bare, a whole argument that is the name alone (both; python counts positional arguments only, so `exc_info=exc` is silent); `err` stands for the error names (`e`, `err`, `error`, `exc`, `exception`, `*Err`, `*Error`), `/REGEX/` for others. Bare `err` belongs on an interpolating logger (`logger.warning("%s", exc)`) or `console.error`, never on a logger that takes the error (the scaffold's TS `log.error(err)`). One violation per call. Not seen: the error re-bound to another name first. Seed: rollcall #63 (ten log sites, one an API-keyed URL); bare: locus's ten `%s`, exc sites |
| `logger-name PREFIX [except GLOB...]` | python | `logging.getLogger(x)`, however imported, whose name is not PREFIX or PREFIX.<x> (constants and f-string heads judged; `__name__`, a variable or no name fire), and any root emitter (`logging.info(...)`, an alias or `from logging import error` too) |
| `outbound-timeout [except GLOB...]` | python | `requests.<verb>`/`request`, `httpx.<verb>`/`stream`, `httpx.Client`/`AsyncClient`, `urllib.request.urlopen` without a timeout, or with `timeout=None`. Not seen: a `**kwargs` spread (silent) and a client's methods (judged where the client is built) |
| `utc-today [except GLOB...]` | python | `date.today()`, `datetime.utcnow()`, `datetime.now()` with no tz or `None` (resolved through the imports: pendulum's `date` is not datetime's) |
| `single-writer ATTR GLOB...` | python | a write of `<x>.ATTR` outside the globs: any assignment target (augmented, annotated, tuple, `for`) and `setattr(x, "ATTR", v)`; reads, keyword arguments and dict keys are not writes |
| `single-writer TABLE[.FIELD] GLOB[:FUNCTION,...]...` | ts | a drizzle write of TABLE (`.update(T)`, `.insert(T)`, `.delete(T)` on any receiver, `schema.T` too) outside the globs; `GLOB:FUNCTION` sanctions only those top-level functions of the file, and each must still write. With FIELD (the drizzle key, `setBy`, not `set_by`), only a write whose literal has the key as its own: `.update(T).set({...})`, `.insert(T).values({...})` or `.values([{...}])`, and the insert's `.onConflictDoUpdate({ set: {...} })` (rollcall #67). Not seen: raw SQL, a re-bound table, and with FIELD rows or a patch passed by name (`.values(row)`, `.set(patch)`) or spread (`set({ ...patch })`): hold such a column with the TABLE form, which sees every write. Seed: rollcall #64 (four functions updated `signals`; `single-writer signals` with the owners fires 4 on main, 0 after) |
| `own-transaction GLOB[:FUNCTION,...]...` | ts | opening or ending a transaction outside the globs, the TS form of `own_commit_check.py`: `.transaction(`, `.commit(`, `.rollback(` on any receiver (drizzle `db.transaction(cb)`, a savepoint `tx.transaction(`, `tx.rollback()`) and a literal that is a whole BEGIN, COMMIT, ROLLBACK or START TRANSACTION (`client.query("BEGIN")`, sql`commit`); `GLOB:FUNCTION` owners as single-writer's. The scorecard's `arch.own_commit` reads this line in a TS repo. Not seen: run-time-built SQL, postgres.js `sql.begin(`. Seed: closet 32 sites in 16 files, rollcall 17 in `src/db/queries` |
| `only-text PATTERN GLOB...` | both | outside the globs, a line whose code text holds PATTERN, a substring or `/REGEX/` (comments blanked; strings, and a component's template, kept): one spelling of a query key, header, env var or route lives in one module. Quote a pattern with a space or `#` (`"for: x"`, no escapes) and name its rule with `@NAME`. Not seen: a spelling built at run time. Seed: closet #408 (the `for` query schema in 5 routes; 5 before, 0 after) |
| `calls-one-of GLOB NAME[,NAME] [depth N] [functions-only] [server-only] [except GLOB[:EXPORT,...]...]` | ts | an export of a module under GLOB (scoped-exports' forms, named as exported: `export { authed as GET }` is GET) that calls none of NAMEs, the callee as written, itself or through module-local helpers N deep (default 1: rollcall's localCallees). A value export is judged by its initializer (`export const GET = withAuth(h)` passes; route segment config fails closed, so except it by name) unless `functions-only` skips values (action-auth's Zod schemas); `server-only` judges only modules whose first statement is `"use server"`. A re-export in scope is exit 2. Seeds: rollcall route-auth (default) and action-auth (`functions-only server-only`) |
| `decorated-with GLOB DECORATOR[,DECORATOR] [when DECORATOR[,DECORATOR]] [except GLOB[:FUNCTION,...]...]` | python | a function under GLOB that carries a `when` decorator (at any depth: methods and nested functions too) but none of DECORATORs; without `when`, a public module-level function (not an @overload stub) without one. Names match as written on a dotted suffix: `post` names `holdings_router.post`, `router.post` does not; a decorator re-bound under another name fires. Seed: finplat's "every state-changing route carries `@limiter.limit`" (AGENTS.md; its HTTP contract test keeps the 429 shape). TS: none, no seed |
| `scoped-exports GLOB PARAM[,PARAM] [marker TEXT] [except GLOB...]` | both | a public module-level function (python) or exported function (ts: `export function`, `export const` arrow, `function` + `export { }`, default) under GLOB that declares none of the params (by name, annotation or destructured field) or never uses it (the word, a spread, or the object passed whole); a marker in the docstring or leading comment exempts it. A TS value that is not a function literal fails closed; a TS re-export in scope is exit 2 |

A rule line may start with `@NAME`, its id in the output and in `known` lines (default:
`<kind>:<subject>`, so two rules of one kind and subject need one). On ban-import,
calls-one-of and decorated-with, `except GLOB:NAME,...` sanctions only those names there
(banned imports, exports, functions), and each must still fire or it is stale; a TS
single-writer's owner `GLOB:FUNCTION,...` does the same for the functions that write. A unit rule
whose filter selects no function anywhere is exit 2, as a glob that matches nothing is.
Not expressible, so it stays a repo test: a rule over the framework's resolved dependency
graph (finplat's demo-gate and app-lock route gates walk FastAPI's `Depends` chain from the
live app, classify routes by method and path, and check both directions). A `known` line counts the
violations of one rule in one file, with no line numbers: an edit above a site costs no conf
fix. More than COUNT fails naming every site; fewer fails as stale, naming the count to write.

Python reads `metrics/python.py`'s runtime imports (relative ones resolved, `TYPE_CHECKING`
erased) and the AST; the semantic rules resolve a callee through the file's imports
(`dt.now()` after `from datetime import datetime as dt`). TypeScript reads `bin/_ts_lex.py`,
the lexer `layer_check.py` shares (comments, strings, templates and regex literals skipped;
type-only imports erased; aliases and relative specifiers resolved to root-relative paths),
and scoped-exports reads its top-level functions with the walker lifted from rollcall's
`tests/invariants/ast.ts`. Single-file components (`.vue`, `.svelte`): their script blocks are
scanned, lines as in the file; templates are not, so a template `@click="client.get()"` is not
seen (only-text alone reads the whole file, since a spelling in a template is still one). A rule glob that matches no scanned file is exit 2 (vacuous), as is
a file that does not parse. A sanctioned site (an only-*/single-writer glob, an `except` glob)
under which nothing fires any more fails, as does a stale `known` line.

Output, an API: `<root>/<path>:<line>: <rule>: ...` per violation, `GUARD <section> <rule>
ok|FAIL <n> known=<k>` per rule, `guards <section> files=<n> violations=<n> known=<k>` per
section, `guard_violations=<n>` last; exit 0, 1 (violations, stale known lines or sites), 2.
`--metrics-out` writes `guards.<section>.known` (direction lower), the `guards` collector in a
scaffold's `metrics.conf`, so new debt needs the `metrics-rebaseline` label.

Adoption, one PR per repo: declare the rule, DELETE the repo test it replaces, move that
test's allow-list to `except` (a design decision) or `known` (debt, with the change that pays
it down), and name the deleted tests in the decisions entry. Rules ruff or eslint already
express (deferred imports, `print`, `console`) stay lint rules: those run in the editor.

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
raises the committed shares. As in the metrics ratchet, `check` holds today's shares to the
PR's committed file and that file to main's; the `metrics-rebaseline` label admits a committed
share lower than main's (`--mode rebaseline`, commit it), never a share below the committed
file, and deleting the file lowers every track. T7, T8, T9, T11 and T15
move without a code change (live metrics, seconds, the ledger, new advisories, devkit itself) and
stay graded, not gated. T15's `kit.devkit_rev` passes while `.devkit-rev`'s commit is at most
`kit_devkit_days_max` days older than devkit's tip (commit dates, so a quiet devkit ages nobody);
the commits-behind count is printed only.

## Deploy

devkit itself is not deployed. A squash-merge to `main` is the release; each consumer takes it
with its `devkit-sync` target in its own PR, which runs that repo's gate against the new tree.

## Commands

Every check is a Makefile target; `scripts/ci/gate_plan.sh` and `.github/workflows/ci.yml` call
the same ones. `make gate PR=<n>` is the merge signal (it posts `local-gate` on the PR head);
Actions is a second opinion that the account's billing has blocked before.

```sh
make ci-quick        # shellcheck 0.11, python and template unit tests (needs npm), docs/toolchain/workflows guards on devkit itself
make ci-unit         # bats tests/
make gate PR=<n>     # both, on PR <n> merged into origin/main
```

## Documentation

- Contributors and agents: see [AGENTS.md](AGENTS.md).
- [docs/decisions.md](docs/decisions.md): every decision, dated, newest last.
- [docs/metrics-keys.md](docs/metrics-keys.md): the metrics snapshot key shape.
- [templates/new/README.md](templates/new/README.md): what `devkit new` renders and how to add a stack.
