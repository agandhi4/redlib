import path from "node:path";

import { defineConfig } from "vitest/config";

// DB tier (`make ci-db`): scripts/ci/with_test_pg.sh exports DATABASE_URL for a fresh,
// migrated throwaway Postgres. Refuse to run against whatever else might be configured.
if (!process.env.DATABASE_URL) {
  throw new Error("tests/db needs DATABASE_URL; run them with `make ci-db`");
}

export default defineConfig({
  resolve: { alias: { "@": path.resolve(import.meta.dirname, "src") } },
  test: { include: ["tests/db/**/*.test.ts"] },
});
