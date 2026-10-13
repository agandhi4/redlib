// Every environment variable the app reads, read once; .env.example mirrors this file.
// Fails at first use, not at import, so `next build` (which imports route modules) needs no
// database; the Makefile's ci-build still passes a placeholder that cannot connect.
export function databaseUrl(): string {
  const url = process.env["DATABASE_URL"];
  if (!url) throw new Error("DATABASE_URL is not set (copy .env.example to .env.local)");
  return url;
}
