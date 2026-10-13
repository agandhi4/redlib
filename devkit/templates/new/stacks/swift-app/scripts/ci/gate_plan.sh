# shellcheck shell=bash disable=SC2034  # GATE_* are read by the skeleton that sources this
# __NAME__'s gate plan, sourced by devkit/bin/local_gate.sh (contract in its header).
# Which jobs run for which changed paths; every job is a `make ci-*` target the hooks and
# Actions also call.
#
#   *.md, docs/** only                 -> nothing (pass)
#     ...but an AGENTS.md/CLAUDE.md change -> docs (docs-check only; Actions skips *.md PRs)
#   anything else, on macOS            -> quick (guards + swift-format), swift (build), unit
#                                         (Swift Testing on the newest iPhone simulator)
#   anything else, elsewhere           -> guards; the Xcode jobs are skipped "mac only", never
#                                         failed, so a Linux gate box still reports something
GATE_SLUG=agandhi4/__NAME__
GATE_STATE_NAME=__NAME__-gate

gate_plan() {
  local code=0 agent_docs=0 path j
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      AGENTS.md|*/AGENTS.md|CLAUDE.md|*/CLAUDE.md) agent_docs=1 ;;
      *.md|docs/*) ;;
      *) code=1 ;;
    esac
  done <<< "$CHANGED"

  if [ "$code" = 0 ]; then
    [ "$agent_docs" = 1 ] || nothing_to_run "docs-only change"
    job docs docs-check
    for j in quick swift unit; do skip "$j" "docs-only change"; done
    return
  fi

  skip db "no database tier (ci-db is a stub)"
  skip e2e "no UI-test tier yet (ci-e2e is a stub)"
  skip image "no image is published (an iOS app ships through Xcode and TestFlight)"
  if [ "$(uname)" != Darwin ]; then
    job guards ci-guards
    for j in quick swift unit; do skip "$j" "mac only"; done
    return
  fi
  # Also on Actions as ci-guards, but a draft PR or a cancelled run never reported it, and this
  # is the status the merge queue reads. ci-swift before ci-unit, so a build failure is
  # reported as one rather than as a failed test run.
  job quick ci-quick
  job swift ci-swift
  job unit ci-unit
}
