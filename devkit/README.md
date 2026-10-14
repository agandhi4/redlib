# devkit

Shared, executable delivery tooling for agandhi4's apps. One copy of each script, vendored
into every repo at `devkit/` (the paths in `VENDOR_PATHS`, by `devkit-sync.sh`), so a clone can reproduce "what must pass"
offline and worktrees, Actions and Docker build contexts see plain files.

Design: `~/projects/solo/standardization/PLAN.md` §1 (layer L5) and `docs/decisions.md`.

## Getting started

- A new repo: `devkit-new.sh`, below in "New project". It passes every guard on its first commit.
- An existing repo: "Vendor into a repo (once)", then `make devkit-sync` for every update.
- Changing devkit itself: "Commands" below, and [AGENTS.md](AGENTS.md) for the invariants.

## Architecture

What each path is; [AGENTS.md](AGENTS.md) holds the invariants that tie them together.

| Path | What |
|---|---|
| `bin/local_gate.sh` | The PR gate skeleton: gates `<pr>` merged into `origin/main`, posts the `local-gate` status, emits the `GATE`/`VERDICT` lines the merge queues parse, holds jobs to their time budgets and writes their seconds to `build/metrics/gate.json` (`docs/metrics-keys.md`). The repo supplies `scripts/ci/gate_plan.sh` (contract in the script header). |
| `bin/gate.sh` | What `make gate` calls: `remote_gate.sh` when this machine names a gate host, else `local_gate.sh`. See "Remote gate". |
| `bin/remote_gate.sh` | Runs the repo's gate on the gate host over ssh (clone if absent, reset to `origin/main`, `local_gate.sh` there); same output, exit code and `local-gate` status. |
| `bin/devkit-sync.sh` | Fetch upstream, replace `devkit/` with its tree filtered to `VENDOR_PATHS`, record `<commit> <filtered tree>` in `.devkit-rev`, commit. Conflict-free by construction. `--stage` leaves it in the index for the caller's own commit. |
| `bin/devkit-new.sh`, `templates/new/` | `devkit new <name> --stack <stack> [--dir <parent>] [--no-image]`: a new repo that passes every guard on its first commit, which is made through the hooks. Stacks: `python-fastapi`, `node-service`, `rust`, `next-vercel`, `swift-app`; each is a directory under `templates/new/stacks/` (how to add one: `templates/new/README.md`). See "New project". |
| `bin/devkit-check.sh` | Offline guard for `ci-quick` and pre-commit: the staged `devkit/` tree equals the staged `.devkit-rev` (both read from the index). Fails on in-repo edits, and on a tree holding paths outside its own `VENDOR_PATHS` (vendored whole by a pre-manifest sync: rerun `make devkit-sync`). |
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
| `bin/docs_check.sh` | Guard for `ci-quick`: every `AGENTS.md` is the real file with `CLAUDE.md` symlinked to it, size caps (30 KB root, 16 KB nested, shrink-only allowlist in `scripts/ci/docs_oversize.txt`), `docs/decisions.md` exists, no retired-tool words, and the standard docs set ("Standard docs" below: required files and README sections, dated decisions entries, `make` targets and relative links that resolve, `docs/decisions.md merge=union` in `.gitattributes`; warnings until their date, then failures); repo extras in `scripts/ci/docs_rules.sh`. |
| `bin/quiet_run.sh`, `bin/hook_steps.sh`, `bin/push_ranges.sh`, `bin/hooks_check.sh`, `templates/githooks/` | Git hooks: one line per step, 40-line tail on failure; per-repo steps in `scripts/ci/hooks.conf`, scoped by changed paths by default from one fleet layout table (docs, backend, frontend, native, other: `_hook_classify` in `hook_steps.sh`) and each step's target name, so a docs-only change runs docs-check alone, a frontend-only one skips backend steps and a native-only one (ios/, OrbitAgent/) runs nothing, with `:unless=<globs>`, `:only=<globs>` or `:always` per step only where a repo's layout deviates; `hooks_check` asserts `core.hooksPath=.githooks` (a tool install silently repointed finplat's for two months) and `--fix` self-heals it and adds the decisions-log union line to `.gitattributes`; it rejects a malformed step override; LFS chained when the repo uses it. Before the first step the pinned Node and Rust go first on PATH, as in the gate (`toolchain_path.sh`), so `hooks.conf` lists steps only. A passing cargo step's summary sums every `test result:` line (the last one is the doctests). |
| `bin/tier_guard.sh` | `<tier> --budget <s> [--floor <runner>=<min>]... -- <cmd...>`: one test tier under a wall-clock budget (the whole command's wall time; it fails over budget even when every test passed, `TIER_BUDGET_ENFORCE=0` only reports) and per-runner floors on the tests that RAN (skipped ones do not count), read from the runner's own summary line: `pytest`, `vitest`, `playwright`, `cargo`. Streams the command's output, exits with its code, prints `TIER <tier>: …` / `FAIL` / `FLOOR` / `OVERBUDGET` lines and writes `build/metrics/tier-<tier>.json` at the git top level (`tier.<tier>.seconds`, `tests.<tier>.<runner>`). Every `devkit new` stack's test tiers run through it. |
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
`make ci-guards`, the only tier that runs off a Mac), and for image stacks `publish.yml`
(build, `ci-smoke`, push `sha-<7>` + `latest`, ship tag, never cancelled) with a Dockerfile carrying the `APP_VERSION` trio;
`renovate.json` on the shared preset; `.claude/settings.json` (claude-kit plugins); `AGENTS.md`
(the project delta only: Stack + `Conventions:`, Architecture placeholder, Convention deltas,
Commands, Workflow) with `CLAUDE.md` symlinked; `docs/decisions.md` with its first entry; the
toolchain pin; the stack's lockfile; the smallest app that serves `/health/live` and
`/health/ready` (swift-app: shows its build identity), with a test per tier. The first commit runs through pre-commit, so
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

and write `scripts/ci/gate_plan.sh`. The three existing plans (finplat, Orbit, locus) are
the reference: scalar config at the top, a `gate_plan()` that maps changed paths to `job`
calls, an optional `gate_cleanup()`.

Gate environment (full contract in the script header):

| Variable | Default | What |
|---|---|---|
| `GATE_SLOTS` | `1` | How many gates may run at once on this machine, across repos. `1` keeps the single lock file `GATE_LOCK`; `N` > 1 uses `GATE_LOCK.1` … `GATE_LOCK.N`. The merge queues and linux-box keep `1`; raising it on a laptop accepts load-induced timing-test failures (2026-10-05). |
| `GATE_SILENT_MINUTES` | `15` | Watchdog: a job whose log has not grown for this long is stopped, status `error`, exit 2. `0` disables. |
| `GATE_JOB_BUDGET_MINUTES` | `5` | Per-job budget (owner directive 2026-10-13). An over-budget job runs to completion, then `GATE <job> OVERBUDGET (<n>s > <b>s)` and VERDICT FAIL naming it. Decimals allowed; `0` disables. |
| `GATE_BUDGET_MINUTES` | `10` | Whole-gate budget, counted once a slot is held: `GATE total OVERBUDGET (...)` and FAIL. |
| `GATE_BUDGET_ENFORCE` | `1` | `0` keeps the OVERBUDGET lines (plus one `GATE note`) but the verdict PASSes: for a queue adopting budgets before its suites fit. |
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
Swift). Nothing else in a repo changes; the host's own `gate.env` sets its `GATE_SLOTS`.

