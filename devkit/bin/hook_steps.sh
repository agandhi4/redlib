# shellcheck shell=bash
# The body of every repo's .githooks/pre-commit, pre-push and commit-msg (templates/githooks/).
# Sourced after quiet_run.sh, whose run_step it uses; defines run_hook_steps and runs nothing.
#
#   run_hook_steps <pre-commit|pre-push|commit-msg> "$@"   # the hook's own args; returns its code
#
# The per-repo part is scripts/ci/hooks.conf, a sourced file:
#   PRE_COMMIT_STEPS=("backend: static=ci-static-backend" "frontend: static=ci-static-frontend")
#   PRE_PUSH_STEPS=("backend: unit=ci-unit-backend")
#   ENV_REQUIRED_HOOKS="pre-push"   # hooks to skip when the worktree has no .env (optional)
#   COMMIT_MSG_STEPS=("trailer:off")   # commit-msg checks; default ("trailer") (optional)
#
# commit-msg runs devkit's own message checks, never make targets: a message is not a tree a
# ci-* target can read. Each COMMIT_MSG_STEPS entry is `<check>` or `<check>:off`; the one check:
#   trailer  an agent's commit (devkit_is_agent, bin/_trailer_lib.sh: CLAUDECODE or CLAUDE_CODE_*
#            in the environment, or `git config devkit.agent true`) must hold, as a line of its
#            own, a Claude co-author trailer naming the model that ran it (devkit_trailer_ok:
#            `Co-Authored-By: Claude[ <model>] <noreply@anthropic.com>`). It never compares
#            against DEVKIT_COMMIT_TRAILER or devkit.trailer, which an agent can set to anything;
#            those are only what devkit-sync writes. It fails printing the form to add. A human's
#            commit and a merge commit (git writes its message) pass untouched. Why a hook
#            (owner, 2026-10-18): the convention lived only in briefs.
# A check that applied writes its ledger rows (header: Timings), so gate_bite.py counts it.
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
# Vendoring only: a pre-commit whose staged paths only vendor devkit (devkit/ at the tree
# .devkit-rev records, .devkit-rev, byte-exact base copies: devkit-sync's commit) runs no step
# and prints one line; _hook_vendoring_only says why.
#
# Overrides, for a repo whose layout or target naming the defaults misjudge (most need none):
#   :unless=<globs>  skip the step when EVERY changed path matches one of the globs
#   :only=<globs>    run the step only when SOME changed path matches one of the globs
#   :always          run the step on every change
#
# Timings: every step that ran appends `<date>\t<hook>\t<label>\t<seconds>\t<ok|fail>` (plus a
# sixth note column: `core.bare=<v> is-bare=<v>` when the step flipped core.bare, below, and
# `load=<1m>/<cpus> scale=<x>` when the box ran above its core count as the hook started,
# bin/_load_lib.sh's rule, for a reader to divide out of the seconds) and the hook appends
# `<date>\t<hook>\ttotal\t<seconds>\t<ok|fail>` to
# ${XDG_STATE_HOME:-~/.local/state}/devkit/hooks/<repo>.tsv (never printed, never fails the
# hook). <repo> is the MAIN checkout's directory name (the parent of the common git dir), so a
# commit in a worktree (.claude/worktrees/<branch>) lands in the repo's file, not <branch>.tsv;
# scorecard.py derives the same name. The scorecard's WIRED (`hooks.ledger`: a row in 30 d) and
# gate_bite.py (failed steps) read it; the owner's budgets stand: pre-commit <= 30 s, pre-push
# <= 60 s (2026-10-13).
# <globs> are comma-separated, no spaces, one override per step. A glob is a bash `case`
# pattern over the whole repo-relative path, as in scripts/ci/gate_plan.sh: `*` also matches
# `/`, so `*.md` matches at any depth and `docs/*` everything under docs/; `**` means `*`.
#
# Filters only ever remove work; the PR gate stays authoritative. Changed paths: pre-commit,
# the staged paths; pre-push, every path touched by a commit in PUSH_RANGES (a bare sha is all
# of its history: a new branch with no main to compare against). A rename counts as its old
# and its new path, so a move out of an area still runs that area's steps. A merge commit
# counts only the paths it changed against every parent (git's dense combined diff: conflict
# resolutions), so merging main into a docs branch stays docs-only. A commit <remote>/main
# already holds is not this push's change (it passed its own push and gate; push_ranges.sh's
# new-branch range starts at the same ref): make merge's carry push, main merged into the PR
# with only docs/decisions.md resolved, is docs-only, not every path main moved (devkit #239's
# carry ran the 67 s python-tests; 2026-10-26). With no changed paths (an
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
# core.bare (devkit #48): in a linked worktree's hook git exports GIT_DIR, and a step that runs
# `git init <dir>` (or `git clone`, `git -C <other> config`) then reinitializes the HOOK's
# repository instead, writing core.bare=true into the config every checkout of it shares; the main
# checkout then refuses `git status`. So the steps run without GIT_DIR/GIT_WORK_TREE whenever git
# finds the same git dir from <root> without them (always, unless git was invoked with an explicit
# --git-dir). GIT_INDEX_FILE stays: a pre-commit step reads the index being committed. And each
# step is watched: core.bare (and `rev-parse --is-bare-repository`) is read before the first step
# and after every step; a change prints `hook_steps: core.bare flipped to <v> after step <label>`
# to stderr, adds `core.bare=<v> is-bare=<v>` as a sixth column on that step's ledger row, and
# restores the value from before the step. Only a failed restore fails the hook.
#
# Metrics preview (pre-push, after every step passed): when the repo has scripts/ci/metrics.conf
# and docs/metrics/ratchet.json and the push touched more than docs and native paths, the hook
# runs `metrics_collect.sh check --quick` (the collectors whose tier inputs are already built;
# no tier runs). It never blocks the push: a clean ratchet is one line, a failing one prints the
# lines the gate's metrics job would fail on (with `BETTER: run make metrics-tighten before push`
# for a gain left unlocked), a preview that cannot run says why in one line. A collector whose
# tool is not installed (a fresh worktree) is skipped, its line naming the fix printed above the
# verdict. Why (2026-10-20):
# all eight instalite PRs #37-#46 failed their first gate on unlocked coverage gains and bundle
# growth that a 20 s local run shows. The ledger row is `metrics-quick`, always ok.
#
# Merge drivers: every hook first runs merge_drivers_heal (bin/_gitattributes_lib.sh), so a clone
# whose merge.devkit-metrics or merge.devkit-decisions driver is unset or not the vendored command
# gets it, with one line, at its next commit; it never blocks. A failed step whose output reads as a missing module or
# command, in a worktree with a tracked lockfile and no node_modules beside it, adds a line
# naming that and `run npm ci (or make install) in this worktree` under the blocked line
# (_hook_missing_node_modules).
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
# shellcheck source=bin/_load_lib.sh  # devkit_load_scale, shared with local_gate.sh and tier_guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/_load_lib.sh"
# shellcheck source=bin/_trailer_lib.sh  # devkit_trailer_ok and devkit_is_agent for the commit-msg trailer step
. "$(dirname "${BASH_SOURCE[0]}")/_trailer_lib.sh"
# shellcheck source=bin/_vendor_paths.sh  # base_copies, for a vendoring-only commit
. "$(dirname "${BASH_SOURCE[0]}")/_vendor_paths.sh"
# shellcheck source=bin/_gitattributes_lib.sh  # merge_drivers_heal, run by every hook
. "$(dirname "${BASH_SOURCE[0]}")/_gitattributes_lib.sh"
# shellcheck source=bin/_makefile_lib.sh  # makefile_targets, for the docs-check fallback
. "$(dirname "${BASH_SOURCE[0]}")/_makefile_lib.sh"

