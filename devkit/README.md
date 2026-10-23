# devkit

Shared, executable delivery tooling for agandhi4's apps. One copy of each script, vendored
into every repo at `devkit/` (the paths in `VENDOR_PATHS`, by `devkit-sync.sh`), so a clone can reproduce "what must pass"
offline and worktrees, Actions and Docker build contexts see plain files.

Design: `~/projects/solo/standardization/PLAN.md` §1 (layer L5) and `docs/decisions.md`.

## Getting started

- A new repo: `devkit-new.sh`, below in "New project". It passes every guard on its first commit.
- An existing repo: "Vendor into a repo (once)", then its `devkit-sync` target for every update.
- Changing devkit itself: "Commands" below, and [AGENTS.md](AGENTS.md) for the invariants.
- Every machine that merges: `bin/install_gh_shim.sh` once, so only `make merge PR=<n>` can merge.

## Architecture

What each path is; [AGENTS.md](AGENTS.md) holds the invariants that tie them together.

| Path | What |
|---|---|
| `bin/local_gate.sh` | The PR gate skeleton: gates `<pr>` merged into `origin/main`, posts the `local-gate` status, emits the `GATE`/`VERDICT` lines the merge queues parse, holds jobs to their time budgets and writes their seconds to `build/metrics/gate.json` (`docs/metrics-keys.md`). The repo supplies `scripts/ci/gate_plan.sh` (contract in the script header), usually declarations plus `devkit_default_gate_plan`. On macOS it holds a `caffeinate -i -s -w <its pid>` assertion while it runs (`bin/_awake_lib.sh`, which tier_guard.sh and every Docker entry point share), since its budgets and watchdog read wall time; on Linux run it under `systemd-inhibit --what=idle:sleep`. `DEVKIT_CAFFEINATE=0` turns it off. |
| `bin/_paths_lib.sh` | Sourced: the one path classification (`devkit_classify_path`: docs, backend, frontend, native, tooling, other) shared by the hooks and the gate, which prints `GATE areas: …` and exports `GATE_AREAS`/`GATE_HAS_<AREA>` before the plan; and `devkit_default_gate_plan`, the plan body a repo calls after declaring `GATE_JOBS_<GROUP>`. A devkit-only change (tooling) gates as quick, plus the image when a boot script changed. |
| `bin/gate_record.py` | The gate's outcome record: each run's per-job verdict and failing rules (`kind:id`, parsed from the job logs) in `logs/<pr>/gate.json`, one row per run in `runs.tsv`. Run by `local_gate.sh`'s EXIT trap. See "Gate record". |
| `bin/gate_bite.py`, `bin/_repo_identity.py` | BITE, "does enforcement act here": over `--days N` (30), gate runs and failures by rule and job (`runs.tsv`), hook failures by step (the hooks ledger), and merged PRs whose head has no `local-gate` success (one `gh pr list`). One summary line and a table, or `--json` for the scorecard; a source it cannot read is UNMEASURED, never 0. `_repo_identity.py` names the repo, its plan literals and state dir for it and scorecard.py. |
| `bin/gate.sh` | What `make gate` calls: `remote_gate.sh` when this machine names a gate host, else `local_gate.sh`. See "Remote gate". |
| `bin/install_gh_shim.sh` | Once per machine: `bin/install_gh_shim.sh` writes a `gh` ahead of the real one on PATH (`~/.local/bin/gh`, else the first writable PATH directory ahead of it; it prints which) that refuses `gh pr merge` unless `DEVKIT_MERGE_VERIFIED` equals its `--match-head-commit` (only `make merge` sets it) and passes every other call to the real gh, found at run time and never itself. `--check` says whether the first gh on PATH is the shim (the scorecard's WIRED `gh_shim`). |
| `bin/pr_merge.sh`, `bin/codex_review.py` | What `make merge PR=<n>` calls: squash-merges pinned to the PR's current head (`--match-head-commit`), and refuses with the reason unless that head's `local-gate` status is success, and every context the plan's literal `GATE_MERGE_REQUIRES=a,b` names (closet: `codex-review`), and unless GitHub's main is still the main the gate ran on (the gate's `gate.json` here, else the `on main <sha>` of its status; `re-gate: main moved <sha>→<sha>` otherwise; GitHub's own refusals for a moved head or main, or a branch its protection wants up to date, are `re-gate:` refusals too, exit 1), and unless Codex is done with the PR: `codex_review.py` reads its summary comment's `codex-review-state` marker (`running` refuses with `Codex review still running`, unless its summary row's `Running since` time is older than the plan's literal `GATE_CODEX_RUNNING_MAX_MIN=<minutes>` (default 30; devkit-check holds it to whole minutes, 1–999999): then it is `hung`, treated as `failed`, and the line names its age; no or an unreadable time stays running; a status or marker shape it does not know is exit 2 naming it) and every review thread whose first comment is `chatgpt-codex-connector`'s, which must be resolved (GraphQL `isResolved`; a reply alone is not); the refusal lists each open finding as path:line, title, URL and thread id. Other reviewers' threads never block, so a repo Codex never reviews is unaffected. A plan with the literal line `GATE_CODEX_REVIEW=1` (devkit-check holds it to `0`/`1`) also wants Codex's completed review of the current head: one that `failed` or hung, never ran or saw an older commit refuses with `no Codex review of PR #<n>'s head` and the way out (`@codex review`, or the fallback record where Codex cannot review: failed, hung, or a gap its usage-limit comment answers (posted after the failed or stale review and after the newest `@codex review`, or in place of any review); its `<why>` is the blocker's, `at limit`, `failed` or `hung <N> min`), unless the head's `codex-review` status is success and names this head as `Claude adversarial review (Codex <why>) of <sha7>` or codex_gate.py's `Codex unavailable (usage limit); <sha8> passed on Claude self-review` (Rules); Codex's open threads still block then. Nor does it want one of a Renovate or Dependabot PR whose every commit is that bot's and whose diff changes only dependency pins (`_dependency_pr.py exempt`, printing `codex-review: not required (bot dependency PR, manifest-only diff)`): Codex never reviews bot PRs. The fixed list: `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `pyproject.toml`, `uv.lock`, `Cargo.toml`, `Cargo.lock`, `go.mod`, `go.sum`, `.nvmrc`, `.python-version`, `rust-toolchain.toml` whole; `image:` lines of a compose file (Renovate's `(docker-)compose*.y(a)ml`) and `FROM` lines of a Dockerfile; any line right under an unchanged `renovate:` comment (a custom manager's pinned default). Any other file or line, a renamed file, a file GitHub sends no patch for, a file list shorter than the PR's `changedFiles`, or a commit by anyone else keeps the requirement, and the refusal names the first one; its open threads and a running review still block. Nor of a docs-only PR (`codex-review: not required (docs-only diff)`; claude-kit work-loop §3c skips Codex for those): every path it touches, both sides of a rename (`_dependency_pr.py paths`), is `docs` in `_paths_lib.sh`'s table, the one hooks and gate use, so `docs/metrics/ratchet.json` stays reviewed; paths decide, never a label. A short file list or no changed files is not exempt; a PR that touches docs and something else names the first other path; open threads and a running review still block. Nor of a devkit sync (`codex-review: not required (devkit sync, vendoring-only diff from devkit main)`): at its head every path is under `devkit/`, is `.devkit-rev` or is a base copy byte-equal to its base, `devkit/` is the tree `.devkit-rev` records (`_vendor_paths.sh vendoring_only`, the hooks' rule), and that record names a commit on devkit's main (fetched from `DEVKIT_URL`) forward of main's, whose `VENDOR_PATHS` tree it is (`vendored_from`): devkit's own reviewed code, which the gate judges here. A hand edit under `devkit/`, a downgrade, a branch commit or any repo-owned path (a `metrics-tighten` included) keeps the requirement, with a hint for a PR that changes `.devkit-rev`; open threads and a running review still block. Codex's `has_unresolved_findings` is never read (its usage-limit summary says true with no thread, orbit #115). A gh error is exit 2, never a merge; there is no override (Rules). A PR labelled `metrics-rebaseline` gets one `Metrics-Rebaseline: <key>=<old>→<new>` trailer per bound its head loosens in `docs/metrics/ratchet.json` against main, after the PR body as the squash body: the label's record in git, which the scorecard's TREND reads. A draft that passes those checks is marked ready (`gh pr ready`, one line saying so) and merged, since the fleet Workflow gates drafts; a draft that fails one is refused and stays a draft. Branch protection is unavailable on the private repos, so this is the check, and the fleet's only merge path: the `gh pr merge` call alone runs with `DEVKIT_MERGE_VERIFIED=<full 40-char head sha>` (any inherited value is dropped), and `bin/install_gh_shim.sh` installs the gh shim that refuses a `pr merge` whose `--match-head-commit` is not that value. devkit-check warns on a `gate` target with no `merge` target and on an AGENTS.md Workflow line that says `gh pr merge`. |
| `bin/remote_gate.sh` | Runs the repo's gate on the gate host over ssh (clone if absent, reset to `origin/main`, `local_gate.sh` there); same output, exit code and `local-gate` status. |
| `bin/devkit-sync.sh` | Fetch upstream, replace `devkit/` with its tree filtered to `VENDOR_PATHS`, record `<commit> <filtered tree>` in `.devkit-rev`, commit. Refreshes tracked copies of vendored bases (`.swift-format`, `.githooks/*`) in the same commit. The commit ends with `DEVKIT_COMMIT_TRAILER`, else `git config devkit.trailer`, else the model-agnostic `Co-Authored-By: Claude <noreply@anthropic.com>` (an empty env value means none); an agent sets the env to the trailer naming its model. Conflict-free by construction. `--stage` leaves it in the index for the caller's own commit. |
| `bin/devkit-new.sh`, `templates/new/` | `devkit new <name> --stack <stack> [--dir <parent>] [--no-image]`: a new repo that passes every guard on its first commit, which is made through the hooks. Stacks: `python-fastapi`, `node-service`, `rust`, `next-vercel`, `swift-app`, `infra-compose`; each is a directory under `templates/new/stacks/` (how to add one: `templates/new/README.md`). See "New project". |
| `bin/devkit-check.sh` | Offline guard for `ci-quick` and pre-commit: the staged `devkit/` tree equals the staged `.devkit-rev` (both read from the index). Fails on in-repo edits, and on a tree holding paths outside its own `VENDOR_PATHS` (vendored whole by a pre-manifest sync: rerun the repo's `devkit-sync`), and on any tracked `.swift-format` that is not byte-equal to `lint/swift-format.json`, and on a `scripts/ci/gate_plan.sh` that sets a retired plan variable (read from the working tree, where the fix is made; `--staged` reads the index instead). Warns, without failing, on a `.dockerignore` that lets a TS repo's build context see a `tsbuildinfo` beside any tracked `tsconfig*.json` (a stale one let `tsc -b` skip the image's type-check, locus #145; add `**/*.tsbuildinfo`), and on a Makefile recipe line (the Makefile and its literal includes) that runs `docker` itself, naming `<file>:<line>`: route it through `docker_bounded.sh`. |
| `bin/node_toolchain.sh` | Provides the exact Node in the repo's `.nvmrc`: uses PATH's node when it matches, else a checksum-verified install cached under `~/.local/share/devkit/node`. The gate and the hooks call it through `toolchain_path.sh`. |
| `bin/rust_toolchain.sh` | Provides the exact Rust in `rust-toolchain.toml` (or `rust-toolchain`): uses PATH's cargo when it matches, else installs through rustup (PATH's, or a private one bootstrapped under `~/.local/share/devkit/rust`) and prints the toolchain's sysroot bin, so callers export PATH only. `--declared` prints the version. The gate and the hooks call it through `toolchain_path.sh`. |
| `bin/toolchain_path.sh` | Sourced: `toolchain_path <tree>` puts the tree's pinned Node (`.nvmrc`) and Rust (`rust-toolchain.toml`) first on PATH through the two scripts above, or fails naming the pin. The one provisioning path for `local_gate.sh` (merged worktree) and `hook_steps.sh` (the hook's checkout), so a hook runs the gate's node and cargo on a machine with none. It also puts devkit's own python3 (below) first when PATH's is not it, so a recipe's bare `python3` gets it too; a repo's project Python needs nothing: uv reads `.python-version`. |
| `bin/_toolchain_lib.sh`, `bin/python.sh` | devkit's toolchain lookup, independent of PATH. `devkit_python`: python3 >= 3.11 (ruff.toml's target) from `DEVKIT_PYTHON` (an error if it does not qualify), PATH, mise (`mise which` from `$HOME`, then its installs), uv-managed installs, Homebrew. `devkit_tool uv`: `DEVKIT_UV`, PATH, mise, beside devkit's python3 (a pip install), `XDG_BIN_HOME`, `CARGO_HOME`, Homebrew. Each fails once naming every place tried. `devkit_toolchain_bin` gives a directory holding only `python3` and `uv` links for PATH (`toolchain_path` leads with it); `devkit_preflight` checks the skeleton's PATH tools, python3 and the tools a checkout declares (uv for a tracked `uv.lock`) and names every missing one in one line. bin/*.sh run devkit's .py tools on `"$DEVKIT_PYTHON"`, Makefiles and the metrics merge driver on `bin/python.sh` (exit 2 naming why when none qualifies). `dependency_merge.sh`, `local_gate.sh` and `pr_merge.sh` run the preflight before anything else, and `install_dependency_merge.sh` bakes the directory into the plist's PATH or refuses to install. |
| `bin/toolchain_exec.sh` | `<command> [args...]`: runs one command on the repo's pins (`toolchain_path` over the vendored `devkit/`'s parent), exit 2 naming a pin it cannot provide. For a caller outside make (a script, a hand-run command): a Makefile's recipes already run on the pins through `SHELL := devkit/bin/toolchain_shell.sh`, so a recipe calls plain `cargo` and needs no wrapper. |
| `bin/toolchain_shell.sh` | make's SHELL (`SHELL := devkit/bin/toolchain_shell.sh`): every recipe line and `$(shell …)` runs on the repo's pins, then `/bin/sh`, so a hand-run `make metrics-tighten` installs and measures on the gate's Node. A line under the gate, a hook or a provisioned make skips provisioning (`DEVKIT_TOOLCHAIN_TREE`). macOS make 3.81 runs a bare command on its own PATH, so `export PATH :=` cannot do this. The node, next-vercel and rust scaffolds set it; devkit-check warns on a Makefile without it in a repo that tracks `.nvmrc` or `rust-toolchain.toml`. |
| `bin/cargo_tool.sh` | `<crate>@<version> -- <command> [args...]`: runs one command on the repo's pins with a pinned cargo subcommand on PATH (the rust scaffold's `COV_TOOL`, cargo-llvm-cov for the unit tier's coverage). PATH's tool at that version is used as-is; else `cargo install --locked` once per machine into `~/.local/share/devkit/cargo-tools/<crate>-<version>`, shared by worktrees and gate slots. Exit 2 naming the tool when it cannot be provided (`DEVKIT_OFFLINE=1` and a cold store, a failed install). |
| `bin/release_tool.sh` | `<tool> -- <command> [args...]` (or `<tool> --version`): runs one command with a devkit-pinned release binary first on PATH; the pin and its per-platform sha256 live in the script (shellcheck 0.11.0, the fleet's one shellcheck; bats 1.14.0, the infra-compose stack's test runner, installed as its whole source tree). PATH's tool at that version is used as-is; else the release archive is downloaded and verified once per machine into `~/.local/share/devkit/tools/<tool>-<version>`. Exit 2 naming the tool when it cannot be provided (`DEVKIT_OFFLINE=1` and a cold store, a checksum mismatch). |
| `bin/shellcheck.sh` | shellcheck as the fleet runs it, from the repo root: the pinned release over `lint/shellcheckrc` with the repo's `.shellcheckrc` appended (a merged `--rcfile`), so a lint step and `metrics/shell.py` read one config. |
| `bin/toolchain_check.sh` | Guard for `ci-quick`: `.nvmrc` is exact, every `FROM node:` major and every setup-node step agree with it; same for `.python-version` (plus a regular-file copy beside every one-level-down `pyproject.toml`, because uv stops pin discovery at the project boundary) and `rust-toolchain.toml` (`FROM rust:` minor, `Cargo.toml` `rust-version` not above it, no inline `toolchain:`); `.swift-version` against `swift --version` on macOS only (Xcode's compiler; skipped elsewhere). Runs `ci_targets_check.sh` first. |
| `bin/ci_targets_check.sh` | Guard for `ci-quick`, run by `toolchain_check.sh`: per-area halves of the standard targets are named tier first, `ci-<tier>-<area>` (`ci-unit-backend`, not `ci-backend-unit`). Warns naming the expected name until 2026-11-15, then fails. |
| `bin/_makefile_lib.sh`, `bin/_dockerfile_lib.sh`, `bin/_gitattributes_lib.sh` | Sourced readers the guards share: root Makefile targets (with literal includes), Dockerfile list and final stage, the decisions-log `.gitattributes` line. |
| `bin/docker_bounded.sh` | One docker call from a Makefile recipe behind the daemon probe (`DOCKER_PROBE_TIMEOUT`, 15 s) and the per-call bound (`DOCKER_CALL_TIMEOUT`, 180 s; an image build sets more): `DOCKER_CALL_TIMEOUT=900 devkit/bin/docker_bounded.sh build -t "$(CI_IMAGE)" .`. A recipe cannot source `_timeout_lib.sh` (make's `/bin/sh` is dash on Linux). Exit: docker's, 124 when stopped, 1 for a hung or unreachable daemon. Like throwaway_pg.sh and boot_image.sh (all through `devkit_docker_guard`) it holds the Mac awake while it runs, and on macOS a probe that times out gets one `caffeinate -u -t 2` wake and one re-probe; still hung, the line names the likely sleeping OrbStack VM and the remedy order (wake again; `orbctl stop && orbctl start` only as a last resort, it kills every container). devkit never restarts OrbStack. |
| `bin/throwaway_pg.sh` | One throwaway Postgres container for tests and smoke boots: `up` prints `PG_PORT=<n>`, `url`, `down`. tmpfs on by default (the volume-leak fix), TCP readiness, loopback only; env-driven. **Lanes:** `name <base>` prints `<base>-<lane>`, the lane being `GATE_LANE_ID` or a hash of the checkout's top-level path, so two worktrees of one repo never share a container; `up` labels the container with its lane and refuses (exit 1) to remove one still running for another lane. A repo's container default is `$(shell devkit/bin/throwaway_pg.sh name <repo>-test-pg)` with an auto port read back through `url`; a Makefile that builds its URL from a port at parse time derives it with `port <base>` (20000-29999 from the base and the lane) instead of a literal, since a fixed port collides the same way. devkit-check warns on a literal name or port, quoted or not (finplat's `finplat-test-pg` on 55460). Per-worker databases on a server several lanes share are `<db>_<lane>_<worker>`, not `<db>_<worker>`. |
| `bin/boot_image.sh` | Boots a built app image on a private network (optionally with `throwaway_pg.sh` Postgres as `<name>-pg`), waits for its health endpoint with early exit on container death, prints `BASE=<url>`; `down` removes everything. Post-boot assertions stay in each repo. Env-driven (`BOOT_*`); `BOOT_EXPECT_VERSION` also requires the health JSON `version` to equal it. |
| `bin/contract_probe.sh` | `<base> --live P --health P --request-id P --json-log FILE\|CONTAINER --metrics P --require-metric NAME --proxy-404 URL`: the observability contract asserted against a booted app, each assertion opt-in so repos switch them on as they comply. Called from a smoke after `boot_image.sh up`; `BOOT_EXPECT_VERSION` is checked in health, logs and `app_info`. One `probe <name> PASS\|FAIL` line each, every assertion runs. |
| `bin/ship_tag.sh` | `<owner/repo> <sha> [--date YYYY-MM-DD]`: the deploying step marks a main commit shipped with the annotated tag `ship-<date>-<sha7>` via `gh api` (no clone). Idempotent for the same sha, refuses another, survives a create race; prints `SHIP_TAG=<tag>`. Needs `contents: write`. |
| `bin/release_check.sh` | Guard for `ci-quick`: the image is the only source of `APP_VERSION`. Dockerfile final stage has the ARG, ENV and OCI `image.version` LABEL; no compose file sets it under `environment:`; every workflow step that pushes an image passes it as a build arg. Every Dockerfile (root and one level down): a non-root final `USER` may `EXPOSE` and health-check only ports >= 1024 (the NAS kernel refuses a privileged bind; Orbit was down 16 h on 2026-10-13). |
| `bin/workflows_check.sh`, `bin/_workflows_lib.sh` | Guard for `ci-quick`: Actions follows the minutes and supply-chain rules. Every `uses:` is a commit SHA with a `# vX.Y.Z` comment (devkit reusable workflows may float on `@main`). A `pull_request` workflow runs one job, skips drafts, cancels superseded runs and ignores `**.md`; more jobs need a top-level `# workflows-check: multi-job ok: <reason>`. A job pushing an image on main runs with `cancel-in-progress: false`. Every `runs-on:` names a versioned image (`ubuntu-24.04`), never a `-latest` label. The lib's push-step detection is shared with `release_check.sh`. |
| `bin/playwright_browsers.sh` | Installs the Playwright browsers the lockfile pins (default `chromium`) with the lockfile's runner and the `.nvmrc` Node; idempotent via Playwright's cache. `--with-deps` is honoured on Linux, ignored on macOS. |
| `bin/docs_check.sh` | Guard for `ci-quick`: every `AGENTS.md` is the real file with `CLAUDE.md` symlinked to it, size caps (30 KB root, 16 KB nested; the shrink-only allowlist in `scripts/ci/docs_oversize.txt` ends 2026-11-15), `docs/decisions.md` exists, no retired-tool words, and the standard docs set ("Standard docs" below: required files and README sections, the root AGENTS.md's H2 list, the fixed `docs/` set with dated `docs/reports/`, no CONTRIBUTING.md, dated decisions entries, `make` targets and relative links that resolve, `docs/decisions.md merge=union` in `.gitattributes`; warnings until their date, then failures); repo extras in `scripts/ci/docs_rules.sh`; trees of agent files the repo installs elsewhere (dotfiles) declared in `scripts/ci/docs_payload.txt`. `--report` prints the numbers (sizes vs caps, allowances, docs outside the set, H2s outside the list) for trims and the monthly audit. |
| `bin/quiet_run.sh`, `bin/hook_steps.sh`, `bin/push_ranges.sh`, `bin/hooks_check.sh`, `templates/githooks/` | Git hooks: one line per step, 40-line tail on failure; per-repo steps in `scripts/ci/hooks.conf`, scoped by changed paths by default from one fleet layout table (docs, backend, frontend, native, tooling, other: `devkit_classify_path` in `_paths_lib.sh`, which the gate uses too; tooling runs every hook step, like other) and each step's target name, so a docs-only change runs docs-check alone, a frontend-only one skips backend steps, a native-only one (ios/, OrbitAgent/) runs nothing and a vendoring-only pre-commit (devkit-sync's: devkit/ at `.devkit-rev`'s tree plus byte-exact base copies) runs no step, so a sync commits in a fresh worktree before any install, with `:unless=<globs>`, `:only=<globs>` or `:always` per step only where a repo's layout deviates; `hooks_check` asserts `core.hooksPath=.githooks` (a tool install silently repointed finplat's for two months) and every template hook (pre-commit, pre-push, commit-msg) there, and `--fix` self-heals the path, installs a missing hook from its template and adds the decisions-log union line to `.gitattributes`; it rejects a malformed step override and warns on a typecheck or unit step at pre-commit or a pre-commit that never runs `ci-lint` ("Git hooks"); LFS chained when the repo uses it. Before the first step the pinned Node and Rust go first on PATH, as in the gate (`toolchain_path.sh`), so `hooks.conf` lists steps only. A passing cargo step's summary sums every `test result:` line (the last one is the doctests). Every run appends step and total wall seconds to `$XDG_STATE_HOME/devkit/hooks/<repo>.tsv` (`<repo>` = the origin remote's repository name, lowercased, so worktree lanes share the repo's file), the per-machine hooks ledger the scorecard reads (T8: pre-commit p90 ≤ 30 s, pre-push ≤ 60 s). Steps run without the GIT_DIR git exports to a worktree's hooks (a step's `git init` would otherwise set core.bare=true in the shared config), and a step that still changes core.bare is named on stderr and in its ledger row, then undone (#48). |
| `bin/tier_guard.sh` | `<tier> --budget <s> [--floor <runner>=<min>]... -- <cmd...>`: one test tier under a wall-clock budget (the whole command's wall time; it fails over budget even when every test passed, `TIER_BUDGET_ENFORCE=0` only reports, as does a shifted run, whose unshifted twin holds the budget; a box above its core count stretches it by min(load / cores, 2), sampled at start and end with the larger kept, printed as `budget 110 s ×1.6 (load 2.0 at start, 13.1 at end on 8 cpus) → 176 s`) and per-runner floors on the tests that RAN (skipped ones do not count), read from the runner's own summary line: `pytest`, `vitest`, `playwright`, `cargo`, `bats` (its TAP `ok`/`not ok` lines without `# skip`, or the pretty formatter's summary). Streams the command's output, exits with its code, prints `TIER <tier>: …` / `FAIL` / `FLOOR` / `OVERBUDGET` lines and writes `build/metrics/tier-<tier>.json` at the git top level (`tier.<tier>.seconds`, `tests.<tier>.<runner>`). Outside a gate it first takes one of the gate slots (`GATE_SLOTS`, below; holder `<repo>:<tier>`, `TIER <tier> waiting for a gate slot (…)` every 30 s, the wait outside the budget), so hand-run tiers queue with the gates; inside a gate or another tier it runs on that slot, and `TIER_SLOT=0` skips it for a quick single test. Every `devkit new` stack's test tiers run through it. `DEVKIT_CLOCK_SHIFT=<n>d` runs a pytest or vitest tier with the wall clock shifted ("Clock shift" below). |
| `clock_shift/devkit_clock_shift.py` | The pytest plugin tier_guard.sh loads under `DEVKIT_CLOCK_SHIFT` (`PYTEST_PLUGINS`, this directory on `PYTHONPATH`): time-machine shifts the clock before the initial conftests load and ticks, every xdist worker shifts itself, `scripts/ci/clock_shift.conf` entries run as non-strict xfails with their reasons, and each shifted process records itself in tier_guard's `DEVKIT_CLOCK_SHIFT_PROOF` file (`NOSHIFT` without it). |
| `clock_shift/vitest_clock_shift.mjs` | Its vitest half, the setup file tier_guard.sh names as `DEVKIT_CLOCK_SHIFT_VITEST` and `lint/vitest.base.mjs`'s `clockShiftSetupFiles` hands to the repo's config: a `Date` proxy shifted and ticking in every pool and project (a test's fake timers start from it and restore it), `clock_shift.conf` entries by vitest test id turn a failure into a pass with the reason, and the same proof record. |
| `bin/metrics_collect.sh` | `<snapshot\|check\|tighten\|rebaseline>`: the `ci-metrics` mechanism. Reads `scripts/ci/metrics.conf` (`<name> <area> <command...>`), runs each collector from the repo root into `build/metrics/<name>.json`, skips those whose area no changed path touched (in the gate; `tooling`/`other` and `repo` collectors run regardless), merges with the gate's and tiers' files, then runs the ratchet. A repo's Makefile holds four one-line targets and nothing else. "Metrics ratchet" below. |
| `metrics/` | The shared collectors a `metrics.conf` line calls, one per stack, each `--scope <name> [--out FILE]`, deterministic, exit 2 naming a missing dev dependency: `python.py --root <dir> --src <subdir|module.py>... [--python <interp>] [--mccabe] [--cognitive] [--vulture [--vulture-ignore-declarative] [--vulture-base <set,...>]] [--cycles] [--exclude <glob>]...` (ruff C901, complexipy, vulture, AST import cycles; run under the repo's interpreter, `uv run --frozen --project backend python devkit/metrics/python.py …`, so the tools resolve); `ts.mjs --root <dir> --src <subdir> [--tsconfig F] [--test-glob G]... [--exclude G]... [--cyclomatic] [--cognitive] [--knip [--knip-base]] [--cycles] [--bundle [--bundle-entry index.html]]` (eslint `complexity`, sonarjs cognitive, knip, dependency-cruiser cycles, vite bundle KiB; tools from `<root>/node_modules/.bin`); `rust.py --root <workspace> [--cognitive] [--dead] [--cycles] [--fan] [--exclude <glob>]...` (clippy `cognitive_complexity` scoring every function, rustc's unused-code warnings; one `cargo clippy`/`check --workspace --locked` on PATH's cargo, which the gate provisions from `rust-toolchain.toml`, else through `bin/toolchain_exec.sh` for a hand run; module cycles and fan from the source, the production targets `cargo metadata` names, read by `metrics/_rust_graph.py`); `shell.py --root <dir> [--src <glob>]... [--exclude <glob>]... [--shellcheck] [--complexity] [--dead] [--cycles] [--fan]` (shellcheck errors and warnings through `bin/shellcheck.sh`, plus devkit's own `stdin-in-read-loop` warning: ssh, `docker exec -i` or ffmpeg draining a `while read` loop's input, which shellcheck 0.11 hides under any disable directive; branches per function, functions nothing calls, and the cycles and fan of the `source` graph, from a stdlib lexical scanner; default `--src` `**/*.sh` `**/*.bash`, the vendored `devkit/` never read); `jscpd.mjs --scope repo [--min-tokens 50] [--min-lines 5] [--bin <jscpd>] [--base] [--format <f,...>] [--list-out FILE] <paths...>` (shell: `--format bash`); `coverage.py --scope <s> (--coverage-json F \| --istanbul-summary F \| --llvm-cov-json F)` (the tier writes the report; "run make ci-unit-<s> first" when it is missing). `--exclude` on python.py, ts.mjs and rust.py drops vendored production files (a shadcn component) from every key they emit; a glob matching nothing is exit 2, and the report-only `meta.<scope>.excluded_files` keeps the list visible. Keys per collector: `docs/metrics-keys.md`. The `--*base` flags merge `lint/`'s knip, jscpd and vulture bases under the repo's own config (`lint/README.md`). |
| `bin/metrics_ratchet.py` | The "never worse than main" gate. `check` holds a snapshot to `docs/metrics/ratchet.json` and that file to main's copy (`git show origin/main:…`), so a PR cannot loosen its own bounds; a BETTER key fails it too (`… BETTER — run make metrics-tighten and commit …`; a float key within 0.05 passes), so `tighten` locks in BETTER numbers in the improving PR; `tighten` prints every WORSE or MISSING key as `check` would, exiting 1, so the author sees the gate's refusal first; report-only keys (`vuln.*`, `coupling.*.fan_in_max`, `duplication.*.jscpd_percent`, `size.*.max_lines`, `size.*.over_600`) are printed, never gated, dropped from the bounds by `tighten`/`rebaseline`, which commit their values to `docs/metrics/report-only.json` for the scorecard; `merge` joins `build/metrics/*.json` into one snapshot that records each key's collector and the collectors skipped, so a key whose collector did not run is SKIPPED, not a failure. Committing a looser bound needs the fail-closed `metrics-rebaseline` PR label; no label admits a value past the committed bound. |
| `templates/metrics/ratchet.json`, `docs/metrics-keys.md` | Starter bounds (all `null` until `rebaseline` fills them, so `check` refuses a raw copy; `{}` is the other valid start) and the flat `<domain>.<scope>.<stat>` key shape every collector emits. |
| `bin/own_commit_check.py` | Transaction-boundary guard: AST scan fails a raw `.commit()` on a session the function did not open itself (`with … as db` / `db = Session()`), and pins every `commit_now(…, reason=…)` call to a shrink-only `path::qualname` allow-list. Prints `own_commit_allowlist_entries=<n>` for `metrics_ratchet.py` (direction lower). Opener regex and excludes are per repo. A TS repo holds the same boundary with guard_check's `own-transaction` kind. |
| `bin/_dockerignore.py` | Which paths a root-context `docker build` sees: the root `.dockerignore` matched as Docker's patternmatcher does (from the context root, so `*.md` is root-only; parent matches exclude subtrees; `**`, `!`, last match wins; `.dockerignore` and `Dockerfile` always count). `keep` feeds the gate's image classifier (`_paths_lib.sh`); `redundant` feeds devkit-check's warning on a `GATE_IMAGE_EXCLUDE_PATHS` alternative the file already covers. Stdlib only. |
| `bin/py_cognitive_lint.py` | The Python `ci-lint` step for cognitive complexity, the backend analogue of `sonarjs/cognitive-complexity`: complexipy, through `metrics/python.py`'s own run, over the `.py` files under `--src` changed since the merge-base with `--base-ref` (origin/main), committed or not; any function over 15 in them fails, worst first. When `docs/metrics/ratchet.json` holds `complexity.<scope>.cognitive_over_15` at 0 it lints the whole tree (graduation, lint/README.md). Runs under the repo's interpreter (`uv run python devkit/bin/py_cognitive_lint.py --root . --src server --scope backend`). |
| `bin/changed_lint.py` | `ci-lint`'s changed-file rules: `ruff` (PLR0915, PLR0916 and PLR1702 at `lint/ruff.toml`'s max-statements 50, max-bool-expr 5 and max-nested-blocks 5) or `eslint` (`lint/eslint.base.mjs`'s `sonarjsChangedRules`) over only the files changed since the merge-base with `--base-ref` (origin/main); `--hold <rule>` adds a base rule the repo's config ignores while it owes it (devkit's E501), judged only on the lines the change adds or rewrites (`git diff -U0` against the merge-base; `FILE_SCOPED` names the function-scoped rules judged on the whole file), through `bin/_changed_files.py` as py_cognitive_lint.py does; a rule with fleet debt fails the edit that adds to it while the debt drains (lint/README.md "Changed-file rules"). Exit the tool's, 2 for a missing tool or an unresolvable base. |
| `bin/layer_check.py` | Dependency-direction guard for `ci-quick` (the consumer's `layer-check` target): the repo's `scripts/ci/layers.conf` declares, per source tree (`[section]`, the ratchet scope), its layers bottom-first by path glob, plus `peer` (same rank, neither imports the other), `entry` (composition root), `leaf` (imports nothing of ours), sanctioned `allow` edges, `deny` for a skipped layer and the shrink-only `known` violations. An import from a lower rank to a higher one fails, as does a file in no layer or a `known` line that is no longer refused. Python reads `metrics/python.py`'s runtime import graph (the one `coupling.<scope>.cycles` counts), its import-statement edges only (the package-initializer edges the cycle count adds run beneath every layer); TypeScript reads import statements (aliases from the conf, type-only imports erased). Prints `layer_violations=<n>`; `--metrics-out` writes `coupling.<section>.layer_violations` (direction lower), so a scaffold's `metrics.conf` runs it as the `layers` collector. Stdlib only. |
| `bin/guard_check.py` | Code-structure guard for `ci-quick` (the consumer's `guard-check` target): the repo's `scripts/ci/guards.conf` declares import, call and semantic rules per source tree (the catalogue in "Guards (guard-check)" below), with `except` sites and shrink-only per-file `known` debt. `--metrics-out` writes `guards.<section>.known`, so a scaffold's `metrics.conf` runs it as the `guards` collector. Stdlib only; the predicates are `bin/_guard_rules.py`, and it shares `bin/_source_tree.py` (the conf's section keys, globs, file walks) and `bin/_ts_lex.py` (the TS lexer) with `layer_check.py`. |
| `bin/dead_alert_audit.py` | Monthly review of vmalert rules (not a gate, exit 0): statically flags missing `severity`/`runbook`, `outcome` values outside `success|failure`, names duplicated across files; with `--vm-url` asks VictoriaMetrics which alerts never fired and which selectors matched no series in `--since` (default 30d). One `dead-alert <high|medium|low> <alert> <reason>` line per finding. |
| `bin/monthly_audit.sh` | Monthly fleet audit, run from this checkout (not vendored). Per active vendoring repo, in a fresh shallow clone: the guards `ci-quick` does not already reach, `.devkit-rev` skew, the ratchet, and a re-invention diff (`reinvent <repo> <path> <kind> <devkit equivalent>`; naming the file under AGENTS.md "Convention deltas" silences it). Fleet: labels/settings dry-runs, `dead_alert_audit.py`, gate-ledger digest. Writes `report.md`, `summary.tsv`, `findings.json`; one read-only `claude -p` proposes ≤ 3 structural findings, which the script files as `fleet-audit` issues (none while 3 are open; off for the first two runs) and PRs the report to homelab `docs/audits/`. Kill switch `~/.config/devkit/audit.off`. Schedule (owner step, install by hand): fill `__DEVKIT__`/`__HOME__` in `templates/launchd/com.agandhi4.devkit.monthly-audit.plist`, `mkdir -p ~/Library/Logs/devkit`, `cp` it to `~/Library/LaunchAgents/`, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.agandhi4.devkit.monthly-audit.plist`. |
| `bin/dependency_merge.sh`, `bin/_dependency_pr.py`, `bin/install_dependency_merge.sh` | Nightly devkit sync, then gated merge of minor and patch dependency PRs (owner, 2026-10-21: Renovate never merges by itself; 2026-10-22: devkit reaches every repo without a hand-run sync PR). `bin/dependency_merge.sh [--max <n>] [--dry-run] <repo-root>...`: per repo, from a fresh worktree of origin/main and with main's gate plan, first the devkit sync: a main whose `.devkit-rev` is behind `DEVKIT_URL`'s main (and vendors another tree) gets `make devkit-sync` in a second worktree of main, with the model-agnostic trailer; it must only vendor (`vendoring_only` and `vendored_from`, `make merge`'s Codex exemption, or it is `refused` and not pushed), is force-pushed to `devkit-sync/<sha7>` and opened as a draft labelled `devkit-sync` whose body is the devkit commit range and the `docs/decisions.md` titles it adds; an open PR already vendoring that commit and merging cleanly is reused as it is, any other one is `closed` as superseded. It is gated and merged like a dependency PR and counts toward `--max`; a failed gate is a devkit regression, commented once per head and never re-gated (a failing metrics job included: tighten or rebaseline by hand, which makes it a repo change under the normal Codex rule); merged, the worktree moves to the new main so the dependency PRs gate on it. `current` (at devkit main, or the same vendored tree) and a `.devkit-rev` off devkit's main (`skipped`) are one line each; `--dry-run` prints `would-sync <old>..<new> (<n> devkit commits)`. Then the open Renovate and Dependabot PRs against main, oldest first (`_dependency_pr.py`: minor/patch from Renovate's Update column or a minor-and-patch group title, Dependabot's commit `update-type` for every `dependency-name`; majors, `major-bump`, other or missing types are skipped and listed), at most `--max` (3) gated per repo. The PR list never asks for `commits` (GitHub's GraphQL node limit refuses that query for 100 PRs, homelab #123); each Dependabot PR's commits are one `gh pr view`, and the list pages past 100 open PRs. A PR conflicting with main now is skipped for its bot to rebase; one merely behind main is gated as it is (the gate tests the merge into the current main; the preset's `rebaseWhen: auto`, never `behind-base-branch`, which force-pushed every open branch after each merge, homelab #128); a head whose gate already failed is skipped until it moves. Else `make gate PR=<n>` pinned to the head (a gate slot like any gate), then `make merge PR=<n>` on PASS; a `re-gate:` refusal (main or the head moved after the gate, GitHub's "Head branch is out of date" included) is `skipped behind`, retried next run. Otherwise the gate record's verdict decides (`gate_record.py verdict-of`; make exits 2 for any failed recipe): `fail` with a plan job failing gets one PR comment per head naming the failing jobs and rules (`gate_record.py failures`); `error`, no record, or only machine failures (`failures --code-only` empty: a gate step such as worktree, toolchain or a conflict, the silence watchdog, a budget overrun under load) is only logged, with no marker, so the next run retries it. One `dependency-merge: <slug>#<n> <outcome> <detail>` line per PR (merged, failed, error, refused, skipped, closed, current, would-sync, would-gate; the sync's line is `<slug>` alone until it has a PR) to stdout and `$XDG_STATE_HOME/devkit/dependency-merge.log`, a summary per repo; exit 0 unless no repo could be read. Kill switch `~/.config/devkit/dependency-merge.off`. Schedule: `bin/install_dependency_merge.sh <repo-root>...` from the devkit main checkout fills `templates/launchd/com.agandhi4.devkit.dependency-merge.plist` (02:30 nightly, under caffeinate, logs in `~/Library/Logs/devkit/`) and bootstraps it; rerun to change the repos, `--uninstall` to remove. |
| `github/` | Fleet operations run from this checkout, not vendored: `labels.json` + `labels_sync.sh` (idempotent; `--prune` to delete), `repos.json` + `repo_settings.sh` (squash-only, PR_TITLE/PR_BODY, delete-branch; auto-merge only on public repos). |
| `renovate/default.json` | Shared Renovate preset (`github>agandhi4/devkit//renovate/default`) for every fleet repo: weekly grouped minors, pinned action digests, no automerge (see Renovate below), `.nvmrc` + `FROM node` + `engines` bumped together, dashboard approval instead of hard ignores so security fixes still flow. |
| `renovate/automerge-digest.json` | The one automerge hole: digest-only pins merge ungated, in their own group. Extended after the default only with `GATE_RENOVATE_AUTOMERGE=digest` in the plan. |
| `bin/bats_assert_check.py` | Bats assertions errexit never sees, so each passes whether or not it holds: `[[ ]]` and `(( ))` (exempt from errexit on bash < 4.1, macOS's 3.2, where lanes run bats), `! cmd` and `[ a ] && [ b ]` (exempt on every bash). Each must end `|| false` (or another failing `||` handler); `--fix` appends it where that alone fixes it, leaving `&&` lists (maybe a conditional) to a person. Reads tracked `*.bats` outside `devkit/` and the files they `load`. Fails devkit's `ci-lint`; devkit-check warns on a consumer's. |
| `bin/_renovate.py` | The Renovate audit devkit-check (WARNING lines) and the scorecard's `renovate` check share: the preset extended, no `automerge`/`ignoreTests: true` or automerge preset in the repo's file, the digest hole declared on both sides. |
| `.github/workflows/quick-check.yml` | Reusable `workflow_call` quick-check (checkout, Node from `.nvmrc`, optional Python + uv, `make ci-quick`); caller template in `templates/workflows/`. Needs devkit's Actions access set to "repositories owned by the user". |
| `lint/ruff.toml` | Shared ruff base (py313, 100 cols, E F I N W UP T20 PLC0415); consumers `extend` it. |
| `lint/eslint.base.mjs` | Import-free flat-config array of core rules (no-console, no-eval, no-implied-eval, HTML-sink properties); consumers spread it first. |
| `lint/swift-format.json` | The swift-format config; a repo's `.swift-format` is a byte copy that `devkit-check` holds. |
| `metrics/size.py` | File-size collector for any language: `size.<scope>.max_lines` and `size.<scope>.over_600` over the production files (tests, fixtures, generated paths excluded), and every file over the limit on stderr. Both keys are report-only: the ratchet never gates them and the scorecard prints them on its T2 complexity line (size alone never justifies a split). One conf line per area. |
| `bin/secrets_check.sh` | Guard for `ci-quick` (scorecard T11): no credential in the tracked files (~1 s per 1,000 files; `--staged` scans only the staged paths, for pre-commit). gitleaks' high-confidence shapes (private keys, AWS, GitHub, Slack, Google, Stripe, Anthropic/OpenAI, age) everywhere, and long literals assigned to secret-named variables outside tests and placeholders; `scripts/ci/secrets_allow.txt` names a fixture's fake key with its reason. The matched text is never printed. |
| `bin/migration_check.py` | Guard for `ci-quick` (scorecard T5, data.md 12 and 14): no shipped migration is modified or deleted (the `migration-contract` label, or `--allow-shipped-edits`, makes a deliberate one pass), and no alembic `downgrade()` is a `pass` body (write it, or raise with the reason; merge revisions are exempt). `--versions <dir>` per migrations directory; Django packages (`__init__.py` + `NNNN_*.py`) are detected and get the edit check only (Django raises on a missing reverse itself); drizzle dirs get the edit check only, and a `meta/_journal.json` change that only appends entries (every other key and every shipped entry unchanged) is not an edit: each new migration appends one. `--frozen <dir>` names a vendored upstream graph (kitchen's Tandoor `server/cookbook/migrations`) that fails on any added, modified, deleted or renamed file, untracked ones included, so upstream releases still merge; `--allow-frozen-edits` (or `MIGRATION_FROZEN_OK=1`) is the upstream-merge PR's escape. Both compare with the merge base of `--base` and HEAD, so a branch behind main is not blamed for what main shipped since. |
| `bin/ios_check.py` | Guard for a Swift app's `ci-quick` (its `ios-check` target in `ci-guards`), over `scripts/ci/ios.conf`; see "iOS apps" below. **brand**: a Swift string literal whose whole value equals a `BRAND_*` value of `Config/Brand.xcconfig` fails, naming the key; each conditional assignment (`BRAND_X[sdk=iphoneos*]`) is a value of its own, and a `$(REF)` takes the REF values a build of its conditions can select, patterns compared as globs (`iphoneos*` overlaps `iphoneos26*`), every reference of one value agreeing on one build (no device+simulator mixtures). **crash**: `crash sentry` wants sentry-cocoa in a `Package.resolved` or `project.yml` and exactly one `SentrySDK.start` call (`start(…)` or `start { … }`; a bare or `start(options:)` reference is not one); `crash none <anchor>` wants that heading in `docs/decisions.md`. Each `known <path>:<line> <rule> <reason>` line allows one finding (two on one line need two) and fails once stale. |
| `bin/ios_device.sh` | `install\|pull`: the physical-iPhone recipe, macOS only, env-driven (`IOS_SCHEME`, `IOS_BUNDLE_ID`, `IOS_DIAG_GROUP`, `IOS_DIAG_SOURCE`, `IOS_DEVICE`; the header is the contract). `install` builds with the device's UDID and installs the newest `.app` with its CoreDevice UUID, both from one `devicectl list devices` listing, retrying a `CoreDeviceError` once; `pull` copies the app (or App Group) container's diagnostics to `diagnostics/<timestamp>`. A Swift app's `ios-install` and `ios-pull-diagnostics` targets. |
| `bin/codegen_drift.sh` | `[--ref <rev>\|--index] [--regen '<cmd>'] -- '<generator>' <path>...`: a generated file as committed equals what its generator writes now. The generator is one shell string writing `$DRIFT_OUT/<path>` (a temp dir, never the working tree); each path is compared with its bytes at `--ref` (`$DRIFT_REF`, else HEAD) or the index, and drift names each path, a short diff and the regenerate command (`DRIFT_OUT="$PWD" bash -c '<generator>'`, runnable as printed for any generator shape, unless `--regen`). A `--ref` naming no revision is exit 2, and `DRIFT_OUT` is absolute under a relative `TMPDIR`. With `--index`, an unstaged change to a tracked file other than a `<path>`, or an untracked unignored one, is `codegen-drift: SKIP (…)`, exit 0 (each `<path>` excluded literally, so `gen/[ab].txt` never hides `gen/a.txt`): the generator would read the working tree, not the commit, so the gate's run judges it. The shape finplat's `ci-drift` and locus's `codegen:check` hand-roll. |
| `metrics/vuln.py` | Vulnerability collector for any stack (scorecard T11): the locked production dependencies (`uv export`, package-lock.json, pnpm-lock.yaml, Cargo.lock) asked of OSV in one batch, each hit fetched once for severity; `vuln.<scope>.critical|high|total|packages` (packages 0 is a dev-only lockfile), report-only (a new advisory is not a code regression, so the ratchet never tracks it). `--compose <files>` counts the services' image references instead (OSV indexes no image): `vuln.<scope>.images|images_unpinned|images_undigested`. No audit tool needs installing. |
| `metrics/statements.py` | The statements collector (decision H): the db tier's statement fixture writes `{"<METHOD>:/<route>": <max statements>}` to a file outside `build/metrics/`; one `statements job:db …` line in `metrics.conf` validates and copies it into the snapshot as `statements.<METHOD>:/<route>` keys at tolerance 0. closet's `test/support/statement-budgets.ts` and finplat's `count_statements` are the two fixtures to copy. |
| `bin/agent_cost.py`, `docs/agent-cost.tsv` | The agent-cost ledger (scorecard T9): one row per (repo, PR, agent) from the Claude Code session transcripts (API calls, tool calls, output and cache-read tokens attributed to the PR the agent was on, gate rounds, `GATE … FAIL` lines seen, merged) joined with the gate state dir's seconds. Append-only; `--summary` prints per-repo medians, which the scorecard grades. Run it after a wave of lanes (`make agent-cost`). Transcripts are data: only counts and PR URLs leave them. |
| `bin/scorecard.py`, `scorecard.conf` | The fleet scorecard v2 (standardization/scorecard-design.md §5): per repo one line and three readouts, WIRED (devkit mechanisms wired, `n/m`), TREND (ratchet.json and report-only.json history over 7 and 30 days, labelled worsens, largest debts) and BITE (`gate_bite.py`); UNMEASURED is the devkit backlog, owner items are listed apart; the scorecard ratchet holds the WIRED share. "Scorecard" below. |
| `tests/` | bats contract tests (fake `gh`/`make`/`node`, temp bare repos). |

## New project

```sh
~/projects/solo/devkit/bin/devkit-new.sh <name> --stack python-fastapi   # or node-service, rust, next-vercel, swift-app, infra-compose; --no-image for a repo that publishes nothing
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
`/health/ready` (swift-app: shows its build identity, plus the fleet's iOS baseline: team
373B8X2G98 and `io.silversky` bundle ids from one `Config/Brand.xcconfig` read through `Brand`,
sentry-cocoa reporting to the app's Bugsink project from `App.init` (an empty DSN is off with one
log line), a rolling `LogFile` with a `DiagnosticsView` to share it, and its `ios-install` /
`ios-pull-diagnostics` targets through `bin/ios_device.sh`), with a test per tier. The first commit runs through pre-commit, so `ci-guards`
(devkit-check, toolchain-check, docs-check, release-check, workflows-check, layer-check and
guard-check outside rust and swift-app, own-commit-check for Python, ios-check for swift-app), the staged secrets scan
and lint/format have passed on it before you see it.
It also adds `"<name>": {}` to this checkout's `github/repos.json` (sorted; commit it to devkit
in a PR), so the fleet scorecard and the monthly audit measure the repo from its first commit;
it needs `jq`. `tests/new_contract.bats` holds every stack to this.

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

Then, by hand, in this order (devkit new prints the first two, since they act on GitHub):

1. `gh repo create agandhi4/<name> --private --source <dir>/<name> --push`
2. Run `github/repo_settings.sh <name>` (squash-only, PR title/body) and
   `github/labels_sync.sh <name>`.
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
path scoping and the ledger: its header). What goes in which hook follows the owner's
budgets (2026-10-13): pre-commit p90 at most 30 s, pre-push at most 60 s, timed in the hooks ledger.

- **pre-commit** runs the parts of ci-quick that take seconds: `ci-guards` (the stdlib guards),
  `secrets-staged` (`secrets_check.sh --staged`; the full-tree scan stays in ci-quick),
  `ci-lint` (cached eslint, then `prettier --check`; ruff; rustfmt) and `ci-drift` where the
  stack has migrations.
- **pre-push** runs `ci-typecheck` (tsc, clippy) and `ci-unit`.
- **commit-msg** runs devkit's own message checks, no make target. Its one check, `trailer`,
  refuses an agent's commit (CLAUDECODE or CLAUDE_CODE_* in the environment, or `git config
  devkit.agent true`) without a Claude trailer naming the model that ran it, any line matching
  `Co-Authored-By: Claude[ <model>] <noreply@anthropic.com>` (`bin/_trailer_lib.sh`). It never
  compares against `DEVKIT_COMMIT_TRAILER` or `devkit.trailer`: an agent can set those to
  anything, so they are only what devkit-sync writes. A human's commit and a merge pass, and
  `COMMIT_MSG_STEPS=("trailer:off")` in hooks.conf turns it off. `devkit new` installs it, and
  devkit-sync creates it in a repo that already tracks `.githooks/` copies.
- **ci-quick is the union of its parts**, so the gate and Actions still run all of it. A new
  quick check goes into a part, and a new part into ci-quick and one hook.
- **hooks_check.sh warns** when a pre-commit step's target names typecheck or unit, and when
  the Makefile has `ci-lint` but no pre-commit step runs `ci-lint`, a `ci-lint-<area>` or
  `ci-quick` (the changed-file rules would first fail at the gate).
- **Every hook heals the metrics merge driver.** When `.gitattributes` names
  `merge=devkit-metrics`, a clone whose `merge.devkit-metrics.driver` is unset or not the
  vendored command gets it, with one line, never a block; devkit-sync and `make install` do the
  same (`metrics_driver_heal`, `bin/_gitattributes_lib.sh`; rollcall #78).
- **A missing-module failure names a missing `node_modules`.** When the failed step's output
  reads as a missing module or command (`Cannot find module`, `command not found`, ...) and a
  tracked npm, pnpm or yarn lockfile with a package.json has none beside it, a line under the
  blocked one says `run npm ci (or make install) in this worktree`.

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
`git subtree` involved any more: squash merges drop the trailers subtree needs. The sync also refreshes the repo's tracked byte copies of vendored bases (every `.swift-format`, and each `.githooks/` hook) when they differ, printing one line each; it creates a hook only in a repo that tracks another. Once `devkit/` is replaced, the sync hands over to the freshly vendored `devkit-sync.sh` (`DEVKIT_SYNC_REEXEC=<commit>`, once), so a new base rule or hook template lands on the first sync, not the second.

Only what consumers run is vendored: `VENDOR_PATHS` at this repo's root lists it (`bin/`, the
hook, workflow and metrics templates, `lint/`, `renovate/`, the docs consumers read). Stack
scaffolds (`templates/new/`), `tests/`, `.github/` and `github/` stay here; `devkit new` and the
monthly audit read them from a full checkout. Adding a path a consumer needs is a one-line
manifest change.

Then add to the Makefile (every repo uses the same three targets):

```make
gate:            ## make gate PR=<n> [GATE_ARGS=--no-post]; local or the gate host
	devkit/bin/gate.sh "$(PR)" $(GATE_ARGS)
merge:           ## make merge PR=<n>; refused unless the head has local-gate success
	devkit/bin/pr_merge.sh "$(PR)"
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
GATE_IMAGE_EXCLUDE_PATHS='^eslint\.config\.mjs$'       # copied by the build, read by no stage
GATE_IMAGE_PATHS='^scripts/ci/smoke_image\.sh$'        # paths that also run the image group
gate_plan() { devkit_default_gate_plan; }
gate_plan_extra() { ...; }                             # optional: the repo's own rules
```

Each changed path gets one area from the table the hooks use (docs, backend, frontend,
native, tooling, other). A repo whose Markdown is what it ships declares a literal
`GATE_CODE_PATHS=<prefix>[,<prefix>...]` line (claude-kit: `plugins/`, where SKILL.md and
agents are the plugins' code): every path under those prefixes is other, for the gate, the hooks
and `make merge`'s docs-only exemption alike; devkit-check holds it to that one unquoted line. Docs-only runs docs; tooling (`devkit/`, `.devkit-rev`, hooks.conf,
`.githooks/`; a devkit sync) runs quick, plus the image group when `boot_image.sh` or
`contract_probe.sh` changed; native-only runs nothing; backend and frontend run their groups
plus quick, image and e2e; other runs everything (`docs/metrics/ratchet.json` and
`scripts/ci/metrics.conf` are other, so a bounds-only PR meets the ratchet and its label).
The metrics group runs for backend, frontend and other, after `gate_plan_extra`, so
`ci-metrics` sees every earlier job's seconds; when the PR
carries the `metrics-rebaseline` label (read through `gh`, fail-closed) its jobs get
`METRICS_REBASELINE=1`. `GATE_AREAS_<GROUP>="..."` overrides a group's areas, except IMAGE and
E2E: every app path runs them, and a plan setting `GATE_AREAS_IMAGE` or `GATE_AREAS_E2E` is
exit 2 at the gate and a devkit-check failure in ci-quick. A changed path the root
`.dockerignore` excludes cannot reach the image, and the gate reads that file itself with
Docker's matcher (`bin/_dockerignore.py`; an unanchored `*.md` matches only at the root, unlike
gitignore). The `.dockerignore` and `Dockerfile` always count. `GATE_IMAGE_EXCLUDE_PATHS` adds
only paths the build copies but no stage reads, and devkit-check warns on an alternative the
`.dockerignore` already covers. The table and
defaults: the `_paths_lib.sh` header. A plan may still be hand-written against the
skeleton's helpers, reading `GATE_AREAS` and `GATE_HAS_<AREA>`.

Gate environment (full contract in the script header):

| Variable | Default | What |
|---|---|---|
| `GATE_SLOTS` | ceil(cores / 4) | How many gates and hand-run tiers (tier_guard.sh outside a gate) may run at once on this machine, across repos. `1` keeps the single lock file `GATE_LOCK`; `N` > 1 uses `GATE_LOCK.1` … `GATE_LOCK.N`. A waiting gate prints `GATE waiting for a gate slot (<n> running: <repo>#<pr>, …)` at once and every 30 s; the holder's line is in its slot file and in `<slot file>.holder`, read when a waiter vendored before #175 (it opens slot files with `>`) has emptied the first and that holder's pid still lives. Two gates of one PR never overlap: the second prints `GATE waiting for another gate of PR #<n> (…)` and waits, holding no slot, since both would share its ref, worktree and run numbers. This laptop's gate.env sets `2`. |
| `GATE_SILENCE_SECONDS` | `300` | Watchdog: a job whose log has not grown for this long is stopped (`GATE <job> WATCHDOG (silent for <n>s; …)`), status `error`, record verdict `error` with rule `silence:<job>`, exit 2. `0` disables. A job that works quietly for minutes prints progress (devkit's `tests/shards.sh` does). |
| `GATE_CLEANUP_SECONDS` | `120` | The plan's `gate_cleanup` (EXIT trap) is stopped after this long, with one stderr line; a hung docker daemon once held a slot there for 12+ min. `throwaway_pg.sh` and `boot_image.sh` also probe the daemon (`DOCKER_PROBE_TIMEOUT`, 15 s) and bound each docker call (`DOCKER_CALL_TIMEOUT`, 180 s). |
| `GATE_JOB_BUDGET_MINUTES` | `5` | Per-job budget (owner directive 2026-10-13). An over-budget job runs to completion, then `GATE <job> OVERBUDGET (<n>s > <b>s)` and VERDICT FAIL naming it. Decimals allowed; `0` disables. Above the core count it stretches by min(load / cores, 2), as tier budgets do (`bin/_load_lib.sh`), and the line says so. The job's make (and each tier_guard command) sees the factor as `DEVKIT_LOAD_SCALE`, which `lint/vitest.base.mjs` applies to vitest's timeouts. |
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

**Stale heads.** When the repo has a local branch named by the PR (checked out here or not),
`gate.sh` passes its tip as `--expect-head <sha>` (local or remote alike), and the gate re-polls
GitHub's pull ref for up to 60 s before planning, printing one `GATE waiting:` line, instead of
gating the commit before your push (Orbit #80, finplat #657). A head that never arrives is
`GATE head FAIL (GitHub head X ≠ local Y …; push or wait)`, no status. A local branch strictly
behind its fetched `origin/<branch>` is a stale copy and sets no expectation.

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

## Gate record (gate.json, runs.tsv)

Every gate run that gets as far as its log dir leaves an outcome record (`bin/gate_record.py`,
from local_gate.sh's EXIT trap, so an interrupt or a watchdog stop leaves one too). It parses the
job logs the gate already keeps; no job's output changes. A remote gate writes it on the host,
then remote_gate.sh copies that PR's runs.tsv rows and gate.json back into this machine's state
dir (`gate_record.py import`, deduped by pr, head and finished), so gate_bite.py and `make merge`
read remote runs too. A failed copy is one `remote_gate: WARNING:` line; the verdict stands.

Each run keeps its logs and record in its own dir, `logs/<pr>/<head7>-<n>/` (`nohead-<n>` when the
fetch failed), `n` counting up per PR; a run that opens deletes all but its PR's newest 5.
`logs/<pr>/latest` names the newest dir, and `logs/<pr>/gate.json` links to `latest/gate.json`,
so a failure's logs outlive the green rerun that follows it.

`$XDG_STATE_HOME/<GATE_STATE_NAME>/logs/<pr>/gate.json`, the last run of that PR:

| Key | Value |
|---|---|
| `schema_version` | `2` |
| `pr`, `head`, `main` | the PR number and the two SHAs gated (`""` when the run ended before fetching) |
| `started`, `finished` | UTC, `2026-10-18T10:00:00Z` |
| `verdict` | `pass`, `fail`, or `error` (a watchdog stop or an interrupt) |
| `seconds` | whole-gate seconds from the slot, as the budget counts them |
| `rules` | every failing rule of the run, in job order |
| `jobs.<name>` | `{"verdict": "pass"\|"fail"\|"skip"\|"budget"\|"error", "seconds": n\|null, "rules": [...]}`, plus `"error": "<first error line>"` for a failure no pattern names |
| `gate.<job>.seconds`, `gate.total.seconds` | the metrics keys, as in the worktree's `build/metrics/gate.json` |

`budget` is a job that passed but went over its enforced budget; `error` is a job the silence watchdog stopped, whose one rule is `silence:<job>` (its log is not parsed: the box stalled, not a test). A failing gate step (`fetch`,
`head`, `worktree`, `merge`, `toolchain`) is a job with `seconds: null`. Rules are `kind:id`:
`ratchet:<key>` (a WORSE or MISSING line), `guard:<rule>` (a `GUARD … FAIL` line),
`lint:<code>` (ruff, shellcheck, mypy, tsc, eslint), `budget:<tier>` (tier_guard OVERBUDGET),
`budget:gate.<job>` and `budget:gate.total` (the gate's own budgets), `test:<file or name>`
(pytest, unittest, bats, vitest, playwright, cargo, go, XCTest), else `job:<name>:<hash>` (also after budget rules when a tier in that log failed or floored, so a failure no pattern names never reads as a budget alone), the
hash of the log's last error line with its digits folded (`job:<name>:nolog` for an empty log),
which gate_bite.py prints with the job's first error line. Only failed
jobs' logs are read. The patterns are `RULE_PATTERNS` in gate_record.py, one fixture line each.

`$XDG_STATE_HOME/<GATE_STATE_NAME>/runs.tsv` gets one row per run, never rewritten, so 30 days
of runs read without opening every gate.json (`bin/gate_bite.py <repo> --days 30` reads it):

```
finished  pr  head  verdict  seconds  rules (JSON array)  failed_jobs (comma-separated, or -)
```

## Metrics ratchet (ci-metrics)

**Every key is a signal, not a verdict** (owner, 2026-10-18). A number says where to look; an
agent judges whether the code needs to change, and acts or records an exception. A ratchet
bound holds a floor against drift so a regression is seen in the PR that caused it, and the
`metrics-rebaseline` label is the exception path when judgement says the number should move.
A key whose movement says nothing about the code without that judgement is report-only: size
is, because size alone never justifies a split (decisions 2026-10-17, T2 file size).

A repo declares its collectors in `scripts/ci/metrics.conf`, one per line, and its Makefile
holds four one-line targets. Everything else (which collectors a PR runs, the merge, the
comparison with main, the label) is devkit's.

```make
ci-metrics:       ## gate job: no metric worse than main
	devkit/bin/metrics_collect.sh check
metrics-snapshot: ## run the collectors; build/metrics.json is the report
	devkit/bin/metrics_collect.sh snapshot
metrics-tighten:  ## lock in BETTER numbers; commit docs/metrics/ratchet.json in the same PR; TIGHTEN_RUN_TIERS=1 runs the tiers it needs first; SEED=1 bounds keys that have none
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
collectors in `devkit/metrics/` (`python.py`, `ts.mjs`, `rust.py`, `shell.py`, `jscpd.mjs`, `coverage.py`; CLIs in the
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
`--list-out build/metrics/<name>.findings.txt` to every `python.py`, `ts.mjs`, `rust.py` and `shell.py` line and ends
the run with `findings: <files>`, pass or fail. Each file holds a `# <key>` header per key
with findings and one line per finding: functions over the complexity threshold worst first
(`backend/server/x.py:120 sync_all cognitive=52`), every dead-code finding
(`web/src/a.ts:3 Id type`), one line per import cycle naming its files, and the top 10 modules
by fan-in and fan-out. The ratchet and the scorecard never read it; formats in
`docs/metrics-keys.md`.

**Shell.** `shell.py` measures shellcheck, complexity, dead functions and the `source` graph's
cycles and fan; duplication is `jscpd.mjs --format bash` (jscpd reads `.sh` and `.bash`), and
shell has no coverage key (bats reports tests, not lines). The infra-compose scaffold wires all
of them, and devkit's own `scripts/ci/metrics.conf` holds its bin/ to them (`make ci-metrics`).

**Rust.** `rust.py` measures complexity, dead code and module coupling; jscpd already reads
`.rs`, so duplication is `jscpd.mjs` over the source dirs. The coupling keys come from a
lexical module graph (files are modules, `use` and `crate::`/`super::`/child-module paths are
edges, re-exports followed to the defining file, `#[cfg(test)]` code unread). A module cycle
compiles in Rust, so its count is a design signal: the cycle's modules cannot be split into
crates. A Rust repo (redlib) adds, beside its `size-app` line:

```sh
# scripts/ci/metrics.conf
rust-app other python3 -I devkit/metrics/rust.py --root . --scope app --cognitive --dead --cycles --fan --out build/metrics/rust-app.json
dup      other node devkit/metrics/jscpd.mjs --scope app --base --out build/metrics/dup.json src
```

then `devkit/bin/metrics_collect.sh rebaseline` (on the pinned toolchain: `PATH="$(devkit/bin/rust_toolchain.sh .):$PATH"`
outside the gate). `rust-app` needs `clippy` in `rust-toolchain.toml` components. `dup` needs a
pinned jscpd: a root `package.json` with `"jscpd": "5.4.0"` in devDependencies, its
`package-lock.json`, `node_modules/` git-ignored, an `.nvmrc`, and `npm ci` in the gate before
`ci-metrics`; until that is worth a Node toolchain, leave `dup` out. redlib on 2026-10-17:
`complexity.app.cognitive_max` 23, `cognitive_over_15` 5, `dead.app.rustc` 0 (its two
`#![allow(dead_code)]` files), jscpd 2.76% and 18 clones over `src`; on 2026-10-18
`coupling.app.cycles` 1 (client, media, model, oauth, oauth_device, utils), `fan_out_max` 9
(post.rs), `fan_in_max` 12 (server.rs).

Coverage comes from the unit tier, as in the rust scaffold: `llvm-tools` in the
`rust-toolchain.toml` components, `COV_TOOL ?= devkit/bin/cargo_tool.sh cargo-llvm-cov@0.9.1 --`
in the Makefile, `ci-unit` as `@mkdir -p build` then `$(COV_TOOL) $(TIER) unit … -- $(CARGO)
llvm-cov --locked --json --summary-only --output-path build/coverage.json`, and the line
`cov-app job:unit python3 -I devkit/metrics/coverage.py --scope app --llvm-cov-json build/coverage.json --out build/metrics/cov-app.json`
(lines only: rustc's branch coverage is nightly-only); `SEED=1 make metrics-tighten` then
bounds it. The first `make ci-unit` on a machine installs cargo-llvm-cov (about 35 s).

**Coverage** is produced by the unit tier, not by a collector: each `ci-unit-<area>` runs with
coverage on and writes the tool's report (coverage.py JSON, an istanbul summary, a
`cargo llvm-cov --json` export);
`devkit/metrics/coverage.py` converts it to `coverage.<area>.lines|branches`, declared with
`job:<the tier's gate job>` so it runs only when that job ran. Outside the gate
a missing report fails the collector with "run make ci-unit-<area> first". A tier whose budget
coverage would break says so in its PR rather than dropping the budget.

**Never track `gate.*`, `tier.*` or `tests.*`** in `ratchet.json`: jobs and tiers are
area-scoped, so those keys are absent on narrow PRs, and the seconds are noisy. They stay in
the snapshot as untracked, for the report.

**Report-only keys** (`vuln.*`, `coupling.<scope>.fan_in_max`,
`duplication.<scope>.jscpd_percent`, `size.<scope>.max_lines`, `size.<scope>.over_600`, and any
key its collector declares in a `"report_only"` list, as ts.mjs does for a Next build's
`bundle.<scope>.kb_total`, which `bundle.<scope>.kb_route_max` replaces) are collected and never gated, even when `ratchet.json`
still holds a bound for one: `check` prints it as REPORT-ONLY with a note to run `make
metrics-tighten`, a PR may drop it without the label, and `tighten` and `rebaseline` drop it. `tighten` and `rebaseline` write their values to
`docs/metrics/report-only.json`, committed with the bounds, which the scorecard reads from a
fresh clone (`check` never touches it). A hub module's fan-in is
architecture, not drift (finplat #659); fan-out (a god module) stays gated. The duplicated
share rises when unduplicated lines are deleted (orbit #86, #88), so `duplication.<scope>.clones`
is the one ratcheted duplication key and the scorecard grades on it. A file's length is read
with judgement, never split for its own sake (owner 2026-10-18): `size.py` lists every file
over the limit on stderr for the reader.

**Gate-only.** Collectors need the dev dependencies and take tens of seconds (target under
60 s; the job budget is 5 min), so `ci-metrics` is neither a hook step nor an Actions job.
`check` reads main's bounds through `git show origin/main:docs/metrics/ratchet.json`; an
unresolvable base ref is an error, never "no guard".

Adoption: start `docs/metrics/ratchet.json` from `{}` (or from
`devkit/templates/metrics/ratchet.json`, every shared-collector key at `null`), write
`scripts/ci/metrics.conf`, then `SEED=1 make metrics-tighten` fills every bound
from today's numbers, seeds every untracked key the collectors emit (never `gate.*`,
`tier.*`, `tests.*` or a report-only key; a repo-specific domain is added by hand with its direction) and records
each key's collector. The same command bounds a key a collector starts emitting later
(`ratchet <key> SEEDED <value>`): an added bound is a tightening, so it needs no label, and
plain `tighten` names the keys still without one. Commit both files; the devkit-sync commit itself needs no change, the
adoption PR carries the attribution trailer. From then on a PR
that improves a number runs the repo's `metrics-tighten` target and commits the bounds: the
gate fails a BETTER key until it does (an integer key on any gain, a float key such as coverage
or bundle KiB on a gain over 0.05), and the `metrics-rebaseline` label does not exempt it. A
float gain within 0.05 is left at its old bound by `tighten` too, since both read one predicate,
so run-to-run noise is never committed and then read WORSE. When HEAD does not contain
origin/main's tip, `tighten` measures their merge in a temporary worktree (the repo's own
`metrics-tighten` there, tiers included) and copies the bounds back, so the number it commits is
the one the gate reads. The pre-push hook previews the ratchet with `check --quick` (no tiers;
`BETTER: run make metrics-tighten before push`) and never blocks. `docs/metrics/*.json` merge per
key, the stricter bound winning, once `make install`, a hook or devkit-sync has set the driver (bin/_gitattributes_lib.sh). A tighten on a HEAD that lacks origin/main measures their merge in a temporary worktree, as the gate will, with the call's own `--conf`, `--bounds` and `--out` (the script's header, "Merged tree"). Outside
the gate every collector runs, so a coverage report or `build/statements.json` that no tier has
written yet stops the run once, listing each missing file with the `make` target of the gate
job that writes it; `TIGHTEN_RUN_TIERS=1 make metrics-tighten` runs those targets first (the inputs are one
table in the script: coverage reports, the statement fixture, a Next app's
`.next/build-manifest.json` for `ts.mjs --bundle`). An
input older than the newest tracked file under its source directory (after a rebase, say) is a
WARNING, and under `TIGHTEN_RUN_TIERS=1` its tier reruns as well; `TIGHTEN_RUN_TIERS=fresh` (the
script's `--fresh`) reruns every tier input.

The `metrics-rebaseline` label permits a PR to COMMIT bounds looser than main's; it never
permits a measured value past the committed bound. A PR whose numbers moved for a legitimate
reason (a tool knob, a deliberate trade) runs `make metrics-rebaseline KEYS=<key>[,<key>]`,
which loosens only the named bounds to today's numbers (a named key that is not worse is left
and reported, one with no bound yet is seeded, one in neither file is exit 2), and commits `docs/metrics/ratchet.json` with the label.
The gate's fix lines name that command with the WORSE keys filled in. Without `KEYS` the target
rewrites every bound and `docs/metrics/scorecard.json`, which is for a label-approved tool
change that moves everything, never for adding a bound (rollcall #74 did, to add two bundle keys); it then warns, naming each bound it loosened. The gate then holds every key to that committed file exactly as in
check mode; the only difference is that the LOOSENED, REMOVED and DIRECTION bound lines are
accepted. A key that is worse than its committed bound fails even under the label, with a line
naming the fix (Orbit #78 merged a coverage drop under a label meant for two size bounds, and
the next PR failed on it):

```
metrics-rebaseline: coverage.backend.lines 49.24 is past its bound 49.45; set the bound in docs/metrics/ratchet.json or fix the regression
```

## Clock shift

A test that dates fixtures from the real clock beside a pinned one, or asserts against a fixed
date, passes until real time moves past it, then fails every gate at once (finplat #706: 30
days green, then red at ET midnight). The CLOCK group reruns a repo's pytest and vitest tiers
with the wall clock shifted, so such a test fails the day it is written. A shifted tier's
budget is reported, never enforced: its unshifted run holds it, and the CLOCK group runs every
shifted tier at once. The plan and the repo's exceptions:

```sh
# scripts/ci/gate_plan.sh: each job runs once per offset, as <name>-<offset>, before BACKEND,
# on backend, frontend and other paths (a GATE_AREAS_CLOCK that omits an area the repo has
# paths in fails the scorecard: which tiers a change there reaches is not knowable from it)
GATE_JOBS_CLOCK="clock-unit ci-unit-backend|clock-db test-db"
GATE_CLOCK_SHIFTS="30d 365d"     # the default

# scripts/ci/clock_shift.conf: what a process clock shift cannot move, each with its reason
tests/db/test_push.py::test_payload_carries_the_unreviewed_badge  # the inbox window is Postgres now()
test/integration/draft-batch.spec.ts > a batch of drafts  # its waits are Postgres now()
```

By hand: `DEVKIT_CLOCK_SHIFT=30d` on the tier's own make command line. pytest needs `time-machine`
in the dev dependencies and nothing else. vitest needs one config line, the base's setup file
first in the root config's `setupFiles` (projects with `extends: true` inherit it ahead of
their own; vitest 3 in a subdirectory package also needs vitest 4+ or `server.fs.strict: false`,
`clock_shift/vitest_clock_shift.mjs` "Gotchas"):

```ts
import { clockShiftSetupFiles, timeouts } from "./devkit/lint/vitest.base.mjs";
  test: { ...timeouts, setupFiles: [...clockShiftSetupFiles, "./src/test/setup.ts"] },
```

The tier's target must floor only pytest and vitest (tier_guard refuses a shifted playwright,
cargo or bats floor: those would run on the real clock), and every floored runner must record
its shifted processes in tier_guard's proof file, or the tier fails `NOSHIFT` (a pytest in a
container, a vitest config without the line). An entry names a pytest node id relative to the
tier's rootdir, or a vitest test id as its failure line prints it (`<file> > <describe> >
<test>`, relative to the vitest root); spaces are allowed, the first `#` starts the reason, and
an entry covers everything under it. Its tests still run and count toward the floor: pytest
runs them as non-strict xfails (an XPASS shows an entry no longer needed), vitest turns a
covered failure into a pass with a `clock-shift exception` line. The shifted run writes no tier
metrics, and tier_guard puts back every file a `scripts/ci/metrics.conf` collector reads (its
`TIER_INPUTS`: the coverage report, `statements.json`) as it found it, mtime and all, or removes
it when there was none (`TIER <tier> shift kept <n> metrics input(s): …`), so the ratchet reads
the real-clock run whatever the job order: a unit tier in QUICK, before CLOCK, is fine. An input
it cannot put back fails the tier, and so does a shifted run that rebuilt a Next app's `.next/`
(`ts.mjs --bundle` reads all of it). Only the guarded command is covered: a recipe step after
tier_guard (a `coverage combine` that writes the report) runs shifted and unguarded, so a target
in `GATE_JOBS_CLOCK` writes its inputs inside the guard. Rust,
Swift and bats are not covered. The scorecard's `clock_shift` check wants every pytest and
vitest tier in `GATE_JOBS_CLOCK` (its target, or one whose recipe runs it); the `devkit new`
python-fastapi, node-service and next-vercel scaffolds declare every one of their tiers.

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
| `compose-healthcheck [except GLOB[:SERVICE,...]...]` | compose | a service with an `image:` or `build:` and no healthcheck (`disable: true` or test `NONE` is none; a block with no `test`, immich's `disable: false`, keeps the image's own HEALTHCHECK and passes). `except GLOB:SERVICE` sanctions those services there (a scratch image with no shell to probe from). Not seen: an image's own HEALTHCHECK when the file declares none. Seed: homelab, 37 services on 2026-10-18 |
| `compose-pinned-image [except GLOB[:SERVICE,...]...]` | compose | an `image:` with neither a digest nor a tag other than `latest` (none is latest); `${VAR:-default}` reads as its default, a variable with no default in the tag is the `.env`'s pin and passes. Seed: homelab, 6 own apps on `:latest` (autoupdate by design: an `except`) |
| `compose-no-privileged [except GLOB[:SERVICE,...]...]` | compose | `privileged: true` on a service. Not seen: `cap_add: [ALL]`, device lists |
| `compose-restart-policy [except GLOB[:SERVICE,...]...]` | compose | a service with no `restart:` and no `deploy.restart_policy` (compose's default `no` leaves it down after a reboot); `restart: "no"` is a declared choice and passes |

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

A `lang compose` section (`root`, `src` the directories holding the stacks) takes only the
compose rules. It reads every `compose.y[a]ml`/`docker-compose.y[a]ml` and environment variant
under `src` (never `*.override.*`, whose partial services compose merges at run time) through
`bin/_compose.py`, a stdlib reader of the YAML subset compose files are written in (anchors,
merge keys, flow and block collections, block scalars; tags and multi-document files are exit
2 at `<file>:<line>`), with each service's `extends` resolved. It reads homelab's 25 compose
files and every YAML file of the fleet as PyYAML does (2026-10-18), so the guard needs nothing
installed.

Python reads `metrics/python.py`'s runtime imports (relative ones resolved, `TYPE_CHECKING`
erased) and the AST; the semantic rules resolve a callee through the file's imports
(`dt.now()` after `from datetime import datetime as dt`). TypeScript reads `bin/_ts_lex.py`,
the lexer `layer_check.py` shares (comments, strings, templates and regex literals skipped;
type-only imports erased; aliases and relative specifiers resolved to root-relative paths),
and scoped-exports reads its top-level functions with the walker lifted from rollcall's
`tests/invariants/ast.ts`. Single-file components (`.vue`, `.svelte`): their script blocks are
scanned, lines as in the file; templates are not, so a template `@click="client.get()"` is not
seen (only-text alone reads the whole file, since a spelling in a template is still one). A rule with no candidates (no file under any of its globs, or a filter that selects no
function) is inert: it passes with one `inert:` line. A glob that matches nothing beside one
that does, an unmatched `except` or sanctioned glob, and a file that does not parse are exit 2. A sanctioned site (an only-*/single-writer glob, an `except` glob)
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

