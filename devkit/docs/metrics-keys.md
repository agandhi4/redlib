# Metrics keys: the snapshot shape `metrics_ratchet.py` reads

A snapshot is one flat JSON object of numbers: `{"<domain>.<scope>.<stat>": <number>}`.
Collectors write one file each to `build/metrics/<collector>.json` (flat, or nested objects
that flatten to the same dotted keys); `metrics_ratchet.py merge` joins them into one
snapshot and refuses a key that two collectors both emit.

## Rules

- **Domain first**, from the list below, so one prefix finds a kind of metric in every repo
  and the domain fixes the direction. `<scope>` is the stack area (`backend`, `frontend`,
  `web`, `repo` for whole-repo tools). `<stat>` names the number, with its unit when it has
  one (`kb_total`, `jscpd_percent`).
- **Numbers only, no whitespace in a key.** Output lines are space-separated, so a space in a
  key breaks every reader. Lists, strings, booleans and nulls are skipped as non-metrics.
- **Deterministic collectors only** feed the bounds: the same commit must give the same
  number. Timings and Lighthouse stay in the report (delivery.md, Coverage and Metrics); the
  one exception is the gate's own `gate.*` seconds, below.
- **Statements** are `statements.<METHOD>:<route template>`, exact counts written by the
  test suite's statement fixture to `build/metrics/statements.json`, held at tolerance 0
  (decision H, 2026-10-13). Example: `statements.GET:/api/v1/accounts/{account_id}`.

| Domain | Direction | Examples |
|---|---|---|
| `coverage` | higher | `coverage.backend.lines`, `coverage.frontend.branches` |
| `duplication` | lower | `duplication.repo.jscpd_percent` |
| `dead` | lower | `dead.backend.vulture`, `dead.frontend.knip_exports` |
| `complexity` | lower | `complexity.backend.cognitive_max`, `complexity.backend.mccabe_over_10` |
| `coupling` | lower | `coupling.frontend.cycles`, `coupling.backend.fan_in_max` |
| `bundle` | lower | `bundle.frontend.kb_total`, `bundle.frontend.kb_login` |
| `statements` | lower | `statements.POST:/api/items` |
| `allowlist` | lower | `allowlist.backend.own_commit` (shrink-only allow-lists) |
| `gate` | lower | `gate.backend-unit.seconds`, `gate.total.seconds` (wall-clock seconds) |

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

A repo-specific collector (finplat's reinvention registry, closet's `audit-pages`) uses its
own domain name and states the direction in `ratchet.json`.

## Bounds file

`docs/metrics/ratchet.json` maps each gated key to `{"direction": "lower"|"higher", "bound":
<number>}`. Start from `devkit/templates/metrics/ratchet.json`: delete the keys you do not
collect, add your statement keys, then fill every bound from today's snapshot:

```sh
python3 -I devkit/bin/metrics_ratchet.py rebaseline --snapshot build/metrics.json --bounds docs/metrics/ratchet.json
```

The starter's `null` bounds make `check` refuse to run until that happens, so a copied
template never gates on a placeholder. Keys in the snapshot but not in the bounds are
reported as untracked and never fail.
