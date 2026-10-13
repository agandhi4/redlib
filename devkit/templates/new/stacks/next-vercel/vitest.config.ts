import path from "node:path";

import { defineConfig } from "vitest/config";

// Hermetic tiers only (`make ci-unit`). tests/db needs Postgres: vitest.db.config.ts.
export default defineConfig({
  resolve: { alias: { "@": path.resolve(import.meta.dirname, "src") } },
  test: { include: ["tests/unit/**/*.test.ts"] },
});