## iOS apps

A Swift app's two fleet rules live in `scripts/ci/ios.conf`, which `ios-check` (in `ci-guards`)
reads; the swift-app scaffold ships one that passes:

```sh
# scripts/ci/ios.conf
brand Config/Brand.xcconfig                 # the one brand source; Swift reads it via Info.plist keys
crash sentry                                # or: crash none #2026-10-21--why-this-app-reports-nothing
known Sources/Legacy.swift:12 brand the pre-rename container id, read once to migrate
```

Every `BRAND_*` key in the brand xcconfig is a brand value (bundle id base, app group, URL
scheme, log subsystem, Sentry DSN), its `$(NAME)` references expanded; other settings there are
not.
A device is driven through `devkit/bin/ios_device.sh`, never a recipe of its own.

## Renovate

Owner decision (2026-10-18): no paid GitHub features, so enforcement is client-side, and
`make merge` is the only merge path. Branch protection is paid on private repos, so GitHub
cannot require `local-gate`, and a Renovate automerge is a server-side merge that no gate,
hook or gh shim sees (homelab #109/#110, 2026-10-19). So no Renovate PR merges itself: every
repo's `renovate.json` extends `renovate/default` (automerge, platformAutomerge and
ignoreTests all off) and waits for `make gate` and `make merge` like any PR.

