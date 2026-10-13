// Hermetic: readiness() with stand-in checks; no database, no server.
import { afterEach, describe, expect, it, vi } from "vitest";

import { readiness } from "@/lib/health";
import { appVersion } from "@/lib/version";

afterEach(() => {
  vi.restoreAllMocks();
});

describe("readiness", () => {
  it("is 200 and up when every check passes", async () => {
    const health = await readiness("test", { database: async () => {} });
    expect(health).toEqual({
      status: 200,
      body: { status: "up", version: "test", checks: { database: { status: "up" } } },
    });
  });

  it("is 503 and names the check that is down, never why", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const health = await readiness("test", {
      cache: async () => {},
      database: async () => {
        throw new Error("password authentication failed");
      },
    });
    expect(health.status).toBe(503);
    expect(health.body).toEqual({
      status: "down",
      version: "test",
      checks: { cache: { status: "up" }, database: { status: "down" } },
    });
    expect(JSON.stringify(health.body)).not.toContain("password");
  });

  it("counts a hung check as down after the timeout", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const health = await readiness("test", { database: () => new Promise(() => {}) }, 10);
    expect(health.body.checks["database"]).toEqual({ status: "down" });
  });
});

describe("appVersion", () => {
  it("is sha-<7> of the Vercel commit, else APP_VERSION, else dev", () => {
    expect(appVersion({ VERCEL_GIT_COMMIT_SHA: "0123456789abcdef", APP_VERSION: "x" })).toBe("sha-0123456");
    expect(appVersion({ APP_VERSION: "ci-abc1234" })).toBe("ci-abc1234");
    expect(appVersion({})).toBe("dev");
  });
});
