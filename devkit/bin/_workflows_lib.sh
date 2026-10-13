# shellcheck shell=bash
# Workflow helpers shared by release_check.sh and workflows_check.sh. Sourced from the repo root
# (both scripts cd there first); defines functions and runs nothing.
#
#   workflow_files              every .github/workflows/*.yml|yaml, one per line
#   image_push_steps <file>     "<line> <kind> <versioned>" for each step that pushes an image:
#     kind action      docker/build-push-action with `push:` not false
#     kind build-push  a `run:` step that builds and pushes (`docker build … --push`, or a build
#                      and a `docker push` in one script)
#     kind push        a `run:` step that only pushes (`docker push` of an image built earlier)
#     versioned        1 when the step passes APP_VERSION (`APP_VERSION=` under build-args:, or
#                      `--build-arg APP_VERSION=`), else 0; only meaningful for the two build kinds

workflow_files() {
  local f
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do [ -f "$f" ] && echo "$f"; done
}

# A step starts at "- <key>:" and ends at the next step at its indent or a line indented less.
image_push_steps() {
  awk '
    function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
    function judge() {
      if (!start) return
      if (is_action && pushes) print start " action " action_arg
      else if (!is_action && run_pushes) print start " " (builds ? "build-push" : "push") " " run_arg
      start = 0
    }
    /^[[:space:]]*(#|$)/ { next }
    start && indent($0) < step_ind { judge() }
    /^[[:space:]]*-[[:space:]]+[A-Za-z_-]+:/ && (!start || indent($0) == step_ind) {
      judge()
      start = NR; step_ind = indent($0)
      is_action = pushes = action_arg = builds = run_pushes = run_arg = in_args = 0
    }
    !start { next }
    in_args && indent($0) <= args_ind { in_args = 0 }
    /uses:[[:space:]]*["'"'"']?docker\/build-push-action/ { is_action = 1 }
    /^[[:space:]]*push:/ && $0 !~ /push:[[:space:]]*["'"'"']?false/ { pushes = 1 }
    /^[[:space:]]*build-args:/ { in_args = 1; args_ind = indent($0) }
    (in_args || /^[[:space:]]*build-args:/) && /APP_VERSION=/ { action_arg = 1 }
    /docker[[:space:]]+((buildx|image)[[:space:]]+)?build([[:space:]]|$)/ { builds = 1 }
    /(^|[[:space:]])--push([[:space:]]|$)|docker[[:space:]]+(image[[:space:]]+)?push([[:space:]]|$)/ { run_pushes = 1 }
    /--build-arg[=[:space:]]+["'"'"']?APP_VERSION=/ { run_arg = 1 }
    END { judge() }
  ' "$1"
}
