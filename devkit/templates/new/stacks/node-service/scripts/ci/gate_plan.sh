# shellcheck shell=bash disable=SC2034  # GATE_* are read by the skeleton that sources this
# __NAME__'s gate plan, sourced by devkit/bin/local_gate.sh (contract in its header).
# Which jobs run for which changed paths; every job is a `make ci-*` target the workflows
# also call.
#
#   *.md, docs/** only                 -> nothing (pass)
#     ...but an AGENTS.md/CLAUDE.md change -> docs (docs-check only; Actions skips *.md PRs)
#   anything else                      -> quick + unit, and image when it can change
GATE_SLUG=agandhi4/__NAME__
GATE_STATE_NAME=__NAME__-gate

#@image
# Paths that can change how the production image builds or boots. Widen this as the image
# grows; a code-only PR that breaks boot is still caught by publish.yml's smoke before push.
IMAGE_PATHS='^(Dockerfile|\.dockerignore|package\.json|package-lock\.json|tsconfig[^/]*\.json|scripts/ci/smoke_image\.sh)$'
IMAGE="__NAME__:gate-$PR"

gate_cleanup() {
  docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
}
#@end

gate_plan() {
  local code=0 agent_docs=0 path
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
    skip quick "docs-only change"; skip unit "docs-only change"
    skip image "docs-only change"
    return
  fi

  # Also on Actions, but a draft PR or a cancelled run never reported it, and this is the
  # status the merge queue reads.
  job quick ci-quick
  job unit ci-unit
  skip db "no database tier yet (ci-db is a stub)"
  skip e2e "no browser tier yet (ci-e2e is a stub)"
#@image
  if changed "$IMAGE_PATHS"; then
    job image ci-image CI_IMAGE="$IMAGE" CI_BUILD_VERSION="gate-$PR"
  else
    skip image "no image-affecting paths changed"
  fi
#@end
#@no-image
  skip image "no image is published (devkit new --no-image)"
#@end
}