run_hook_steps() {
  local hook=$1
  shift
  local root conf step rc env_file push_input='' uses_lfs=0
  local PRE_COMMIT_STEPS PRE_PUSH_STEPS ENV_REQUIRED_HOOKS COMMIT_MSG_STEPS GATE_CODE_PATHS=
  PRE_COMMIT_STEPS=()
  PRE_PUSH_STEPS=()
  ENV_REQUIRED_HOOKS=
  COMMIT_MSG_STEPS=(trailer)
  root=$(git rev-parse --show-toplevel) || return 1
  # Never blocks: a clone whose config cannot be written still merges, only as text.
  merge_drivers_heal "$root" "$(dirname "${BASH_SOURCE[0]}")" "$hook" || true

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
  # The gate's path carve-out (_paths_lib.sh header), so a hook scopes a path as the gate does.
  devkit_load_code_paths "$root/scripts/ci/gate_plan.sh"
  if [ "$hook" = commit-msg ]; then
    _hook_commit_msg "$root" "${1:-}"
    return
  fi

  local steps=()
  case "$hook" in
    pre-commit) steps=(${PRE_COMMIT_STEPS[@]+"${PRE_COMMIT_STEPS[@]}"}) ;;
    pre-push)
      PUSH_RANGES=$(printf '%s\n' "$push_input" | "$(dirname "${BASH_SOURCE[0]}")/push_ranges.sh" "${1:-origin}") || return $?
      if [ -z "$PUSH_RANGES" ]; then
        echo "✓ $hook: nothing to check (deletion or tag push)"
        _hook_allow_push "$uses_lfs" "$push_input" "$@"
        return
      fi
      export PUSH_RANGES
      steps=(${PRE_PUSH_STEPS[@]+"${PRE_PUSH_STEPS[@]}"})
      ;;
    *) echo "run_hook_steps: unknown hook '$hook' (expected pre-commit, pre-push or commit-msg)"; return 2 ;;
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
    if changed=$(_hook_changed_paths "$hook" "${1:-origin}"); then
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
    if case "$(cd "$root" && makefile_targets)" in *" docs-check "*) true ;; *) false ;; esac; then
      steps+=("docs=docs-check")
      plan+=("")
      runs=$((runs + 1))
    else
      echo "– docs: no docs-check target in the Makefile; docs-only change checked by nothing here"
    fi
  fi

  if [ "$listed" = 1 ] && _hook_vendoring_only "$hook" "$push_input" "$changed"; then
    echo "– vendoring only (devkit/ is .devkit-rev's tree ${HOOK_VENDORED_TREE:0:7}, every other path a base copy): the repo's steps skip; the PR gate runs them"
    _hook_allow_push "$uses_lfs" "$push_input" "$@"
    return 0
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

  _hook_drop_git_dir "$root"
  # shellcheck disable=SC2034  # LOAD_* are devkit_load_scale's outputs, local so they do not leak
  local i=0 hook_start step_start bare_before missing HOOK_LOAD_NOTE LOAD_SCALE LOAD_BUDGET LOAD_NOTE LOAD_LEDGER LOAD_BASE LOAD_START LOAD_NCPU LOAD_HELD LOAD_HELD_START
  bare_before=$(_hook_bare_state "$root")
  hook_start=$(date +%s)
  # Any positive budget: only the factor is recorded, as the ledger note (header: Timings).
  devkit_load_scale 1
  HOOK_LOAD_NOTE=$LOAD_LEDGER
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
    _hook_bare_restore "$root" "$HOOK_STEP_LABEL" "$bare_before" || [ "$rc" -ne 0 ] || rc=1
    _hook_record "$root" "$hook" "$HOOK_STEP_LABEL" "$step_start" "$rc" "$HOOK_BARE_NOTE"
    if [ "$rc" -ne 0 ]; then
      _hook_record "$root" "$hook" total "$hook_start" "$rc"
      echo "$hook: blocked by '$HOOK_STEP_LABEL'; fix it and try again"
      if missing=$(_hook_missing_node_modules "$root" "$QUIET_FAILED_LOG"); then
        echo "$hook: $missing has no node_modules: run npm ci (or make install) in this worktree"
      fi
      return "$rc"
    fi
  done
  if [ "$hook" = pre-push ] && [ "$native_only" = 0 ] && ! { [ "$listed" = 1 ] && _hook_areas_within " docs native "; }; then
    _hook_metrics_quick "$root"
  fi
  _hook_record "$root" "$hook" total "$hook_start" 0

  echo "✓ $hook passed"
  _hook_allow_push "$uses_lfs" "$push_input" "$@"
}

