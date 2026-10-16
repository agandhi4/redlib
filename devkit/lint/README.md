# lint

`ruff.toml` is the shared ruff base (target py313, 100 columns, rules `E F I N W UP`). A consumer
replaces its own copies of those keys with one `extend` line, whose path is relative to the file
that contains it, and keeps only what names its own code: `src`, `exclude` and isort's
`known-first-party`. In locus (`pyproject.toml` at the root) that is
`[tool.ruff]` `extend = "devkit/lint/ruff.toml"` plus `[tool.ruff.lint.isort]`
`known-first-party = ["server"]`; finplat's `backend/pyproject.toml` sits one level down, so it
uses `extend = "../devkit/lint/ruff.toml"`. A key the consumer sets wins over the base, so
widening `select` locally is a visible diff, not a fork of the shared list.

## Bases the collectors merge

knip, jscpd and vulture have no `extends`, and in this fleet only devkit's collectors run them
(`scripts/ci/metrics.conf`). So the collector merges the base under the repo's own config and
hands the tool the result as `--config`, opt-in per collector line. The merge is one rule
everywhere (`mergeConfig` in `metrics/_lib.mjs`, `merge_config` in `metrics/python.py`): lists
are unions, base first, so a repo adds to an ignore list but cannot silently drop a base entry.
Tables merge key by key, and any other repo value wins. Keep in the repo only what names its
own code. Opting in can move the numbers, so the adopting PR runs `metrics-rebaseline` or
`metrics-tighten`.

| Base | Collector flag | Holds | Stays in the repo |
|---|---|---|---|
| `knip.base.jsonc` | `ts.mjs --knip --knip-base` | `ignoreDependencies` for the tools devkit's collectors run (dependency-cruiser, eslint-plugin-sonarjs, jscpd); `ignore` `devkit/**` | entries, `paths`, `ignoreBinaries`, stack choices such as shadcn/ui's `src/components/ui/**` and openapi-typescript's `schema.d.ts` |
| `jscpd.base.json` | `jscpd.mjs --base` | `ignore`: tests (`tests/`, `test/`, `__tests__/`, `test-helpers/`, `*.test.*`, `*.spec.*`, `test-setup.*`, `conftest.py`) and `*.d.ts` | `format`, extra ignores; `--min-tokens` stays a flag |
| `vulture.toml` | `python.py --vulture --vulture-base <set>[,<set>…]` | `[tool.vulture] min_confidence = 60`; decorator sets `fastapi`, `flask`, `pydantic`, `sqlalchemy` | `paths`, whitelist files, `ignore_names` |

The repo config is read where the tool would read it: knip's `knip.json[c]`/`.knip.json[c]` or
package.json `knip` under `--root` (a `knip.ts` is code and is exit 2), jscpd's `.jscpd.json` or
package.json `jscpd` in the working directory, and vulture's `[tool.vulture]` in
`<root>/pyproject.toml`. The tools resolve the merged file's globs and paths against their
working directory, so the temporary file lives outside the repo.

A plain `npx knip` or `jscpd` run by hand does not see the base. Its only effect is the
devkit-run tools reported as unused dependencies and tests counted as clones.
