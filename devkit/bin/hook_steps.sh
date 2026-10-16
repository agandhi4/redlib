# shellcheck shell=bash
# The body of every repo's .githooks/pre-commit and pre-push (templates/githooks/). Sourced
# after quiet_run.sh, whose run_step it uses; defines run_hook_steps and runs nothing.
#
#   run_hook_steps <pre-commit|pre-push> "$@"     # the hook's own args; returns the hook's code
#
# The per-repo part is scripts/ci/hooks.conf, a sourced file:
#   PRE_COMMIT_STEPS=("backend: static=ci-static-backend" "frontend: static=ci-static-frontend")
#   PRE_PUSH_STEPS=("backend: unit=ci-unit-backend")
#   ENV_REQUIRED_HOOKS="pre-push"   # hooks to skip when the worktree has no .env (optional)
# Each step is "<label>=<make target>[:<override>]". Steps call the gate's own ci-* targets,
# never raw tools, so a hook cannot drift from the gate. They run in order and stop at the
# first failure. A conf lists steps only: devkit decides which of them a change needs.
#
# Path scoping, by default: most repos need no conf change and no override. Each changed path
# gets one area from the fleet layout table, devkit_classify_path in _paths_lib.sh (the gate
# classifies with the same table): docs, backend, frontend, native (ios/, OrbitAgent/,
# *.xcodeproj/: macOS-only, never run by hooks, as the gate plans say), tooling (devkit/,
# .devkit-rev, hooks.conf, .githooks/: treated like other here) or other (Makefile, scripts/,
# Dockerfile, .github/, src/, ...).
# Each step's area comes from its make target's words (split on - and _), in either order
# (ci-unit-backend, the standard ci_targets_check.sh holds, or a not-yet-renamed
# ci-backend-unit): backend|server, frontend|web, or docs.
#   backend target    skipped when every path is docs, frontend or native
#   frontend target   skipped when every path is docs, backend or native
#   docs target       runs only when some path is docs
#   any other target  (ci-quick, ci-unit, ci-drift, ...) skipped when every path is docs or native
# So an "other" or "tooling" path runs every step (the gate runs less for tooling: hooks are
# cheap). A change of only docs (and native) paths still runs docs-check: when no listed step
# is a docs target, the hook runs `make docs-check` itself (if the Makefile declares it), the one check an AGENTS.md change must not
# skip. A native-only change runs nothing and prints one line saying so.
#
# Overrides, for a repo whose layout or target naming the defaults misjudge (most need none):
#   :unless=<globs>  skip the step when EVERY changed path matches one of the globs
#   :only=<globs>    run the step only when SOME changed path matches one of the globs
#   :always          run the step on every change
#
# Timings: every step that ran appends `<date>\t<hook>\t<label>\t<seconds>\t<ok|fail>` and the
# hook appends `<date>\t<hook>\ttotal\t<seconds>\t<ok|fail>` to
# ${XDG_STATE_HOME:-~/.local/state}/devkit/hooks/<repo>.tsv (never printed, never fails the
# hook). <repo> is the MAIN checkout's directory name (the parent of the common git dir), so a
# commit in a worktree (.claude/worktrees/<branch>) lands in the repo's file, not <branch>.tsv;
# scorecard.py derives the same name. The scorecard (T8 gate.precommit) reads it against the owner's budgets, pre-commit
# <= 30 s and pre-push <= 60 s (2026-10-13), so a hook that quietly grew shows up as a letter.
# <globs> are comma-separated, no spaces, one override per step. A glob is a bash `case`
# pattern over the whole repo-relative path, as in scripts/ci/gate_plan.sh: `*` also matches
# `/`, so `*.md` matches at any depth and `docs/*` everything under docs/; `**` means `*`.
#
# Filters only ever remove work; the PR gate stays authoritative. Changed paths: pre-commit,
# the staged paths; pre-push, every path touched by a commit in PUSH_RANGES (a bare sha is all
# of its history: a new branch with no main to compare against). A rename counts as its old
# and its new path, so a move out of an area still runs that area's steps. A merge commit
# counts only the paths it changed against every parent (git's dense combined diff: conflict
# resolutions), so merging main into a docs branch stays docs-only. With no changed paths (an
# empty commit) docs and `only` steps skip and every other step runs. If git cannot list the
# paths, every step runs, with a note. A skipped step prints "– <label> skipped (<why>)".
# Every step is parsed before any runs, so a bad override blocks the hook up front;
# hooks_check.sh rejects one too.
#
# ENV_REQUIRED_HOOKS: a listed hook loads ${HOOK_ENV_FILE:-<root>/.env} (shell-sourceable KEY=value, exported) or,
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
#
# Toolchains: before the first step, toolchain_path (bin/toolchain_path.sh, the gate's own code)
# puts the checkout's pinned Node (.nvmrc) and Rust (rust-toolchain.toml) first on PATH, so
# `make ci-*` here runs what the gate runs. A machine with no cargo (redlib's Mac) or another node
# would otherwise fail the hook or test a different version. A pin that cannot be provided blocks
# the hook, as it fails the gate. Nothing is provisioned when no step will run, including when
# path scoping skips every step.

