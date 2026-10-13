import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

export default defineConfig([
  ...nextVitals,
  ...nextTs,
  globalIgnores([
    // eslint-config-next's defaults, restated because globalIgnores replaces them.
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    // Vendored, and it carries other stacks' TypeScript templates: devkit-check owns it.
    "devkit/**",
    "playwright-report/**",
    "test-results/**",
  ]),
]);
