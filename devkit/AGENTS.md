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
  nothing (and `! cmd` or `[ a ] && [ b ]` never do, on any bash): every such assertion ends
  `|| false` straight after the test, unless it is its function's last line. ci-lint holds it
  (`bin/bats_assert_check.py`, a line-level form, not a parser: grow its grammar, never a
  lexer; `--fix` appends the handler).
- A bats file's git fixture (bare origin, clones, commits, fakes) is built once in `setup_file`
  and copied per test (`tests/fixture_template.bash`): built per test it was a fifth of the unit
  tier's CPU. Every `tests/*.bats` is in `tests/shard_costs.tsv`, at its share: `tests/shards.sh`
  fails the run otherwise (`make shard-costs`, on a quiet box).

## Architecture
Scripts in `bin/` and the shared metrics collectors in `metrics/`, vendored by consumers (the
paths in `VENDOR_PATHS`); fleet operations in `github/`; `devkit new` scaffolds in `templates/new/`; contract tests in `tests/`. The path map
is README.md "Architecture". Invariants of the design:
- Output contracts are APIs. `bin/local_gate.sh` prints `GATE <job> PASS|FAIL|SKIPPED|WATCHDOG|OVERBUDGET …` and
  `VERDICT PASS|FAIL head=<sha> main=<sha>`; `finplat_merge_queue.sh`, `mac_merge_queue.sh`
  and `worker.py` parse them. `bin/tier_guard.sh` prints `TIER <tier>: …|FAIL|FLOOR|OVERBUDGET|NOSHIFT …`
  and exits with the command's code, 1 for its own verdict, 2 for a bad call. The gate's outcome
  record (`logs/<pr>/gate.json`, `runs.tsv`; README "Gate record") is an API too. `.devkit-rev` is `<upstream commit> <tree sha>`,
  the tree filtered to `VENDOR_PATHS`. A new file consumers run must sit under a listed path.
  The lint bases' exports are APIs too (`lint/exports.txt`): one leaves only after 30 days marked
  deprecated there, since repo-owned configs import them and devkit-sync cannot edit those.
- The skeleton owns mechanics; the repo's `scripts/ci/gate_plan.sh` declares its jobs. Which
  paths run which group is devkit's (`bin/_paths_lib.sh`: one table for hooks and gate,
  `devkit_default_gate_plan`); a repo adds only its own rules in `gate_plan_extra`. A new
  mechanic belongs here; a new check belongs in the repo's Makefile.
- Every gate job is a Makefile target the repo's workflows also call. Parity is structural.
- One version string per toolchain per repo: `.nvmrc`, `.python-version`, `rust-toolchain.toml`,
  all exact. CI reads them (`*-version-file`). The gate (from the MERGED tree) and the hooks
  provision them through `toolchain_path.sh`, the one code path; never inline it again.
  `toolchain_check.sh` holds Dockerfiles, workflows and manifests to them. Never pin a
  toolchain version anywhere else.
- devkit's own .py tools run on `"$DEVKIT_PYTHON"` (`devkit_python`, `bin/_toolchain_lib.sh`) in
  bin/*.sh and on `bin/python.sh` in Makefiles, never a bare `python3`: under launchd that is
  Xcode's 3.9 (tests/toolchain_resolver.bats greps for it).
- A tool a gate job calls by bare name that this Mac installs off launchd's PATH is found by
  `_toolchain_lib.sh` (`devkit_tool`, one entry in `DEVKIT_TOOLCHAIN_TOOLS` plus its marker in
  `devkit_declared_tools`) and linked alone into the toolchain directory, never a second
  resolver and never an interpreter's whole bin/. The gate preflight (`devkit_preflight`) names
  every missing tool in one error.
- `make merge` runs origin/main's `merge_rules.sh` and plan (`bin/pr_merge.sh` extracts them), never
  the checkout's: a rule a branch changes governs merges only once it is on main.
- A launchd job runs devkit main's copy of itself: its plist starts the job dir's `launcher.sh`
  (`bin/job_launcher.sh`, installed by `bin/_launchd_job_lib.sh`), never a path in a checkout, so
  a devkit merge reaches the next run with no fast-forward. A new job goes through the same lib.
- Every repo's `gate` target is `devkit/bin/gate.sh "$(PR)" $(GATE_ARGS)`. Where gates run is
  per machine (`GATE_REMOTE_HOST` in `~/.config/devkit/gate.env`), never per repo, except a plan's
  literal `GATE_REMOTE=0` for a gate only a Mac can run.
- Fail loudly on a missing tool (`flock`, `gh`) with the install hint; never degrade silently.
- Test work on the box queues in one place: `bin/_slot_lib.sh`'s pool at its fixed path, every gate
  job and hand-run tier admitted for its cost. A new entry point that runs suites goes through it
  (`slot_acquire`), never its own lock; a job the cost table misprices gets a plan `GATE_JOB_COSTS` entry.
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
make gate PR=<n>               # all three, on the PR merged into origin/main; posts `local-gate`
make merge PR=<n>              # squash-merge, refused unless the current head has local-gate success
bin/docs_check.sh --report .   # the docs numbers behind the diet rules; --fix does the mechanical moves
python3 -I bin/gate_bite.py --days 30 <repo>   # BITE: gate fails by rule, hook fails, unguarded merges
make scorecard REPOS='~/projects/solo/finplat …'   # the fleet scorecard (bin/scorecard.py)
make agent-cost                # append this project's merged-PR costs to docs/agent-cost.tsv (bin/agent_cost.py)
```

## Workflow
- `make install` once per checkout (core.hooksPath=.githooks): pre-commit runs ci-lint (ruff
  and changed_lint.py's held rules), shellcheck, the guards and the staged secrets scan,
  pre-push the python tests (scripts/ci/hooks.conf).
- Branch, PR, `make gate PR=<n>` green (the `local-gate` status is the merge signal; Actions is
  a second opinion and has been billing-blocked), `make merge PR=<n>` with a descriptive
  sentence title. Consumers pick it up with
  their `devkit-sync` target; a devkit change that needs plan changes ships as devkit PR first, then
  one PR per consumer.
- Record decisions in `docs/decisions.md` in the same PR (`## YYYY-MM-DD — title`, Why /
  Decision / Consequence, ≤ 8 lines).

## Convention deltas
- None. devkit ships no running service, so `observability.md` does not apply to it.
