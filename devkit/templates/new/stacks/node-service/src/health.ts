// Health contract (~/.claude/conventions/observability.md, Health Contract).
// /health/live checks nothing and answers 200 while the process serves. /health/ready runs
// every registered check and answers 503 when one is down. The body names what is down,
// never why: the endpoint is unauthenticated, so the detail goes to the log.
import type { IncomingMessage, ServerResponse } from "node:http";

export interface Check {
  readonly status: "up" | "down";
}
export type Checker = () => Promise<Check>;

export function healthHandler(
  version: string,
  checkers: Readonly<Record<string, Checker>>,
) {
  return async (
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<boolean> => {
    if (req.url === "/health/live") {
      sendJson(res, 200, { status: "up", version });
      return true;
    }
    if (req.url === "/health/ready") {
      const checks: Record<string, Check> = {};
      for (const [name, check] of Object.entries(checkers)) {
        checks[name] = await check().catch(() => ({ status: "down" }));
      }
      const up = Object.values(checks).every((c) => c.status === "up");
      sendJson(res, up ? 200 : 503, {
        status: up ? "up" : "down",
        version,
        checks,
      });
      return true;
    }
    return false;
  };
}

export function sendJson(
  res: ServerResponse,
  status: number,
  body: unknown,
): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}