# _hook_missing_node_modules <root> <failed step's log>: when the log reads as a missing module
# or command, print the first directory with a tracked npm, pnpm or yarn lockfile, a package.json
# and no node_modules beside it (`.` for the root), or exit 1; a Yarn PnP project (.pnp.cjs) has
# none by design. Why: a fresh worktree (an agent's lane) has none, and the step's tail then
# shows a raw "Cannot find module" or "command not found" rather than the fix (closet). Without
# the log check it also printed under a plain lint failure (E501) in any such worktree
# (devkit-as), so an empty log (QUIET_VERBOSE) gets no hint either.
_hook_missing_node_modules() {
  local lock dir
  # node's two spellings, bash's, dash/busybox's ("sh: 1: eslint: not found"), a node_modules/.bin
  # path run by sh or make, and make's own exec of a bare command. grep reads the raw file:
  # piping it from a sed would SIGPIPE under the hook's pipefail once grep -q matched.
  local missing_re='Cannot find (module|package)|ERR_MODULE_NOT_FOUND|command not found'
  missing_re+='|sh(: (line )?[0-9]+)?: [^ ]+: not found|node_modules/[^ ]*: No such file or directory'
  missing_re+='|make(\[[0-9]+\])?: [^ ]+: No such file or directory'
  [ -n "$2" ] && grep -qE "$missing_re" "$2" || return 1
  while IFS= read -r lock; do
    dir=$(dirname "$lock")
    [ -f "$1/$dir/package.json" ] && [ ! -e "$1/$dir/.pnp.cjs" ] || continue
    [ -d "$1/$dir/node_modules" ] || { echo "$dir"; return 0; }
  done < <(git -C "$1" ls-files -- package-lock.json pnpm-lock.yaml yarn.lock \
    '*/package-lock.json' '*/pnpm-lock.yaml' '*/yarn.lock' | grep -v '^devkit/')
  return 1
}

