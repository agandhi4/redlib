# shellcheck shell=bash
# THE fleet path classification, and the default gate plan built on it. Sourced; defines
# functions and runs nothing. Used by: hook_steps.sh (which steps a commit or push needs) and
# local_gate.sh (GATE_AREAS before gate_plan, and devkit_default_gate_plan for the repo's plan).
# One table for both, so a hook and the gate can never disagree about what a path is.
#
#   devkit_classify_path <path>     print its area: docs|backend|frontend|native|tooling|other
#   devkit_areas <paths>            DEVKIT_AREAS=" a b " ("" for none), areas in DEVKIT_AREA_ORDER
#   devkit_gate_areas <paths>       export GATE_AREAS, GATE_HAS_<AREA>=0|1, GATE_ONLY_TOOLING_OR_DOCS
#   devkit_default_gate_plan        the plan body a repo's gate_plan() calls (contract below)
#
# Areas (one `case`, first match wins, so a specific entry sits above the general one it carves
# out of; each entry names the repo or devkit fact it comes from):
#   docs      prose and what docs-check alone reads
#   native    macOS-only trees the Linux gate box and the hooks never build
#   tooling   paths that can change only the gate skeleton, the hooks, or the guards ci-quick
#             runs: never the app, and never a job beyond ci-quick (except the image inputs
#             below, which pull in the image group). Strict on purpose; anything unlisted is other.
#   backend, frontend   the fleet's app halves
#   other     everything else: Makefile, scripts/, Dockerfile, .github/, src/, ... (runs all)
#
# A repo's GATE_CODE_PATHS, a literal plan line of comma-separated path prefixes
# (`GATE_CODE_PATHS=plugins/`), makes every path under them other, ahead of the table: for a
# repo whose Markdown is what it ships (claude-kit's SKILL.md and agents/*.md are the plugins'
# code; as docs, a skill-only PR would gate as docs-check alone and skip Codex). The gate and
# metrics_collect.sh source the plan; hook_steps.sh and pr_merge.sh read the literal line
# (devkit_load_code_paths), so devkit-check holds it to one literal line.
#
# A devkit/bin file is tooling only when it is listed in DEVKIT_TOOLING_BIN or DEVKIT_IMAGE_BIN;
# DEVKIT_JOB_BIN names the files a gate job executes beyond ci-quick (other, so they run
# everything). An unlisted file is other until someone decides: tests/gate_contract.bats fails
# when a bin/ file is in none of the three lists. devkit/metrics/* (the shared collectors the
# metrics job runs) is other by the default case, like DEVKIT_JOB_BIN.

DEVKIT_AREA_ORDER="docs backend frontend native tooling other"

# The METRICS group's areas come from the repo's metrics.conf (metrics_conf_areas). Guarded:
# metrics_collect.sh sources both libs, and its plan probe sources this one again. Not followed
# by shellcheck (/dev/null): inlined into that probe's subshell, the parse's arrays would read
# as modified there (SC2031) in every sourcer; the lib is linted on its own.
# shellcheck source=/dev/null
declare -F metrics_conf_parse >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/_metrics_conf_lib.sh"

# Never run from the merged tree by a job: the gate and hook machinery (run from the invoking
# checkout, main's copy), the guards ci-quick runs (devkit-check, docs/toolchain/workflows/
# release/ci-targets checks, own-commit, ios-check, hooks_check, bats_assert_check and their libs), and fleet
# operations run from a devkit checkout or after merge (sync, new, monthly audit, ship_tag in
# publish.yml, the nightly dependency merge and its vuln_watch.py), machine setup (install_gh_shim.sh, whose --check
# the scorecard reads; install_dependency_merge.sh, install_monthly_audit.sh, _launchd_job_lib.sh,
# and job_launcher.sh, the launchd entry they install), and
# ios_device.sh, which only a person's `make ios-install` runs against a phone.
DEVKIT_TOOLING_BIN="local_gate.sh gate.sh remote_gate.sh _paths_lib.sh
  hook_steps.sh quiet_run.sh push_ranges.sh hooks_check.sh
  devkit-check.sh _vendor_paths.sh docs_check.sh toolchain_check.sh ci_targets_check.sh
  _makefile_lib.sh workflows_check.sh _workflows_lib.sh release_check.sh _dockerfile_lib.sh
  _gitattributes_lib.sh _trailer_lib.sh own_commit_check.py _dockerignore.py py_cognitive_lint.py changed_lint.py _changed_files.py
  devkit-sync.sh devkit-new.sh monthly_audit.sh dead_alert_audit.py ship_tag.sh scorecard.py agent_cost.py secrets_check.sh migration_check.py
  gate_record.py pr_merge.sh merge_rules.sh pr_create.sh _gh_repo_lib.sh codex_review.py _merge_carry.sh decisions_merge.py gate_bite.py _repo_identity.py _renovate.py install_gh_shim.sh
  dependency_merge.sh _dependency_pr.py vuln_watch.py install_dependency_merge.sh install_monthly_audit.sh _launchd_job_lib.sh job_launcher.sh
  ios_check.py ios_device.sh bats_assert_check.py"
