# devkit — agent rules

Shared scripts vendored into every app repo by `bin/devkit-sync.sh` (only the paths in `VENDOR_PATHS`). Read `README.md` first.

## Invariants
- Portable shell: macOS bash 3.2 + GNU bash; BSD + GNU coreutils. Empty arrays under `set -u`
  use `${a[@]+"${a[@]}"}`. No `readarray`, no `declare -A`, no GNU-only `sed -i` without `''`.
- `shellcheck -s bash` clean; `bats tests/` green before any push. CI runs both.
- Output contracts are APIs. `bin/local_gate.sh` prints `GATE <job> PASS|FAIL|SKIPPED|WATCHDOG|OVERBUDGET …` and
  `VERDICT PASS|FAIL head=<sha> main=<sha>`; `finplat_merge_queue.sh`, `mac_merge_queue.sh`
  and `worker.py` parse them. `.devkit-rev` is `<upstream commit> <tree sha>`,
  the tree filtered to `VENDOR_PATHS`. A new file consumers run must sit under a listed path.
- The skeleton owns mechanics; the repo's `scripts/ci/gate_plan.sh` owns policy (which jobs
  for which paths). A new mechanic belongs here; a new check belongs in the repo's Makefile.
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

## Workflow
- Branch, PR, squash-merge with a descriptive sentence title. Consumers pick it up with
  `make devkit-sync`; a devkit change that needs plan changes ships as devkit PR first, then
  one PR per consumer.
- Record decisions in `docs/decisions.md` in the same PR (`## YYYY-MM-DD — title`, Why /
  Decision / Consequence, ≤ 8 lines).

## Convention deltas
- None. devkit ships no running service, so `observability.md` does not apply to it.
