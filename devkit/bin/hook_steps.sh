# shellcheck shell=bash
# The body of every repo's .githooks/pre-commit and pre-push (templates/githooks/). Sourced
# after quiet_run.sh, whose run_step it uses; defines run_hook_steps and runs nothing.
#
#   run_hook_steps <pre-commit|pre-push> "$@"     # the hook's own args; returns the hook's code
#
# The per-repo part is scripts/ci/hooks.conf, a sourced file:
#   PRE_COMMIT_STEPS=("backend: static=ci-backend-static" "frontend: static=ci-frontend-static")
#   PRE_PUSH_STEPS=("backend: unit=ci-backend-unit")
#   ENV_REQUIRED_HOOKS="pre-push"   # hooks to skip when the worktree has no .env (optional)
# Each step is "<label>=<make target>". Steps call the gate's own ci-* targets, never raw tools,
# so a hook cannot drift from the gate. They run in order and stop at the first failure.
# A listed hook loads ${HOOK_ENV_FILE:-<root>/.env} (shell-sourceable KEY=value, exported) or,
# with no such file, skips its checks with a one-line note. Scripted vitest runs share the box
# with agents and other worktrees, so VITEST_MAX_WORKERS defaults to 4 (closet #184).
#
# pre-push reads git's stdin once ("<local ref> <local sha> <remote ref> <remote sha>" lines),
# runs nothing for deletions and tag pushes, and exports PUSH_RANGES (bin/push_ranges.sh, one
# range per line) for targets that scope themselves.
# git-lfs: core.hooksPath makes git ignore .git/hooks, where `git lfs install` put its own
# pre-push. When .gitattributes uses LFS, every pre-push outcome that lets the push through
# (pass, skip, nothing to check) runs `git lfs pre-push` with the same args and stdin, or LFS
# objects would never upload. LFS without git-lfs installed blocks the push.

run_hook_steps() {
  local hook=$1
  shift
  local root conf step rc env_file push_input='' uses_lfs=0
  local PRE_COMMIT_STEPS PRE_PUSH_STEPS ENV_REQUIRED_HOOKS
  PRE_COMMIT_STEPS=()
  PRE_PUSH_STEPS=()
  ENV_REQUIRED_HOOKS=
  root=$(git rev-parse --show-toplevel) || return 1

  if [ "$hook" = pre-push ]; then
    push_input=$(cat)
    if grep -qs 'filter=lfs' "$root/.gitattributes"; then
      uses_lfs=1
      git lfs version >/dev/null 2>&1 || {
        echo "$hook: this repository uses Git LFS but git-lfs is not installed (brew install git-lfs)"
        return 2
      }
    fi
  fi

  conf=$root/scripts/ci/hooks.conf
  [ -f "$conf" ] || { echo "$hook: scripts/ci/hooks.conf is missing (format: devkit/bin/hook_steps.sh)"; return 1; }
  # shellcheck source=/dev/null
  . "$conf"

  local steps=()
  case "$hook" in
    pre-commit) steps=(${PRE_COMMIT_STEPS[@]+"${PRE_COMMIT_STEPS[@]}"}) ;;
    pre-push)
      PUSH_RANGES=$(printf '%s\n' "$push_input" | "$root/devkit/bin/push_ranges.sh" "${1:-origin}") || return $?
      if [ -z "$PUSH_RANGES" ]; then
        echo "✓ $hook: nothing to check (deletion or tag push)"
        _hook_allow_push "$uses_lfs" "$push_input" "$@"
        return
      fi
      export PUSH_RANGES
      steps=(${PRE_PUSH_STEPS[@]+"${PRE_PUSH_STEPS[@]}"})
      ;;
    *) echo "run_hook_steps: unknown hook '$hook' (expected pre-commit or pre-push)"; return 2 ;;
  esac

  export VITEST_MAX_WORKERS=${VITEST_MAX_WORKERS:-4}

  case " $ENV_REQUIRED_HOOKS " in
    *" $hook "*)
      env_file=${HOOK_ENV_FILE:-$root/.env}
      if [ ! -f "$env_file" ]; then
        echo "$hook: checks skipped, no env file at $env_file (set HOOK_ENV_FILE to use another)"
        _hook_allow_push "$uses_lfs" "$push_input" "$@"
        return
      fi
      set -a
      # shellcheck source=/dev/null
      . "$env_file"
      set +a
      ;;
  esac

  for step in ${steps[@]+"${steps[@]}"}; do
    case "$step" in *=?*) ;; *) echo "$hook: bad step '$step' in hooks.conf (want label=make-target)"; return 1 ;; esac
    rc=0
    run_step "${step%%=*}" make -C "$root" --no-print-directory "${step#*=}" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "$hook: blocked by '${step%%=*}'; fix it and try again"
      return "$rc"
    fi
  done

  echo "✓ $hook passed"
  _hook_allow_push "$uses_lfs" "$push_input" "$@"
}

# <uses_lfs> <push stdin> <hook args...>: the last word on a push that may go through.
# A no-op for pre-commit, which never sets uses_lfs.
_hook_allow_push() {
  local uses_lfs=$1 push_input=$2
  shift 2
  [ "$uses_lfs" = 1 ] || return 0
  if [ -n "$push_input" ]; then
    printf '%s\n' "$push_input" | git lfs pre-push "$@"
  else
    git lfs pre-push "$@" </dev/null
  fi
}