The one hole is a conscious one. A repo whose dependencies move by digest alone (homelab's
compose images) may extend `renovate/automerge-digest` after the default, which merges
`digest`/`pinDigest` updates ungated, and must say so in its plan:

```sh
# scripts/ci/gate_plan.sh: digest-only pins merge without the gate (renovate/automerge-digest)
GATE_RENOVATE_AUTOMERGE=digest
```

devkit-check warns, and the scorecard's `renovate` check fails, on a config that does not
extend the preset, sets `automerge` or `ignoreTests` to true anywhere, extends any other
automerge preset, or declares only one half of the digest hole. A repo's own packageRules apply
after its presets, so the preset alone cannot forbid this; the check reads the repo's file.

## Rules

- Never edit `devkit/` inside a consuming repo; `devkit-check` fails quick-check. Change it
  here, merge, then `devkit-sync` in each repo.
- Output contracts (`GATE …`, `VERDICT …`, `.devkit-rev` format) are APIs: the merge queues,
  `worker.py` and the Mac stand-in parse them. Changing one is a coordinated change.
- Scripts run on macOS bash 3.2 and GNU bash, with BSD and GNU coreutils. shellcheck clean.
- A Codex finding is answered in its thread and then resolved, or `make merge` refuses the PR.
  Fix it (reply `fixed in <sha>`) or decline it with a specific reason, then resolve:
  `gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' -f id=<thread id>`
  (claude-kit's `codex_gate.py reply <id> "<text>" --resolve` does both). Resolving changes no
  commit, so the gate stays valid. There is no override: a resolved thread with its reason is it.
- In a repo whose plan sets `GATE_CODEX_REVIEW=1`, a head Codex has not reviewed is refused by
  `make merge`. Missing or of an older commit: wait, or comment `@codex review` (a draft: mark it
  ready, or comment). Failed, or answered by Codex's usage-limit comment: run claude-kit work-loop's Claude adversarial
  review (SKILL.md §3c), fix what it finds, and record it on the head, naming why Codex did not:
  `gh api repos/<owner>/<repo>/statuses/<head sha> -f state=success -f context=codex-review -f description='Claude adversarial review (Codex <why>) of <sha7>'`,
  `<why>` one of `at limit` (Codex's usage-limit comment answered it), `hung <N> min` (a review
  "Running" longer than the plan's `GATE_CODEX_RUNNING_MAX_MIN`, default 30, counts as failed) or
  `failed` (any other failure), as claude-kit work-loop SKILL.md §3c writes it. A new push is a
  new head and needs its own. `make merge` prints the exact command for the case it refused.
  A docs-only PR (every path `docs` in
  `_paths_lib.sh`) and a bot's dependency-pin PR need no review, only resolved threads.

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
rules go in `scripts/ci/docs_rules.sh`. A repo that ships agent instruction files for other places
(dotfiles stowing `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`) names those trees in
`scripts/ci/docs_payload.txt` (`<dir> <reason>` per line): their names and shapes belong to the
tool that reads them, so docs-check leaves them out of every rule; a stale entry fails.

## Scorecard

`bin/scorecard.py <repo>` (v2, `standardization/scorecard-design.md` §5) prints one line,
`scorecard <repo> wired n/m · 7d: a↓ b= c↑(l labelled) · 30d: … · gates g, fails f, unguarded merges u`,
then a table per readout, never averaged together; there are no letters and no repo grade.

- **WIRED**: is devkit enforcing here. `wired <id> <scope> PASS|FAIL|D|NA` per mechanism the
  stack can use (a manifest names python, ts, rust or swift; a tracked `*.sh` outside `devkit/`
  names shell, held to `shell.py`'s complexity, dead, cycles and fan keys and `jscpd.mjs --format bash`, coverage NA; a compose project file names
  compose, held to guards.conf and `vuln.py --compose`): a ratchet key per domain, guards.conf, layers.conf, tier budgets, hooks, the
  hooks ledger live in 30 d, the gate plan, the scorecard file, `make merge` in the AGENTS.md
  Workflow, renovate, secrets, migration and contract-probe wiring, devkit-rev age ≤
  `kit_devkit_days_max` days (commit dates). UNMEASURED prints in a "devkit backlog" list and
  the owner's items (VM reader, glossary, restore drill, Actions billing) in an "owner" list,
  neither counted in n/m. NA is structural: a tier target with no recipe of its own is an
  aggregate and only its prerequisites are judged, and a `ci-smoke*` that boots through
  `boot_image.sh` is capped by its BOOT_TIMEOUT. `ratchet.vuln` is NA when every
  `vuln.<scope>.packages` is 0 (dev-only lockfiles), and `contract_probe` is NA when the plan has
  no `GATE_JOBS_IMAGE` (a Dockerfile the gate never builds). Run from a consumer's vendored
  `devkit/`, `devkit_rev` and `repos_json` read GitHub through `gh api`, with repos.json cached
  7 days under `<state>/devkit/scorecard/`. `--mode` skips both, since the ratchet never reads them.
- **TREND**: is it improving. Per key of `docs/metrics/ratchet.json` and `report-only.json`, the
  value at the start of 7 and 30 days of git history against HEAD, direction-aware. A worsen is
  labelled when every commit that worsened it carries a `Metrics-Rebaseline: <key>=<old>→<new>`
  trailer naming it, which `make merge` writes into a metrics-rebaseline PR's squash body. A
  commit with no trailer (older history, an unsynced repo) falls back to a `docs/decisions.md`
  line it adds naming the key, or `metrics-rebaseline` in its message; the table says which. "Largest debts" lists keys past the
  `scorecard.conf` thresholds, with no verdict.
- **BITE**: does enforcement act, from `gate_bite.py`: gate runs and fails by rule, hook fails,
  merged PRs whose head lacks a `local-gate` success.

The numbers WIRED and "Largest debts" read are the committed bounds, then `report-only.json`,
then a fresh `build/metrics.json`. A snapshot older than the checkout's HEAD commit is a leftover
from another tree, so it is not read: one stderr line says
`scorecard: <repo>: snapshot build/metrics.json is older than HEAD (<age>); reading committed bounds instead`.

`--fleet <repo>...` prints the fleet report (`--md` writes it; `--json` the per-repo documents
that `--table` renders again, as the monthly audit does). `--fleet` with no paths reads
`github/repos.json` and clones every repo 45 days deep into a scratch directory first; WIRED's
`repos_json` check fails a repo missing from that file.

The ratchet holds each `repo`-scoped check: a repo commits `docs/metrics/scorecard.json`
(`{"checks": {<id>: true|false}}`, `bin/scorecard.py . --mode rebaseline` once), and its
`ci-metrics` target fails a PR in which a check the file records wired reads unwired or NA, or one it
records unwired reads wired until `make metrics-tighten` commits it (gains lock in). A check the
file does not record is new devkit backlog: printed as `new, unwired: devkit backlog`, never a
failure, so a devkit sync that vendors a new check passes in every repo that has not wired it
yet. The WIRED share is still printed, as a number, not a bound. `machine` checks (hooks ledger,
gh shim) and `fleet` checks (devkit-rev age) print in n/m but are never ratcheted: they move
without a code change. As in the metrics ratchet, `check` holds the checks to the PR's file and
that file to main's; the `metrics-rebaseline` label admits a check main records wired going
unwired or unrecorded in the PR's file, never a loss against the PR's own file. An older file
(v1 `tracks`, or the share-only `{"wired": <share>}`) records no check by name: it reads as
first adoption on either side and fails the `scorecard_file` check until `make metrics-tighten`
rewrites it.

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