# <hook> <push input> <changed paths>: true when the change only vendors devkit
# (_vendor_paths.sh vendoring_only), as devkit-sync's own commit does: pre-commit judges the
# index, pre-push the one commit it pushes (a push of several tips runs every step). Sets
# HOOK_VENDORED_TREE. Why skip the repo's steps for it (closet, 2026-10-19): the sync commits and
# pushes from a fresh worktree before any install (by hand, or the nightly sync in
# dependency_merge.sh), and a lint, typecheck or test step then fails on a missing node_modules,
# not on the change. The tree hash is the check it needs and it needs no dependency; the code is
# upstream's, already gated there, and its effect on this repo is the PR gate's to judge. A hand
# edit under devkit/ breaks the hash, so it runs every step.
_hook_vendoring_only() {
  local rev='' tips rc
  HOOK_VENDORED_TREE=
  case $1 in
    pre-commit) ;;
    pre-push)
      tips=$(awk '$2 !~ /^0+$/ { print $2 }' <<<"$2" | sort -u)
      [[ "$tips" =~ ^[0-9a-f]{40}$ ]] || return 1
      rev=$tips ;;
    *) return 1 ;;
  esac
  vendoring_only "$rev" "$3"
  rc=$?
  HOOK_VENDORED_TREE=$VENDORED_TREE
  return "$rc"
}

# <root> <message file>: run COMMIT_MSG_STEPS (header: commit-msg); stops at the first failure.
_hook_commit_msg() {
  local root=$1 msg=$2 step start rc
  [ -f "$msg" ] || { echo "commit-msg: no message file '$msg' (git passes it as the hook's argument)"; return 2; }
  for step in ${COMMIT_MSG_STEPS[@]+"${COMMIT_MSG_STEPS[@]}"}; do
    _hook_parse_msg_step "$step" || { echo "commit-msg: $HOOK_STEP_ERROR in scripts/ci/hooks.conf"; return 1; }
    [ "$HOOK_MSG_OFF" = 0 ] || continue
    start=$(date +%s)
    rc=0
    case "$HOOK_MSG_CHECK" in
      trailer)
        _hook_trailer_applies || continue
        _hook_msg_trailer "$msg" || rc=1 ;;
    esac
    _hook_record "$root" commit-msg "$HOOK_MSG_CHECK" "$start" "$rc"
    _hook_record "$root" commit-msg total "$start" "$rc"
    [ "$rc" -eq 0 ] || return 1
  done
}

