import { pingDatabase } from "@/db";
import { readiness } from "@/lib/health";
import { appVersion } from "@/lib/version";

export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
  const { status, body } = await readiness(appVersion(), { database: pingDatabase });
  return Response.json(body, { status });
}
