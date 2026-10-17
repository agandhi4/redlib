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
