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
| `duplication` | lower | `duplication.repo.clones`; `duplication.<s>.jscpd_percent` is REPORT-ONLY: it is duplicated over scanned lines, so deleting unduplicated code raises it with no new clone (orbit #86, #88; decision 2026-10-17) |
| `dead` | lower | `dead.backend.vulture`, `dead.frontend.knip_exports` |
| `complexity` | lower | `complexity.backend.cognitive_max`, `complexity.backend.mccabe_over_10` |
| `coupling` | lower | `coupling.frontend.cycles`, `coupling.backend.layer_violations` (`bin/layer_check.py`), `coupling.backend.fan_out_max`; `coupling.<s>.fan_in_max` is REPORT-ONLY: a models or core hub has many importers by design, so its fan-in is architecture, not drift (decision 2026-10-17) |
| `guards` | lower | `guards.backend.known` (`bin/guard_check.py`: the guard violations that fire, `known` lines once the check passes; tolerance 0) |
| `bundle` | lower | `bundle.frontend.kb_total`, `bundle.frontend.kb_login` |
| `statements` | lower | `statements.POST:/api/items` |
| `size` | lower | `size.backend.max_lines`, `size.frontend.over_600` (`metrics/size.py`: lines of the largest production file; files over 600 lines); REPORT-ONLY: size alone never justifies a split, so a long file is a signal to read, never a gate failure (owner 2026-10-18) |
| `vuln` | lower | `vuln.backend.high`, `vuln.frontend.total` (`metrics/vuln.py`, OSV over the locked production set; REPORT-ONLY: a new advisory moves it without a code change, so never gated even with a bound in the file; the scorecard reads the snapshot, else `docs/metrics/report-only.json`) |
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
| | `--fan` | `coupling.<s>.fan_in_max` (most importers one module has; report-only), `coupling.<s>.fan_out_max` (most modules one module imports: a god module) over the import-statement edges of the same graph (no initializer edges: they would make every package initializer a hub) |
| | `--cycles` | `coupling.<s>.cycles` (strongly connected components of the runtime import graph over the `--src` directories and `.py` modules, so a flat backend lists `app.py` beside its packages; `if TYPE_CHECKING:` imports excluded, imports inside functions included). Importing `a.b.c` also runs `a/__init__` and `a/b/__init__`, so the graph holds an initializer edge from the importer to each such ancestor that imports something of ours, except the importer's own ancestors (already loaded): a cycle through a re-exporting package initializer counts |
| `ts.mjs` | `--cyclomatic` | `complexity.<s>.cyclomatic_max` (eslint `complexity` at 0, `--no-inline-config`, production files: `--src` minus tests, `__tests__`/`__mocks__`/`test-helpers`, `test-setup.*`, `setupTests.*`, `*.d.ts` and `--test-glob`s; `.vue` components too when `vue-eslint-parser` and `@vue/compiler-sfc` are installed under `--root`, else skipped with a stderr note; a production file the repo's eslint config does not cover is exit 2) |
| | `--cognitive` | `complexity.<s>.cognitive_max`, `complexity.<s>.cognitive_over_15` (eslint-plugin-sonarjs) |
| | `--knip` | `dead.<s>.knip_exports` (exports + types), `dead.<s>.knip_files` (knip 6: files reported as issues), `dead.<s>.knip_deps` (dependencies, devDependencies, unlisted, unresolved, binaries) |
| | `--cycles` | `coupling.<s>.cycles` (dependency-cruiser `--no-config` graph of `--src`, same production filter, `--ts-pre-compilation-deps` so an `import type`/`type-import` edge is dropped alike in `.ts` and in a `.vue` `<script>`) |
| | `--fan` | `coupling.<s>.fan_in_max`, `coupling.<s>.fan_out_max` (the same graph; the python.py definition). Nodes are the production source set the complexity keys read (`.ts/.tsx/.js/.jsx/.mts/.cts/.mjs/.cjs` and `.vue` as above, no tests or `.d.ts`); a component registered by an auto-import `.d.ts` or used only in a `<template>` is no edge, so a stylesheet, image or `?raw`/`?url` import is no edge: an asset is not coupling |
| | `--bundle` | `bundle.<s>.kb_total` (every file `vite build` emits, raw KiB, one decimal), `bundle.<s>.kb_entry` (the `--bundle-entry` chunk, its static-import closure and their CSS). A Next app (`.next/` or `next.config.*`) is read from its `next build` output instead: total `.next/static`, entry build-manifest.json's rootMainFiles, polyfillFiles and pages/_app |
| `rust.py` | `--cognitive` | `complexity.<s>.cognitive_max` (clippy `cognitive_complexity` at threshold 0, so every function is scored and the max is real; clippy's own metric, comparable to itself, not to sonarjs or complexipy), `complexity.<s>.cognitive_over_15` |
| | `--dead` | `dead.<s>.rustc` (rustc's unused-code warnings: `dead_code`, `unused_imports`/`_variables`/`_assignments`/`_mut`/`_macros`/`_macro_rules`/`_labels`/`_extern_crates`, `unreachable_code`/`_patterns`; production targets only; a crate's `#![allow]` hides what it allows). Duplication is `jscpd.mjs` over the `.rs` dirs |
| | `--cycles` | `coupling.<s>.cycles` (strongly connected components of more than one file in the module graph of every production target `cargo metadata --no-deps` names: files are modules; edges are `use` leaves and `crate::`/`self::`/`super::`/child-module paths, each resolved to the file defining the item, re-exports and glob re-exports followed; a `pub use` is an alias, not an edge; `mod x;` is no edge; `#[cfg(test)]` items and `#![cfg(test)]` files are not read; cross-crate paths are no edges. Lexical: `metrics/_rust_graph.py`'s header lists what it cannot see) |
| | `--fan` | `coupling.<s>.fan_in_max` (report-only), `coupling.<s>.fan_out_max` over the same graph (the python.py definition) |
| `jscpd.mjs` | | `duplication.<s>.jscpd_percent` (jscpd's `statistics.total.percentage`, two decimals), `duplication.<s>.clones` |
| `size.py` | `--scope <s> --src <dir>... --ext .py|.ts,.tsx [--exclude <glob>]...` | `size.<s>.max_lines`, `size.<s>.over_600` (production files only: tests, fixtures, generated and vendored paths excluded; any language; both report-only, not in the starter; every file over the limit is listed on stderr) |
| `vuln.py` | `--scope <scope> --uv <dir>|--npm-lock <file>|--pnpm-lock <file>|--cargo-lock <file>...` | `vuln.<scope>.critical`, `vuln.<scope>.high`, `vuln.<scope>.total` (known vulnerabilities in the locked production packages, from OSV; report-only, not in the starter), `vuln.<scope>.packages` (the production packages queried; 0 for a dev-only lockfile, which the scorecard reads as NA) |
| `statements.py` (area `job:db`) | `--in <file> --out … [--min-routes N]` | `statements.<METHOD>:/<route template>` (the db tier's statement fixture writes the per-route maxima to a file outside build/metrics/; the collector validates the shape, prefixes and sorts; tolerance 0 by the ratchet; fewer than N routes is exit 2, so a fixture that recorded nothing cannot pass as clean) |
| `coverage.py` (area `job:<tier job>`) | `--coverage-json` | `coverage.<s>.lines` (covered_lines / num_statements), `coverage.<s>.branches` (covered_branches / num_branches; omitted when no branches were measured) |
| | `--istanbul-summary` | `coverage.<s>.lines` (`total.lines.pct`), `coverage.<s>.branches` (`total.branches.pct`; omitted when "Unknown") |
| | `--llvm-cov-json` | `coverage.<s>.lines` (`cargo llvm-cov --json` export: `data[0].totals.lines` covered / count), `coverage.<s>.branches` (the same for `branches`; omitted at count 0, which is every stable-toolchain run: rustc's branch coverage is nightly-only). Inline `#[cfg(test)]` modules are in the counts |

**Findings (`--list-out FILE`, `python.py`, `ts.mjs`, `rust.py` and `jscpd.mjs`).** The lines behind the counts, for
a lane to work from; never a ratchet input, and the JSON is the same bytes with or without it.
A `# <key>` header per key that has findings, then one line each; keys sorted; an empty file
when nothing is over. Paths are `--root` joined with the tool's path, so repo-relative in a
gate run. Complexity (`mccabe_over_10`, `cognitive_over_15`, and `cyclomatic_max` with the
functions over 10): `<path>:<line> <function> <metric>=<n>`, worst first; complexipy gives no
line, so the `def` is found by name (`Class::method`); sonarjs gives no name, so it is the
identifier at the reported column, `<anonymous>` for an inline callback. Dead code:
`<path>:<line> <name> <kind>` (vulture's kind, or knip's `export`, `type`, `file`,
`dependency`, `devDependency`, `unlisted`, `unresolved`, `binary`; no `:<line>` when knip has
none), by path and line; a vulture reachability finding prints its message; rustc's is `<path>:<line> <lint> <message>` at the macro call site for a finding inside an expansion. `cycles`: one line
per cycle, its files space-separated, largest first. `fan_in_max`, `fan_out_max`:
`<path> fan_in=<n>`, the top 10, ties by path. `clones` (jscpd.mjs, whose paths are relative
to the working directory, the repo root): one line per clone pair,
`<pathA>:<start>-<end> ↔ <pathB>:<start>-<end> lines=<n>`, largest first, the two ends in
path order.

**Bundle keys and the label (2026-10-17).** `bundle.*` keys stay at tolerance 0: every KiB
the first screen loads is a bound. Extracting a component or helper adds a sub-KiB rise the
code did not earn as weight, because names survive minification (an export, a component name,
an import specifier). That rise is the sanctioned use of `metrics-rebaseline`: run
`make metrics-rebaseline KEYS=bundle.frontend.kb_total` (the moved key or keys, comma-separated;
nothing else moves), commit `docs/metrics/ratchet.json`, label the PR `metrics-rebaseline`, and
add a line to the repo's decisions.md naming the extraction and the KiB. Never hand-edit the
bounds file. Anything past a KiB, or a rise with no extraction, is a regression to fix.
Precedents: finplat #663, orbit #84, instalite #22, locus #127.

**Vue components counted (2026-10-17).** Before, ts.mjs saw no `.vue` file, so a Vue repo's
`complexity.<s>.*` and `coupling.<s>.*` measured its `.ts` alone. At the first sync after this
change those keys RISE with no code change (orbit: `cognitive_max` 31 to 37, `fan_out_max` 10
to 23; `fan_in_max`, report-only, 22 to 45). That sync PR carries the `metrics-rebaseline`
label legitimately: the bound moves because the measurement widened, not because code got worse.

**Coverage determinism.** vitest's V8 coverage remaps branches per worker unless
`coverage.experimentalAstAwareRemapping: true` is set in the vitest config: locus saw 12 vs 13
branches depending on worker order, which the ratchet reads as a regression. Set it (or use
the istanbul provider) before tracking `coverage.<s>.branches` from vitest.

**A key held by a lint rule** (lint/README.md, "Graduating a ratchet key to a lint rule") may
leave the bounds: with ruff C901 or eslint `complexity` on at 10, `mccabe_over_10` stays 0 and
`cyclomatic_max` stays at 10 or less by construction. Drop the collector flag from
`scripts/ci/metrics.conf` (`--mccabe`, `--cyclomatic`) and its keys from `ratchet.json` in the
PR that turns the rule on, under the `metrics-rebaseline` label (a removed bound is REMOVED).
Deleting only the key does not stick: `rebaseline` and `tighten --seed` seed every snapshot key back. Keep
`--cognitive` running even where sonarjs holds it: the scorecard's WIRED reads the
`complexity.*` keys (`ratchet.complexity`), and a repo with none is not wired.

A repo-specific collector (finplat's reinvention registry, closet's `audit-pages`) uses its
own domain name and states the direction in `ratchet.json`.

`bin/layer_check.py --metrics-out <file>` is a guard that also reports:
`coupling.<section>.layer_violations`, the refused imports per `scripts/ci/layers.conf` section
(its `known` lines once the check passes). It is not in the starter because it needs the repo's
conf; the `devkit new` stacks declare it as their `layers` collector.

`bin/guard_check.py --metrics-out <file>` reports the same way: `guards.<section>.known`, the
violations of `scripts/ci/guards.conf`'s rules in that section (its `known` lines once the
check passes), so paying debt down is ratcheted and adding a `known` line needs the
metrics-rebaseline label. The `devkit new` stacks declare it as their `guards` collector.

## Bounds file

`docs/metrics/ratchet.json` maps each gated key to `{"direction": "lower"|"higher", "bound":
<number>, "source": "<collector>"}`. `source` is written by `rebaseline` and `tighten` from the
snapshot's `sources`; it is informational for the comparison with main (a bound whose source
alone changed has not moved) and is what the skipped-collector rule below reads. Start from
`devkit/templates/metrics/ratchet.json` and delete the keys you do not collect, or from `{}`
(valid for every subcommand; the scaffold ships it), then fill every bound from today's
numbers:

```sh
SEED=1 make metrics-tighten     # runs scripts/ci/metrics.conf, merges, fills the bounds
```

`tighten --seed` (and `rebaseline`, whose whole-file form is for a label-approved loosening
only) fills every unset bound and seeds every snapshot key the bounds do not track
yet (except `gate.*`, `tier.*` and `tests.*`, never seeded, and the report-only keys) with the
direction its domain fixes in the table above; a key of a domain not in that table is an error naming it, so a
repo-specific domain is added by hand with its direction. So `{}` is a complete start: one
`SEED=1 make metrics-tighten` tracks everything the collectors emit, and later bounds a new key
without moving any other. The starter's `null` bounds make `check`
refuse to run until that happens, so a copied template never gates on a placeholder; the
starter lists exactly the keys the shared collectors emit (`tests/metrics_ratchet_test.py`
holds it to the table below). Keys in the snapshot but not in the bounds are reported as
untracked by `check` and never fail; remove a seeded key from the bounds to leave it so.

**Every key is a signal** (owner, 2026-10-18): it says where to look, and an agent judges
whether to act or to record an exception. A bound holds a floor against drift; the
`metrics-rebaseline` label is the exception path. A key whose movement says nothing about the
code without that judgement is report-only: size, because size alone never justifies a split
(decisions 2026-10-17, T2 file size).

**Report-only keys** (`vuln.*`, `coupling.<s>.fan_in_max`, `duplication.<s>.jscpd_percent`,
`size.<s>.max_lines`, `size.<s>.over_600`; `is_report_only` in `bin/metrics_ratchet.py`) are
never gated, even when the bounds file holds one: `check` prints
`ratchet <key> <value>|- vs <bound> REPORT-ONLY (...)` and counts it as `report_only=` in the
summary, the comparison with main ignores it (dropping or moving its bound needs no label), and
`tighten` and `rebaseline` drop it and seed none. A consumer whose bounds still hold one passes
`check` after its next devkit sync; `make metrics-tighten` drops the entries, and the PR commits
both files.

**`docs/metrics/report-only.json`** is the committed copy of the report-only keys:
`metrics_collect.sh tighten` and `rebaseline` write it beside the bounds (a schema 2 snapshot,
`--report-only` of the ratchet; a key whose collector was skipped keeps its committed value), and
the author commits it with the bounds. `check` never writes or reads it, so it gates nothing. It
exists because the bounds never hold these keys and `build/metrics.json` is untracked: without
it a fresh clone's scorecard graded `sec.audit` UNMEASURED in every repo, vuln collector or not
(devkit #76). The scorecard reads the bounds, then this file, then a fresh `build/metrics.json`.

**Gains lock in.** `check` fails a BETTER key with `ratchet <key> <value> vs <bound> BETTER —
run make metrics-tighten and commit docs/metrics/ratchet.json`: integer keys on any gain, float
keys (coverage, bundle KiB) on a gain over 0.05; a smaller float gain prints `BETTER (within
tolerance 0.05; not a failure)`. The `metrics-rebaseline` label does not exempt it; the fix is
always `make metrics-tighten` and the bounds commit.

**`tighten` prints what the gate will refuse.** Every WORSE and MISSING key gets check's
`ratchet <key> ...` line; the BETTER bounds are written, then the run exits 1 with a last
`ratchet FAIL:` line naming the fixes. `metrics_collect.sh tighten` still runs the scorecard's
tighten before passing the 1 on.

**Skipped collectors.** In the gate, `metrics_collect.sh` runs a collector only when a changed
path is in its area (`other` runs everything, `tooling` widens nothing, `repo` collectors
always run; a `job:<name>` collector, which reads a gate job's report, only when
`build/metrics/gate.json` records that job) and passes the rest to `merge --skipped`. `check` then reports a tracked key that is absent from
the snapshot as `SKIPPED (collector <name> did not run)`, and does not fail, exactly when the
bound's `source` is in the snapshot's `skipped`. A key with no `source` (bounds written before
schema 2: run `rebaseline` once to add them), or whose collector ran and emitted nothing, is
MISSING and fails even with `--rebaseline-ok`. `tighten` and `rebaseline` leave a skipped key's
bound as it is.
