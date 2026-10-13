// The HTTP server. Used by: src/main.ts (process entry), test/ (started on port 0).
import { createServer, type Server } from "node:http";

import type { Config } from "./config.js";
import { healthHandler, sendJson, type Checker } from "./health.js";

export function createApp(
  config: Config,
  checkers: Readonly<Record<string, Checker>> = {},
): Server {
  const health = healthHandler(config.appVersion, checkers);
  return createServer((req, res) => {
    void health(req, res).then((handled) => {
      if (!handled) sendJson(res, 404, { status: "not found" });
    });
  });
}
