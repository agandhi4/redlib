import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  use: { baseURL: "http://localhost:3000" },
  webServer: {
    command: "npm run dev",
    url: "http://localhost:3000/health/live",
    // `make ci-e2e` sets CI=1: a stray dev server on :3000 then fails the run instead of
    // silently serving it from other code and another database.
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
});
