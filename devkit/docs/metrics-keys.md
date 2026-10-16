# Metrics keys: the snapshot shape `metrics_ratchet.py` reads

Collectors write one file each to `build/metrics/<collector>.json`: a flat JSON object of
numbers, `{"<domain>.<scope>.<stat>": <number>}`, or nested objects that flatten to the same
dotted keys. `metrics_ratchet.py merge` (run by `metrics_collect.sh`) joins them into one
snapshot, `build/metrics.json`, and refuses a key that two collectors both emit:

```json
{"schema_version": 2,
 "metrics": {"coverage.backend.lines": 81.5, "gate.quick.seconds": 41},
 "sources": {"coverage.backend.lines": "cov-backend", "gate.quick.seconds": "gate"},
 "skipped": ["ts-frontend"]}
```

`sources` names the collector (the file's stem) behind each key; `skipped` lists the collectors
`metrics_collect.sh` did not run for this PR. `check`, `tighten` and `rebaseline` also read a
schema 1 envelope (finplat's `make metrics`) and a bare flat file, which carry neither.

## Rules

- **Domain first**, from the list below, so one prefix finds a kind of metric in every repo
  and the domain fixes the direction. `<scope>` is the stack area (`backend`, `frontend`,
  `web`, `repo` for whole-repo tools). `<stat>` names the number, with its unit when it has
  one (`kb_total`, `jscpd_percent`).
- **Numbers only, no whitespace in a key.** Output lines are space-separated, so a space in a
  key breaks every reader. Lists, strings, booleans and nulls are skipped as non-metrics.
- **Deterministic collectors only** feed the bounds: the same commit must give the same
  number. Timings and Lighthouse stay in the report (delivery.md, Coverage and Metrics); the
  exceptions are the gate's own `gate.*` seconds and `tier_guard.sh`'s `tier.*` seconds, below.
- **Statements** are `statements.<METHOD>:<route template>`, exact counts written by the
  test suite's statement fixture to `build/metrics/statements.json`, held at tolerance 0
  (decision H, 2026-10-13). Example: `statements.GET:/api/v1/accounts/{account_id}`.

| Domain | Direction | Examples |
|---|---|---|
| `coverage` | higher | `coverage.backend.lines`, `coverage.frontend.branches` |
| `duplication` | lower | `duplication.repo.jscpd_percent` |
| `dead` | lower | `dead.backend.vulture`, `dead.frontend.knip_exports` |
| `complexity` | lower | `complexity.backend.cognitive_max`, `complexity.backend.mccabe_over_10` |
| `coupling` | lower | `coupling.frontend.cycles`, `coupling.backend.layer_violations` (`bin/layer_check.py`) |
| `bundle` | lower | `bundle.frontend.kb_total`, `bundle.frontend.kb_login` |
| `statements` | lower | `statements.POST:/api/items` |
| `size` | lower | `size.backend.max_lines`, `size.frontend.over_600` (`metrics/size.py`: lines of the largest production file; files over 600 lines) |
| `vuln` | lower | `vuln.backend.high`, `vuln.frontend.total` (`metrics/vuln.py`, OSV over the locked production set; REPORT-ONLY like `gate.*`: a new advisory moves it without a code change, so never a tracked bound; the scorecard reads the snapshot) |
| `allowlist` | lower | `allowlist.backend.own_commit` (shrink-only allow-lists) |
| `gate` | lower | `gate.backend-unit.seconds`, `gate.total.seconds` (wall-clock seconds) |
| `tier` | lower | `tier.unit.seconds`, `tier.db.seconds` (wall-clock seconds of the guarded command) |
| `tests` | higher | `tests.unit.pytest`, `tests.e2e.playwright` (tests that ran, per tier and runner) |

**Gate seconds** come from `local_gate.sh`, not a repo collector: after every job it rewrites
`build/metrics/gate.json` in the merged worktree with `gate.<job>.seconds` for the jobs run so
far, and adds `gate.total.seconds` after the last one (a copy stays in the gate's log dir). A
metrics job the plan runs last therefore merges every earlier job's seconds, but never its own
or the total. They are the one timing domain allowed into a snapshot (owner directive
2026-10-13: job seconds only ever get faster); the hard limits are the gate's budgets
(`GATE_JOB_BUDGET_MINUTES`, `GATE_BUDGET_MINUTES`). Wall-clock seconds are noisy and the
ratchet has no tolerance, so a repo that tracks a `gate.*` key sets its bound with headroom by
hand rather than with `tighten`. The worktree's `build/` must be git-ignored, as it already is
for every other collector.

**Tier seconds and test counts** come from `tier_guard.sh` (README), one file per tier:
`build/metrics/tier-<tier>.json` at the git top level (whatever directory the tier ran from) holds `tier.<tier>.seconds` and `tests.<tier>.<runner>` for each
floored runner, written after a command that passed (an over-budget or under-floor run still
writes them). Two domains because the directions differ: a tier only gets faster, and the count
of tests that ran only goes down in the PR that removes tests, which is what a `higher` bound
plus the rebaseline label already enforce. The seconds are as noisy as `gate.*`, so a tracked
bound gets headroom by hand; the counts are deterministic and can use `tighten`.

## Shared collectors (`devkit/metrics/`)

Exactly the keys each emits, per flag; `<s>` is `--scope`. CLIs: devkit README, Architecture.

| Collector | Flag | Keys |
|---|---|---|
| `python.py` | `--mccabe` | `complexity.<s>.mccabe_max`, `complexity.<s>.mccabe_over_10` (ruff C901 at 0, `--ignore-noqa`) |
| | `--cognitive` | `complexity.<s>.cognitive_max`, `complexity.<s>.cognitive_over_15` (complexipy) |
| | `--vulture` | `dead.<s>.vulture` (findings; `[tool.vulture]` in `--root`'s pyproject.toml is honoured, else the `--src` paths; unused fields of pydantic/SQLAlchemy models, dataclasses, enums, TypedDicts and Protocols are dropped with `--vulture-ignore-declarative`) |
| | `--fan` | `coupling.<s>.fan_in_max` (most importers one module has), `coupling.<s>.fan_out_max` (most modules one module imports: a god module) over the same runtime graph |
| | `--cycles` | `coupling.<s>.cycles` (strongly connected components of the runtime import graph over the `--src` directories and `.py` modules, so a flat backend lists `app.py` beside its packages; `if TYPE_CHECKING:` imports excluded, imports inside functions included) |
| `ts.mjs` | `--cyclomatic` | `complexity.<s>.cyclomatic_max` (eslint `complexity` at 0, `--no-inline-config`, production files: `--src` minus tests, `__tests__`/`__mocks__`/`test-helpers`, `test-setup.*`, `setupTests.*`, `*.d.ts` and `--test-glob`s) |
| | `--cognitive` | `complexity.<s>.cognitive_max`, `complexity.<s>.cognitive_over_15` (eslint-plugin-sonarjs) |
| | `--knip` | `dead.<s>.knip_exports` (exports + types), `dead.<s>.knip_files` (knip 6: files reported as issues), `dead.<s>.knip_deps` (dependencies, devDependencies, unlisted, unresolved, binaries) |
| | `--cycles` | `coupling.<s>.cycles` (dependency-cruiser `--no-config` graph of `--src`, same production filter, `import type` is not an edge) |
| | `--fan` | `coupling.<s>.fan_in_max`, `coupling.<s>.fan_out_max` (the same graph; the python.py definition) |
| | `--bundle` | `bundle.<s>.kb_total` (every file `vite build` emits, raw KiB, one decimal), `bundle.<s>.kb_entry` (the `--bundle-entry` chunk, its static-import closure and their CSS) |
| `jscpd.mjs` | | `duplication.<s>.jscpd_percent` (jscpd's `statistics.total.percentage`, two decimals), `duplication.<s>.clones` |
| `size.py` | `--scope <s> --src <dir>... --ext .py|.ts,.tsx [--exclude <glob>]...` | `size.<s>.max_lines`, `size.<s>.over_600` (production files only: tests, fixtures, generated and vendored paths excluded; any language) |
| `vuln.py` | `--scope <scope> --uv <dir>|--npm-lock <file>|--pnpm-lock <file>|--cargo-lock <file>...` | `vuln.<scope>.critical`, `vuln.<scope>.high`, `vuln.<scope>.total` (known vulnerabilities in the locked production packages, from OSV; report-only, not in the starter) |
| `statements.py` (area `job:db`) | `--in <file> --out … [--min-routes N]` | `statements.<METHOD>:/<route template>` (the db tier's statement fixture writes the per-route maxima to a file outside build/metrics/; the collector validates the shape, prefixes and sorts; tolerance 0 by the ratchet; fewer than N routes is exit 2, so a fixture that recorded nothing cannot pass as clean) |
| `coverage.py` (area `job:<tier job>`) | `--coverage-json` | `coverage.<s>.lines` (covered_lines / num_statements), `coverage.<s>.branches` (covered_branches / num_branches; omitted when no branches were measured) |
| | `--istanbul-summary` | `coverage.<s>.lines` (`total.lines.pct`), `coverage.<s>.branches` (`total.branches.pct`; omitted when "Unknown") |

**Coverage determinism.** vitest's V8 coverage remaps branches per worker unless
`coverage.experimentalAstAwareRemapping: true` is set in the vitest config: locus saw 12 vs 13
branches depending on worker order, which the ratchet reads as a regression. Set it (or use
the istanbul provider) before tracking `coverage.<s>.branches` from vitest.

A repo-specific collector (finplat's reinvention registry, closet's `audit-pages`) uses its
own domain name and states the direction in `ratchet.json`.

`bin/layer_check.py --metrics-out <file>` is a guard that also reports:
`coupling.<section>.layer_violations`, the refused imports per `scripts/ci/layers.conf` section
(its `known` lines once the check passes). It is not in the starter because it needs the repo's
conf; the `devkit new` stacks declare it as their `layers` collector.

## Bounds file

`docs/metrics/ratchet.json` maps each gated key to `{"direction": "lower"|"higher", "bound":
<number>, "source": "<collector>"}`. `source` is written by `rebaseline` and `tighten` from the
snapshot's `sources`; it is informational for the comparison with main (a bound whose source
alone changed has not moved) and is what the skipped-collector rule below reads. Start from
`devkit/templates/metrics/ratchet.json` and delete the keys you do not collect, or from `{}`
(valid for every subcommand; the scaffold ships it), then fill every bound from today's
numbers:

```sh
devkit/bin/metrics_collect.sh rebaseline     # runs scripts/ci/metrics.conf, merges, fills the bounds
```

`rebaseline` fills every tracked bound and seeds every snapshot key the bounds do not track
yet (except `gate.*`, `tier.*` and `tests.*`, never tracked) with the direction its domain
fixes in the table above; a key of a domain not in that table is an error naming it, so a
repo-specific domain is added by hand with its direction. So `{}` is a complete start: one
`rebaseline` tracks everything the collectors emit. The starter's `null` bounds make `check`
refuse to run until that happens, so a copied template never gates on a placeholder; the
starter lists exactly the keys the shared collectors emit (`tests/metrics_ratchet_test.py`
holds it to the table below). Keys in the snapshot but not in the bounds are reported as
untracked by `check` and never fail; remove a seeded key from the bounds to leave it so.

**Skipped collectors.** In the gate, `metrics_collect.sh` runs a collector only when a changed
path is in its area (`other` runs everything, `tooling` widens nothing, `repo` collectors
always run; a `job:<name>` collector, which reads a gate job's report, only when
`build/metrics/gate.json` records that job) and passes the rest to `merge --skipped`. `check` then reports a tracked key that is absent from
the snapshot as `SKIPPED (collector <name> did not run)`, and does not fail, exactly when the
bound's `source` is in the snapshot's `skipped`. A key with no `source` (bounds written before
schema 2: run `rebaseline` once to add them), or whose collector ran and emitted nothing, is
MISSING and fails even with `--rebaseline-ok`. `tighten` and `rebaseline` leave a skipped key's
bound as it is.