# What the image group exercises (ci-smoke/ci-image boot through them): tooling, but a change
# to one runs the image group even when nothing else would.
DEVKIT_IMAGE_BIN="boot_image.sh contract_probe.sh"
# Executed by unit/db/e2e/build/metrics jobs (tier budgets, throwaway Postgres for db tiers
# and smokes, Playwright browsers, toolchains and cargo tools a Makefile provisions (toolchain_exec.sh,
# cargo_tool.sh: the unit tier's cargo-llvm-cov; release_tool.sh and shellcheck.sh: the
# pinned linter metrics/shell.py and a lint step run); layer_check.py
# and guard_check.py, ci-quick guards that are also the metrics job's `layers` and `guards`
# collectors, and the modules they load, _source_tree.py, _ts_lex.py, _guard_rules.py and
# _compose.py (vuln.py --compose reads it too); codegen_drift.sh, which finplat's drift job
# runs; devkit's toolchain lookup (_toolchain_lib.sh, which toolchain_path.sh sources, and python.sh); the
# timeout and load libs, docker_bounded.sh, which a recipe's docker call runs through, and the
# slot pool, gate.env parser and metrics.conf reader (_metrics_conf_lib.sh) tier_guard.sh
# sources; npm_tool.sh, jscpd.mjs's pinned jscpd): other. Only
# a record of the decision; the classification needs no lookup for other.
# shellcheck disable=SC2034  # read by tests/gate_contract.bats (every bin/ file listed once)
DEVKIT_JOB_BIN="tier_guard.sh throwaway_pg.sh playwright_browsers.sh node_toolchain.sh
  rust_toolchain.sh toolchain_path.sh toolchain_exec.sh toolchain_shell.sh cargo_tool.sh metrics_ratchet.py metrics_collect.sh layer_check.py
  guard_check.py _source_tree.py _ts_lex.py _guard_rules.py _compose.py _timeout_lib.sh _load_lib.sh
  docker_bounded.sh release_tool.sh shellcheck.sh _awake_lib.sh _slot_lib.sh _gate_env.sh
  codegen_drift.sh _toolchain_lib.sh python.sh _metrics_conf_lib.sh npm_tool.sh"

