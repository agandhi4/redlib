#!/usr/bin/env bash
# Run a command against a fresh, fully migrated throwaway Postgres. Used by `make ci-db` and
# `make ci-e2e`, so the gate and a laptop provision the database the same way.
# Usage: PG_CONTAINER=<name> scripts/ci/with_test_pg.sh <command...>
#
# Exports DATABASE_URL for <command>. The shell's DATABASE_URL beats .env.local everywhere
# (drizzle.config.ts, vitest.db.config.ts, `next dev`), so a developer's .env.local never
# points a test run at the dev database. The container is removed on exit, pass or fail.
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: PG_CONTAINER=<name> $0 <command...>" >&2; exit 2; }
NAME=${PG_CONTAINER:?PG_CONTAINER must name the throwaway container (the Makefile sets it)}
PG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/devkit/bin/throwaway_pg.sh"

trap '"$PG" down "$NAME"' EXIT
"$PG" up "$NAME" >/dev/null
DATABASE_URL=$("$PG" url "$NAME")
export DATABASE_URL

echo "with_test_pg: migrating $NAME" >&2
npm run db:migrate
"$@"