# shellcheck source=/dev/null  # bin/toolchain_path.sh: toolchain_path, shared with local_gate.sh
. "$(dirname "${BASH_SOURCE[0]}")/toolchain_path.sh"
# shellcheck source=bin/_paths_lib.sh  # the path classification, shared with local_gate.sh
. "$(dirname "${BASH_SOURCE[0]}")/_paths_lib.sh"

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

  # Plan every step before running any: skip reasons ("" = run), and how many will run.
  local plan=() changed='' listed=1 runs=0 reason docs_steps=0
  HOOK_AREAS=''
  if [ "${#steps[@]}" -gt 0 ]; then
    if changed=$(_hook_changed_paths "$hook"); then
      _hook_classify "$changed"
    else
      echo "$hook: cannot list the changed paths; running every step"
      listed=0
    fi
  fi
  for step in ${steps[@]+"${steps[@]}"}; do
    _hook_parse_step "$step" || { echo "$hook: $HOOK_STEP_ERROR in scripts/ci/hooks.conf"; return 1; }
    [ "$(_hook_target_area "$HOOK_STEP_TARGET")" != docs ] || docs_steps=$((docs_steps + 1))
    reason=
    [ "$listed" = 0 ] || reason=$(_hook_skip_reason "$changed")
    plan+=("$reason")
    [ -n "$reason" ] || runs=$((runs + 1))
  done
  # Only docs (and native) paths, no docs step listed: docs-check is the check they must not skip.
  if [ "$listed" = 1 ] && _hook_areas_within " docs native " && [ "$docs_steps" = 0 ] &&
    case "$HOOK_AREAS" in *" docs "*) true ;; *) false ;; esac; then
    if grep -qE '^docs-check[[:space:]]*:' "$root/Makefile" 2>/dev/null; then
      steps+=("docs=docs-check")
      plan+=("")
      runs=$((runs + 1))
    else
      echo "– docs: no docs-check target in the Makefile; docs-only change checked by nothing here"
    fi
  fi

  if [ "$runs" -gt 0 ] && ! toolchain_path "$root"; then
    echo "$hook: $TOOLCHAIN_ERROR"
    return 1
  fi

  # Native-only: one line for the whole hook instead of a skip line per defaulted step.
  local native_only=0
  if [ "$listed" = 1 ] && [ "$HOOK_AREAS" = " native " ]; then
    native_only=1
    echo "– native-only change (ios/, OrbitAgent/, *.xcodeproj/): hooks run nothing for it; build and test it on the Mac"
  fi

  local i=0 hook_start step_start
  hook_start=$(date +%s)
  for step in ${steps[@]+"${steps[@]}"}; do
    reason=${plan[$i]}
    i=$((i + 1))
    _hook_parse_step "$step"
    if [ -n "$reason" ] && [ "$native_only" = 1 ] && [ -z "$HOOK_STEP_FILTER" ]; then
      continue
    fi
    if [ -n "$reason" ]; then
      echo "– $HOOK_STEP_LABEL skipped ($reason)"
      continue
    fi
    rc=0
    step_start=$(date +%s)
    run_step "$HOOK_STEP_LABEL" make -C "$root" --no-print-directory "$HOOK_STEP_TARGET" || rc=$?
    _hook_record "$root" "$hook" "$HOOK_STEP_LABEL" "$step_start" "$rc"
    if [ "$rc" -ne 0 ]; then
      _hook_record "$root" "$hook" total "$hook_start" "$rc"
      echo "$hook: blocked by '$HOOK_STEP_LABEL'; fix it and try again"
      return "$rc"
    fi
  done
  _hook_record "$root" "$hook" total "$hook_start" 0

  echo "✓ $hook passed"
  _hook_allow_push "$uses_lfs" "$push_input" "$@"
}