# <step>: split a COMMIT_MSG_STEPS entry into HOOK_MSG_CHECK and HOOK_MSG_OFF (1 for `:off`).
# Returns 1 with HOOK_STEP_ERROR naming it when malformed. Used by: _hook_commit_msg, and
# hooks_check.sh to validate the conf.
_hook_parse_msg_step() {
  HOOK_MSG_CHECK=${1%%:*} HOOK_MSG_OFF=0 HOOK_STEP_ERROR=''
  case "$1" in
    *:off) HOOK_MSG_OFF=1 ;;
    *:*) HOOK_STEP_ERROR="bad commit-msg step '$1' (want <check> or <check>:off)"; return 1 ;;
  esac
  case "$HOOK_MSG_CHECK" in
    trailer) ;;
    *) HOOK_STEP_ERROR="bad commit-msg step '$1' (unknown check '$HOOK_MSG_CHECK', want trailer)"; return 1 ;;
  esac
}

# Does the trailer check apply to this commit (header: commit-msg)?
_hook_trailer_applies() {
  devkit_is_agent && ! git rev-parse -q --verify MERGE_HEAD >/dev/null
}

# <message file>: the trailer check; returns 1 after printing the line to add.
_hook_msg_trailer() {
  local msg=$1 found
  devkit_trailer_ok "$msg" && return 0
  echo "✗ commit-msg: an agent's commit must carry a Claude trailer naming the model that ran it. Add this line, after a blank line, at the end of the message:"
  echo "  Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  echo "  <model> is the one your harness attribution names (e.g. Opus 5.5); without one, $DEVKIT_DEFAULT_TRAILER"
  found=$(grep -iE '^co-authored-by:' "$msg" | head -1)
  [ -z "$found" ] || echo "  (the message has '$found', which is not a Claude trailer)"
  echo "  COMMIT_MSG_STEPS=(\"trailer:off\") in scripts/ci/hooks.conf turns the check off."
  return 1
}

# <root> <hook> <label> <start epoch> <rc> [note]: one timing line in the per-machine hooks
# ledger (header comment above); the note column joins [note] and the hook's load note with a
# space; gate_bite.py reads columns 1-5, the scorecard column 1. Best effort: an unwritable
# state dir never fails a hook.
_hook_record() {
  local root=$1 hook=$2 label=$3 start=$4 rc=$5 note=${6:-} dir row
  [ -z "${HOOK_LOAD_NOTE:-}" ] || note="${note:+$note }$HOOK_LOAD_NOTE"
  dir=${XDG_STATE_HOME:-$HOME/.local/state}/devkit/hooks
  mkdir -p "$dir" 2>/dev/null || return 0
  row=$(printf '%s\t%s\t%s\t%s\t%s' "$(date +%F)" "$hook" "$label" "$(( $(date +%s) - start ))" \
    "$([ "$rc" -eq 0 ] && echo ok || echo fail)")
  [ -z "$note" ] || row+=$'\t'$note
  printf '%s\n' "$row" >>"$dir/$(_hook_ledger_name "$root").tsv" 2>/dev/null || true
}