# <path>: set DEVKIT_AREA (no subshell; devkit_areas calls it once per changed path).
_devkit_area() {
  # The repo's own carve-out, ahead of the table (header: GATE_CODE_PATHS).
  # Split on commas by expansion, not word splitting: a caller's IFS cannot change it.
  local rest=${GATE_CODE_PATHS:-} prefix
  while [ -n "$rest" ]; do
    prefix=${rest%%,*}
    case "$1" in "$prefix"*) DEVKIT_AREA=other; return ;; esac
    case "$rest" in *,*) rest=${rest#*,} ;; *) rest= ;; esac
  done
  case "$1" in
    # Read by docs-check alone (finplat, Orbit, locus, rollcall).
    scripts/ci/docs_oversize.txt) DEVKIT_AREA=docs ;;
    # The metrics ratchet's inputs: both bounds files (under docs/, but a loosened bound must run
    # the METRICS group and face the label, not pass as docs-only; locus #121 slipped through with
    # scorecard.json before it was listed) and the collectors file. Other, which runs every
    # group: the collectors need the tiers' output.
    docs/metrics/ratchet.json|docs/metrics/scorecard.json|scripts/ci/metrics.conf) DEVKIT_AREA=other ;;
    # The rule files of the two structure guards: ci-quick reads them, and so do the metrics
    # job's `layers` and `guards` collectors (a new `known` line moves a ratcheted key). Other,
    # never tooling, so the METRICS group runs and faces the label.
    scripts/ci/layers.conf|scripts/ci/guards.conf) DEVKIT_AREA=other ;;
    # Fixtures under docs/ that tests read (locus): rule-fixtures by pytest and vitest,
    # sync-wire-fixtures by pytest. Above docs/* so they are not mistaken for prose.
    docs/rule-fixtures/*.md|docs/sync-wire-fixtures/*.md) DEVKIT_AREA=docs ;;
    docs/rule-fixtures/*) DEVKIT_AREA=other ;;
    docs/sync-wire-fixtures/*) DEVKIT_AREA=backend ;;
    # Prose at any depth (every repo; frontend/AGENTS.md and devkit/README.md are docs), and
    # Orbit's specs/.
    docs/*|*.md|specs/*) DEVKIT_AREA=docs ;;
    # macOS-only: locus ios/, Orbit OrbitAgent/, instalite's project file. The gate plans
    # run nothing for them; instalite's Swift sources (InstaLite/) stay other.
    ios/*|OrbitAgent/*|*.xcodeproj/*) DEVKIT_AREA=native ;;
    # tooling, each entry and why it cannot reach the app or a job beyond ci-quick:
    #   .devkit-rev            read only by devkit-check (ci-quick)
    #   scripts/ci/hooks.conf  read only by the hooks and hooks_check
    #   .githooks/*            the hooks themselves (templates/githooks copies)
    #   devkit/VENDOR_PATHS    read only by devkit-sync and devkit-check
    #   devkit/lint/*          ruff's shared base: lint runs in ci-quick
    #   devkit/renovate/*      Renovate's preset, read by the Renovate app
    #   devkit/templates/*     copied by devkit-sync/hooks_check/devkit new; Actions callers
    # Not tooling: .gitattributes (eol/text/filter attributes change checked-out bytes, so every
    # job), scripts/ci/gate_plan.sh (policy: other, reviewed by eye).
    .devkit-rev|scripts/ci/hooks.conf|.githooks/*) DEVKIT_AREA=tooling ;;
    devkit/VENDOR_PATHS|devkit/lint/*|devkit/renovate/*|devkit/templates/*) DEVKIT_AREA=tooling ;;
    devkit/bin/*)
      case " $DEVKIT_TOOLING_BIN $DEVKIT_IMAGE_BIN " in
        *[[:space:]]"${1#devkit/bin/}"[[:space:]]*) DEVKIT_AREA=tooling ;;
        *) DEVKIT_AREA=other ;;
      esac
      ;;
    # kitchen server/vue3/: Tandoor's Vue 3 frontend, vendored inside its Django server/.
    # Above server/* so a UI-only change runs the frontend group, not the backend's.
    server/vue3/*) DEVKIT_AREA=frontend ;;
    # finplat, Orbit backend/; locus server/ plus its root-level Python project (tests/,
    # alembic, pyproject.toml, uv.lock); kitchen server/ (Tandoor's Django). rollcall's tests/
    # lands here too, harmlessly: its steps are generic targets, which run for any non-docs area.
    backend/*|server/*|tests/*|alembic/*|alembic.ini|pyproject.toml|uv.lock) DEVKIT_AREA=backend ;;
    # finplat, Orbit frontend/; locus, instalite web/; Orbit's Playwright e2e/.
    frontend/*|web/*|e2e/*) DEVKIT_AREA=frontend ;;
    *) DEVKIT_AREA=other ;;
  esac
}

# <plan>: set GATE_CODE_PATHS from the plan's literal line, without sourcing it ("" when the plan
# or the line is absent). Used by hook_steps.sh and pr_merge.sh.
devkit_load_code_paths() {
  local line re='^GATE_CODE_PATHS=([A-Za-z0-9._,/-]+)[[:space:]]*(#.*)?$'
  GATE_CODE_PATHS=
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ $re ]] || continue
    GATE_CODE_PATHS=${BASH_REMATCH[1]}
    return 0
  done <"$1"
}

devkit_classify_path() { # <path>
  local DEVKIT_AREA
  _devkit_area "$1"
  echo "$DEVKIT_AREA"
}

# <paths, one per line>: DEVKIT_AREAS, the areas present as " a b " in DEVKIT_AREA_ORDER ("" for none).
devkit_areas() {
  local path area seen=' ' DEVKIT_AREA
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    _devkit_area "$path"
    case "$seen" in *" $DEVKIT_AREA "*) ;; *) seen+="$DEVKIT_AREA " ;; esac
  done <<<"$1"
  DEVKIT_AREAS=
  for area in $DEVKIT_AREA_ORDER; do
    case "$seen" in *" $area "*) DEVKIT_AREAS+=" $area" ;; esac
  done
  [ -z "$DEVKIT_AREAS" ] || DEVKIT_AREAS+=" "
}

# <paths, one per line>: what a plan reads. GATE_AREAS is "docs tooling" (space-separated, no
# padding, "" for none); GATE_HAS_<AREA> is 0|1 per area; GATE_ONLY_TOOLING_OR_DOCS is 1 when
# some path is docs or tooling and none is backend, frontend or other (native may ride along).
devkit_gate_areas() {
  local area flag
  devkit_areas "$1"
  GATE_AREAS=${DEVKIT_AREAS# }
  GATE_AREAS=${GATE_AREAS% }
  for area in $DEVKIT_AREA_ORDER; do
    flag=0
    case "$DEVKIT_AREAS" in *" $area "*) flag=1 ;; esac
    case "$area" in
      docs) GATE_HAS_DOCS=$flag ;;
      backend) GATE_HAS_BACKEND=$flag ;;
      frontend) GATE_HAS_FRONTEND=$flag ;;
      native) GATE_HAS_NATIVE=$flag ;;
      tooling) GATE_HAS_TOOLING=$flag ;;
      other) GATE_HAS_OTHER=$flag ;;
    esac
  done
  GATE_ONLY_TOOLING_OR_DOCS=0
  if [ "$GATE_HAS_BACKEND$GATE_HAS_FRONTEND$GATE_HAS_OTHER" = 000 ] \
      && [ "$GATE_HAS_DOCS$GATE_HAS_TOOLING" != 00 ]; then
    GATE_ONLY_TOOLING_OR_DOCS=1
  fi
  export GATE_AREAS GATE_HAS_DOCS GATE_HAS_BACKEND GATE_HAS_FRONTEND GATE_HAS_NATIVE \
    GATE_HAS_TOOLING GATE_HAS_OTHER GATE_ONLY_TOOLING_OR_DOCS
}

# ---- the default plan ------------------------------------------------------------------------
# A repo's gate_plan() declares its jobs per group and calls devkit_default_gate_plan, which runs
# inside the skeleton (job, skip, note, changed, nothing_to_run, $CHANGED, GATE_AREAS above):
#
#   GATE_JOBS_<GROUP>="<name> <make target> [VAR=val...]|<name> <target> ..."   jobs, in order
#   GATE_AREAS_<GROUP>="<areas>"   which areas run the group; set (even to "") to override the
#                                  default below. Words are split on spaces: no spaces in a val.
#                                  Not for IMAGE or E2E (DEVKIT_RETIRED_PLAN_VARS): every app path
#                                  runs them.
#   GATE_IMAGE_PATHS=<ERE>         paths that also run the image group (anchor it)
#   GATE_IMAGE_EXCLUDE_PATHS=<ERE> app paths the build copies but no stage reads (a lint config);
#                                  they do not run the group. Not for what the root .dockerignore
#                                  excludes: the gate reads that file itself (_dockerignore.py),
#                                  and devkit-check warns on an alternative it already covers
#   GATE_JOBS_CLOCK=<jobs>         optional, same shape: pytest/vitest tiers to rerun with the clock
#                                  shifted, each once per GATE_CLOCK_SHIFTS offset as the job
#                                  <name>-<offset> with DEVKIT_CLOCK_SHIFT=<offset> appended
#                                  (bin/tier_guard.sh "Clock shift"; exceptions in
#                                  scripts/ci/clock_shift.conf)
#   GATE_CLOCK_SHIFTS="<n>d ..."   the offsets, whole days ahead; unset or empty: "30d 365d"
#   gate_plan_extra()              optional; called after the groups above, for the repo's own
#                                  rules (devkit_group_ran <group> says whether a group ran)
#
#   group     default areas                 notes
#   QUICK     backend frontend tooling other  required; must include docs-check (every ci-quick does)
#   DOCS      docs tooling other              required; skipped when QUICK ran, which covers it
#   CLOCK     backend frontend other          optional; after QUICK, before BACKEND. Frontend
#                                             too: its vitest tiers are frontend paths, and a
#                                             default that skipped them never shifted a UI-only
#                                             change (kitchen #10 Codex). Order is
#                                             not what keeps METRICS on the real-clock run:
#                                             tier_guard.sh puts back every metrics.conf input
#                                             a shifted run wrote ("Clock shift"), so a unit
#                                             tier in QUICK (rollcall #81) is safe too
#   BACKEND   backend other
#   FRONTEND  frontend other
#   IMAGE     backend frontend other          fixed; minus .dockerignore and GATE_IMAGE_EXCLUDE_PATHS, plus
#                                             GATE_IMAGE_PATHS and the DEVKIT_IMAGE_BIN scripts
#   E2E       backend frontend other          fixed
#   METRICS   backend frontend other, plus    optional; always last (after gate_plan_extra), so
#             every area a metrics.conf       (one source of truth: kitchen's `dup backend,native`
#             collector names but tooling     reads ios/, so an ios/-only change runs it; a
#                                             tooling collector widens nothing, as in
#                                             metrics_collect.sh)
#                                             its ci-metrics merges every earlier job's gate.*
#                                             seconds and the tier-*.json the tiers wrote, and
#                                             metrics_collect.sh reads gate.json for its
#                                             `job:<name>` collectors. Not tooling: devkit's
#                                             collectors and ratchet are other (below), so a
#                                             tooling-only diff cannot move a metric. With
#                                             the PR labelled metrics-rebaseline (pr_has_label,
#                                             fail-closed: no gh answer means no label) each
#                                             job gets METRICS_REBASELINE=1 appended, which
#                                             metrics_collect.sh turns into --rebaseline-ok.
#
# So docs-only runs DOCS; tooling(+docs)-only runs QUICK, plus IMAGE when boot_image.sh or
# contract_probe.sh changed; native-only (or an empty diff) is nothing_to_run unless a group
# runs for native (a GATE_AREAS_<GROUP> naming it, or a native metrics collector); backend and
# frontend run their own group, IMAGE and E2E; any other path runs every group. A group not
# run prints one SKIPPED line per job, naming the areas changed.

# Plan variables the default plan refuses (exit 2). IMAGE and E2E run for every app path: a
# plan that narrowed them to "image inputs only" let closet #406 merge src/ changes no image
# build or smoke had booted (GATE_AREAS_IMAGE="", copied from the devkit new scaffolds), and
# Orbit and locus skipped their image (Orbit's Playwright suite with it) on every backend/ and
# server/ change. devkit-check (ci-quick, the merged tree's copy) fails a plan that still sets
# one, so the sync PR that retires it fails, not the next PR's gate (which sources main's copy
# of this file).
DEVKIT_RETIRED_PLAN_VARS="GATE_AREAS_IMAGE GATE_AREAS_E2E"
DEVKIT_RETIRED_PLAN_ADVICE="IMAGE and E2E run for every backend, frontend or other path; delete it: the gate reads .dockerignore, and GATE_IMAGE_EXCLUDE_PATHS lists paths the build copies but never reads"

devkit_group_ran() { # <group>, lowercase
  case "${DEVKIT_GATE_RAN:-}" in *" $1 "*) return 0 ;; esac
  return 1
}

devkit_default_gate_plan() {
  if [ -z "${GATE_JOBS_QUICK:-}" ] || [ -z "${GATE_JOBS_DOCS:-}" ]; then
    echo "devkit_default_gate_plan: the plan must declare GATE_JOBS_QUICK and GATE_JOBS_DOCS" >&2
    exit 2
  fi
  local retired
  for retired in $DEVKIT_RETIRED_PLAN_VARS; do
    if declare -p "$retired" >/dev/null 2>&1; then
      echo "devkit_default_gate_plan: the plan sets $retired; $DEVKIT_RETIRED_PLAN_ADVICE" >&2
      exit 2
    fi
  done
  _devkit_clock_jobs
  _devkit_metrics_areas
  [ -n "$GATE_AREAS" ] || nothing_to_run "No changed paths"
  [ "$GATE_AREAS" != native ] || _devkit_native_runs \
    || nothing_to_run "Only native paths changed (ios/, OrbitAgent/, *.xcodeproj/); build and test them on the Mac"
  DEVKIT_GATE_RAN=' '
  _devkit_group QUICK "$(_devkit_quick_jobs)"
  if devkit_group_ran quick; then
    _devkit_skip_jobs "$GATE_JOBS_DOCS" "covered by the quick group; ci-quick runs docs-check"
  else
    _devkit_group DOCS
  fi
  _devkit_group CLOCK "$DEVKIT_CLOCK_JOBS"
  _devkit_group BACKEND
  _devkit_group FRONTEND
  _devkit_group IMAGE
  _devkit_group E2E
  if declare -F gate_plan_extra >/dev/null; then gate_plan_extra; fi
  _devkit_metrics_group
}

# The QUICK jobs, with MIGRATION_EDIT_OK=1 appended under the `migration-contract` label
# (pr_has_label, fail-closed; read only when the group will run), which bin/migration_check.py
# reads as "shipped-migration edits are deliberate in this PR" (data.md 12). Same shape as the
# metrics-rebaseline label below.
_devkit_quick_jobs() {
  local jobs=${GATE_JOBS_QUICK:-}
  if [ -n "$jobs" ] && _devkit_group_runs QUICK \
      && declare -F pr_has_label >/dev/null && pr_has_label migration-contract; then
    jobs=$(sed -e 's/|/ MIGRATION_EDIT_OK=1|/g' -e 's/$/ MIGRATION_EDIT_OK=1/' <<<"$jobs")
  fi
  printf '%s' "$jobs"
}

# The METRICS group (header table). The label is read only when the group will run: a
# docs-only PR asks gh nothing. pr_has_label is the skeleton's (local_gate.sh); a harness that
# runs a plan without it (tests/new_contract.bats) gets no label, the fail-closed answer.
_devkit_metrics_group() {
  local jobs=${GATE_JOBS_METRICS:-}
  [ -n "$jobs" ] || return 0
  if _devkit_group_runs METRICS && declare -F pr_has_label >/dev/null \
      && pr_has_label metrics-rebaseline; then
    jobs=$(sed -e 's/|/ METRICS_REBASELINE=1|/g' -e 's/$/ METRICS_REBASELINE=1/' <<<"$jobs")
  fi
  _devkit_group METRICS "$jobs"
}

# DEVKIT_METRICS_AREAS: the METRICS group's areas (header table), from the merged tree's
# metrics.conf ($WT, as _devkit_image_areas reads; the repo root without the skeleton). A
# malformed conf is exit 2 here, before any job, as the metrics job would fail on it.
_devkit_metrics_areas() {
  local named area
  named=$(
    # shellcheck disable=SC2329  # metrics_conf_parse calls its caller's die
    die() { echo "devkit_default_gate_plan: $*" >&2; exit 2; }
    metrics_conf_areas "${WT:-.}/scripts/ci/metrics.conf"
  ) || exit 2
  DEVKIT_METRICS_AREAS="backend frontend other"
  for area in $named; do
    case " $DEVKIT_METRICS_AREAS tooling " in *" $area "*) ;; *) DEVKIT_METRICS_AREAS+=" $area" ;; esac
  done
}

# True when a group with jobs runs for a native-only change: QUICK, DOCS, CLOCK, BACKEND or
# FRONTEND through a GATE_AREAS_<GROUP> naming native, or METRICS through a native collector.
# IMAGE and E2E never do (fixed areas).
_devkit_native_runs() {
  local group jobs_var
  for group in QUICK DOCS CLOCK BACKEND FRONTEND METRICS; do
    jobs_var=GATE_JOBS_$group
    [ "$group" != CLOCK ] || jobs_var=DEVKIT_CLOCK_JOBS
    [ -n "${!jobs_var:-}" ] || continue
    ! _devkit_group_runs "$group" || return 0
  done
  return 1
}

# <GROUP>: the areas that run it unless the plan sets GATE_AREAS_<GROUP> (header table).
_devkit_default_areas() {
  case "$1" in
    QUICK) echo "backend frontend tooling other" ;;
    DOCS) echo "docs tooling other" ;;
    BACKEND) echo "backend other" ;;
    FRONTEND) echo "frontend other" ;;
    CLOCK | IMAGE | E2E) echo "backend frontend other" ;;
    METRICS) echo "$DEVKIT_METRICS_AREAS" ;;
  esac
}

# DEVKIT_CLOCK_JOBS: the CLOCK group's jobs (header table), every GATE_JOBS_CLOCK job once per
# offset, in declaration order, then offset order ("" when the plan declares none). Built before
# the first group runs, so a bad offset fails the gate before minutes of jobs; tier_guard checks
# DEVKIT_CLOCK_SHIFT again for a hand run.
_devkit_clock_jobs() {
  local shifts=${GATE_CLOCK_SHIFTS:-30d 365d} shift spec specs words
  DEVKIT_CLOCK_JOBS=
  [ -n "${GATE_JOBS_CLOCK:-}" ] || return 0
  for shift in $shifts; do
    if [[ ! "$shift" =~ ^[1-9][0-9]*d$ ]]; then
      echo "devkit_default_gate_plan: GATE_CLOCK_SHIFTS names '$shift' (whole days ahead, like 30d)" >&2
      exit 2
    fi
  done
  IFS='|' read -r -a specs <<<"$GATE_JOBS_CLOCK"
  for spec in ${specs[@]+"${specs[@]}"}; do
    read -r -a words <<<"$spec"
    if [ "${#words[@]}" -lt 2 ]; then
      echo "devkit_default_gate_plan: bad GATE_JOBS_CLOCK job '$spec' (want '<name> <make target> [VAR=val...]')" >&2
      exit 2
    fi
    for shift in $shifts; do
      DEVKIT_CLOCK_JOBS+="${DEVKIT_CLOCK_JOBS:+|}${words[0]}-$shift ${words[*]:1} DEVKIT_CLOCK_SHIFT=$shift"
    done
  done
}

# <GROUP>: true when one of the group's areas (GATE_AREAS_<GROUP> overrides
# _devkit_default_areas) is in GATE_AREAS; IMAGE counts only paths the image can see (_devkit_image_areas)
# and also runs on its input paths. An unknown area is exit 2.
_devkit_group_runs() {
  local areas_var="GATE_AREAS_$1" areas area run=0 changed_areas=" $GATE_AREAS "
  if declare -p "$areas_var" >/dev/null 2>&1; then areas=${!areas_var}; else areas=$(_devkit_default_areas "$1"); fi
  if [ "$1" = IMAGE ]; then _devkit_image_areas; changed_areas=$DEVKIT_IMAGE_AREAS; fi
  for area in $areas; do
    case " $DEVKIT_AREA_ORDER " in
      *" $area "*) ;;
      *) echo "devkit_default_gate_plan: $areas_var names '$area' (areas: $DEVKIT_AREA_ORDER)" >&2; exit 2 ;;
    esac
    case "$changed_areas" in *" $area "*) run=1 ;; esac
  done
  if [ "$1" = IMAGE ] && [ "$run" = 0 ] && _devkit_image_input_changed; then run=1; fi
  [ "$run" = 1 ]
}

# <GROUP> [jobs]: run the group's jobs (GATE_JOBS_<GROUP> unless given) when one of its areas
# changed, else skip them.
_devkit_group() {
  local group=$1 jobs jobs_var="GATE_JOBS_$1" area list=''
  if [ $# -ge 2 ]; then jobs=$2; else jobs=${!jobs_var:-}; fi
  [ -n "$jobs" ] || return 0
  if _devkit_group_runs "$group"; then
    DEVKIT_GATE_RAN+="$(tr '[:upper:]' '[:lower:]' <<<"$group") "
    _devkit_run_jobs "$jobs"
    return 0
  fi
  if [ "$group" = IMAGE ] && [ "$GATE_HAS_BACKEND$GATE_HAS_FRONTEND$GATE_HAS_OTHER" != 000 ]; then
    _devkit_skip_jobs "$jobs" "every app path changed is outside the image (.dockerignore, GATE_IMAGE_EXCLUDE_PATHS)"
    return 0
  fi
  group=$(tr '[:upper:]' '[:lower:]' <<<"$group")
  for area in $GATE_AREAS; do list+=${list:+, }$area; done
  _devkit_skip_jobs "$jobs" "only $list paths changed; default for the $group group"
}

# DEVKIT_IMAGE_AREAS: the areas of the changed paths the image can see, as " a b " (" " for
# none): those the merged tree's root .dockerignore keeps (every fleet image builds the root
# context; Docker's matcher, not gitignore's), minus GATE_IMAGE_EXCLUDE_PATHS. Until 2026-10-17
# plans hand-copied .dockerignore into the ERE and the two drifted (redlib #23, locus
# #133). $WT is the merged tree; a harness that runs a plan without the skeleton runs it from
# the repo root. A bad ERE is exit 2: grep's status 2 must not read as "all excluded".
_devkit_image_areas() {
  local DEVKIT_AREAS paths rc=0 tree=${WT:-.}
  paths=$("$(dirname "${BASH_SOURCE[0]}")/python.sh" -I "$(dirname "${BASH_SOURCE[0]}")/_dockerignore.py" keep "$tree" <<<"$CHANGED") || {
    echo "devkit_default_gate_plan: cannot match the changed paths against $tree/.dockerignore" >&2
    exit 2
  }
  if [ -n "${GATE_IMAGE_EXCLUDE_PATHS:-}" ]; then
    paths=$(grep -vE "$GATE_IMAGE_EXCLUDE_PATHS" <<<"$paths") || rc=$?
    if [ "$rc" -gt 1 ]; then
      echo "devkit_default_gate_plan: GATE_IMAGE_EXCLUDE_PATHS is not a valid ERE: $GATE_IMAGE_EXCLUDE_PATHS" >&2
      exit 2
    fi
  fi
  devkit_areas "$paths"
  DEVKIT_IMAGE_AREAS=" ${DEVKIT_AREAS:- } "
}

_devkit_image_input_changed() {
  local path
  if [ -n "${GATE_IMAGE_PATHS:-}" ] && grep -qE "$GATE_IMAGE_PATHS" <<<"$CHANGED"; then return 0; fi
  while IFS= read -r path; do
    case "$path" in
      devkit/bin/*)
        case " $DEVKIT_IMAGE_BIN " in *" ${path#devkit/bin/} "*) return 0 ;; esac
        ;;
    esac
  done <<<"$CHANGED"
  return 1
}

# <specs>: `job` each "<name> <target> [VAR=val...]", split on | then spaces. read -a does no
# pathname expansion, so a val holding * stays literal.
_devkit_run_jobs() {
  local spec words specs
  IFS='|' read -r -a specs <<<"$1"
  for spec in ${specs[@]+"${specs[@]}"}; do
    read -r -a words <<<"$spec"
    if [ "${#words[@]}" -lt 2 ]; then
      echo "devkit_default_gate_plan: bad job '$spec' (want '<name> <make target> [VAR=val...]')" >&2
      exit 2
    fi
    job "${words[@]}"
  done
}

_devkit_skip_jobs() { # <specs> <reason>
  local spec specs
  IFS='|' read -r -a specs <<<"$1"
  for spec in ${specs[@]+"${specs[@]}"}; do
    spec=${spec#"${spec%%[![:space:]]*}"}
    [ -z "$spec" ] || skip "${spec%% *}" "$2"
  done
}
