# devkit — agent rules

Shared scripts vendored into every app repo by `bin/devkit-sync.sh` (only the paths in `VENDOR_PATHS`). Read `README.md` first.

**Purpose (owner, 2026-10-16): devkit is for agents.** Every mechanism here makes an agent's
work cheaper (fewer tokens and turns per merged PR), faster (less wall-clock to a green gate) or
better (defects caught before merge), and its decisions entry names which axis and the number
that shows it. Prefer `--report` summaries, SKIP lines and one-line verdicts over logs an agent
must read; guards in ci-quick (seconds) over gate jobs (minutes). A mechanism that costs an
agent more than it catches is overhead, not standardization.

## Stack
- Portable shell: macOS bash 3.2 + GNU bash; BSD + GNU coreutils. Empty arrays under `set -u`
  use `${a[@]+"${a[@]}"}`. No `readarray`, no `declare -A`, no GNU-only `sed -i` without `''`.
- `shellcheck -s bash` (0.11) clean; `bats tests/` green before any push. CI runs both. On a
  Mac, bats runs under /bin/bash 3.2, where a false `[[ … ]]` or `(( … ))` mid-test fails
  nothing (and `! cmd` or a test before `&&`, as in `[ a ] && [ b ]` or `grep -q a f && grep -q
  b f`, never does, on any bash): every such assertion ends `|| false` straight after the
  test, unless it is its function's last line. ci-lint holds it
  (`bin/bats_assert_check.py`, a line-level form, not a parser: grow its grammar, never a
  lexer; `--fix` appends the handler).
- A bats file's git fixture (bare origin, clones, commits, fakes), and a `devkit new` scaffold,
  is built once in `setup_file` and copied per test (`tests/fixture_template.bash`): built per
  test it was a fifth of the unit tier's CPU. Every `tests/*.bats` is in `tests/shard_costs.tsv`,
  at its share: `tests/shards.sh` fails the run otherwise (`make shard-costs`, on a quiet box).
  A share is judged only on an uncontended run (no pool units held by others, the load less the
  run's own running shards within capacity, at every file boundary; one `shards: drift …` line
  says which it was); beside other work drift is a `shards: note:`, never a failure. A test steps
  a polling loop by hand (a tick command, a faked `sleep`), never by sleeping and counting lines.
  A test never reads the box's live load or sizes a wait by it: seconds a budget, watchdog or
  queue judges come from `devkit_now`'s clock (`DEVKIT_CLOCK_CMD`, `tests/clock_helpers.bash`),
  a stand-in holder ends on a signal the test sends once it has seen the waiter wait, and the one
  real sleep in a file is the one that proves the default clock is wall time, with a comment
  saying so.

## Architecture
Scripts in `bin/` and the shared metrics collectors in `metrics/`, vendored by consumers (the
paths in `VENDOR_PATHS`); fleet operations in `github/`; `devkit new` scaffolds in `templates/new/`; contract tests in `tests/`. The path map
is README.md "Architecture". Invariants of the design:
- Output contracts are APIs. `bin/tier_guard.sh` prints `TIER <tier>: …|FAIL|FLOOR|OVERBUDGET|NOSHIFT …`
  and exits with the command's code, 1 for its own verdict, 2 for a bad call. `.devkit-rev` is `<upstream commit> <tree sha>`,
  the tree filtered to `VENDOR_PATHS`. A new file consumers run must sit under a listed path.
  The lint bases' exports are APIs too (`lint/exports.txt`): one leaves only after 30 days marked
  deprecated there, since repo-owned configs import them and devkit-sync cannot edit those.
  Every squash body's `Kind: product|tooling` and `Kind-By: label|kit|sync|bot` trailers
  (merge_rules.sh) are one too, and so is `<state>/devkit/scorecard/output.json`, which every
  `scorecard.py --fleet` writes for the floor gate to read: `{"date", "window_days": 30,
  "fleet": {"repos", "commits", "product", "share", "tokens": {"product", "tooling", "share"} |
  {"unmeasured"}, "floor", "declared", "declared_min", "judged_product", "judged_share",
  "missing", "status": PASS|FAIL|UNMEASURED, "verdict" (= status)}, "repos": {<name>: {"days", "commits",
  "product", "share", "kit", "declared"/"inferred"/"judged": {"product", "tooling"}, "tokens"} |
  {"unmeasured"}}}`. Add fields, never rename one.
- A kind is declared or deterministic, never guessed (2026-11-05): `make merge` refuses a non-kit
  PR that is no devkit sync or bot PR and has no `kind/*` label, and `make pr` wants `KIND=`.
  Only `Kind-By:` commits are judged. Below the fleet's product floor a kit (`GATE_KIT=1`)
  merges only a sync, a bot's PR, `Unblocks: <owner/repo>#<n>` (an open product issue) or
  `Fixes: #<n>` (an open `bug` here); a stale (> 7 d) or missing cache is UNMEASURED, which
  waits too. An agent never uses `OWNER=` to pass it.
