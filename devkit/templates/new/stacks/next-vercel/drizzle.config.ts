import { loadEnvConfig } from "@next/env";
import { defineConfig } from "drizzle-kit";

// .env.local the way Next loads it; the shell's DATABASE_URL wins (scripts/ci/with_test_pg.sh
// and the Makefile's drift check rely on that). `generate` never connects: the Makefile runs
// it with a placeholder URL to detect drift.
loadEnvConfig(process.cwd());

const url = process.env.DATABASE_URL;
if (!url) throw new Error("DATABASE_URL is not set (copy .env.example to .env.local)");

export default defineConfig({
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "postgresql",
  dbCredentials: { url },
});
