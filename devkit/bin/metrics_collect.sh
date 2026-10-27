#!/usr/bin/env bash
# The ci-metrics mechanism: run the repo's declared metrics collectors, merge their output
# into one snapshot, then run the ratchet. A repo's Makefile holds four one-line targets
# (`ci-metrics` = check, `metrics-snapshot`, `metrics-tighten`, `metrics-rebaseline`) and
# nothing else; which
# collectors exist is scripts/ci/metrics.conf, which run for a PR is decided here from the
# gate's areas (devkit docs/decisions.md 2026-10-15).
#
# Usage, from the repo root (make runs there):
#   devkit/bin/metrics_collect.sh <snapshot|check|tighten|rebaseline>
#       [--conf scripts/ci/metrics.conf] [--bounds docs/metrics/ratchet.json] [--out build/metrics.json]
#   snapshot    run the collectors and merge; build/metrics.json is the report
#   check --quick  outside the gate only: a collector whose tier inputs are missing or stale, or
#               whose tool is not installed (its exit 3, a fresh worktree), is skipped (its keys
#               SKIPPED, the line naming the fix), no tier runs, no scorecard; after the ratchet lines a
#               gain left unlocked adds `BETTER: run make metrics-tighten before push`. The
#               pre-push hook's preview (hook_steps.sh), which never blocks the push
#   check       snapshot, then `metrics_ratchet.py check` (the gate job; METRICS_REBASELINE=1,
#               which the gate plan sets from the metrics-rebaseline label, adds --rebaseline-ok).
#               A BETTER key fails too until `make metrics-tighten` is committed (gains lock in)
#   tighten     snapshot, then lock in the BETTER numbers (commit the bounds in the same PR);
#               exit 1 when a key is WORSE or MISSING, printed as check prints it, after
#               writing the BETTER bounds and running the scorecard's tighten. SEED=1
#               (`make metrics-tighten SEED=1`) also adds a bound at today's value for every
#               key without one (`ratchet <key> SEEDED <value>`): the way to bound a new key,
#               since that is a tightening and needs no label
#               Merged tree (header below): when HEAD does not contain origin/main's tip,
#               tighten measures HEAD merged into it, as the gate will, and copies the bounds back
#   rebaseline  snapshot, then overwrite every bound (a label-approved tool change only).
#               KEYS=<key>[,<key>] (`make metrics-rebaseline KEYS=...`: make hands command-line
#               variables to the recipe's environment) loosens only those bounds, each only
#               when WORSE (a named key with no bound is seeded), and leaves scorecard.json alone: the scorecard runs as `check`
#               under the label instead, so its verdict shows now. Without KEYS every bound
#               moves; the ratchet and this script then WARN, naming each loosened bound and
#               the scorecard.json rewrite (devkit decisions 2026-10-17). With no bounds
#               file (and no KEYS) it seeds every key: first adoption, written only on success
#   tighten and rebaseline also write the report-only keys (vuln.*, fan_in_max) to
#   report-only.json beside the bounds: the committed copy the scorecard reads from a fresh
#   clone (commit it with the bounds)
#   Every mode also runs the scorecard ratchet (bin/scorecard.py --mode <same>) when
#   docs/metrics/scorecard.json exists, and `check` also when only origin/main has it
#   (SCORECARD_BOUNDS overrides the path).
#
# scripts/ci/metrics.conf, one collector per line (`#` comments and blank lines ignored):
#   <name> <area> <command...>
#   name     [A-Za-z0-9_-]+, unique: the collector writes build/metrics/<name>.json and the
#            snapshot records it as each key's `source`
#   area     docs|backend|frontend|native|tooling|other, or several comma-separated
#            (`backend,native`: one jscpd run over server/ and ios/): the fleet areas whose paths
#            can change its numbers. The gate plan's METRICS group runs for each area a
#            collector names (_paths_lib.sh), so a native-only change runs a `native`
#            collector. Or `repo` (always runs when the metrics job does: a whole-repo tool), or
#            job:<gate job name>: the collector reads that gate job's output rather than the
#            tree (coverage.py over the report `unit-backend` wrote), so it runs iff that job
#            ran in this gate
#   command  run with `bash -c` from the repo root; it must write build/metrics/<name>.json
#            (docs/metrics-keys.md shape) and exit 0, or the job fails. Tools come from the
#            repo's own dev dependencies (`uv run …`, `node_modules/.bin/…`).
# A malformed line is exit 2 naming file:line, before anything runs.
#
# Which collectors run: outside the gate (GATE_AREAS unset) all of them. Inside the gate
# (local_gate.sh exports GATE_AREAS before the plan) an area collector runs when one of its
# areas is in GATE_AREAS, or when GATE_AREAS holds `other` (a change outside the app halves may move
# any number); `repo` collectors always run; `tooling` widens nothing (devkit/metrics/*,
# metrics_collect.sh and metrics_ratchet.py classify as other, so a tooling-only diff cannot
# move a metric, and its gate runs no tier anyway). A `job:<name>` collector runs iff
# build/metrics/gate.json holds `gate.<name>.seconds`: local_gate.sh rewrites that file after
# every job and the metrics job runs last, so the entry exists exactly when the job ran. Why a
# job and not an area: a repo's gate_plan_extra may skip one job of an area (closet skips db
# for .github/** and Playwright-only test/**), so "the area's group ran" is not "my input
# exists". A job name the plan never ran, or does not have, is "did not run" (SKIP) in the
# gate and runs outside it. One `metrics <name> RUN|SKIP (<why>)` line each. The skipped names
# go to `metrics_ratchet.py merge --skipped`, so `check` reports their tracked keys as SKIPPED
# rather than MISSING: a frontend-only PR cannot have changed backend coverage, and the unit
# job that produces that coverage did not run either.
#
# Tier inputs, outside the gate: the files a build or test tier writes that a collector reads
# (the TIER_INPUTS table, bin/_metrics_conf_lib.sh: coverage reports, the statement fixture's
# build/statements.json, a Next app's build manifest for ts.mjs --bundle), and the
# build/metrics/tier-<tier>.json of every tier the bounds hold a test-count floor for (collector
# `tier-<tier>`, target the Makefile rule that runs `tier_guard.sh <tier>`: makefile_tier_target),
# since tighten raises a floor from it (metrics_ratchet.py, Floors). --quick never skips on one. Before any collector runs, every such file of every collector that
# will run is checked; when any is missing the run stops once (exit 2) listing each file, its
# collector and the make target of the gate job that writes it (the collector's job:<name> area,
# looked up in scripts/ci/gate_plan.sh: a GATE_JOBS_* entry or a `job <name> <target>` call).
# Lanes in fresh worktrees otherwise met them one failure at a time: frontend coverage, then
# build/statements.json, then `make test-db` (finplat and Orbit, 2026-10-17). TIGHTEN_RUN_TIERS=1
# runs those targets first instead, then checks again. An input that exists but is older than
# the newest tracked file under its source dir (newest_source) is STALE: a WARNING naming its
# target, and under TIGHTEN_RUN_TIERS=1 its target reruns too (closet, 2026-10-18: coverage
# from before a rebase read a false WORSE). `--fresh` (TIGHTEN_RUN_TIERS=fresh through make)
# reruns every input's target. Inside the gate a job: collector runs only when its job ran, so a
# missing input there is the collector's ordinary failure.
#
# Merged tree (tighten only, outside the gate): the gate measures the PR merged into origin/main,
# so a bound tighten set from the branch alone read WORSE there once main had moved (instalite
# #29: coverage 0.04 under the bound it had just committed). When origin/main's tip (fetched
# first when there is an origin remote) is not an ancestor of HEAD, tighten refuses a dirty
# tree (an untracked, unignored file too: the worktree is built from commits), adds a detached worktree at origin/main under $TMPDIR, merges HEAD into it (a conflict
# is exit 2: rebase first, the gate would fail the merge too) and runs the repo's own
# `make metrics-tighten` there with TIGHTEN_RUN_TIERS=1 (a new worktree has no tier outputs;
# `fresh` passes through), so its deps target installs what the merged tree declares. It then
# copies the bounds file, report-only.json and scorecard.json beside it, and the snapshot, back
# into this checkout (commit them) and removes the worktree. The bounds then carry main's moves
# too, so the PR's copy merges cleanly. METRICS_TIGHTEN_MERGED is set inside: no second hop.
# --conf, --bounds and --out reach the inner tighten as METRICS_TIGHTEN_{CONF,BOUNDS,OUT}, which
# only a tighten under METRICS_TIGHTEN_MERGED reads: the recipe it runs passes no flags. They and
# SCORECARD_BOUNDS go relative when inside this checkout (in_checkout), else absolute.
#
# Toolchain: before any collector, the tree's pinned Node and Rust go first on PATH
# (bin/toolchain_path.sh, as the gate and the hooks do), so `make metrics-snapshot` on a Mac
# whose PATH has Node 25 still runs dependency-cruiser on the .nvmrc Node. A pin that cannot
# be provided is exit 2 naming it.
#
# build/metrics/ before a run: only this conf's collector files (and their logs) are removed.
# gate.json (local_gate.sh, every earlier job's seconds) and tier-*.json (tier_guard.sh, the
# tiers that ran in this gate) were written before this job and are merged into the snapshot;
# an `rm -rf build/metrics` here would silently drop them.
#
# Findings: a collector whose command runs devkit's metrics/python.py, ts.mjs, rust.py, shell.py or jscpd.mjs gets
# `--list-out build/metrics/<name>.findings.txt` appended (nothing to declare in the conf; a
# command that names its own --list-out keeps it): the file, function, module behind every
# count, so a lane reads what to fix instead of scripting it. Appended to the end of the
# command, so the collector must be its last command (no trailing `&&`, `|` or `;`). The run ends with one `findings: <files>` line, whatever the verdict. The ratchet and the
# scorecard never read these files.
#
# Output: the `metrics …` lines above (and `metrics tiers RUN …` under TIGHTEN_RUN_TIERS=1), each collector's log tail (40 lines) on failure, then
# the ratchet's own `ratchet …` lines, then the `findings:` line. Exit: 0 ok, 1 the ratchet failed, 2 usage, a malformed
# conf, a collector that failed or wrote no file, or an unreadable bounds file.
# Portability: macOS bash 3.2 and GNU bash.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RATCHET=$HERE/metrics_ratchet.py
# shellcheck source=bin/_gate_env.sh  # fetch_main: merge_needed reads a current origin/main
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_metrics_conf_lib.sh  # the conf's parse and its TIER_INPUTS table
. "$HERE/_metrics_conf_lib.sh"
# shellcheck source=bin/_makefile_lib.sh  # makefile_tier_target: the rule a floor's tier runs in
. "$HERE/_makefile_lib.sh"
# shellcheck source=bin/_toolchain_lib.sh  # devkit_python, for floor_tiers before toolchain_path
. "$HERE/_toolchain_lib.sh"
# Where every collector writes, and where local_gate.sh and tier_guard.sh already wrote: the
# merge reads the whole directory.
readonly COLLECT_DIR=build/metrics
readonly GATE_JSON=build/metrics/gate.json   # local_gate.sh's job seconds: which jobs ran
readonly SUBCOMMANDS="snapshot check tighten rebaseline"
# A conf command that runs one of devkit's --list-out collectors (any path prefix: devkit/,
# ../devkit/). Matched against " <command> " so the name may end the line.
readonly LIST_OUT_COLLECTOR='[[:space:]/]metrics/(python\.py|ts\.mjs|rust\.py|shell\.py|jscpd\.mjs)[[:space:]]'

