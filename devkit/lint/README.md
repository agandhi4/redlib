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

### TypeScript configs

`eslint.base.d.mts` declares the module's exports, so an `eslint.config.ts` imports the base
with no declaration of its own (orbit's `frontend/eslint-base.d.ts` goes at its next sync):
`default` is the configs, a subset of `Linter.Config[]`, and `sonarjsRules` and
`sonarjsTestRules` are `Linter.RulesRecord`. It imports nothing either, for the same reason, so it
spells eslint's shapes out. template-tests holds them assignable to eslint's own types, and
`tests/lint_contract.bats` holds its export list to the module's.

### sonarjs

The base also exports two rule maps for eslint-plugin-sonarjs. `sonarjsRules` turns on
`sonarjs/no-nested-conditional` and `sonarjs/no-duplicate-string` at threshold 3, sonar's
default. Two refactor sweeps named them: finplat #663 and instalite #22 flattened nested
load-state ternaries five times and turned copy-pasted JSX into tables four times, by hand.
`sonarjsTestRules` turns the duplicate-string rule off again, for the repo's test-file layer.

They are rule maps, not config objects, because a plugin's rules only resolve in a files scope
that also registers the plugin, and that scope is the repo's. Every JS repo in the fleet pins
eslint-plugin-sonarjs 4.2.x (closet, finplat, instalite, locus, orbit, rollcall); a repo
without it ignores both exports. Adoption is one spread in the layer that already registers
the plugin, plus one in the test layer, at the repo's next sync (the next-vercel scaffold ships
both, so a new app starts with them):

```js
import base, { sonarjsRules, sonarjsTestRules } from "../devkit/lint/eslint.base.mjs"

  {
    files: ["**/*.{ts,tsx}"],
    plugins: { sonarjs },
    rules: { "sonarjs/cognitive-complexity": ["error", 15], ...sonarjsRules },
  },
  { files: ["**/*.test.{ts,tsx}", "e2e/**"], rules: sonarjsTestRules },
```

No repo is at 0 yet, so the adopting sync also fixes what the rules flag (read-only dry run on
each origin/main, 2026-10-17, test files under the test layer):

| Repo | no-nested-conditional | no-duplicate-string |
|---|---|---|
| locus | 4 | 0 |
| instalite | 2 | 7 |
| rollcall | 15 | 17 |
| finplat | 92 | 18 |

finplat's count wants a sweep lane of its own before its sync turns the rules on.

### Prettier