- The skeleton owns mechanics; the repo's `scripts/ci/gate_plan.sh` declares its jobs. Which
  paths run which group is devkit's (`bin/_paths_lib.sh`: one table for hooks and gate,
  `devkit_default_gate_plan`); a repo adds only its own rules in `gate_plan_extra`. A new
  mechanic belongs here; a new check belongs in the repo's Makefile.
- Every gate job is a Makefile target the repo's workflows also call. Parity is structural.
- One version string per toolchain per repo: `.nvmrc`, `.python-version`, `rust-toolchain.toml`,
  all exact. CI reads them (`*-version-file`). The gate (from the MERGED tree) and the hooks
  provision them through `toolchain_path.sh`, the one code path; never inline it again.
  `toolchain_check.sh` holds Dockerfiles, workflows and manifests to them. Never pin a
  toolchain version anywhere else. A package manager's pin is `package.json`'s `packageManager`
  (`package_manager_toolchain.sh`, after Node): recipes call bare `pnpm`, never `corepack`.
- devkit's own .py tools run on `"$DEVKIT_PYTHON"` (`devkit_python`, `bin/_toolchain_lib.sh`) in
  bin/*.sh and on `bin/python.sh` in Makefiles, never a bare `python3`: under launchd that is
  Xcode's 3.9 (tests/toolchain_resolver.bats greps for it). The resolution is made once per
  process tree (`DEVKIT_PYTHON_RESOLVED`, exported with the source and version): never re-probe
  an inherited one, and never unset the marker while keeping `DEVKIT_PYTHON`.
- A tool a gate job calls by bare name that this Mac installs off launchd's PATH is found by
  `_toolchain_lib.sh` (`devkit_tool`, one entry in `DEVKIT_TOOLCHAIN_TOOLS` plus its marker in
  `devkit_declared_tools`) and linked alone into the toolchain directory, never a second
  resolver and never an interpreter's whole bin/. The gate preflight (`devkit_preflight`) names
  every missing tool in one error.
- `make merge` runs origin/main's `merge_rules.sh` and plan (`bin/pr_merge.sh` extracts them), never
  the checkout's: a rule a branch changes governs merges only once it is on main. `make review`
  runs main's `review_rules.sh` the same way.
- No pre-merge gate (owner 2026-11-02): `make merge` decides on review rounds (`codex_review.py`
  docstring), never on `local-gate`, a moved main or a running Codex review. The cap is the plan's
  `DEVKIT_REVIEW_ROUNDS` (default 3), never an environment value. Below the cap, P0/P1
  findings block; at the cap only P0 does, and P1 and below are filed as issues at the merge. A local round is only
  ever `make review`'s record (the gh shim refuses the marker without `DEVKIT_REVIEW_VERIFIED`);
  never hand-post one. `OWNER=` is the owner's, at a terminal; an agent never tries it.
- Main is proven at deploy: `bin/publish.sh` runs `bin/check_tree.sh` (every job of the commit's
  plan, clean worktree) on every new main, whatever it changes, and publishes only the newest green
  commit, never a red one, filing one `main-red` issue per first bad commit. Image inputs decide
  only the build: a green commit with none is `checked` (green recorded, `main-red` closed), never
  skipped unchecked. Only correctness fails a check: a flake is retried once
  and files `flaky`; ratchets and budgets report or file issues, never fail it. `--ungated` is the
  owner's alone. Every plan declares `DEPLOY_KINDS=` (README "Deploy kinds"; the scorecard's
  `deploy_kinds`), so every kind the publisher does not prove is proven on the Mac. check_tree
  prints `CHECK <job> PASS|FAIL|REPORTED|SKIPPED …` and `CHECK VERDICT PASS|FAIL head=<sha>` (an
  API, like the gate's). A repo's checks start at most once per window
  (`bin/_cadence_lib.sh`: the plan's `MAIN_CHECK_MINUTES`, default 180, at the slug's own minute),
  never an environment knob; `--recheck`/`--ungated` are the urgent path; anything else that
  checks main on a schedule uses the same lib.
- A problem with the box never reads as a bad commit: docker down, or a job failing its run and
  retry with a cause in check_tree's one `ENV_CAUSES` list (an OS or daemon message, or a build
  script naming a host tool or library the box lacks: cmake, libclang, an sdist's C headers), is
  exit 2 and records nothing. A red record expires after 24 h (`publish.sh --recheck <sha>` sooner),
  a green commit closes `main-red`, a job is a FAIL after `CHECK_JOB_SECONDS` (1800), and the Mac's
  hourly `publisher_deadman.sh` (GitHub only) files `publisher stalled` when linux-box stops
  publishing.
- Every main the publisher does not prove is proven on the Mac: `bin/main_check.sh` (one
  LaunchAgent, each repo once per cadence window, in its own clone of the repo, never the
  checkout lanes share) runs check_tree at a new main of every plan but
  `DEPLOY_KINDS=image` alone (ios, mac, hosted, library, tooling; devkit's own), posts the verdict
  as the commit's `main-check` status (`_commit_status_lib.sh`, the one context name), and files
  and closes only its own `main-red` issues (`main is red on the Mac at …`, `_issue_lib.sh`).
  A plan's `DEPLOY_BRANCH=<branch>` is fast-forwarded to each green main, never forced: the one
  way a host that deploys a branch (rollcall's Vercel production) ships only checked commits.
- The nightly devkit sync (`bin/dependency_merge.sh`) is weekly: a repo syncs only once its
  `.devkit-rev` commit is `SYNC_MIN_AGE_DAYS` (7) older than the green target by commit date, or
  the oldest pending devkit commit is that old by the run's clock.
  An urgent devkit fix puts a line `Devkit-Sync: now` in its PR body (the squash commit message)
  to sync the fleet that night; never a line of its own otherwise. `make devkit-sync` by hand
  syncs any time.
- A launchd job runs devkit main's copy of itself: its plist starts the job dir's `launcher.sh`
  (`bin/job_launcher.sh`, installed by `bin/_launchd_job_lib.sh`), never a path in a checkout, so
  a devkit merge reaches the next run with no fast-forward. A new job goes through the same lib.
- `bin/gate.sh` is the retired gate's stub (2026-11-02): one line naming `make review` and
  `make merge`, exit 0, so a consumer's old `gate` target never fails. Never grow it back.
- Fail loudly on a missing tool (`flock`, `gh`) with the install hint; never degrade silently.
- Time budgets (a job's, a tier's) report and never fail (owner 2026-10-29); correctness (tests, floors,
  ratchets) still fails. Never make a budget fail a PR again.
- Test work on the box queues in one place: `bin/_slot_lib.sh`'s pool at its fixed path, every
  tier and every check_tree job admitted for its cost. A new entry point that runs suites goes through it (`slot_acquire`),
  never its own lock. A job's cost is the table's (`_slot_word_cost`); a plan `GATE_JOB_COSTS`
  entry is for what the table misprices.
- A pytest or vitest tier must not rot with real time: the plan reruns it shifted (`GATE_JOBS_CLOCK`, README
  "Clock shift"), and what a shift cannot reach is a `scripts/ci/clock_shift.conf` line with its reason.
- `ci-metrics` is `bin/metrics_collect.sh` over the repo's `scripts/ci/metrics.conf`, run as
  the gate's last job and nowhere else (not a hook, not Actions). Bounds never track `gate.*` or
  `tier.*`; `tests.<tier>.<runner>` is the tier's floor, which tier_guard reads and tighten raises
  (never a Makefile number); a collector that cannot run is exit 2, never a silent skip.

## Commands
```sh
make ci-quick                  # shellcheck, python + template unit tests (npm), devkit's own guards and ruff (ci-lint) on itself
make ci-unit                   # bats tests/ (~2 min)
make ci-metrics                # the ratchet over devkit's own shell (scripts/ci/metrics.conf, docs/metrics/ratchet.json)
make review PR=<n>             # one local review round: claude -p over the diff, its record posted on the PR
make merge PR=<n>              # squash-merge once the review rounds allow it (DEVKIT_REVIEW_ROUNDS, default 3)
bin/docs_check.sh --report .   # the docs numbers behind the diet rules; --fix does the mechanical moves
python3 -I bin/bite.py --days 30 <repo>   # BITE: hook runs and fails by step
make scorecard REPOS='~/projects/solo/finplat …'   # the fleet scorecard (bin/scorecard.py)
make agent-cost                # append this project's merged-PR costs to docs/agent-cost.tsv (bin/agent_cost.py)
```

## Workflow
- `make install` once per checkout (core.hooksPath=.githooks): pre-commit runs ci-lint (ruff
  and changed_lint.py's held rules), shellcheck, the guards and the staged secrets scan,
  pre-push the python tests (scripts/ci/hooks.conf).
- Branch, PR, a review round (`@codex review`, or `make review PR=<n>` when Codex is out of
  budget), answer its findings once (push fixes, or reply and resolve), then `make merge PR=<n>`
  with a descriptive sentence title. Consumers pick it up with
  their `devkit-sync` target; a devkit change that needs plan changes ships as devkit PR first, then
  one PR per consumer.
- A lane's worktree lives at `.claude/worktrees/<branch>`, never beside the checkout; run
  `make merge` from the main checkout, which then removes the lane's worktree and local branch
  (a merge run inside the lane's worktree leaves it, with the command to remove it).
- Record decisions in `docs/decisions.md` in the same PR (`## YYYY-MM-DD — title`, Why /
  Decision / Consequence, ≤ 8 lines).

## Convention deltas
- None. devkit ships no running service, so `observability.md` does not apply to it.
