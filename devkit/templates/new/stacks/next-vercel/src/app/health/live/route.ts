import { appVersion } from "@/lib/version";

// Per request, never prerendered: a cached body would report a stale version.
export const dynamic = "force-dynamic";

export function GET(): Response {
  return Response.json({ status: "up", version: appVersion() });
}