# <root>: the pre-push metrics preview (header: Metrics preview). Prints, never fails.
_hook_metrics_quick() {
  local root=$1 out rc=0 start missing
  [ -f "$root/scripts/ci/metrics.conf" ] && [ -f "$root/docs/metrics/ratchet.json" ] || return 0
  start=$(date +%s)
  # A hook is never inside a gate, even when a gate job's tests run one: drop the gate's areas.
  out=$(cd "$root" && env -u GATE_AREAS "$(dirname "${BASH_SOURCE[0]}")/metrics_collect.sh" check --quick 2>&1 </dev/null) || rc=$?
  _hook_record "$root" pre-push metrics-quick "$start" 0
  missing=$(grep -E '^metrics [^ ]+ SKIP \(--quick, tool missing: ' <<<"$out" || true)
  [ -z "$missing" ] || printf '%s\n' "$missing"
  case "$rc" in
    0)
      if [ -n "$missing" ]; then
        echo "✓ metrics (quick): every measured bound holds; the collectors above did not run"
      else
        echo "✓ metrics (quick): every bound holds"
      fi ;;
    1)
      grep -E '^ratchet ' <<<"$out" | grep -vE ' SAME$| SKIPPED \(|REPORT-ONLY|within tolerance|^ratchet (summary|untracked|base|merged) '
      grep '^BETTER: ' <<<"$out"
      echo "– metrics (quick): the gate's metrics job fails on the lines above; not blocking the push" ;;
    *) echo "– metrics (quick) did not run ($(grep -m1 -E '^metrics_collect: |FAIL' <<<"$out" || echo "exit $rc")); the gate's metrics job decides" ;;
  esac
}

# <root>: unexport GIT_DIR and GIT_WORK_TREE when git resolves the same git dir from <root>
# without them (header: core.bare). Left alone otherwise: then the steps need them to find it.
_hook_drop_git_dir() {
  [ -n "${GIT_DIR:-}" ] || return 0
  local exported found
  exported=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  found=$(cd "$1" && env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --absolute-git-dir 2>/dev/null) || return 0
  [ "$exported" = "$found" ] || return 0
  unset GIT_DIR GIT_WORK_TREE
}

# <root>: "<core.bare> <is-bare-repository>" as git sees them from <root>; "unset" for no key.
_hook_bare_state() {
  local bare is_bare
  bare=$(git -C "$1" config --get core.bare 2>/dev/null) || bare='unset'
  is_bare=$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null) || is_bare=error
  printf '%s %s\n' "$bare" "$is_bare"
}

# <root> <label> <state before>: after a step, report and undo a core.bare change (header:
# core.bare). Sets HOOK_BARE_NOTE (the ledger note, "" when nothing changed); returns 1 only when
# the restore fails.
_hook_bare_restore() {
  local root=$1 label=$2 before=$3 now
  HOOK_BARE_NOTE=''
  now=$(_hook_bare_state "$root")
  [ "$now" != "$before" ] || return 0
  HOOK_BARE_NOTE="core.bare=${now%% *} is-bare=${now#* }"
  echo "hook_steps: core.bare flipped to ${now%% *} after step $label" >&2
  if [ "${before%% *}" = unset ]; then
    git -C "$root" config --unset core.bare
  else
    git -C "$root" config core.bare "${before%% *}"
  fi
  if [ "$(_hook_bare_state "$root")" != "$before" ]; then
    echo "hook_steps: could not restore core.bare=${before%% *}; run: git -C $root config core.bare false" >&2
    return 1
  fi
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

# <hook> [remote]: the changed paths, one per line (duplicates and blank lines possible); for
# pre-push, without the commits <remote>/main holds (header). A subshell so pipefail reaches
# git's status: a git failure must not read as "no changed paths". -z keeps git from C-quoting
# non-ASCII names, which would then match no glob.
_hook_changed_paths() (
  set -o pipefail
  if [ "$1" = pre-commit ]; then
    git diff --cached --name-only --no-renames -z | tr '\0' '\n'
    exit
  fi
  shipped=()
  ! git rev-parse --verify -q "refs/remotes/$2/main^{commit}" >/dev/null || shipped=(--not "refs/remotes/$2/main")
  while IFS= read -r range; do
    [ -n "$range" ] || continue
    git log --name-only --format= --no-renames --diff-merges=dense-combined -z "$range" ${shipped[@]+"${shipped[@]}"} | tr '\0' '\n' || exit 1
  done <<<"$PUSH_RANGES"
)
