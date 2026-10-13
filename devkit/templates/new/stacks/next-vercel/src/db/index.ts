// The app's one Postgres pool and Drizzle handle. Module scope is right on Vercel: a warm
// function instance reuses it. Keep `max` small; a serverless pooler (Neon's -pooler URL)
// does the real multiplexing, and more connections per instance multiply by instance count.
import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import { Pool } from "pg";

import { databaseUrl } from "@/lib/env";

import * as schema from "./schema";

let pool: Pool | undefined;
let handle: NodePgDatabase<typeof schema> | undefined;

// Created on first use, so importing this module (next build does) never needs DATABASE_URL.
export function db(): NodePgDatabase<typeof schema> {
  if (!handle) {
    pool = new Pool({
      connectionString: databaseUrl(),
      max: 5,
      // pg's default is 0, waiting forever for a free client; fail fast instead.
      connectionTimeoutMillis: 10_000,
    });
    // REQUIRED: pg re-emits an idle client's error on the pool, and an unhandled 'error' event
    // kills the process (a serverless pooler drops idle connections routinely).
    pool.on("error", (error) => {
      console.error(JSON.stringify({ level: "error", logger: "__NAME__.db", msg: "idle client error", error: String(error) }));
    });
    handle = drizzle({ client: pool, schema });
  }
  return handle;
}

// The /health/ready database check: one round-trip.
export async function pingDatabase(): Promise<void> {
  await db().execute("select 1");
}