usage() {
  echo "usage: $0 <snapshot|check|tighten|rebaseline> [--conf FILE] [--bounds FILE] [--out FILE] [--fresh] [--quick]" >&2
  exit 2
}
die() { echo "metrics_collect: $*" >&2; exit 2; }

[ $# -ge 1 ] || usage
SUB=$1
shift
case " $SUBCOMMANDS " in *" $SUB "*) ;; *) usage ;; esac
CONF=scripts/ci/metrics.conf
BOUNDS=docs/metrics/ratchet.json
OUT=build/metrics.json
# Inside the merged hop the outer call's --conf/--bounds/--out arrive as env (tighten_on_merge):
# the repo's metrics-tighten recipe passes no flags of its own, so make cannot carry them.
if [ "$SUB" = tighten ] && [ -n "${METRICS_TIGHTEN_MERGED:-}" ]; then
  CONF=${METRICS_TIGHTEN_CONF:-$CONF}
  BOUNDS=${METRICS_TIGHTEN_BOUNDS:-$BOUNDS}
  OUT=${METRICS_TIGHTEN_OUT:-$OUT}
fi
# --fresh, or TIGHTEN_RUN_TIERS=fresh (the spelling a make target passes): rerun every tier input.
FRESH=0
[ "${TIGHTEN_RUN_TIERS:-0}" != fresh ] || FRESH=1
QUICK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1 ;;
    --quick) QUICK=1 ;;
    --conf) [ $# -ge 2 ] || usage; CONF=$2; shift ;;
    --bounds) [ $# -ge 2 ] || usage; BOUNDS=$2; shift ;;
    --out) [ $# -ge 2 ] || usage; OUT=$2; shift ;;
    *) usage ;;
  esac
  shift
