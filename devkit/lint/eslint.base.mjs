// Shared ESLint base: the frontend.md and observability.md rules that core ESLint can hold.
// A repo spreads it FIRST in its flat config, then its own recommended and framework layers
// (lint/README.md shows the tseslint.config and defineConfig shapes).
//
// Gotcha: this file imports nothing, on purpose. It is vendored at <repo>/devkit/lint/, and Node
// resolves an import from the importing file's ancestors, so a package.json in a subdirectory
// (locus/web, finplat/frontend, orbit/frontend, instalite/web) is invisible from here: importing
// typescript-eslint failed with ERR_MODULE_NOT_FOUND. Core rules need no plugin, and each repo
// already brings @eslint/js and typescript-eslint recommended (directly, via eslint-config-next,
// or via @vue/eslint-config-typescript).
const htmlSink = (property) => ({
  property,
  message: `${property} renders HTML: frontend.md Security forbids it with unsanitised input. Use textContent or DOM nodes.`,
});

export default [
  {
    name: "devkit/base",
    rules: {
      // observability.md: never console.* in app code; a repo's logger module is the one
      // file-level override.
      "no-console": "error",
      // frontend.md Security: no eval, and no string-to-code through setTimeout/Function.
      "no-eval": "error",
      "no-implied-eval": "error",
      "no-restricted-properties": [
        "error",
        htmlSink("innerHTML"),
        htmlSink("outerHTML"),
        htmlSink("insertAdjacentHTML"),
      ],
    },
  },
];

// eslint-plugin-sonarjs rules, as plain rule maps rather than config objects: the plugin must be
// registered in the same files scope that uses its rules ("Could not find plugin" otherwise), and
// only the repo knows that scope. So a repo spreads these into its own sonarjs layer
// (lint/README.md "sonarjs"); a repo without the plugin ignores them. Both rules were named by
// two refactor sweeps (finplat #663, instalite #22).
export const sonarjsRules = {
  // Nested ternaries were the load-state pattern (loading ? … : error ? … : …) flattened 5x.
  "sonarjs/no-nested-conditional": "error",
  // 3 is sonar's default; it catches the copy-pasted rows (instalite health.ts labels at 3x and
  // 4x) that the sweeps turned into tables.
  "sonarjs/no-duplicate-string": ["error", { threshold: 3 }],
};

// Rules held only in the files a change touches until a repo's count is 0 (lint/README.md
// "Changed-file rules"): bin/changed_lint.py eslint passes this map as --rule over those files.
// Not in sonarjsRules yet, which lints the whole tree: the existing debt would fail every repo.
// A rule graduates into sonarjsRules once every repo is at 0. finplat's and rollcall's 2026-10-18
// lanes extracted a named predicate from a repeated multi-term &&/|| chain six times, and a
// 16-term || list drifted. max counts &&, || and ?: operators, so 4 is five terms: the same
// chain ruff's PLR0916 allows (max-bool-expr 5 in lint/ruff.toml).
export const sonarjsChangedRules = {
  "sonarjs/expression-complexity": ["error", { max: 4 }],
};

// For the repo's test-file layer: repeated literals in tests (titles, fixture ids, expected
// text) are the readable form, and they were 87% of the 2026-10-17 fleet dry run's duplicate-string findings.
export const sonarjsTestRules = {
  "sonarjs/no-duplicate-string": "off",
};
