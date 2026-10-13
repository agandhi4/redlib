// Against the throwaway Postgres `make ci-db` provisions and migrates (with_test_pg.sh).
import { describe, expect, it } from "vitest";

import { pingDatabase } from "@/db";
import { readiness } from "@/lib/health";

describe("readiness against Postgres", () => {
  it("is up when the database answers", async () => {
    const health = await readiness("test", { database: pingDatabase });
    expect(health.status).toBe(200);
  });
});
