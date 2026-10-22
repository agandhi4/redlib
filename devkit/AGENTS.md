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
  Mac, bats runs under /bin/bash 3.2, where a false `[[ … ]]` that is not a test's last line
  passes silently: a Mac run is a smoke test, CI (bash 5, mawk) is the verdict.

## Architecture
Scripts in `bin/` and the shared metrics collectors in `metrics/`, vendored by consumers (the
paths in `VENDOR_PATHS`); fleet operations in `github/`; `devkit new` scaffolds in `templates/new/`; contract tests in `tests/`. The path map
is README.md "Architecture". Invariants of the design:
- Output contracts are APIs. `bin/local_gate.sh` prints `GATE <job> PASS|FAIL|SKIPPED|WATCHDOG|OVERBUDGET …` and
  `VERDICT PASS|FAIL head=<sha> main=<sha>`; `finplat_merge_queue.sh`, `mac_merge_queue.sh`
  and `worker.py` parse them. `bin/tier_guard.sh` prints `TIER <tier>: …|FAIL|FLOOR|OVERBUDGET …`
  and exits with the command's code, 1 for its own verdict, 2 for a bad call. The gate's outcome
  record (`logs/<pr>/gate.json`, `runs.tsv`; README "Gate record") is an API too. `.devkit-rev` is `<upstream commit> <tree sha>`,
  the tree filtered to `VENDOR_PATHS`. A new file consumers run must sit under a listed path.
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
- Every repo's `gate` target is `devkit/bin/gate.sh "$(PR)" $(GATE_ARGS)`. Where gates run is
  per machine (`GATE_REMOTE_HOST` in `~/.config/devkit/gate.env`), never per repo, except a plan's
  literal `GATE_REMOTE=0` for a gate only a Mac can run.
- Fail loudly on a missing tool (`flock`, `gh`) with the install hint; never degrade silently.
- `ci-metrics` is `bin/metrics_collect.sh` over the repo's `scripts/ci/metrics.conf`, run as
  the gate's last job and nowhere else (not a hook, not Actions). Bounds never track `gate.*`,
  `tier.*` or `tests.*`; a collector that cannot run is exit 2, never a silent skip.

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
