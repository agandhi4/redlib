// Health contract (~/.claude/conventions/observability.md, Health Contract).
// /health/live checks nothing and answers 200 while the app serves. /health/ready runs every
// registered check and answers 503 when one is down. The body names what is down, never why:
// the endpoint is unauthenticated, so the detail goes to the log.
// Used by: src/app/health/*/route.ts. Pure, so tests/unit covers it without a database.

export type Checker = () => Promise<void>;

export interface Health {
  readonly status: 200 | 503;
  readonly body: {
    readonly status: "up" | "down";
    readonly version: string;
    readonly checks: Record<string, { readonly status: "up" | "down" }>;
  };
}

// A check that has not answered by then is down: a hung database must not hang the probe.
export const CHECK_TIMEOUT_MS = 3_000;

export async function readiness(
  version: string,
  checkers: Readonly<Record<string, Checker>>,
  timeoutMs: number = CHECK_TIMEOUT_MS,
): Promise<Health> {
  const names = Object.keys(checkers);
  const results = await Promise.all(
    names.map((name) => passes(checkers[name]!, timeoutMs, name)),
  );
  const checks = Object.fromEntries(
    names.map((name, i) => [name, { status: results[i] ? "up" : "down" }] as const),
  );
  const up = results.every(Boolean);
  return { status: up ? 200 : 503, body: { status: up ? "up" : "down", version, checks } };
}

async function passes(check: Checker, timeoutMs: number, name: string): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out after ${timeoutMs} ms`)), timeoutMs);
  });
  try {
    await Promise.race([check(), timeout]);
    return true;
  } catch (error) {
    // The reason goes to the log, never into the unauthenticated body.
    console.error(
      JSON.stringify({ level: "error", logger: "__NAME__.health", msg: "check down", check: name, error: String(error) }),
    );
    return false;
  } finally {
    clearTimeout(timer);
  }
}