**Switching finplat, Orbit and locus to linux-box.** Each repo's `gate` target becomes the
one line above (after its `make devkit-sync`), then on the Mac:

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

## Standard docs

Every repo carries the same docs set, and `make docs-check` (in `ci-quick`) keeps it present and
honest. `devkit new` emits all of it from `templates/new/common/`. The new rules warn until
2026-11-15 and fail from then; the dates live at the top of `bin/docs_check.sh`.

Required:

| File | Holds | Checked |
|---|---|---|
| `README.md` | For a human arriving cold. One intro paragraph, then five H2 sections (aliases in `README_SECTIONS`): **Getting started** (install, run locally), **Commands** (the everyday `make` targets), **Architecture** (a short map, linking the full one), **Deploy** (how a change reaches users; "not deployed" is an answer), **Documentation** (an index of the other docs). | sections present; every `make <target>` it names exists |
| `AGENTS.md` + `CLAUDE.md -> AGENTS.md` | For every agent session: rules, commands, `## Convention deltas`. | pair shape, size cap, retired tools, the deltas heading, `make` targets |
| `docs/decisions.md` | Dated entries, newest last: `## YYYY-MM-DD — title`, then Why / Decision / Consequence lines (`**Why:**`, `**Why**:` or `Why:`), at most eight lines. The root `.gitattributes` gives it `merge=union`, so two PRs that each append an entry rebase without a conflict (`hooks_check.sh --fix` adds the line). | exists; every H2 dated, in order, all three lines; the union line |
| `docs/architecture.md`, or `## Architecture` in the root `AGENTS.md` | Components, data flow, runtime. One home: a repo whose AGENTS.md already maps itself needs no second copy. | one of the two exists |

Every relative link in `README.md`, `AGENTS.md` and `docs/*.md` must resolve to a tracked file.

Recommended, not checked (the fleet has no common shape for these yet): `docs/observability.md`
or an Observability section for a running service, testing notes per tier, runbooks under
`docs/`. A repo's own extra rules go in `scripts/ci/docs_rules.sh`.

## Deploy

devkit itself is not deployed. A squash-merge to `main` is the release; each consumer takes it
with `make devkit-sync` in its own PR, which runs that repo's gate against the new tree.

## Commands

devkit's CI runs its own guards (`docs_check`, `toolchain_check`, `workflows_check`) on
itself, and a PR touching only docs that `docs_check` judges (`AGENTS.md`, `CLAUDE.md`,
`README.md`, `docs/*.md`) still runs it: devkit has no local gate, so CI is the only check
before consumers vendor a change.

```sh
shellcheck -s bash bin/*.sh tests/*.bats
bats tests/
```

## Documentation

- [AGENTS.md](AGENTS.md): invariants and workflow for changing devkit.
- [docs/decisions.md](docs/decisions.md): every decision, dated, newest last.
- [docs/metrics-keys.md](docs/metrics-keys.md): the metrics snapshot key shape.
- [templates/new/README.md](templates/new/README.md): what `devkit new` renders and how to add a stack.
