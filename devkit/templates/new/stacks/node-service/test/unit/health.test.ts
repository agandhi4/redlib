// Hermetic: the server listens on an ephemeral port; no dependency is real.
import type { AddressInfo } from "node:net";

import { afterEach, describe, expect, it } from "vitest";

import { createApp } from "../../src/app.js";
import type { Checker } from "../../src/health.js";

const config = { port: 0, appVersion: "test", logLevel: "info" } as const;
let close: (() => Promise<void>) | undefined;

async function start(checkers: Record<string, Checker> = {}): Promise<string> {
  const server = createApp(config, checkers);
  await new Promise<void>((resolve) => server.listen(0, resolve));
  close = () => new Promise((resolve) => server.close(() => resolve()));
  const { port } = server.address() as AddressInfo;
  return `http://127.0.0.1:${port}`;
}

afterEach(async () => {
  await close?.();
});

describe("health", () => {
  it("live reports the version", async () => {
    const base = await start();
    const response = await fetch(`${base}/health/live`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "up", version: "test" });
  });

  it("ready is 503 when a check is down and names it", async () => {
    const base = await start({ database: async () => ({ status: "down" }) });
    const response = await fetch(`${base}/health/ready`);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      status: "down",
      version: "test",
      checks: { database: { status: "down" } },
    });
  });

  it("unknown paths are 404", async () => {
    const base = await start();
    const response = await fetch(`${base}/nope`);
    expect(response.status).toBe(404);
  });
});
