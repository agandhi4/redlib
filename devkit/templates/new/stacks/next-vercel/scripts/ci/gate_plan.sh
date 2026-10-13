# shellcheck shell=bash disable=SC2034  # GATE_* are read by the skeleton that sources this
# __NAME__'s gate plan, sourced by devkit/bin/local_gate.sh (contract in its header).
# Which jobs run for which changed paths; every job is a `make ci-*` target the workflows
# also call. No image job: Vercel builds the app, and ci-build is the closest local check.
#
#   *.md, docs/** only                 -> nothing (pass)
#     ...but an AGENTS.md/CLAUDE.md change -> docs (docs-check only; Actions skips *.md PRs)
#   tests/unit/**, .github/**, renovate.json
#                                      -> quick + unit
#   drizzle/**, tests/db/**, drizzle.config.ts, vitest.db.config.ts
#                                      -> quick + unit + db
#   src/**, public/**, tests/e2e/**, playwright.config.ts, next.config.ts
#                                      -> quick + unit + e2e + build (src/db/** also db)
#   anything else (package*.json, Makefile, configs, scripts/, devkit/, ...)
#                                      -> everything
GATE_SLUG=agandhi4/__NAME__
GATE_STATE_NAME=__NAME__-gate
PG_CONTAINER="__NAME__-gate-$PR-pg"

gate_cleanup() {
  # with_test_pg.sh removes its container on exit; this covers a gate killed mid-job.
  docker rm -fv "$PG_CONTAINER" >/dev/null 2>&1 || true
}

gate_plan() {
  local code=0 agent_docs=0 db=0 app=0 all=0 path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      AGENTS.md|*/AGENTS.md|CLAUDE.md|*/CLAUDE.md) agent_docs=1 ;;
      *.md|docs/*) ;;
      tests/unit/*|.github/*|renovate.json) code=1 ;;
      drizzle/*|tests/db/*|drizzle.config.ts|vitest.db.config.ts) code=1; db=1 ;;
      src/db/*) code=1; db=1; app=1 ;;
      src/*|public/*|tests/e2e/*|playwright.config.ts|next.config.ts) code=1; app=1 ;;
      *) code=1; all=1 ;;
    esac
  done <<< "$CHANGED"
  [ "$all" = 1 ] && { db=1; app=1; }

  if [ "$code" = 0 ]; then
    [ "$agent_docs" = 1 ] || nothing_to_run "docs-only change"
    job docs docs-check
    for j in quick unit db e2e build; do skip "$j" "docs-only change"; done
    skip image "Vercel builds the app (no image)"
    return
  fi

  # Also on Actions, but a draft PR or a cancelled run never reported it, and this is the
  # status the merge queue reads.
  job quick ci-quick
  job unit ci-unit
  if [ "$db" = 1 ]; then job db ci-db PG_CONTAINER="$PG_CONTAINER"; else skip db "no schema, migration or DB-test changes"; fi
  if [ "$app" = 1 ]; then
    job e2e ci-e2e PG_CONTAINER="$PG_CONTAINER"
    job build ci-build
  else
    skip e2e "no app or e2e changes"
    skip build "no app changes"
  fi
  skip image "Vercel builds the app (no image)"
}
