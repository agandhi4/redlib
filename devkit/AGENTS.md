# devkit — agent rules

Shared scripts vendored into every app repo as a `git subtree`. Read `README.md` first.

## Invariants
- Portable shell: macOS bash 3.2 + GNU bash; BSD + GNU coreutils. Empty arrays under `set -u`
  use `${a[@]+"${a[@]}"}`. No `readarray`, no `declare -A`, no GNU-only `sed -i` without `''`.
- `shellcheck -s bash` clean; `bats tests/` green before any push. CI runs both.
- Output contracts are APIs. `bin/local_gate.sh` prints `GATE <job> PASS|FAIL|SKIPPED|WATCHDOG …` and
  `VERDICT PASS|FAIL head=<sha> main=<sha>`; `finplat_merge_queue.sh`, `mac_merge_queue.sh`
  and `worker.py` parse them. `.devkit-rev` is `<upstream commit> <tree sha>`.
- The skeleton owns mechanics; the repo's `scripts/ci/gate_plan.sh` owns policy (which jobs
  for which paths). A new mechanic belongs here; a new check belongs in the repo's Makefile.
- Every gate job is a Makefile target the repo's workflows also call. Parity is structural.
- One version string per toolchain per repo: `.nvmrc`, `.python-version`, `rust-toolchain.toml`,
  all exact. CI reads them (`*-version-file`), the gate provisions them from the MERGED tree
  (`node_toolchain.sh`, `rust_toolchain.sh`), `toolchain_check.sh` holds Dockerfiles, workflows
  and manifests to them. Never pin a toolchain version anywhere else.
- Fail loudly on a missing tool (`flock`, `gh`) with the install hint; never degrade silently.

## Workflow
- Branch, PR, squash-merge with a descriptive sentence title. Consumers pick it up with
  `make devkit-sync`; a devkit change that needs plan changes ships as devkit PR first, then
  one PR per consumer.
- Record decisions in `docs/decisions.md` in the same PR (`## YYYY-MM-DD — title`, Why /
  Decision / Consequence, ≤ 8 lines).

## Convention deltas
- None. devkit ships no running service, so `observability.md` does not apply to it.