# <root> <hook> <label> <start epoch> <rc>: one timing line in the per-machine hooks ledger
# (header comment above). Best effort: an unwritable state dir never fails a hook.
_hook_record() {
  local root=$1 hook=$2 label=$3 start=$4 rc=$5 dir
  dir=${XDG_STATE_HOME:-$HOME/.local/state}/devkit/hooks
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%F)" "$hook" "$label" "$(( $(date +%s) - start ))" \
    "$([ "$rc" -eq 0 ] && echo ok || echo fail)" >>"$dir/$(_hook_ledger_name "$root").tsv" 2>/dev/null || true
}

# <root>: the ledger file's stem, lowercased: the origin remote's repository name, else the main
# checkout's directory name (`--git-common-dir` is <main>/.git for the main checkout and every
# worktree of it; relative in the main checkout, so resolved from <root>). A worktree, a clone
# under another directory name and the developer checkout share one file. Mirrored by
# repo_name() in scorecard.py; keep the two agreeing.
_hook_ledger_name() {
  local url common name
  if url=$(git -C "$1" remote get-url origin 2>/dev/null) && [ -n "$url" ]; then
    url=${url%/}; url=${url%.git}; name=${url##*/}; name=${name##*:}
    if [ -n "$name" ]; then printf '%s\n' "$name" | tr '[:upper:]' '[:lower:]'; return; fi
  fi
  common=$(cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || { basename "$1" | tr '[:upper:]' '[:lower:]'; return; }
  basename "$(dirname "$common")" | tr '[:upper:]' '[:lower:]'
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

# <step>: split one hooks.conf step into HOOK_STEP_LABEL, HOOK_STEP_TARGET, HOOK_STEP_FILTER
# (unless, only, always or empty: the default rule) and HOOK_STEP_GLOBS (array). Returns 1 with HOOK_STEP_ERROR naming the
# step when it is malformed. Used by: run_hook_steps, and hooks_check.sh to validate the conf.
# The label may contain ':' ("backend: pytest"); the first '=' ends it, and the first ':' after
# that starts the filter, since a make target name cannot hold one.
_hook_parse_step() {
  local step=$1 rest filter
  HOOK_STEP_LABEL='' HOOK_STEP_TARGET='' HOOK_STEP_FILTER='' HOOK_STEP_ERROR=''
  HOOK_STEP_GLOBS=()
  case "$step" in
    ?*=?*) ;;
    *) HOOK_STEP_ERROR="bad step '$step' (want label=make-target)"; return 1 ;;
  esac
  HOOK_STEP_LABEL=${step%%=*}
  rest=${step#*=}
  HOOK_STEP_TARGET=${rest%%:*}
  [ -n "$HOOK_STEP_TARGET" ] || { HOOK_STEP_ERROR="bad step '$step' (empty make target)"; return 1; }
  [ "$HOOK_STEP_TARGET" != "$rest" ] || return 0
  filter=${rest#*:}
  case "$filter" in
    always) HOOK_STEP_FILTER=always; return 0 ;;
    unless=*|only=*) ;;
    *) HOOK_STEP_ERROR="bad step '$step' (unknown override '${filter%%=*}', want unless=<globs>, only=<globs> or always)"; return 1 ;;
  esac
  HOOK_STEP_FILTER=${filter%%=*}
  filter=${filter#*=}
  case "$filter" in
    '') HOOK_STEP_ERROR="bad step '$step' (empty glob list)"; return 1 ;;
    ,*|*,|*,,*) HOOK_STEP_ERROR="bad step '$step' (empty glob in '$filter')"; return 1 ;;
    *:*) HOOK_STEP_ERROR="bad step '$step' (one override per step; ':' in '$filter')"; return 1 ;;
    *[[:space:]]*) HOOK_STEP_ERROR="bad step '$step' (whitespace in '$filter')"; return 1 ;;
  esac
  # read -a splits on IFS without pathname expansion, so the globs stay patterns.
  IFS=, read -r -a HOOK_STEP_GLOBS <<<"$filter"
}

