#!/usr/bin/env bash
# The ci-metrics mechanism: run the repo's declared metrics collectors, merge their output
# into one snapshot, then run the ratchet. A repo's Makefile holds three one-line targets
# (`ci-metrics` = check, `metrics-snapshot`, `metrics-tighten`) and nothing else; which
# collectors exist is scripts/ci/metrics.conf, which run for a PR is decided here from the
# gate's areas (devkit docs/decisions.md 2026-10-15).
#
# Usage, from the repo root (make runs there):
#   devkit/bin/metrics_collect.sh <snapshot|check|tighten|rebaseline>
#       [--conf scripts/ci/metrics.conf] [--bounds docs/metrics/ratchet.json] [--out build/metrics.json]
#   snapshot    run the collectors and merge; build/metrics.json is the report
#   check       snapshot, then `metrics_ratchet.py check` (the gate job; METRICS_REBASELINE=1,
#               which the gate plan sets from the metrics-rebaseline label, adds --rebaseline-ok)
#   tighten     snapshot, then lock in the BETTER numbers (commit the bounds in the same PR);
#               exit 1 when a key is WORSE or MISSING, printed as check prints it, after
#               writing the BETTER bounds and running the scorecard's tighten
#   rebaseline  snapshot, then overwrite every bound (first adoption, or after a tool change)
#   Every mode also runs the scorecard ratchet (bin/scorecard.py --mode <same>) when
#   docs/metrics/scorecard.json exists, and `check` also when only origin/main has it
#   (SCORECARD_BOUNDS overrides the path).
#
# scripts/ci/metrics.conf, one collector per line (`#` comments and blank lines ignored):
#   <name> <area> <command...>
#   name     [A-Za-z0-9_-]+, unique: the collector writes build/metrics/<name>.json and the
#            snapshot records it as each key's `source`
#   area     docs|backend|frontend|native|tooling|other|repo: the fleet area whose paths can
#            change its numbers (`repo` = always runs: a whole-repo tool such as jscpd), or
#            job:<gate job name>: the collector reads that gate job's output rather than the
#            tree (coverage.py over the report `unit-backend` wrote), so it runs iff that job
#            ran in this gate
#   command  run with `bash -c` from the repo root; it must write build/metrics/<name>.json
#            (docs/metrics-keys.md shape) and exit 0, or the job fails. Tools come from the
#            repo's own dev dependencies (`uv run …`, `node_modules/.bin/…`).
# A malformed line is exit 2 naming file:line, before anything runs.
#
# Which collectors run: outside the gate (GATE_AREAS unset) all of them. Inside the gate
# (local_gate.sh exports GATE_AREAS before the plan) an area collector runs when its area is
# in GATE_AREAS, or when GATE_AREAS holds `other` (a change outside the app halves may move
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
# Findings: a collector whose command runs devkit's metrics/python.py, ts.mjs or rust.py gets
# `--list-out build/metrics/<name>.findings.txt` appended (nothing to declare in the conf; a
# command that names its own --list-out keeps it): the file, function, module behind every
# count, so a lane reads what to fix instead of scripting it. Appended to the end of the
# command, so the collector must be its last command (no trailing `&&`, `|` or `;`). The run ends with one `findings: <files>` line, whatever the verdict. The ratchet and the
# scorecard never read these files.
#
# Output: the `metrics …` lines above, each collector's log tail (40 lines) on failure, then
# the ratchet's own `ratchet …` lines, then the `findings:` line. Exit: 0 ok, 1 the ratchet failed, 2 usage, a malformed
# conf, a collector that failed or wrote no file, or an unreadable bounds file.
# Portability: macOS bash 3.2 and GNU bash.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RATCHET=$HERE/metrics_ratchet.py
# Where every collector writes, and where local_gate.sh and tier_guard.sh already wrote: the
# merge reads the whole directory.
readonly COLLECT_DIR=build/metrics
readonly AREAS="docs backend frontend native tooling other repo"
readonly GATE_JSON=build/metrics/gate.json   # local_gate.sh's job seconds: which jobs ran
readonly SUBCOMMANDS="snapshot check tighten rebaseline"
# A conf command that runs one of devkit's --list-out collectors (any path prefix: devkit/,
# ../devkit/). Matched against " <command> " so the name may end the line.
readonly LIST_OUT_COLLECTOR='[[:space:]/]metrics/(python\.py|ts\.mjs|rust\.py)[[:space:]]'

