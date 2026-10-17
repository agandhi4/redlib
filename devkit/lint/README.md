# lint

`ruff.toml` is the shared ruff base (target py313, 100 columns, rules `E F I N W UP T20 PLC0415`). A consumer
replaces its own copies of those keys with one `extend` line, whose path is relative to the file
that contains it, and keeps only what names its own code: `src`, `exclude` and isort's
`known-first-party`. In locus (`pyproject.toml` at the root) that is
`[tool.ruff]` `extend = "devkit/lint/ruff.toml"` plus `[tool.ruff.lint.isort]`
`known-first-party = ["server"]`; finplat's `backend/pyproject.toml` sits one level down, so it
uses `extend = "../devkit/lint/ruff.toml"`. A key the consumer sets wins over the base, so
widening `select` locally is a visible diff, not a fork of the shared list.

`T20` (no `print`, observability.md) and `PLC0415` (imports at module top, backend.md) replace
guard tests: PLC0415 retires orbit's `test_no_deferred_imports.py`, T20 the print half of the
logger guards. The repo keeps its own `per-file-ignores` for code where printing is the
interface, since only it knows those paths:

```toml
[tool.ruff.lint.per-file-ignores]
"scripts/**" = ["T20"]
```

A deliberate deferred import (an app factory registering routers) is a `# noqa: PLC0415` with
the reason on the line, never a file-wide ignore.

## ESLint

`eslint.base.mjs` is a flat-config array of core ESLint rules: `no-console`, `no-eval`,
`no-implied-eval`, and `no-restricted-properties` on `innerHTML`, `outerHTML` and
`insertAdjacentHTML` (frontend.md Security; reads are flagged too, since the rule is per
property). A repo spreads it first, then its own recommended and framework layers, so a later
layer can relax a rule for one glob (a logger module's `no-console: off`).

The base imports nothing. It is vendored at `<repo>/devkit/lint/`, and Node resolves imports
from the importing file's ancestors, so in a repo whose `package.json` is in a subdirectory
(locus `web/`, finplat and orbit `frontend/`, instalite `web/`) an import of `typescript-eslint`
fails with `ERR_MODULE_NOT_FOUND`. Recommended configs stay in the repo, which already has them.

locus `web/eslint.config.js`, the `tseslint.config(...)` shape:

```js
import base from "../devkit/lint/eslint.base.mjs"

export default tseslint.config(
  { ignores: ["dist", "src/api/schema.d.ts"] },
  ...base,
  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    files: ["**/*.{ts,tsx}"],
    // languageOptions, plugins and rules as today
  },
)
```

rollcall `eslint.config.mjs`, the `eslint/config` `defineConfig` shape:

```js
import base from "./devkit/lint/eslint.base.mjs";

const eslintConfig = defineConfig([
  ...base,
  ...nextVitals,
  ...nextTs,
  globalIgnores([/* as today */]),
]);
```

## swift-format

swift-format has no `extends`, so `swift-format.json` cannot be referenced; the repo's
`.swift-format` (at the root, or beside the sources, e.g. locus `ios/`) is a byte copy:
`cp devkit/lint/swift-format.json .swift-format`. `devkit-check` fails `ci-quick` when any
tracked `.swift-format` differs from the vendored base, naming the file and the restore. A rule
change is a devkit PR; each repo's `devkit-sync` then refreshes every tracked copy in its own
commit (it never creates one), so that commit passes its devkit-check. The base is
instalite's config as of 2026-10-16.

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