# <changed paths, one per line>: why the parsed step should be skipped, or nothing to run it.
# The default rules read HOOK_AREAS (set by _hook_classify); the overrides read the paths.
_hook_skip_reason() {
  local changed=$1 path globs area others
  case "$HOOK_STEP_FILTER" in
    always) return 0 ;;
    unless|only)
      globs=$(IFS=,; echo "${HOOK_STEP_GLOBS[*]}")
      if [ "$HOOK_STEP_FILTER" = unless ]; then
        [ -n "$HOOK_AREAS" ] || return 0
        while IFS= read -r path; do
          [ -z "$path" ] || _hook_path_matches "$path" || return 0
        done <<<"$changed"
        echo "changed paths match unless=$globs"
      else
        while IFS= read -r path; do
          [ -z "$path" ] || ! _hook_path_matches "$path" || return 0
        done <<<"$changed"
        echo "no changed path matches only=$globs"
      fi
      return 0
      ;;
  esac
  area=$(_hook_target_area "$HOOK_STEP_TARGET")
  case "$area" in
    docs)
      case "$HOOK_AREAS" in *" docs "*) return 0 ;; esac
      echo "no docs path changed; default for a docs target"
      return 0
      ;;
    backend) others=" frontend docs native " ;;
    frontend) others=" backend docs native " ;;
    *) area=generic others=" docs native " ;;
  esac
  # Runs on an empty change, or when any changed area is outside the skippable set.
  [ -n "$HOOK_AREAS" ] || return 0
  _hook_areas_within "$others" || return 0
  local list=''
  for path in $HOOK_AREAS; do list+=${list:+, }$path; done
  echo "only $list paths changed; default for a $area target"
}

# <" a b ">: is every area in HOOK_AREAS one of these? True for no areas at all.
_hook_areas_within() {
  local area
  for area in $HOOK_AREAS; do
    case "$1" in *" $area "*) ;; *) return 1 ;; esac
  done
}

# <changed paths, one per line>: set HOOK_AREAS to the areas present, " a b " ("" for none).
# The table is devkit_classify_path's (_paths_lib.sh), shared with the gate. tooling is in no
# skippable set below, so for hooks it runs every step, like other: hooks are cheap, and a
# hooks.conf or .githooks/ change is exactly what the hooks should exercise.
_hook_classify() {
  devkit_areas "$1"
  HOOK_AREAS=$DEVKIT_AREAS
}

# <make target>: backend, frontend, docs or generic, from its words split on - and _. A target
# naming two areas (ci-backend-frontend) is generic. Used by: the default rules, and the
# implicit docs-check (a listed docs target makes it unnecessary).
_hook_target_area() {
  local word area=generic found=''
  local words=()
  IFS='-_' read -r -a words <<<"$1"
  for word in ${words[@]+"${words[@]}"}; do
    case "$word" in
      backend|server) word=backend ;;
      frontend|web) word=frontend ;;
      docs) ;;
      *) continue ;;
    esac
    if [ -z "$found" ]; then found=$word; elif [ "$found" != "$word" ]; then found=mixed; fi
  done
  case "$found" in backend|frontend|docs) area=$found ;; esac
  echo "$area"
}

# <path>: does it match one of HOOK_STEP_GLOBS? `case` semantics, as in gate_plan.sh.
_hook_path_matches() {
  local glob
  for glob in "${HOOK_STEP_GLOBS[@]}"; do
    # shellcheck disable=SC2254  # unquoted on purpose: the glob is the pattern
    case "$1" in $glob) return 0 ;; esac
  done
  return 1
}

# <hook>: the changed paths, one per line (duplicates and blank lines possible). A subshell so
# pipefail reaches git's status: a git failure must not read as "no changed paths". -z keeps
# git from C-quoting non-ASCII names, which would then match no glob.
_hook_changed_paths() (
  set -o pipefail
  if [ "$1" = pre-commit ]; then
    git diff --cached --name-only --no-renames -z | tr '\0' '\n'
    exit
  fi
  while IFS= read -r range; do
    [ -n "$range" ] || continue
    git log --name-only --format= --no-renames --diff-merges=dense-combined -z "$range" | tr '\0' '\n' || exit 1
  done <<<"$PUSH_RANGES"
)