usage() {
  echo "usage: $0 <snapshot|check|tighten|rebaseline> [--conf FILE] [--bounds FILE] [--out FILE]" >&2
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
while [ $# -gt 0 ]; do
  case "$1" in
    --conf) [ $# -ge 2 ] || usage; CONF=$2; shift ;;
    --bounds) [ $# -ge 2 ] || usage; BOUNDS=$2; shift ;;
    --out) [ $# -ge 2 ] || usage; OUT=$2; shift ;;
    *) usage ;;
  esac
  shift
done
[ -f "$CONF" ] || die "no collectors file at $CONF (format: devkit/bin/metrics_collect.sh header)"
[ "$SUB" = snapshot ] || [ -f "$BOUNDS" ] \
  || die "no bounds file at $BOUNDS (start from '{}' or devkit/templates/metrics/ratchet.json, then run rebaseline)"

# ---- parse the conf: every line before anything runs ---------------------------------------
NAMES=()
COLLECTOR_AREAS=()
COMMANDS=()
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  line=${line#"${line%%[![:space:]]*}"}
  case "$line" in ''|'#'*) continue ;; esac
  read -r name area command <<<"$line"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "$CONF:$line_no: collector name '$name' must match [A-Za-z0-9_-]+ (it names build/metrics/<name>.json)"
  for seen in ${NAMES[@]+"${NAMES[@]}"}; do
    [ "$seen" != "$name" ] || die "$CONF:$line_no: collector '$name' declared twice"
  done
  case "${area:-}" in
    job:*)
      [[ "${area#job:}" =~ ^[A-Za-z0-9_-]+$ ]] \
        || die "$CONF:$line_no: '${area}' must name a gate job, job:<name> with [A-Za-z0-9_-]+" ;;
    *)
      case " $AREAS " in
        *" ${area:-} "*) ;;
        *) die "$CONF:$line_no: area '${area:-}' must be one of: $AREAS, or job:<gate job name>" ;;
      esac ;;
  esac
  [ -n "${command:-}" ] || die "$CONF:$line_no: collector '$name' has no command"
  NAMES+=("$name")
  COLLECTOR_AREAS+=("$area")
  COMMANDS+=("$command")
done <"$CONF"

# ---- decide: RUN or SKIP per collector ---------------------------------------------------------
# gate_job_ran <job>: true when gate.json records the job's seconds (the gate wrote it).
gate_job_ran() { [ -f "$GATE_JSON" ] && grep -q "\"gate.$1.seconds\"" "$GATE_JSON"; }
# run_reason <area>: prints why the collector runs, or nothing when it is skipped.
run_reason() {
  if [ -z "${GATE_AREAS+x}" ]; then echo "outside the gate: every collector runs"; return; fi
  case "$1" in
    repo) echo "repo: always runs"; return ;;
    job:*) ! gate_job_ran "${1#job:}" || echo "gate job ${1#job:} ran"; return ;;
  esac
  case " $GATE_AREAS " in
    *" other "*) echo "other paths changed: every collector runs"; return ;;
    *" $1 "*) echo "$1 paths changed"; return ;;
  esac
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

# ---- run ------------------------------------------------------------------------------------------
# shellcheck source=bin/toolchain_path.sh
. "$HERE/toolchain_path.sh"
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
python3 -I "$RATCHET" merge --out "$OUT" ${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"} \
  -- ${INPUTS[@]+"${INPUTS[@]}"} || exit $?
[ "$SUB" != snapshot ] || exit 0

RATCHET_ARGS=("$SUB" --snapshot "$OUT" --bounds "$BOUNDS")
if [ "$SUB" = check ] && [ "${METRICS_REBASELINE:-0}" = 1 ]; then RATCHET_ARGS+=(--rebaseline-ok); fi
python3 -I "$RATCHET" "${RATCHET_ARGS[@]}"
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
  SC_ARGS=(. --mode "$SUB" --bounds-file "$SCORECARD_BOUNDS")
  if [ "$SUB" = check ] && [ "${METRICS_REBASELINE:-0}" = 1 ]; then SC_ARGS+=(--rebaseline-ok); fi
  python3 -I "$HERE/scorecard.py" "${SC_ARGS[@]}" | grep -E '^(scorecard-ratchet(-bound)?|grade|metrics-rebaseline:) ' || exit "${PIPESTATUS[0]}"
fi
exit "$ratchet_rc"