eslint-plugin-prettier doubles the cost: it runs prettier as an eslint rule over the files
`prettier --check` already reads, and it reports formatting as lint errors. Use
eslint-config-prettier, which only turns off the stylistic rules prettier owns, and run
`prettier --check` as its own command in the lint step. In closet (#407) the plugin read every
file a second time, a third of a cold lint. With it gone and the hook split (README "Git
hooks"), closet's pre-commit went from p90 33 s to 21 s cold and 3 s warm.

### Caches

The scaffolds lint with `eslint --cache --cache-strategy content --cache-location
node_modules/.cache/eslint/` and type-check with `tsc --incremental` (node-service's build
info in `node_modules/.cache/tsc/`, next-vercel's in the gitignored `tsconfig.tsbuildinfo`).
`content` keys on file hashes, so a rebase that rewrites mtimes keeps the cache. The caches
are per checkout, and a cold one costs a lane's first commit 16 to 21 s in closet. They cannot
be shared across a repo's worktrees (measured 2026-10-17, ESLint 9.39 and 10.8, tsc 5.9 and
6.0, two worktrees of one fixture):

- ESLint (file-entry-cache 8) keys every entry by absolute path. A directory location gets
  one `.cache_<hash of cwd>` file per worktree; a file location holds both worktrees' entries
  side by side, and every run rewrites the whole file, so concurrent lanes race.
- tsc's build info stores paths relative to itself, and each worktree's own `node_modules`
  gives every file, `lib.d.ts` included, another path. A shared file re-checks everything
  after each worktree switch, so the two worktrees thrash it.

## Graduating a ratchet key to a lint rule

The ratchet holds a count at the gate, minutes after the edit; a lint rule fails the edit
itself. When a repo's count reaches 0, the repo turns the matching rule on, at the same
threshold the collector uses, so the next function over it fails in the editor and ci-quick:

| Key at 0 | Rule the repo turns on | Where |
|---|---|---|
| `complexity.<s>.mccabe_over_10` (python.py `--mccabe`) | ruff `C901`, `max-complexity = 10` | the repo's ruff block |
| `complexity.<s>.cyclomatic_max` at 10 or less (ts.mjs `--cyclomatic`; no over-10 key exists) | eslint `complexity` 10 | the repo's eslint config |
| `complexity.<s>.cognitive_over_15` (ts.mjs `--cognitive`) | `sonarjs/cognitive-complexity` 15, where eslint-plugin-sonarjs is installed | the repo's eslint config |
| `complexity.<s>.cognitive_over_15` (python.py `--cognitive`) | none: `bin/py_cognitive_lint.py` graduates itself (below) | the repo's `ci-lint` recipe, once |
| `complexity.<s>.cognitive_over_15` (rust.py `--cognitive`) | clippy `cognitive_complexity`: `cognitive-complexity-threshold = 15` in clippy.toml, `-D clippy::cognitive_complexity` on the clippy command (redlib #21) | the repo's clippy.toml and ci-quick recipe |

In Rust, `#[allow(clippy::cognitive_complexity)]` is forbidden: it is the same lint rust.py runs, so it also hides the function from the collector.

```toml
# pyproject.toml, beside the `extend` line
[tool.ruff.lint]
extend-select = ["C901"]

[tool.ruff.lint.mccabe]
max-complexity = 10
```

```js
// the repo's own layer, after ...base
{
  files: ["**/*.{ts,tsx}"],
  plugins: { sonarjs }, // only where the plugin is installed
  rules: {
    complexity: ["error", 10],
    "sonarjs/cognitive-complexity": ["error", 15],
  },
},
```

The rule lives in the repo, not the base, until every repo of that language is at 0: ruff and
flat config have no conditional select, so a base `C901` would fail every repo still above 0.
When the last one graduates, the rule moves into `ruff.toml` or `eslint.base.mjs` and the repo
lines go. A `# noqa: C901` or `eslint-disable-next-line complexity` carries its reason on the
line, as PLC0415 does: once the key retires (docs/metrics-keys.md), nothing else counts them.
Python cognitive complexity (complexipy) has no ruff rule, so a Python repo adds
`bin/py_cognitive_lint.py` to its `ci-lint` recipe instead, at any count (the python-fastapi
scaffold has it). Before graduation it fails any function over 15 in the `.py` files changed
since origin/main, committed or not, so the file a lane edits leaves at 15 or under. finplat
#670's sweep named the same helper-extraction shape three times, and ruff's PLR0912/PLR0915
caught only 4 of its 16 functions. Once the ratchet's `cognitive_over_15` bound is 0, the same
line lints the whole tree with no edit, because it reads the bound. An ignore comment does not
count: complexipy runs with `--no-ignore`, as the collector does.

```make
ci-lint: ci-deps
	uv run ruff check server tests
	uv run python devkit/bin/py_cognitive_lint.py --root . --src server --scope backend
```

## Changed-file rules

Some rules have debt in the fleet, so a base cannot select them: the base lints the whole tree,
and every repo above 0 would fail at its next sync. `bin/changed_lint.py` holds such a rule only
in the files a change touches, the files `py_cognitive_lint.py` reads (`bin/_changed_files.py`:
everything that differs from the merge-base with origin/main, committed or not; in a repo with
no remote yet, every file). The debt drains as files are touched, and a new instance fails in
the edit that writes it.

| Tool | Rule | Threshold lives in | ci-lint line |
|---|---|---|---|
| ruff | `PLR0916`, too many boolean expressions in one `if` (preview, so the three run alone) | `ruff.toml` `[lint.pylint] max-bool-expr = 5` | `uv run python devkit/bin/changed_lint.py ruff --root . --src server` |
| ruff | `PLR0915`, too many statements in one function | `ruff.toml` `[lint.pylint] max-statements = 50` | the same line |
| ruff | `PLR1702`, too many nested blocks (preview) | `ruff.toml` `[lint.pylint] max-nested-blocks = 5` | the same line |
| eslint | `sonarjs/expression-complexity`, at most 4 `&&`/`\|\|`/`?:` operators (five terms) | `eslint.base.mjs` `sonarjsChangedRules` | `python3 -I devkit/bin/changed_lint.py eslint --root frontend --src src` (`--ext .vue` for components) |

**A repo whose whole-tree count is 0 enables the rule tree-wide in its own config instead of
adding the changed-file line** (instalite, 2026-10-19): `sonarjs/expression-complexity` in its
eslint layer from `sonarjsChangedRules`, ruff `PLR0915` in `extend-select`. The line is for a
repo above 0; it drops the line for the same tree-wide rule the day its count reaches 0. The
one exception is ruff's two preview rules (PLR0916, PLR1702): tree-wide they need `lint.preview`,
which changes other rules' verdicts, so a repo at 0 keeps the line for those two. At 0 the line
holds the same tree, since a new finding can only appear in a file the change touches.

PLR0915 and PLR1702 (2026-10-19): finplat's pass-7 lane split five long functions along their
phases, each of which these flag; the fix is that split, or early returns and a helper per inner
loop, never a disable comment. The two boolean thresholds are one rule: five terms. finplat's and rollcall's 2026-10-18 lanes
extracted a named predicate from a repeated multi-term `&&`/`||` chain six times, and a
16-term `||` list drifted. The fix is the same shape: a named predicate function, or a set or
table for a membership list, never a disable comment. The eslint run needs eslint-plugin-sonarjs
under `--root` and keeps the repo's own config (parser, plugins); the ruff run uses the repo's
interpreter, so its lockfile's ruff judges. A repo with no Python project env (homelab, devkit)
declares `--ruff-from release` instead: `python3 -I devkit/bin/changed_lint.py ruff --ruff-from
release --root . --src stacks` runs release_tool.sh's pinned, checksummed ruff, installed once
per machine. It is never a fallback: a repo whose env lacks ruff still fails with the hint.

Whole-tree counts on 2026-10-21, each repo's origin/main, own code only (the vendored `devkit/`
excluded; devkit excludes `templates/` and `tests/fixtures`). ruff 0.17.1 (release_tool.sh's pin;
count from `--output-format json`, since 0.17's concise format prints rule names, not codes);
eslint 9 with eslint-plugin-sonarjs 4.2, every TS/JS/Vue file outside build output, so tests
and scripts count; instalite's generated `Resources/filter.js` bundle is left out.

| Repo | PLR0916 | PLR0915 | PLR1702 | expression-complexity |
|---|---|---|---|---|
| finplat | 1 | 3 | 0 | 5 |
| orbit | 0 | 3 | 1 | 2 |
| locus | 0 | 5 | 0 | 1 |
| closet | 0 | 0 | 0 | 7 |
| rollcall | 0 | 0 | 0 | 1 |
| devkit | 0 | 0 | 0 | 1 |
| instalite | 0 | 0 | 0 | 0 |
| redlib | 0 | 0 | 0 | 0 |
| homelab | 0 | 0 | 0 | no JS/TS |

devkit's root `ruff.toml` extends this base and holds its full `select` plus PLR0915 tree-wide.

**A base `select` rule a repo still owes** is ignored in its own config and held with `--hold
<rule>` on the ruff line (`RUFF_HOLDABLE` in changed_lint.py, today E501): the command line's
`--select` wins over the config's `ignore`. A held rule judges only the lines the change adds or
rewrites (`git diff -U0` against the merge-base; a pure move has none), so the first PR into a
file pays for its own lines, not the file's history, and the debt drains as lines are touched.
The rules judged on the whole changed file are `FILE_SCOPED` in changed_lint.py: PLR0915,
PLR0916, PLR1702 and expression-complexity report on a def's or a statement's first line, which
the edit that grows its body never touches. devkit holds E501 this way (2026-10-21); the repo
drops the ignore and the flag at 0.

Once every repo is at 0, the rule moves into the base (`select`, or `sonarjsRules`) and leaves the table.

## vitest

`vitest.base.mjs` stretches vitest's per-test timeouts by the load factor the gate and
tier_guard.sh already apply to budgets: both export it as `DEVKIT_LOAD_SCALE` (1 unscaled, at
most 2; `bin/_load_lib.sh`). finplat #689's frontend-unit hit the 5 s default at load 169 on 10
cores while its tier budget had stretched ×2. It imports nothing but node builtins (the eslint
base: nothing), and `vitest.base.d.mts` types it for a `vitest.config.ts`. The scaffolds spread `timeouts`
(vitest's 5 s and 10 s defaults, stretched); a repo's own timeout goes through `loadScaled`:

```js
import { loadScaled, timeouts } from "../devkit/lint/vitest.base.mjs"

  test: { ...timeouts, include: ["src/**/*.test.ts"] },
  test: { testTimeout: loadScaled(180_000) },   // finplat's metrics config
```

`clockShift()` is the vitest half of the clock shift (README "Clock shift"): under
`DEVKIT_CLOCK_SHIFT`, a vite plugin that lists tier_guard.sh's setup file first in `setupFiles`
and adds it to vite's resolved `server.fs.allow` (never narrowing the default or the repo's own
list), else no plugin. It goes in the root config's `plugins: [clockShift()]`; one export, so a
config cannot list the file without allowing it (orbit #124). It reads the setup file's
realpath (`node:fs`), since vite checks the resolved path. `clockShiftSetupFiles`, the file
alone (the repo allows it itself), is deprecated since 2026-10-24 and devkit-check names each
config still importing it.

## Retiring an export

Repo-owned configs import the bases by name and devkit-sync cannot edit them, so `exports.txt`
lists every export of `eslint.base.mjs` and `vitest.base.mjs`. To retire one, keep it and mark
its line `deprecated <date> <migration>`: devkit-check warns each consumer file importing it, with
that migration, and the line and export go 30 days later. `tests/lint_contract.bats` holds each
module's exports to the list and refuses a line leaving it early (against the merge base).

## swift-format

swift-format has no `extends`, so `swift-format.json` cannot be referenced; the repo's
`.swift-format` (at the root, or beside the sources, e.g. locus `ios/`) is a byte copy:
`cp devkit/lint/swift-format.json .swift-format`. `devkit-check` fails `ci-quick` when any
tracked `.swift-format` differs from the vendored base, naming the file and the restore. A rule
change is a devkit PR; each repo's `devkit-sync` then refreshes every tracked copy in its own
commit (it never creates one), so that commit passes its devkit-check. The base is
instalite's config as of 2026-10-16.

## shellcheck

`shellcheckrc` is the shellcheck base: follow `source` into files not on the command line,
resolved beside the script (`external-sources`, `source-path=SCRIPTDIR`). shellcheckrc has no
include and shellcheck reads only the first `.shellcheckrc` it finds, so `bin/shellcheck.sh`
hands shellcheck one `--rcfile`: this base, then the repo's own `.shellcheckrc` appended. Later
lines win for a scalar key and `disable` lists accumulate, the kit's base-merge rule below. The
version is devkit's (`bin/release_tool.sh`, 0.11.0 with its checksums), so every repo, hook and
`metrics/shell.py` run lints with one shellcheck under one config. A plain `shellcheck` by hand
sees neither the pin nor the base.

## Bases the collectors merge

knip, jscpd and vulture have no `extends`, and in this fleet only devkit's collectors run them
(`scripts/ci/metrics.conf`). So the collector merges the base under the repo's own config and
hands the tool the result as `--config`, opt-in per collector line. The merge is one rule
everywhere (`mergeConfig` in `metrics/_lib.mjs`, `merge_config` in `metrics/python.py`): lists
are unions, base first, so a repo adds to an ignore list but cannot silently drop a base entry.
Tables merge key by key, and any other repo value wins. Keep in the repo only what names its
own code. Opting in can move the numbers, so the adopting PR runs `make metrics-tighten`, or
`make metrics-rebaseline KEYS=<key>[,<key>]` for the keys that rose (commit, then label the PR
`metrics-rebaseline`).

| Base | Collector flag | Holds | Stays in the repo |
|---|---|---|---|
| `knip.base.jsonc` | `ts.mjs --knip --knip-base` | `ignoreDependencies` for the tools devkit's collectors run (dependency-cruiser, eslint-plugin-sonarjs, jscpd); `ignore` `devkit/**` | entries, `paths`, `ignoreBinaries`, stack choices such as shadcn/ui's `src/components/ui/**` and openapi-typescript's `schema.d.ts` |
| `jscpd.base.json` | `jscpd.mjs --base` | `ignore`: tests (`tests/`, `test/`, `__tests__/`, `test-helpers/`, `*.test.*`, `*.spec.*`, `test-setup.*`, `conftest.py`), `*.d.ts`, and non-code: `*.md`, `*.txt` (a font's OFL licence), `LICENSE`/`LICENCE`/`COPYING` and lockfiles | `format`, extra ignores; `--min-tokens` stays a flag |
| `vulture.toml` | `python.py --vulture --vulture-base <set>[,<set>…]` | `[tool.vulture] min_confidence = 60`; decorator sets `fastapi`, `flask`, `pydantic`, `sqlalchemy` | `paths`, whitelist files, `ignore_names` |

The repo config is read where the tool would read it: knip's `knip.json[c]`/`.knip.json[c]` or
package.json `knip` under `--root` (a `knip.ts` is code and is exit 2), jscpd's `.jscpd.json` or
package.json `jscpd` in the working directory, and vulture's `[tool.vulture]` in
`<root>/pyproject.toml`. The tools resolve the merged file's globs and paths against their
working directory, so the temporary file lives outside the repo.

A plain `npx knip` or `jscpd` run by hand does not see the base. Its only effect is the
devkit-run tools reported as unused dependencies and tests counted as clones.
