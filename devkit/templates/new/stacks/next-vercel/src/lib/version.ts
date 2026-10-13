// Release identity (~/.claude/conventions/observability.md): the one version string /health
// reports. Vercel exposes the deployed commit as VERCEL_GIT_COMMIT_SHA (a system env var, on by
// default), so the fleet's `sha-<7>` shape needs no build step; APP_VERSION overrides it
// anywhere else (a self-hosted build), and a local `next dev` is `dev`.
export function appVersion(
  env: Readonly<Record<string, string | undefined>> = process.env,
): string {
  const sha = env["VERCEL_GIT_COMMIT_SHA"];
  if (sha) return `sha-${sha.slice(0, 7)}`;
  return env["APP_VERSION"] ?? "dev";
}
