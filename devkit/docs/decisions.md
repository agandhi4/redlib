# Decisions

## 2026-10-12 — Per-repo gate policy is a sourced bash plan, not a TOML map
**Why**: finplat, Orbit and locus's `local_gate.sh` shared ~110 identical lines of mechanics, but
their differences were control flow: a drift job whose make arg depends on a PR label, "image
subsumes vite-build", one fixture dir triggering two suites, an area skipped with a note. A
path→job data map would lose checks or grow an interpreter, and bash has no TOML parser.
**Decision**: `bin/local_gate.sh` is the skeleton; each repo sources `scripts/ci/gate_plan.sh`
with scalar config + `gate_plan()` using `job`/`skip`/`changed`/`pr_has_label`/`nothing_to_run`.
**Consequence**: three 200-line copies → one skeleton + three ~60-line plans; drift fixes
(missing-pull-ref fallback, status retry, bash 3.2 guard, flock required) land once for all.

## 2026-10-12 — Vendored as git subtree (squash) with a tree-hash guard, not a submodule
**Why**: every repo in the work loop runs in worktrees (agent worktrees, the gate's detached
worktree, the Mac merge queue's checkout). `git worktree add` does not populate submodules, so
devkit scripts called from Makefiles inside a worktree would be missing; Actions and Docker build
contexts would need `submodules: true` everywhere.
**Decision**: `git subtree add/pull --squash` at `devkit/`; `devkit-sync.sh` records the
upstream tree hash in `.devkit-rev`; `devkit-check.sh` (in `ci-quick`) asserts `HEAD:devkit`
matches, offline.
**Consequence**: plain files everywhere; an in-repo edit to `devkit/` fails quick-check, which
mechanically enforces "nothing lives in only one repo".

## 2026-10-12 — Skeleton and plan are read from the invoking checkout, not the gated tree
**Why**: the merge queues fast-forward the main checkout before each gate, so the gate logic is
main's. Reading the plan from the merged worktree would let a PR disable its own checks.
**Decision**: unchanged from the previous per-repo scripts: `$ROOT` (where the script lives)
supplies skeleton + plan; the merged worktree supplies the Makefile targets.
**Consequence**: a PR that changes `gate_plan.sh` is gated by the OLD plan; its change takes
effect after merge. The owner reviews plan changes by eye, as before.

## 2026-10-13 — Node is declared once in `.nvmrc` and the gate provisions exactly that
**Why**: nothing declared which Node a repo is tested with. CI said 22 in nine places, the Mac
gate ran 25 and failed every vitest suite (Node 25's default Web Storage stub shadows jsdom's,
Orbit #40, locus #91), and finplat's image had been bumped to Node 26 by a bot while tests
ran 22. The fix each repo needs for Node 25 (a storage shim) is separate from this drift.
**Decision**: exact version in `.nvmrc`; workflows use `node-version-file`; the gate skeleton
runs `node_toolchain.sh` (checksum-verified download from nodejs.org, cached per version) and
refuses to run without it; `toolchain_check.sh` in quick CI fails on any disagreeing copy.
**Consequence**: a Dockerfile bump by Renovate/Dependabot fails quick-check until `.nvmrc`
moves too, so the image never runs a Node the suites never saw. Pinned at 22.23.3 (CI's);
bumping is a one-file change per repo that goes through the gate.

## 2026-10-13 — Playwright browsers installed by one devkit call, idempotency left to Playwright
**Why**: Orbit installed browsers on every e2e run; finplat and closet never did locally, so a
`@playwright/test` bump failed the Mac gate ("Executable doesn't exist") until a manual install.
**Decision**: `bin/playwright_browsers.sh` picks the runner from the lockfile, runs under the
`.nvmrc` Node, and calls `playwright install`, which already skips cached revisions. No
`--dry-run` parsing, no cache inspection. `--with-deps` is dropped with a warning on macOS.
**Consequence**: gates, hooks and CI can call it unconditionally with the same flags.

## 2026-10-13 — One throwaway Postgres script, env-driven, tmpfs on by default
**Why**: five near-copies (finplat `test_pg.sh`, Orbit `test-db` + `e2e/run.sh`, locus smoke +
`_bootstrap.py`) shared ~15 lines and differed only in data (image, credentials, port strategy,
network, tmpfs, server args). Two divergences were bugs: Orbit lacked the tmpfs that stops the
18 GB anonymous-volume leak, and its e2e probed the socket, which answers during init before the
server restarts.
**Decision**: `bin/throwaway_pg.sh up|down|url <name>`, all variation via `PG_*` env; `up`'s only
stdout is `PG_PORT=<n>`; readiness is `pg_isready` over TCP with early exit on container death.
**Consequence**: finplat and Orbit adopt now; locus keeps its Python warm-reuse bootstrap (a
deliberate speed choice) and may adopt later; closet uses scratch databases, not containers.

## 2026-10-13 — One boot-and-wait script for image smokes; assertions stay per repo
**Why**: locus, finplat, Orbit and closet each booted their image with ~35 shared lines (names, private network, DB, health poll, log dump, cleanup); finplat lacked the early exit on container death and Orbit lacked tmpfs. What each checks after boot differs entirely.
**Decision**: `bin/boot_image.sh up|down <name>` owns only the boot: `<name>-net`, optional `<name>-pg` via `throwaway_pg.sh`, `<name>-app` on loopback, status-code health poll with early exit, log dump plus teardown on failure, `BASE=<url>` as the only stdout. All variation is `BOOT_*` env; the app's settings live in the caller's env file.
**Consequence**: repos keep their assertions and call `down` from their EXIT trap. BASE is `127.0.0.1`, so CORS origins built on `localhost` must change. Closet's `--network host` shape is not supported and stays as is.

## 2026-10-13 — Fork PRs are refused by the gate unless the plan opts in
**Why**: the skeleton fetches `pull/<n>/head` for any PR; closet is public, so a fork PR would run a stranger's code on the gate box.
**Decision**: `GATE_ALLOW_FORKS=0` by default, settable only from the plan (not the environment); anything but `isCrossRepository=false` fails closed before fetch, posting no status.
**Consequence**: a fork contribution to a public repo is gated by a maintainer re-pushing it to a branch, or by a deliberate plan opt-in.

## 2026-10-13 — docs_check: AGENTS.md canonical, caps that only shrink
**Why**: the 2026-10-12 owner decision (AGENTS.md real, CLAUDE.md symlink) was violated in closet and in finplat's and locus's subdirs; ten docs exceed the 30/16 KB context budgets; closet's checker tested none of this.
**Decision**: one bash guard over `git ls-files -s`; oversize files need an allowlist entry that fails once the file drops below 90% of its cap, so budgets ratchet down.
**Consequence**: landing it needs an initial allowlist per repo; from then on docs cannot grow back.

## 2026-10-13 — Hooks: shared runner and step loop, per-repo step list
**Why**: finplat and closet each had a quiet runner; Orbit and locus had no hooks; finplat's `core.hooksPath` was silently repointed by a tool install on 2026-08-16 and nothing noticed for two months.
**Decision**: `quiet_run.sh` (one line per step, tail on failure), `hook_steps.sh` (conf load, env gate, LFS chain), templates that are a few lines, `hooks_check.sh` in install and gate preflight with `--fix`.
**Consequence**: a repo's hooks are a `scripts/ci/hooks.conf` step list; the runner's UX is identical everywhere; locus must chain `git lfs pre-push` and the template does.

## 2026-10-13 — Metrics gate is a committed-bounds ratchet with a fail-closed rebaseline label
**Why**: finplat's metrics diff was advisory (exit 0, no direction, not in the gate); the settled decision is "never worse than main, never an absolute threshold".
**Decision**: `metrics_ratchet.py check` against `docs/metrics/ratchet.json`; `--tighten` only on main; loosening only via the `metrics-rebaseline` PR label read fail-closed by the gate plan. Collectors stay per repo (layout-specific, one consumer).
**Consequence**: Phase 3 wires `ci-metrics` into each gate plan; snapshots stay report-only.

## 2026-10-13 — Labels and repo settings are fleet operations run from devkit
**Why**: every repo's label set and merge settings had drifted; homelab #67 placed the scripts in homelab, but they are not per-repo files and need no vendoring.
**Decision**: `github/labels.json` + `repos.json` are the source of truth; the two scripts are idempotent `gh api` callers; auto-merge and protection skipped on private free-plan repos.
**Consequence**: run after each new repo and monthly (Phase 4); `--prune` is explicit.

## 2026-10-13 — Renovate preset in devkit, dashboard approval instead of hard ignores
**Why**: finplat's Dependabot ignore lists would, as `enabled: false`, also block security fixes; Dependabot let advisories through its ignores.
**Decision**: ignored update kinds use `dependencyDashboardApproval`; `.nvmrc`, `FROM node` and `engines` share one group so `toolchain_check` never sees a half-bump; automerge off everywhere because Renovate PRs never receive the Mac `local-gate`.
**Consequence**: consumers' `renovate.json` is three lines; callers of the reusable quick-check float on `@main` while the subtree is pinned, an accepted skew for a workflow that only runs `make ci-quick`.

## 2026-10-13 — Python declared once in `.python-version`, checked like Node
**Why**: finplat tested on 3.13 and shipped 3.14; Orbit and locus had no pin file. The owner chose 3.13 everywhere (same precedent as Node 26→22).
**Decision**: `toolchain_check.sh` compares `.python-version` (MAJOR.MINOR) with every `FROM python:`/uv image tag, every `requires-python` lower bound, and `setup-python` steps (`python-version-file`). Dockerfiles one level down are scanned for both languages.
**Consequence**: moving finplat's `backend/.python-version` to the root fails the check until its image returns to 3.13; that is the point.

## 2026-10-13 — Release identity: the image carries APP_VERSION, a ship tag marks the deploy
**Why**: Orbit's health said `dev` in prod, locus exposed no version, finplat deployed a rebuild that CI never tested. Nothing recorded what ran when (release-identity-design.md).
**Decision**: `release_check.sh` holds the image to one source: ARG → ENV → `org.opencontainers.image.version` LABEL in the final stage, compose never sets it, and pushing CI steps pass it. `boot_image.sh` `BOOT_EXPECT_VERSION` proves it reaches the health `version` key at runtime. `ship_tag.sh` lets the step that moves `latest` create `ship-<date>-<sha7>` through `gh api`. It compares commits, so a rerun is a no-op and a mismatch is refused, never moved.
**Consequence**: deploying jobs need `contents: write`. The sha must be a full sha on main. A second ship on another day makes a second tag, which is correct for a redeploy.

## 2026-10-13 — Own-commit guard: lexical opener rule, helper allow-list, ratcheted count
**Why**: services in all three apps commit sessions they borrowed, ending the caller's unit of work (transaction-boundary-design.md: finplat 15, locus 6, Orbit 8). Owner rule: the handler or job runner commits.
**Decision**: `own_commit_check.py` allows a raw commit only on a session opened in the same function, by assignment or `with … as`, judged by a per-repo opener regex. Closures count as borrowing. Every other commit must be `commit_now(…, reason=…)` in a function on the allow-list. The list fails both ways (unlisted call, stale line), and an optional per-line count must match exactly.
**Consequence**: the default regex omits `get_session` because finplat's returns the request session. The helper's own body is exempt, and other primitive modules (Orbit `utils/transaction.py`) go in `--exclude`. The repo's metrics collector parses `own_commit_allowlist_entries` into `ratchet.json` as `lower`, so a new entry needs `metrics-rebaseline`.

## 2026-10-13 — Dead-alert audit: report-only, strict YAML subset, live pass fails loudly
**Why**: finplat's JobFailed matched `outcome="failure"` while the app emitted `"error"`, so it could never fire; a dead rule looks exactly like a healthy app (observability.md, Alerts).
**Decision**: `dead_alert_audit.py` exits 0 with findings (it feeds the monthly review, never a gate). It uses its own block-YAML subset parser, not PyYAML, so `python3 -I` behaves the same everywhere, and it rejects anchors and flow style with file:line. Group `labels:` merge into rules as in vmalert. It flags any literal `outcome` value outside `success|failure`, not only `error`. The live pass checks each selector in the expr, matchers included, with `absent_over_time`, so a vocabulary fork shows up at runtime too.
**Consequence**: an unreachable or erroring VictoriaMetrics exits 2 instead of printing an empty report that would read as all-clear. VM has no host port, so run the live pass on the NAS or through a tunnel. `never-fired` is low severity because a healthy quiet app also never fires.

## 2026-10-13 — Rust declared once in `rust-toolchain.toml`, provided through rustup
**Why**: redlib had only an MSRV and a floating builder; the Mac has no Rust, so the gate could not run there. Same drift class as Node and Python.
**Decision**: exact channel in `rust-toolchain.toml` (or `rust-toolchain`). `rust_toolchain.sh` installs via PATH's rustup or a private one under `$XDG_DATA_HOME/devkit/rust` (rustup verifies component hashes) and prints the toolchain's sysroot bin, not `CARGO_HOME/bin`: those are proxies that need `RUSTUP_HOME`, and callers export PATH only. Declared components are installed too. `toolchain_check.sh` holds `FROM rust:` minor, MSRV ≤ channel, and setup-rust-toolchain with no inline `toolchain:`.
**Consequence**: `dtolnay/rust-toolchain` is refused outright because it cannot read the file. Cross builders (`rust-musl-cross`) carry no version and are not checked.

## 2026-10-13 — The gate provisions toolchains from the merged tree, policy from the invoking checkout
**Why**: provisioning Node/Rust from `$ROOT` gated a PR that bumps `.nvmrc` on main's version, so the bump was never proved by its own gate.
**Decision**: toolchain declarations are read from the merged worktree after the merge step; a toolchain the box cannot provide is a FAIL verdict (never a dangling `pending`). Gate policy (`gate_plan.sh`) still comes from `$ROOT`.
**Consequence**: a toolchain bump PR runs on the new version; the "pending without verdict" failure mode is closed.

## 2026-10-13 — workflows_check: Actions rules as a guard, with job eligibility read from `if:`
**Why**: delivery.md's Actions rules (SHA pins, one PR job, draft skip, cancel superseded, docs ignored) lived only in prose; Orbit and locus float on tags, and finplat's and Orbit's publish jobs cancel mid-push.
**Decision**: one bash+awk guard reads triggers, concurrency and job `if:` by indentation. A job counts for an event unless its `if:` names `github.event_name` without that event, so combined PR+push+dispatch files pass. `merged == true` counts as a draft skip. The only understood cancel expression is `github.event_name == 'pull_request'`. Push steps come from `_workflows_lib.sh`, shared with `release_check.sh`.
**Consequence**: a reusable workflow cannot be judged for trigger rules; workflow_call-only files warn. An unusual `if:` or cancel expression fails instead of being guessed.

## 2026-10-13 — Monthly fleet audit: deterministic script files, the LLM only proposes
**Why**: guards in ci-quick see one PR at a time; skew, re-invented copies, loosened ratchets and dead alerts only show across the fleet over time (phase4-audit-design.md). A routine with write tools was the main risk.
**Decision**: `bin/monthly_audit.sh` audits fresh shallow clones, runs only guards ci-quick does not already reach (Makefile parsed transitively, never executed), and runs them from this checkout so repos are judged against the current standard. One read-only `claude -p` (Read/Grep/Glob, 3 turns, $2) proposes ≤ 3 findings; the script files them as `fleet-audit`, deduped by exact title fleet-wide, none while 3 are open, none until two runs are recorded. Every remote write goes through `remote_write` (dry-run guard); the only push is `audit/<YYYY-MM>` in homelab; nothing merges. A bats test pins all of this.
**Consequence**: the report lands at homelab `docs/audits/fleet-<YYYY-MM>.md` (memo name, not `audit-`); local state under `$XDG_STATE_HOME/devkit/audit/`. Deferred from the memo: the `/convention audit` rotation and the 45-minute wall clock (macOS has no `timeout`; `--max-turns` bounds it). A same-month rerun fails at the push rather than overwrite the branch.

## 2026-10-13 — devkit-sync replaces the vendored tree; no git subtree
**Why**: `git subtree pull --squash` finds its base through `git-subtree-split` trailers, and squash-merged PRs drop them; every repo's second sync conflicted on byte-identical files, and rollcall's failed with "never added". Local edits are already forbidden by devkit-check.
**Decision**: `devkit-sync.sh` fetches the upstream ref and does `git rm -r devkit && git read-tree --prefix=devkit/ -u <tree>`, then writes `.devkit-rev` and commits. First vendoring is the same command.
**Consequence**: syncs are conflict-free and idempotent ("already current" is a no-op); `.devkit-rev` + `devkit-check` remain the only contract. Repos still carrying the old vendored script run `~/projects/solo/devkit/bin/devkit-sync.sh` once from their root.

## 2026-10-13 — devkit-check compares the index tree, not HEAD
**Why**: a consumer's pre-commit runs `ci-quick`, so `devkit-check` ran on the sync's own commit with
the new `.devkit-rev` staged and HEAD still holding the old tree: every first sync was refused
by its own hook (locus `own-commit`, 2026-10-13). Comparing HEAD also let a staged edit through.
**Decision**: `devkit-check.sh` hashes `devkit/` from the index (`git write-tree --prefix=devkit/`).
In CI the index equals HEAD; in the hook it is exactly what will be committed.
**Consequence**: syncs commit through the hook; consumers still on the old script need the
sync to land once (the hook runs the new vendored copy from the working tree).

## 2026-10-13 — devkit CI runs on docs-only PRs that touch what docs_check judges
**Why**: devkit once shipped without its CLAUDE.md symlink and broke every consumer's docs-check. CI already ran `docs_check` on devkit, but `paths-ignore: ['**.md', 'docs/**']` skipped exactly the PRs that change AGENTS.md, CLAUDE.md or docs/decisions.md, and devkit has no local gate to catch them.
**Decision**: the PR trigger is an ordered `paths` list: everything, minus markdown and docs/, plus `**/AGENTS.md`, `**/CLAUDE.md`, `docs/decisions.md`. workflows_check accepts `!**.md` in `paths`. The self-check step runs all three guards before failing. `config_contract.bats` pins the list.
**Consequence**: a README-only PR still bills nothing; an agent-docs PR bills one run.

## 2026-10-13 — Gate watchdog: a silent job log ends the run
**Why**: OrbStack paused its VM during an auto-update; a gate's pytest waited on Postgres with no timeout for an hour, holding the machine-wide flock while its log stopped growing.
**Decision**: `job()` backgrounds make under `set -m` (own process group, stdin from /dev/null) and polls its log size every second. Silent for `GATE_SILENT_MINUTES` (default 15, decimals allowed, 0 disables): TERM the group, KILL after 10s, post `error`, print `GATE <job> WATCHDOG (...)` and `VERDICT FAIL`, exit 2. The EXIT trap now also stops a running job, so a TERMed gate no longer waits for its job to finish.
**Consequence**: silence, not duration, is the signal: a 40-minute suite that keeps logging is never cut. A job that legitimately prints nothing for 15 min must log progress or the repo raises the variable. Exit 2 and `error` mark the box, not the code, as failed.

## 2026-10-13 — devkit-check reads .devkit-rev from the index too
**Why**: the tree side was already read from the index, but `.devkit-rev` came from disk, so an unstaged edit to it could vouch for a staged devkit/ tree it would never be committed with (and an unstaged stray edit failed a clean commit).
**Decision**: `git show :.devkit-rev`; missing from the index fails like a missing file. A bats case covers both directions.
**Consequence**: devkit-check judges exactly the commit being made, on both sides.

## 2026-10-13 — Reusable quick-check sets up Node only when the repo has `.nvmrc`

**Why:** homelab (bash, compose, one stdlib Python lint) adopts `make ci-quick` through this workflow and has no Node. The unconditional `setup-node` step fails a repo with no `node-version-file`.
**Decision:** The step runs under `if: hashFiles(inputs.node-version-file) != ''`. A Node repo that drops `.nvmrc` is still caught, by its own `toolchain_check`. A contract test pins the guard.
**Consequence:** Non-Node consumers call the same reusable workflow with no `.nvmrc` stub.

## 2026-10-13 — `devkit new`: templates rendered by one script, stacks as additive directories
**Why**: a new repo took weeks to reach the fleet's bar by copying from a sibling and drifting on the way (PLAN §1: "half a day instead of three weeks"). The `ci-*` names had to converge first; they have in six repos.
**Decision**: `bin/devkit-new.sh` renders `templates/new/common/` then `stacks/<stack>/` (placeholders plus `#@image`/`#@no-image` line blocks), vendors through `devkit-sync.sh --stage` so the scaffold and the vendored tree share ONE first commit, and makes that commit through the hooks: pre-commit runs `make ci-quick`, so every guard has judged the repo before it exists. The hooks, Renovate file and quick-check caller are copied from their one home, never re-typed. Stack choices follow the converged consumers: npm, not pnpm (closet, rollcall); `.python-version` 3.13; no `.nvmrc` in a Python-only repo (the reusable quick-check sets up Node only when `.nvmrc` exists).
**Consequence**: a tier a stack lacks is an `exit 2` stub the gate plan skips with a note, never a silent pass. `hooks_check.sh --fix` is bypassed for `core.hooksPath` because it no-ops under CI and the contract test runs there. Migrations (alembic), logging shape and Bugsink are the first things a real project adds; the scaffold stops at the health contract. `rust`, `next-vercel` and `swift-app` are new directories, not script changes.

## 2026-10-13 — Ratchet: the PR tightens, and the bounds file is held to main's copy
**Why**: the gate checks the merged tree, so `ratchet.json` was the PR's own copy and a hand edit loosened a bound with no label. `--tighten` was "main only", but nothing runs on main after a merge, and delivery.md says the improving PR tightens (phase3-plan §2.3–2.4).
**Decision**: owner decision A. `check` also loads main's bounds (`git show origin/main:<path>`, or `--base-bounds`) and fails on a looser bound, a flipped direction or a removed key unless `--rebaseline-ok`. An unresolvable base ref exits 2; a base without the file is first adoption. `check --tighten` is gone; `tighten` rewrites only improved bounds, run by the author. `merge` joins `build/metrics/*.json` and refuses a key from two collectors. Keys are domain-first (`docs/metrics-keys.md`), not finplat's area-first, so the domain fixes the direction. Starter bounds are `null` until `rebaseline`, so a raw copy never gates on coverage 0.
**Consequence**: supersedes the "`--tighten` only on main" line of the earlier ratchet entry. A PR that improves a number but skips `make metrics-tighten` passes and leaves slack, a cost decision A accepted. The Makefile is still read from the merged tree, so the label flag is as trustworthy as the gate plan model (2026-10-12).

## 2026-10-13 — docs_check warns on a missing "## Convention deltas" heading; it fails from 2026-11-01
**Why**: every convention says a project deviates only by a line under Convention deltas in its AGENTS.md, and six of seven repos had no such heading (phase3-plan §2.11).
**Decision**: check 5 in `docs_check.sh` looks for the exact `## Convention deltas` heading in the root AGENTS.md. It uses `docs_warn` for now, so no consumer's ci-quick breaks on sync.
**Consequence**: on 2026-11-01 a devkit PR flips it to `docs_fail` and its bats test to expect exit 1. Repos add the heading, or `None.`, in their Phase 3 PRs before then.

## 2026-10-13 — contract_probe.sh: the observability contract asserted at runtime, opt-in per flag
**Why**: release_check and BOOT_EXPECT_VERSION prove only the version; health shapes, request ids, log format and metric vocabulary drifted per repo (phase3-plan §1b), and finplat's dead JobFailed alert came from an outcome nobody checked at runtime.
**Decision**: one script, run on boot_image's BASE, with one flag per assertion so each repo opts in the PR that complies. It follows observability.md over the brief where they differ: health `status` is `up|down`, not `ok`, and a 12-hex inbound X-Request-ID must NOT come back ("never trust an inbound id"). Outcomes allow `interrupted|discarded` (decision C); log fields are the convention's `ts level logger msg version request_id`. Every assertion runs after a failure; logs run last. JSON goes through `python3 -I`, since jq is not on every box.
**Consequence**: the smoke must give `--json-log` the container name before `boot_image.sh down` removes it. `--proxy-404` takes a full public URL for post-deploy use; `--metrics` already sends X-Forwarded-For to the container.

## 2026-10-13 — `devkit new` stacks: `rust` (from redlib) and `next-vercel` (from rollcall)
**Why**: two converged repos had no scaffold: redlib (Rust, image) and rollcall (Next on Vercel, Drizzle).
**Decision**: `rust` takes redlib's exact `rust-toolchain.toml` pin (1.99.0), fmt + clippy `-D warnings` + `cargo test --locked`, and an Alpine release stage with the APP_VERSION trio; every cargo call goes through `scripts/ci/cargo.sh` (`rust_toolchain.sh`, then exec), so the hooks on a Rust-less Mac and devkit's reusable quick-check (no Rust step) compile with the gate's version. `next-vercel` takes rollcall's typegen/tsc/eslint, drizzle drift via `git status -- drizzle/`, `with_test_pg.sh` for db and e2e, and `next build` as ci-build; `STACK_IMAGE=0` makes `--no-image` implied. Its `.nvmrc` is rollcall's 24.21.0, not the fleet's 22.23.3: npm 10 (Node 22) crashes resolving this dependency set (`edgesOut` of null) and cannot `npm ci` npm 11's lockfile.
**Left out**: redlib's live-Reddit tests and cross-compiling builder; axum only, no DB tier. Rollcall's Neon preview-branch isolation, CSP, auth and seeding; Vercel preview checks. `next typegen` rewrites tsconfig.json to its own shape, so the template is byte-for-byte Next's output.
**Consequence**: a stack's `.gitignore` now appends to the common one (node-service had not ignored `node_modules/`). Rust quick-checks compile axum uncached (~1 min billed).

## 2026-10-13 — local_gate: GATE_SLOTS bounded concurrency, default 1
**Why**: the single machine-wide flock (2026-10-05: overlapping full suites failed timing tests) queued eight PR gates on the Mac serially for over an hour.
**Decision**: `GATE_SLOTS` (integer >= 1, default 1; junk is exit 2). With 1 the lock is exactly `$GATE_LOCK`, so running queues and linux-box keep sharing the file. With N the gate takes the first free `$GATE_LOCK.<n>` non-blocking, else prints the existing waiting line and polls each slot with `flock -w 5` (no strict FIFO; good enough for a handful of gates). It prints `GATE slot <n>/<N>`, a free-form line like plans' `GATE scope`.
**Consequence**: the merge queues and linux-box keep 1. A human raising it on a laptop accepts the 2026-10-05 timing-test risk. Mixing N=1 and N>1 gates on one box does not bound them together: they lock different files.

## 2026-10-13 — `devkit new` stack `swift-app` (from instalite); `.swift-version` pin; devkit CI on ready_for_review
**Why**: instalite's native half (XcodeGen, swift-format, Swift Testing on a simulator) is the iOS shape; a new app should start there. Nothing in it runs on Linux, and devkit's own ci.yml skipped drafts with no `ready_for_review` trigger, so a draft PR had no CI until its next push.
**Decision**: Swift-only (instalite's `web/` tier is its delta). `ci-guards` (devkit, toolchain, docs, release, workflows) is a target so Actions has one cheap Linux status (`STACK_QUICK_CHECK_TARGET`, appended to the copied caller as `make-target`); `ci-quick` adds `xcrun swift-format lint`; `ci-swift` builds and `ci-unit` tests on a simulator, gate only, never in a hook. Pin: `.swift-version` (swiftly's file), checked against `swift --version` on macOS on the file's precision and skipped elsewhere, since Linux runners ship an unrelated swift. Types use `__PASCAL_NAME__` (a dash is no Swift identifier). AGENTS.md's architecture line, Actions target and hook steps became stack-driven (hooks read from the repo's hooks.conf) instead of a per-stack AGENTS.md copy; `#@no-image-chosen` drops "adding an image" advice from `STACK_IMAGE=0` repos. `STACK_LOCK_CMD` is optional.
**Consequence**: an Xcode upgrade that moves Swift's minor fails toolchain-check until `.swift-version` moves with it, deliberately. `make` exits 2 for any failed recipe, so the bats stub checks only prove the stub fails with its message.

## 2026-10-13 — local_gate reads per-machine defaults from `~/.config/devkit/gate.env`
**Why**: eight lanes queued >1 h serially on 2026-10-13; telling each agent to set `GATE_SLOTS` did not stick, because every agent launches `make gate` from a fresh shell.
**Decision**: `local_gate.sh` parses (never sources) `${XDG_CONFIG_HOME:-$HOME/.config}/devkit/gate.env` before validating: only `GATE_SLOTS=` / `GATE_SILENT_MINUTES=` lines with plain values, blanks and `#` comments; anything else exits 2 naming the line. An allowlist rather than `GATE_*`: `GATE_LOCK`/`GATE_PLAN` in a file would silently split the lock or swap the plan. A non-empty environment variable wins over the file.
**Consequence**: one file per laptop sets its slot count. The merge queues and linux-box never create it, so they keep 1 and the shared lock path.

## 2026-10-13 — Hooks provision the pinned Node and Rust through the gate's code; cargo summaries are summed
**Why**: redlib's hooks failed on the Mac, which has no Rust, while the gate passed: only `local_gate.sh` put the pins on PATH, so redlib's `hooks.conf` grew its own `rust_toolchain.sh` call (redlib #8). A passing cargo step's one-line summary showed the last `test result:` line, the doctests' `0 passed`, not the unit count.
**Decision**: the gate's inline provisioning moved to `bin/toolchain_path.sh` (`toolchain_path <tree>`), sourced by both `local_gate.sh` (merged worktree, same output and verdicts) and `hook_steps.sh` (the hook's checkout, before the first step, never for a push with nothing to check). A pin it cannot provide blocks the hook. Python is left out: `uv run`/`uv sync` read `.python-version` themselves. `quiet_run.sh` sums every cargo `test result:` line into `cargo test: <n> passed; <m> ignored (<k> suites)`.
**Consequence**: `hooks.conf` lists steps only. redlib drops its PATH block from `hooks.conf` in its next PR (it is harmless until then: PATH's cargo already matches, so provisioning prints nothing). The rust stack's `scripts/ci/cargo.sh` stays, since Actions' quick-check runs `make` without a hook. `devkit new` runs the lock step on the pins too. new_contract's fakes need a `node` matching `.nvmrc`, or the pinned real npm shadows the fake one.

## 2026-10-13 — `make gate` runs on the gate host when the machine says so (gate.sh, remote_gate.sh)
**Why**: Mac gates queued for over an hour on 2026-10-13. linux-box already runs finplat's merge queue and `local_gate.sh` from checkouts, so finplat, Orbit and locus gates belong there.
**Decision**: `make gate` calls `gate.sh`, which picks `remote_gate.sh` when `GATE_REMOTE_HOST` is set (env, else `gate.env`), unless the plan has `GATE_REMOTE=0` (a Mac-only gate) or `GATE_REMOTE=0` is set. The remote side clones with `gh`, resets to `origin/main` under a per-checkout flock (the plan is read from there), and runs the vendored `local_gate.sh`, so output contract, exit code and status posting are unchanged. Its state lives in `$GATE_REMOTE_ROOT/.state`, because the host queue gates the same repos from another checkout with the same worktree names. Only `<pr>` and `--no-post` cross ssh: the host keeps its own `GATE_SLOTS`.
**Interrupts**: ssh's stdin is a fifo held open by a `sleep`; the host treats EOF as "client gone" and sends TERM to the gate, whose trap posts `error`. Without it, an orphaned gate held the host's lock to the end.
**Consequence**: switching a repo is one Makefile line plus one `gate.env` line per Mac. `gate.env` has one parser, `_gate_env.sh`: `local_gate.sh` now uses it and skips the `GATE_REMOTE*` lines (its own inline loader from the entry above rejected them, so a Mac naming a host failed every local gate). Untested against the real host until the Mac's ssh key is authorized (README checklist).

## 2026-10-13 — APP_VERSION is the bare sha7; only image tags carry `sha-`
**Why**: the 2026-10-13 release brief wrote `sha-<7>` as the version, so the publish template
passed it as APP_VERSION and the OCI label while observability.md says the bare 7-char sha.
Every repo built from it reported `sha-abc1234`; fixed fleet-wide in closet #381, locus #100,
Orbit #52, redlib #8 and finplat #628.
**Decision**: the version step outputs `${GITHUB_SHA::7}`; the metadata tag adds `sha-` itself.
Local builds default to the bare sha too. `release_check.sh` fails a workflow line that sets a
version, build arg or label to `sha-…`.
**Consequence**: image `sha-<7>`, version `<sha7>`, ship tag `ship-<date>-<sha7>`.

## 2026-10-13 — local_gate: per-job and whole-gate time budgets; job seconds into the metrics snapshot
**Why**: owner directive 2026-10-13: a fast, lean suite with hard budgets (whole gate ≤ 10 min, no job > 5 min) that the tooling enforces and that only ever gets faster.
**Decision**: `GATE_JOB_BUDGET_MINUTES` (5) and `GATE_BUDGET_MINUTES` (10, counted once a slot is held), from the env or gate.env. An over-budget job runs to completion (the watchdog owns hangs, a budget never kills real work), then `GATE <job>|total OVERBUDGET (<n>s > <b>s)`; VERDICT FAIL with "Over budget: …" in the status, unless `GATE_BUDGET_ENFORCE=0` (adoption: lines and a note, verdict PASS). After each job the gate rewrites `build/metrics/gate.json` (`gate.<job>.seconds`, then `gate.total.seconds`) so a last metrics job can merge them; a copy stays in the log dir.
**Consequence**: job names must be `[A-Za-z0-9_-]+` and not `total` (exit 2); every current plan complies. A gate host's budgets come from its own gate.env, like `GATE_SLOTS`. Timings are noisy and the ratchet has no tolerance, so a tracked `gate.*` bound is set with headroom by hand, not `tighten`.

## 2026-10-13 — devkit-sync vendors only `VENDOR_PATHS`
**Why**: consumers vendored the whole tree, including `templates/new/` (five stack scaffolds with .ts/.py/.rs sources) and `tests/`. closet's typecheck compiled the scaffolds and broke (#382 excluded devkit/ from tsconfig as a patch).
**Decision**: one manifest, `VENDOR_PATHS` at the root, read by `bin/_vendor_paths.sh` for both sides: devkit-sync builds the filtered tree in a throwaway index and records its hash in `.devkit-rev` (format unchanged); devkit-check also fails when the vendored tree is not its own filtered form, which is how a full tree from a pre-manifest sync shows up. A manifest path matching nothing is exit 2 (a rename must not silently drop out of every consumer). An upstream ref without the manifest is vendored whole.
**Consequence**: every consumer runs `make devkit-sync` once after this merges; the first run is the old script and vendors the whole tree, which the new pre-commit devkit-check refuses with "run make devkit-sync", and the second (new) run slims it. The sync no longer treats uncommitted changes under `devkit/` or `.devkit-rev` as dirty, since it replaces exactly those. Running `~/projects/solo/devkit/bin/devkit-sync.sh` from the repo root does it in one step.


## 2026-10-13 — uv stops .python-version discovery at the project boundary
**Why**: uv looks for `.python-version` in the working directory and its parents but not beyond the project or workspace boundary. finplat and Orbit keep the pin at the repo root while their uv project is `backend/pyproject.toml`, so `cd backend && uv sync` fell back to `requires-python >=3.13`. When uv 0.13.0 (2026-10-09) made 3.15 its default, CI downloaded CPython 3.15 and built pandas, pydantic-core, numpy, asyncpg and others from source. finplat's quick check took 15–19 min per PR (12 in pandas) and Orbit's 3.5 min, and tests had been running on an unpinned Python for weeks. locus has its pyproject at the root and was not affected.
**Decision**: `toolchain_check` requires every `<dir>/pyproject.toml` one level down to have `<dir>/.python-version` as a regular file holding exactly the root's string. The root file stays the declaration; subproject copies are enforced mirrors, like Dockerfile tags. No symlinks, because a link dangles inside images that COPY `backend/` wholesale (Orbit's runtime stage).
**Consequence**: finplat and Orbit add `backend/.python-version` in their own PRs before syncing this devkit. A Python bump edits the root and every mirror together, and the check names any copy that was missed. Root-pyproject repos (locus, the python-fastapi template) need nothing new.

## 2026-10-13 — Hook steps scope themselves by changed paths
**Why**: owner directive 2026-10-13: an AGENTS.md change should not wait on every test, a backend change not on frontend tests. The gate plans already scope jobs by path; `hooks.conf` steps ran unconditionally, so an AGENTS.md-only finplat commit ran the full vitest in pre-push and failed on a load flake.
**Decision**: a step may end in `:unless=<globs>` (skip when every changed path matches) or `:only=<globs>` (run when one does). Globs are `case` patterns, `*` crossing `/`, exactly as in the gate plans, so a conf mirrors its plan. Changed paths are the staged paths, or every path touched by the pushed ranges. A rename counts both of its paths. A merge counts only what it changed against every parent (dense combined diff), so merging main into a docs branch stays docs-only. No paths: `only` skips, `unless` runs. If git cannot list them, everything runs. A skip prints `– <label> skipped (<why>)`. One parser (`_hook_parse_step`) serves the hook and `hooks_check`, and every step is parsed before any runs.
**Consequence**: filters only remove work; the PR gate stays authoritative. Each consumer adds filters to its `hooks.conf` in its next devkit-sync PR, mirroring its gate plan (proposed lines in devkit's PR). A step with no suffix behaves as before.

## 2026-10-13 — Hook scoping defaults live in devkit; hooks.conf overrides are the exception
**Why**: owner 2026-10-13, on the entry above: "this scoping problem will happen for every project". Per-repo filters would be re-derived, and drift, in every repo, and every new one starts unscoped.
**Decision**: `hook_steps.sh` classifies each changed path (docs = `docs/*`, `*.md`; backend = `backend/*`, `server/*`; frontend = `frontend/*`, `web/*`; else other) and each step by its target's words in either order (finplat `ci-backend-unit`, Orbit `ci-unit-backend`). Backend steps skip when every path is docs or frontend, and frontend steps mirror that. Docs steps run only on docs, and any other step skips only on docs-only changes. A docs-only change with no docs step listed runs `make docs-check` itself. The `:unless=`/`:only=` suffixes, plus `:always`, override one step where a layout deviates.
**Consequence**: consumers get scoping with their next devkit-sync and no conf change. A step that ran on every commit now skips on docs-only ones (`:always` restores it). A locus fixture under `docs/rule-fixtures/` reads as docs, so locus may override `ci-unit`. The gate stays authoritative. The target-naming split (`ci-<area>-unit` vs `ci-unit-<area>`) remains, and both orders match.

## 2026-10-13 — Hook scoping (amends "Hook steps scope themselves by changed paths"): one fleet layout table
**Why**: owner rule: scoping belongs to devkit, because "we fix it per repo but this scoping problem will happen for every project". The first defaults knew only docs/backend/frontend dirs, so locus's root-level Python project, Orbit's `specs/` and `e2e/`, docs_oversize.txt and the macOS dirs still needed per-repo overrides.
**Decision**: `_hook_classify` holds the one table, derived from the five gate plans, with each entry naming its repo. docs adds `specs/` and `scripts/ci/docs_oversize.txt`. backend adds `tests/`, `alembic*`, root `pyproject.toml`/`uv.lock` and locus's `docs/sync-wire-fixtures/`. frontend adds `e2e/`, and locus's `docs/rule-fixtures/` counts as other. A new native area (`ios/`, `OrbitAgent/`, `*.xcodeproj/`) is skippable for every target. A native-only change runs nothing and prints one line. Docs plus native still runs docs-check.
**Consequence**: no consumer needs an override for correctness. A layout outside the table gets a per-step override in its own hooks.conf, and an entry here only when it becomes fleet convention, since every entry classifies every repo.

## 2026-10-13 — Standard docs set, kept honest by docs-check
**Why**: owner directive: standard docs across every repo, kept up to date by devkit. The survey found every repo with a README and a decisions log, but no two READMEs with the same sections, undated or Why-less decision entries, and nothing checking that documented `make` targets or links still exist.
**Decision**: required set is README.md (Getting started, Commands, Architecture, Deploy, Documentation; aliases are the names the fleet already used), AGENTS.md + CLAUDE.md, dated docs/decisions.md, and architecture in docs/architecture.md or AGENTS.md "## Architecture" (one home). `docs_check.sh` rules 6-10 also hold README/AGENTS.md `make` words to the Makefile and relative links to the index. Observability and testing docs stay recommended: the fleet has no common shape for them.
**Decision**: new rules report through `docs_rule <date>`, warning before the date and failing from it with no second PR; dates live at the top of docs_check.sh. Docs set fails from 2026-11-15; the Convention deltas rule moves onto it, keeping 2026-11-01 (this supersedes its "a devkit PR flips it").
**Consequence**: `devkit new` emits README.md and docs/architecture.md and its scaffold is warning-free under a 2099 date (new_contract.bats). Consumers see warnings on their next devkit-sync and fix them in a docs lane before 2026-11-15.