done
# quick_args: --quick is check's, outside the gate, and never reruns a tier (it skips the
# tier's collectors instead), so FRESH goes back to 0.
quick_args() {
  [ "$SUB" = check ] || die "--quick is check's alone (the pre-push preview)"
  [ -z "${GATE_AREAS+x}" ] || die "--quick runs outside the gate only"
  FRESH=0
}
[ "$QUICK" = 0 ] || quick_args
[ -f "$CONF" ] || die "no collectors file at $CONF (format: devkit/bin/metrics_collect.sh header)"
# A whole rebaseline with no bounds file is first adoption: metrics_ratchet.py starts it from no
# bounds and writes the file only when it succeeds (a failed run leaves none to commit), so
# `make metrics-rebaseline` is the one command that creates it (devkit-check names it for a
# hand-built repo). Every other mode needs the file.
case "$SUB" in
  snapshot) ;;
  rebaseline) [ -n "${KEYS:-}" ] || [ -f "$BOUNDS" ] || first_adoption=1 ;;
esac
[ "$SUB" = snapshot ] || [ -n "${first_adoption:-}" ] || [ -f "$BOUNDS" ] \
  || die "no bounds file at $BOUNDS (make metrics-rebaseline creates it)"

# ---- tighten on the merged tree (header: Merged tree) ---------------------------------------------
# merge_needed: true when tighten must measure a merge, setting MERGE_MAIN and MERGE_HEAD (only
# outside the gate, not already inside one, and with an origin/main HEAD does not contain).
merge_needed() {
  [ "$SUB" = tighten ] && [ -z "${GATE_AREAS+x}" ] && [ -z "${METRICS_TIGHTEN_MERGED:-}" ] || return 1
  if git remote get-url origin >/dev/null 2>&1 && ! fetch_main . 2>/dev/null; then
    echo "metrics tighten: could not fetch origin main; using the local origin/main" >&2
  fi
  MERGE_MAIN=$(git rev-parse -q --verify "origin/main^{commit}" 2>/dev/null) || return 1
  MERGE_HEAD=$(git rev-parse HEAD) || return 1
  ! git merge-base --is-ancestor "$MERGE_MAIN" "$MERGE_HEAD"
}
# merge_worktree <dir>: a detached worktree at MERGE_MAIN with MERGE_HEAD merged in; exit 2 when
# the tree is dirty (the merge would not hold the edit) or the merge conflicts. Dirty counts an
# untracked, unignored file: the worktree is built from commits, so a collector walking the tree
# (metrics/size.py) would miss it and its bounds would not describe this checkout.
merge_worktree() {
  local dirty
  # awk, not head: it drains the list, so git never dies of SIGPIPE under pipefail.
  dirty=$(git status --porcelain --untracked-files=all | awk 'NR <= 3 { printf "%s ", substr($0, 4) }')
  [ -z "$dirty" ] \
    || die "tighten measures HEAD merged into origin/main ${MERGE_MAIN:0:7}, as the gate does, and HEAD does not contain it: commit (or stash -u) the changes first, or rebase onto origin/main (dirty: ${dirty% })"
  git worktree add -q --detach "$1" "$MERGE_MAIN" >/dev/null 2>&1 || die "could not add a worktree at origin/main ${MERGE_MAIN:0:7}"
  git -C "$1" -c user.name=metrics-tighten -c user.email=metrics-tighten@local \
    merge -q --no-edit "$MERGE_HEAD" >/dev/null 2>&1 \
    || die "HEAD conflicts with origin/main ${MERGE_MAIN:0:7}; rebase onto it first (the gate would fail the merge too)"
}
# in_checkout <path>: <path> relative to this checkout when it resolves inside it (logically or
# physically: a checkout under a symlinked directory), so the merged worktree reads and writes
# its own copy; else absolute, since a relative `../x` would resolve against the worktree.
in_checkout() {
  local top path dir
  top=$(pwd -P)
  case "$1" in /*) path=$1 ;; *) path=$PWD/$1 ;; esac
  # A directory that does not exist yet (--out build/x.json before any build) stays logical,
  # with its `..` folded first: `../new/x.json` is outside, not under "$PWD"/ (Codex, orbit #116).
  if dir=$(CDPATH='' cd -P "$(dirname "$path")" 2>/dev/null && pwd); then
    path=$dir/$(basename "$path")
  else
    path=$(lexical_path "$path")
  fi
  case "$path" in
    "$top"/*) echo "${path#"$top"/}" ;;
    "$PWD"/*) echo "${path#"$PWD"/}" ;;
    *) echo "$path" ;;
  esac
}
# lexical_path <absolute path>: the path with `.`, `..` and repeated slashes folded, touching
# no filesystem (for a path that does not exist yet, which cd -P cannot resolve).
lexical_path() {
  local part parts kept=()
  IFS=/ read -ra parts <<<"$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      '' | .) ;;
      ..) [ "${#kept[@]}" -eq 0 ] || unset 'kept[${#kept[@]}-1]' ;;
      *) kept+=("$part") ;;
    esac
  done
  local IFS=/
  echo "/${kept[*]+"${kept[*]}"}"  # bash 3.2: an empty array is unbound under set -u
}
# copy_back <dir>: the files tighten writes, from the merged worktree into this checkout. An
# absolute path (outside this checkout: in_checkout) was written in place by the merged run.
copy_back() {
  local f
  for f in "$BOUNDS" "$(dirname "$BOUNDS")/report-only.json" "${SCORECARD_BOUNDS:-docs/metrics/scorecard.json}" "$OUT"; do
    case "$f" in /*) continue ;; esac
    if [ -f "$1/$f" ] && ! cmp -s "$1/$f" "$f"; then
      { mkdir -p "$(dirname "$f")" && cp "$1/$f" "$f"; } || die "could not copy $f back from the merged tree"
      echo "metrics tighten: $f from the merged tree"
    fi
  done
}
# tighten_on_merge: tighten in a temporary worktree of the merge, the results copied back; exits.
tighten_on_merge() {
  local wt tiers rc=0
  MERGED_TMP=$(mktemp -d "${TMPDIR:-/tmp}/metrics-tighten.XXXXXX") || die "mktemp failed"
  wt=$MERGED_TMP/merged
  trap 'git worktree remove --force "$MERGED_TMP/merged" >/dev/null 2>&1; rm -rf "$MERGED_TMP"' EXIT
  merge_worktree "$wt"
  tiers=${TIGHTEN_RUN_TIERS:-1}
  [ "$tiers" = fresh ] || tiers=1
  echo "metrics tighten: HEAD ${MERGE_HEAD:0:7} does not contain origin/main ${MERGE_MAIN:0:7}; measuring their merge, as the gate will, in $wt (TIGHTEN_RUN_TIERS=$tiers)"
  CONF=$(in_checkout "$CONF") BOUNDS=$(in_checkout "$BOUNDS") OUT=$(in_checkout "$OUT")
  if [ -n "${SCORECARD_BOUNDS:-}" ]; then
    SCORECARD_BOUNDS=$(in_checkout "$SCORECARD_BOUNDS")
    export SCORECARD_BOUNDS
  fi
  METRICS_TIGHTEN_MERGED=1 TIGHTEN_RUN_TIERS=$tiers \
    METRICS_TIGHTEN_CONF=$CONF METRICS_TIGHTEN_BOUNDS=$BOUNDS METRICS_TIGHTEN_OUT=$OUT \
    make -C "$wt" --no-print-directory metrics-tighten || rc=$?
  # tighten exits 1 for a WORSE key after writing its BETTER bounds: those still come back.
  [ "$rc" -gt 1 ] || copy_back "$wt"
  exit "$rc"
}
! merge_needed || tighten_on_merge

# ---- parse the conf: every line before anything runs ---------------------------------------
metrics_conf_parse "$CONF"

# ---- decide: RUN or SKIP per collector ---------------------------------------------------------
# gate_job_ran <job>: true when gate.json records the job's seconds (the gate wrote it).
gate_job_ran() { [ -f "$GATE_JSON" ] && grep -q "\"gate.$1.seconds\"" "$GATE_JSON"; }
# run_reason <area>: prints why the collector runs, or nothing when it is skipped.
run_reason() {
  # shellcheck disable=SC2031  # plan_job_target's subshell sets its own GATE_AREAS; this is the gate's
if [ -z "${GATE_AREAS+x}" ]; then echo "outside the gate: every collector runs"; return; fi
  case "$1" in
    repo) echo "repo: always runs"; return ;;
    job:*) ! gate_job_ran "${1#job:}" || echo "gate job ${1#job:} ran"; return ;;
  esac
  case " $GATE_AREAS " in *" other "*) echo "other paths changed: every collector runs"; return ;; esac
  local area
  for area in ${1//,/ }; do
    case " $GATE_AREAS " in *" $area "*) echo "$area paths changed"; return ;; esac
  done
}
# skip_reason <area>: why a skipped collector did not run.
skip_reason() {
  case "$1" in
    job:*) echo "gate job ${1#job:} did not run (no gate.${1#job:}.seconds in $GATE_JSON)" ;;
    *) echo "no $1 path changed; areas: ${GATE_AREAS:-none}" ;;
  esac
}
RUN=()      # 1|0 per collector, by index
SKIPPED=()  # names, for merge --skipped
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  why=$(run_reason "${COLLECTOR_AREAS[$i]}")
  if [ -n "$why" ]; then
    RUN+=(1)
    echo "metrics ${NAMES[$i]} RUN ($why)"
  else
    RUN+=(0)
    SKIPPED+=("${NAMES[$i]}")
    echo "metrics ${NAMES[$i]} SKIP ($(skip_reason "${COLLECTOR_AREAS[$i]}"))"
  fi
  i=$((i + 1))
done

# ---- tier inputs (header: Tier inputs) -------------------------------------------------------------
# plan_job_target <job>: the make target of the plan's gate job <job>, or nothing. The plan is
# run, not parsed: a regex read rollcall's one-line `if …; then job db ci-db; else …` as target
# `ci-db;` (2026-10-19). A subshell sources _paths_lib.sh and the plan with the skeleton's
# helpers stubbed (`job` prints the target of the job asked for on fd 3 and stops; plan output
# and errors are dropped), then declares every GATE_JOBS_<GROUP> and calls gate_plan_extra and
# gate_plan as the gate would for a diff of one unclassified root file: an "other" path, which
# by the plan contract runs every group. A job only some other diff reaches is not found.
plan_job_target() {
  [ -f scripts/ci/gate_plan.sh ] || return 0
  (
    set +eu
    want=$1 CHANGED=devkit-plan-probe
    # shellcheck source=bin/_paths_lib.sh
    . "$HERE/_paths_lib.sh"
    GATE_CODE_PATHS=  # the plan's alone, never the environment's (_paths_lib.sh header)
    # shellcheck source=/dev/null  # the repo's plan, as local_gate.sh sources it
    . scripts/ci/gate_plan.sh
    # shellcheck disable=SC2329  # the skeleton's helpers (local_gate.sh), which the plan calls
    {
      job() { [ "$1" != "$want" ] || { printf '%s\n' "$2" >&3; exit 0; }; }
      skip() { :; }
      note() { :; }
      nothing_to_run() { exit 0; }
      changed() { grep -qE "$1" <<<"$CHANGED"; }
      pr_has_label() { return 1; }
    }
    devkit_gate_areas "$CHANGED"
    for group in $(compgen -v GATE_JOBS_); do _devkit_run_jobs "${!group}"; done
    if declare -F gate_plan_extra >/dev/null; then gate_plan_extra; fi
    if declare -F gate_plan >/dev/null; then gate_plan; fi
  ) 3>&1 >/dev/null 2>&1 </dev/null
}
# STAT_MTIME <file>...: each file's mtime in epoch seconds. GNU is probed first: BSD stat has
# no -c, while GNU `stat -f` is the file-system form and would print a wrong answer, not fail.
if stat -c %Y / >/dev/null 2>&1; then STAT_MTIME=(stat -c %Y); else STAT_MTIME=(stat -f %m); fi
# source_dir <input>: the tracked directory whose code the tier that wrote <input> runs: the
# input's first path segment when git tracks files under it (backend/build/coverage.json ->
# backend), else the whole tree (build/statements.json).
source_dir() {
  local top=${1%%/*}
  if [ "$top" != "$1" ] && [ -n "$(git ls-files -- "$top" 2>/dev/null | head -1)" ]; then echo "$top"; else echo .; fi
}
# newest_source <dir>: the newest mtime of the tracked files under <dir>, less docs/metrics
# (tighten's own output); empty when none. Why mtime, not the last commit: checkout and rebase
# rewrite exactly the files whose content changed, so their mtimes say what a tier has not run
# against (closet, 2026-10-18: a rebase kept coverage from before it, and check read a false
# WORSE), while a commit after a test run rewrites nothing and must not make that run stale.
# A tracked file deleted in the tree has no mtime; stat's complaint about it is dropped.
newest_source() {
  git ls-files -z -- "$1" ':(exclude)docs/metrics' 2>/dev/null \
    | xargs -0 "${STAT_MTIME[@]}" 2>/dev/null | sort -n | tail -1
}
# floor_tiers: the tiers the bounds hold a test-count floor for (metrics_ratchet.py floors), one
# per line. Their tier-<tier>.json is an input like a coverage report: tier_guard.sh writes it
# only when the tier runs, and a stale one would tighten a floor to an old count.
floor_tiers() {
  [ -f "$BOUNDS" ] || return 0
  devkit_python || die "$DEVKIT_PYTHON_ERROR"
  "$DEVKIT_PYTHON" -I "$RATCHET" floors --bounds "$BOUNDS" | awk '!seen[$1]++ { print $1 }'
  [ "${PIPESTATUS[0]}" = 0 ] || exit 2
}
# input_state <file> <name> <target>: adds <file> (<name>'s input, written by `make <target>`) to
# MISSING or STALE, and its target to RERUN when it must rerun (tier_input_state).
input_state() {
  local f=$1 name=$2 target=$3 dir newest
  dir=$(source_dir "$f")
  if [ ! -e "$f" ]; then
    MISSING+="$f"$'\t'"$name"$'\t'"$dir"$'\t'"$target"$'\n'
  else
    newest=$(newest_source "$dir")
    if [ "$FRESH" = 1 ] || { [ -n "$newest" ] && [ "$("${STAT_MTIME[@]}" "$f")" -lt "$newest" ]; }; then
      STALE+="$f"$'\t'"$name"$'\t'"$dir"$'\t'"$target"$'\n'
      [ "$FRESH" = 1 ] || [ "${TIGHTEN_RUN_TIERS:-0}" = 1 ] || return 0
    else
      return 0
    fi
  fi
  case " $RERUN " in *" $target "*) ;; *) [ -z "$target" ] || RERUN="${RERUN:+$RERUN }$target" ;; esac
}
# tier_input_state: for the collectors that will run and the floor tiers (FLOOR_TIERS), sets
# MISSING and STALE (lines "<file>\t<collector>\t<source dir>\t<target or empty>": the empty
# field last, since IFS=tab reads collapse an empty middle one; a floor tier's collector is
# tier-<tier>) and RERUN (the distinct targets to rerun, in conf order, then the floor tiers'):
# every missing input's, and under TIGHTEN_RUN_TIERS=1 or --fresh every stale input's too. With
# --fresh every input that exists counts as stale.
tier_input_state() {
  local i=0 f target tier
  MISSING="" STALE="" RERUN=""
  while [ "$i" -lt "${#NAMES[@]}" ]; do
    if [ "${RUN[$i]}" = 1 ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        target=""
        case "${COLLECTOR_AREAS[$i]}" in job:*) target=$(plan_job_target "${COLLECTOR_AREAS[$i]#job:}") ;; esac
        input_state "$f" "${NAMES[$i]}" "$target"
      done <<<"$(tier_inputs "${COMMANDS[$i]}")"
    fi
    i=$((i + 1))
  done
  while IFS= read -r tier; do
    [ -z "$tier" ] || input_state "$COLLECT_DIR/tier-$tier.json" "tier-$tier" "$(makefile_tier_target "$tier")"
  done <<<"$FLOOR_TIERS"
}
# report_stale: one WARNING per stale input, when nothing reran it.
report_stale() {
  local f name dir target
  while IFS=$'\t' read -r f name dir target; do
    [ -n "$f" ] || continue
    echo "metrics_collect: WARNING: $f ($name) is older than the newest tracked change under $dir; its numbers may predate the code. Rerun: make ${target:-<its tier>} (or TIGHTEN_RUN_TIERS=1)" >&2
  done <<<"$STALE"
}
# quick_skip_unbuilt: --quick drops every collector with a missing or stale tier input, then
# clears MISSING, STALE and RERUN: nothing is left for the steps below to rerun or refuse.
quick_skip_unbuilt() {
  local f name dir target i seen=" "
  while IFS=$'\t' read -r f name dir target; do
    [ -n "$f" ] && [ "${seen/ $name /}" = "$seen" ] || continue
    seen="$seen$name "
    # A floor tier is no collector to drop: its keys read SKIPPED without the file (the ratchet's
    # tier rule), and a stale one is still read, which a preview that never blocks can afford.
    case $name in tier-*) continue ;; esac
    i=0
    while [ "${NAMES[$i]}" != "$name" ]; do i=$((i + 1)); done
    RUN[i]=0
    SKIPPED+=("$name")
    if [ -e "$f" ]; then
      echo "metrics $name SKIP (--quick: $f is older than the newest tracked change under $dir)"
    else
      echo "metrics $name SKIP (--quick: $f is not built${target:+; make $target writes it})"
    fi
  done <<<"$MISSING$STALE"
  MISSING="" STALE="" RERUN=""
}
# shellcheck disable=SC2031  # plan_job_target's subshell sets its own GATE_AREAS; this is the gate's
if [ -z "${GATE_AREAS+x}" ]; then
  FLOOR_TIERS=$(floor_tiers) || exit 2
  tier_input_state
  [ "$QUICK" = 0 ] || quick_skip_unbuilt
  if [ -n "$RERUN" ] && { [ "$FRESH" = 1 ] || [ "${TIGHTEN_RUN_TIERS:-0}" = 1 ]; }; then
    why=TIGHTEN_RUN_TIERS=1
    [ "$FRESH" = 0 ] || why=--fresh
    while IFS=$'\t' read -r f name dir _target; do
      [ -z "$f" ] || echo "metrics tiers STALE $f ($name; $([ "$FRESH" = 1 ] && echo "--fresh" || echo "older than the newest tracked change under $dir"))"
    done <<<"$STALE"
    echo "metrics tiers RUN ($why): make $RERUN"
    # shellcheck disable=SC2086  # RERUN is a word list of make targets
    make --no-print-directory $RERUN || die "make $RERUN failed; the inputs above are still missing or stale"
    FRESH=0
    tier_input_state
  fi
  report_stale
  if [ -n "$MISSING" ]; then
    echo "metrics_collect: $SUB needs files the test tiers write; missing here:" >&2
    while IFS=$'\t' read -r f name _dir target; do
      [ -n "$f" ] || continue
      if [ -n "$target" ]; then
        echo "  $f  ($name; make $target)" >&2
      elif [ "${name#tier-}" != "$name" ]; then
        echo "  $f  ($name: $BOUNDS holds its floor, and no Makefile rule runs tier_guard.sh ${name#tier-})" >&2
      else
        echo "  $f  ($name; no gate job in scripts/ci/gate_plan.sh writes it: give the collector a job:<name> area)" >&2
      fi
    done <<<"$MISSING"
    rerun=metrics-$SUB
    [ "$SUB" != check ] || rerun=ci-metrics
    [ -z "$RERUN" ] || echo "  run: make $RERUN   (or TIGHTEN_RUN_TIERS=1 make $rerun to run them first)" >&2
    exit 2
  fi
fi

# ---- run ------------------------------------------------------------------------------------------
# shellcheck source=bin/toolchain_path.sh
. "$HERE/toolchain_path.sh"
# Also resolves and exports DEVKIT_PYTHON (devkit_python), which the ratchet and scorecard calls
# below run on, so a direct run needs no parent to have set it (floor_tiers resolved it already
# when the bounds hold a floor).
toolchain_path . || die "$TOOLCHAIN_ERROR"
mkdir -p "$COLLECT_DIR" || die "cannot create $COLLECT_DIR"
for name in ${NAMES[@]+"${NAMES[@]}"}; do
  rm -f "$COLLECT_DIR/$name.json" "$COLLECT_DIR/$name.log" "$COLLECT_DIR/$name.findings.txt"
done
# print_findings: the last line of every run from here on (EXIT trap: the ratchet's `exit 1`
# included), naming the findings files this run wrote.
# shellcheck disable=SC2329  # invoked by the EXIT trap
print_findings() {
  local files=() f
  for f in "$COLLECT_DIR"/*.findings.txt; do [ -f "$f" ] && files+=("$f"); done
  [ ${#files[@]} -eq 0 ] || echo "findings: ${files[*]}"
}
trap print_findings EXIT
# A collector's "a tool it runs is not installed" (metrics/*: MissingToolError). The gate fails on it
# like any collector failure; --quick, a preview in a worktree that may predate its install,
# skips it naming the fix.
EXIT_MISSING_TOOL=3
# missing_tool_reason <log>: the collector's own line naming the tool, plus the repo's
# metrics-deps target when its Makefile has one (the repo-local tool installs: claude-kit, ...).
missing_tool_reason() {
  local why
  why=$(grep '^metrics/' "$1" | tail -n 1 | sed 's|^metrics/[^:]*: ||')  # the last: the failure
  [ -n "$why" ] || why="a tool it runs is not installed (exit $EXIT_MISSING_TOOL; log: $1)"
  if [ -f Makefile ] && grep -qE '^metrics-deps:' Makefile; then why="$why; make metrics-deps installs it"; fi
  printf '%s' "$why"
}
t0=$SECONDS
ran=0
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  if [ "${RUN[$i]}" = 1 ]; then
    name=${NAMES[$i]}
    log=$COLLECT_DIR/$name.log
    out=$COLLECT_DIR/$name.json
    command=${COMMANDS[$i]}
    if [[ " $command " =~ $LIST_OUT_COLLECTOR ]] && [[ "$command" != *--list-out* ]]; then
      command="$command --list-out $COLLECT_DIR/$name.findings.txt"
    fi
    bash -c "$command" </dev/null >"$log" 2>&1
    rc=$?
    if [ "$rc" -eq "$EXIT_MISSING_TOOL" ] && [ "$QUICK" = 1 ]; then
      SKIPPED+=("$name")
      echo "metrics $name SKIP (--quick, tool missing: $(missing_tool_reason "$log"))"
      i=$((i + 1))
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      echo "metrics $name FAIL (exit $rc; log: $log)"
      tail -n 40 "$log"
      exit 2
    fi
    if [ ! -f "$out" ]; then
      echo "metrics $name FAIL (exit 0 but wrote no $out; log: $log)"
      tail -n 40 "$log"
      exit 2
    fi
    ran=$((ran + 1))
  fi
  i=$((i + 1))
done
echo "metrics collected $ran of ${#NAMES[@]} collector(s) in $((SECONDS - t0))s (skipped ${#SKIPPED[@]})"

# ---- merge, then the ratchet ----------------------------------------------------------------------
INPUTS=()
for f in "$COLLECT_DIR"/*.json; do
  [ -f "$f" ] && INPUTS+=("$f")
done
MERGE_ARGS=()
for name in ${SKIPPED[@]+"${SKIPPED[@]}"}; do MERGE_ARGS+=(--skipped "$name"); done
"$DEVKIT_PYTHON" -I "$RATCHET" merge --out "$OUT" ${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"} \
  -- ${INPUTS[@]+"${INPUTS[@]}"} || exit $?
[ "$SUB" != snapshot ] || exit 0

RATCHET_ARGS=("$SUB" --snapshot "$OUT" --bounds "$BOUNDS")
if [ "$SUB" = check ] && [ "${METRICS_REBASELINE:-0}" = 1 ]; then RATCHET_ARGS+=(--rebaseline-ok); fi
KEYED=0
if [ "$SUB" = rebaseline ] && [ -n "${KEYS:-}" ]; then KEYED=1; RATCHET_ARGS+=(--keys "$KEYS"); fi
if [ "$SUB" = tighten ] && [ "${SEED:-0}" = 1 ]; then RATCHET_ARGS+=(--seed); fi
# The modes an author commits from also refresh the committed report-only copy beside the
# bounds; check (the gate) never writes a tracked file.
case "$SUB" in tighten|rebaseline) RATCHET_ARGS+=(--report-only "$(dirname "$BOUNDS")/report-only.json") ;; esac
# quick_ratchet: --quick's ratchet, its lines then the pre-push hint; exits with the ratchet's code.
quick_ratchet() {
  local out rc=0
  out=$("$DEVKIT_PYTHON" -I "$RATCHET" "${RATCHET_ARGS[@]}") || rc=$?
  printf '%s\n' "$out"
  ! grep -q ' BETTER — run make metrics-tighten' <<<"$out" || echo "BETTER: run make metrics-tighten before push"
  exit "$rc"
}
[ "$QUICK" = 0 ] || quick_ratchet
"$DEVKIT_PYTHON" -I "$RATCHET" "${RATCHET_ARGS[@]}"
ratchet_rc=$?
# A failing tighten (rc 1: a WORSE key) has still written its BETTER bounds; the scorecard's
# tighten runs too, so one command locks in everything that improved before reporting the rest.
if [ "$ratchet_rc" -ne 0 ] && { [ "$SUB" != tighten ] || [ "$ratchet_rc" -ne 1 ]; }; then
  exit "$ratchet_rc"
fi

# The scorecard ratchet (bin/scorecard.py --mode): opt-in by committing docs/metrics/scorecard.json
# (`scorecard.py . --mode rebaseline` once). Same subcommand, same label semantics, after the
# metric bounds so its evidence lines read the snapshot this job just merged.
# check also runs when only main has the file: deleting it lowers every track, which needs the label.
SCORECARD_BOUNDS=${SCORECARD_BOUNDS:-docs/metrics/scorecard.json}
if [ -f "$SCORECARD_BOUNDS" ] \
  || { [ "$SUB" = check ] && git cat-file -e "origin/main:$SCORECARD_BOUNDS" 2>/dev/null; }; then
  SC_MODE=$SUB
  [ "$KEYED" = 0 ] || SC_MODE=check
  SC_ARGS=(. --mode "$SC_MODE" --bounds-file "$SCORECARD_BOUNDS")
  if [ "$SC_MODE" = check ] && { [ "${METRICS_REBASELINE:-0}" = 1 ] || [ "$KEYED" = 1 ]; }; then
    SC_ARGS+=(--rebaseline-ok)
  fi
  "$DEVKIT_PYTHON" -I "$HERE/scorecard.py" "${SC_ARGS[@]}" | grep -E '^(scorecard-ratchet(-bound)?:?|scorecard|metrics-rebaseline:) ' || exit "${PIPESTATUS[0]}"
  if [ "$SUB" = rebaseline ] && [ "$KEYED" = 0 ]; then
    echo "metrics_collect: WARNING: $SCORECARD_BOUNDS was rewritten too (every check to today's state); to loosen only named bounds, restore both files and run \`make metrics-rebaseline KEYS=<key>[,<key>]\`" >&2
  fi
fi
exit "$ratchet_rc"
