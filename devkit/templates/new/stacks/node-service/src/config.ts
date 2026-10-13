// Every environment variable the service reads is declared here; .env.example mirrors it.
export interface Config {
  readonly port: number;
  // Baked into the image by the build (ARG -> ENV); never set in compose. Reported by
  // /health/ready and the boot log line (observability.md, Release Identity).
  readonly appVersion: string;
  readonly logLevel: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    port: Number(env["PORT"] ?? 3000),
    appVersion: env["APP_VERSION"] ?? "dev",
    logLevel: env["LOG_LEVEL"] ?? "info",
  };
}
