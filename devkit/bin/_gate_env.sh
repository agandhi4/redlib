# shellcheck shell=bash
# The per-machine gate.env parser, the plan-literal reader, and the one way bin/ fetches main.
# Sourced; defines functions and runs nothing.
#
#   gate_env_load <who> <apply-keys> <ignore-keys>
#       Parse ${XDG_CONFIG_HOME:-$HOME/.config}/devkit/gate.env, the per-machine config.
#       It is parsed, never sourced: `KEY=value` lines, blank lines and full-line `#` comments.
#       Keys are `|`-separated names. An apply-key sets the variable unless the environment
#       already has a non-empty value (env wins). An ignore-key is accepted and left alone. Any
#       other line, or a value with quotes, `$`, `;`, `#` or other shell syntax, is exit 2
#       naming the line. Used by: tier_guard.sh, which applies GATE_CAPACITY (the admission
#       pool, _slot_lib.sh) and ignores the rest of the two lists below.
#   gate_plan_literal <plan> <NAME>
#       Print the value of a literal `NAME=value` line in a plan without sourcing it (a caller
#       must not run plan code just to learn the slug). Empty when absent. Used for GATE_SLUG
#       and merge_rules.sh's GATE_MERGE_REQUIRES (a comma-separated list).
#   fetch_main <dir> [refspec...]
#       Fetch <dir>'s origin main into refs/remotes/origin/main, and any extra refspecs in the
#       same fetch, quietly and without tags. The explicit refspec is the point: a bare
#       `git fetch origin main` updates origin/main only when the clone's fetch refspec covers
#       main, so a --single-branch clone of another branch keeps a stale or missing origin/main
#       (devkit #204). Every main fetch in bin/ goes through here; callers keep their own error.
#   gate_plan_main <root>
#       Fetch <root>'s origin main (fetch_main) quietly and read the literal GATE_SLUG
#       (owner/repo, nothing that climbs) from origin/main's plan, not the working tree's: set
#       PLAN_MAIN and PLAN_SLUG, or PLAN_ERROR and return 1. Used by dependency_merge.sh (which
#       runs from a worktree of that commit) and its installer, so a stale or dirty local
#       checkout is judged by the tree the job will run (redlib, 35 behind).

# The deleted gate's keys (devkit 2026-11-02): ignored, never refused, so a machine's existing
# gate.env stays valid for tier_guard.sh.
# shellcheck disable=SC2034  # read by tier_guard.sh, which sources this file
GATE_REMOTE_KEYS='GATE_REMOTE|GATE_REMOTE_HOST|GATE_REMOTE_ROOT|GATE_REMOTE_SSH_OPTS'
# Gotcha: an older vendored copy exits 2 on a key it does not know, so never drop a key from
# these lists while a repo may still vendor a copy that reads gate.env.
# shellcheck disable=SC2034  # same
GATE_LOCAL_KEYS='GATE_CAPACITY|GATE_SLOTS|GATE_SILENCE_SECONDS|GATE_CLEANUP_SECONDS|GATE_JOB_BUDGET_MINUTES|GATE_BUDGET_MINUTES|GATE_BUDGET_ENFORCE|GATE_LOAD_MAX|GATE_LOAD_WAIT_MINUTES'

gate_env_load() { # <who> <apply-keys> <ignore-keys>
  local who=$1 apply=$2 ignore=$3 file line key value n=0
  local value_re='^[[:space:]]*([A-Z_]+)=([A-Za-z0-9@%+=:,./~ _-]*)$'
  file="${XDG_CONFIG_HOME:-$HOME/.config}/devkit/gate.env"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then continue; fi
    if [[ "$line" =~ $value_re ]]; then
      key=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[2]}   # captured now: the key matches below overwrite BASH_REMATCH
      value=${value%"${value##*[![:space:]]}"}   # trailing blanks are not part of a value
      if [[ "$key" =~ ^($apply)$ ]]; then
        [ -n "${!key:-}" ] || printf -v "$key" '%s' "$value"
        continue
      fi
      if [[ "$key" =~ ^($ignore)$ ]]; then continue; fi
    fi
    echo "$who: $file:$n: expected one of ${apply//|/, }, ${ignore//|/, } as KEY=value (got '$line')" >&2
    exit 2
  done <"$file"
}

gate_plan_literal() { # <plan> <NAME>
  sed -n "s/^$2=\\([A-Za-z0-9._,\\/-]*\\)[[:space:]]*\\(#.*\\)\\{0,1\\}\$/\\1/p" "$1" | head -1
}

fetch_main() { # <dir> [refspec...]
  local dir=$1
  shift
  git -C "$dir" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main "$@"
}

gate_plan_main() { # <root>
  local plan
  PLAN_MAIN='' PLAN_SLUG='' PLAN_ERROR=''
  fetch_main "$1" || { PLAN_ERROR="git fetch origin main failed (above)"; return 1; }
  # The full ref: a local branch named origin/main would otherwise win.
  PLAN_MAIN=$(git -C "$1" rev-parse --verify -q refs/remotes/origin/main) || { PLAN_ERROR="no origin/main"; return 1; }
  plan=$(git -C "$1" show "$PLAN_MAIN:scripts/ci/gate_plan.sh" 2>/dev/null) \
    || { PLAN_ERROR="main has no scripts/ci/gate_plan.sh"; return 1; }
  PLAN_SLUG=$(gate_plan_literal <(echo "$plan") GATE_SLUG)
  # dependency_merge.sh names the worktree it rm -rf's after the slug.
  [[ "$PLAN_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$PLAN_SLUG" != *..* ]] \
    || { PLAN_ERROR="main's gate plan lacks a literal GATE_SLUG=owner/repo"; return 1; }
}
