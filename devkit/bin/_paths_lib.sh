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
# A devkit/bin file is tooling only when it is listed in DEVKIT_TOOLING_BIN or DEVKIT_IMAGE_BIN;
# DEVKIT_JOB_BIN names the files a gate job executes beyond ci-quick (other, so they run
# everything). An unlisted file is other until someone decides: tests/gate_contract.bats fails
# when a bin/ file is in none of the three lists. devkit/metrics/* (the shared collectors the
# metrics job runs) is other by the default case, like DEVKIT_JOB_BIN.

DEVKIT_AREA_ORDER="docs backend frontend native tooling other"

# Never run from the merged tree by a job: the gate and hook machinery (run from the invoking
# checkout, main's copy), the guards ci-quick runs (devkit-check, docs/toolchain/workflows/
# release/ci-targets checks, own-commit, hooks_check and their libs), and fleet operations run
# from a devkit checkout or after merge (sync, new, monthly audit, ship_tag in publish.yml).
DEVKIT_TOOLING_BIN="local_gate.sh gate.sh remote_gate.sh _gate_env.sh _paths_lib.sh
  hook_steps.sh quiet_run.sh push_ranges.sh hooks_check.sh
  devkit-check.sh _vendor_paths.sh docs_check.sh toolchain_check.sh ci_targets_check.sh
  _makefile_lib.sh workflows_check.sh _workflows_lib.sh release_check.sh _dockerfile_lib.sh
  _gitattributes_lib.sh own_commit_check.py
  devkit-sync.sh devkit-new.sh monthly_audit.sh dead_alert_audit.py ship_tag.sh"
# What the image group exercises (ci-smoke/ci-image boot through them): tooling, but a change
# to one runs the image group even when nothing else would.
DEVKIT_IMAGE_BIN="boot_image.sh contract_probe.sh"
# Executed by unit/db/e2e/build/metrics jobs (tier budgets, throwaway Postgres for db tiers
# and smokes, Playwright browsers, toolchains a Makefile or cargo.sh provisions; layer_check.py,
# a ci-quick guard that is also the metrics job's `layers` collector): other. Only
# a record of the decision; the classification needs no lookup for other.
# shellcheck disable=SC2034  # read by tests/gate_contract.bats (every bin/ file listed once)
DEVKIT_JOB_BIN="tier_guard.sh throwaway_pg.sh playwright_browsers.sh node_toolchain.sh
  rust_toolchain.sh toolchain_path.sh metrics_ratchet.py metrics_collect.sh layer_check.py"

# <path>: set DEVKIT_AREA (no subshell; devkit_areas calls it once per changed path).
_devkit_area() {
  case "$1" in
    # Read by docs-check alone (finplat, Orbit, locus, rollcall).
    scripts/ci/docs_oversize.txt) DEVKIT_AREA=docs ;;
    # The metrics ratchet's inputs: the bounds (under docs/, but a loosened bound must run the
    # METRICS group and face the label, not pass as docs-only) and the collectors file. Other,
    # which runs every group: the collectors need the tiers' output.
    docs/metrics/ratchet.json|scripts/ci/metrics.conf) DEVKIT_AREA=other ;;
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
    # finplat, Orbit backend/; locus server/ plus its root-level Python project (tests/,
    # alembic, pyproject.toml, uv.lock). rollcall's tests/ lands here too, harmlessly: its
    # steps are generic targets, which run for any non-docs area.
    backend/*|server/*|tests/*|alembic/*|alembic.ini|pyproject.toml|uv.lock) DEVKIT_AREA=backend ;;
    # finplat, Orbit frontend/; locus, instalite web/; Orbit's Playwright e2e/.
    frontend/*|web/*|e2e/*) DEVKIT_AREA=frontend ;;
    *) DEVKIT_AREA=other ;;
  esac
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
#   GATE_IMAGE_PATHS=<ERE>         paths that also run the image group (anchor it)
#   gate_plan_extra()              optional; called after the groups above, for the repo's own
#                                  rules (devkit_group_ran <group> says whether a group ran)
#
#   group     default areas                 notes
#   QUICK     backend frontend tooling other  required; must include docs-check (every ci-quick does)
#   DOCS      docs tooling other              required; skipped when QUICK ran, which covers it
#   BACKEND   backend other
#   FRONTEND  frontend other
#   IMAGE     other                           + GATE_IMAGE_PATHS + the DEVKIT_IMAGE_BIN scripts
#   E2E       backend frontend other
#   METRICS   backend frontend other          optional; always last (after gate_plan_extra), so
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
# contract_probe.sh changed; native-only (or an empty diff) is nothing_to_run; any other path
# runs every group. A group not run prints
# one SKIPPED line per job, naming the areas changed.

devkit_group_ran() { # <group>, lowercase
  case "${DEVKIT_GATE_RAN:-}" in *" $1 "*) return 0 ;; esac
  return 1
}

devkit_default_gate_plan() {
  if [ -z "${GATE_JOBS_QUICK:-}" ] || [ -z "${GATE_JOBS_DOCS:-}" ]; then
    echo "devkit_default_gate_plan: the plan must declare GATE_JOBS_QUICK and GATE_JOBS_DOCS" >&2
    exit 2
  fi
  [ -n "$GATE_AREAS" ] || nothing_to_run "No changed paths"
  [ "$GATE_AREAS" != native ] \
    || nothing_to_run "Only native paths changed (ios/, OrbitAgent/, *.xcodeproj/); build and test them on the Mac"
  DEVKIT_GATE_RAN=' '
  _devkit_group QUICK "backend frontend tooling other"
  if devkit_group_ran quick; then
    _devkit_skip_jobs "$GATE_JOBS_DOCS" "covered by the quick group; ci-quick runs docs-check"
  else
    _devkit_group DOCS "docs tooling other"
  fi
  _devkit_group BACKEND "backend other"
  _devkit_group FRONTEND "frontend other"
  _devkit_group IMAGE "other"
  _devkit_group E2E "backend frontend other"
  if declare -F gate_plan_extra >/dev/null; then gate_plan_extra; fi
  _devkit_metrics_group
}

# The METRICS group (header table). The label is read only when the group will run: a
# docs-only PR asks gh nothing. pr_has_label is the skeleton's (local_gate.sh); a harness that
# runs a plan without it (tests/new_contract.bats) gets no label, the fail-closed answer.
_devkit_metrics_group() {
  local jobs=${GATE_JOBS_METRICS:-} areas="backend frontend other"
  [ -n "$jobs" ] || return 0
  if _devkit_group_runs METRICS "$areas" && declare -F pr_has_label >/dev/null \
      && pr_has_label metrics-rebaseline; then
    jobs=$(sed -e 's/|/ METRICS_REBASELINE=1|/g' -e 's/$/ METRICS_REBASELINE=1/' <<<"$jobs")
  fi
  _devkit_group METRICS "$areas" "$jobs"
}

# <GROUP> <default areas>: true when one of the group's areas (GATE_AREAS_<GROUP> overrides
# the default) is in GATE_AREAS; IMAGE also runs on its input paths. An unknown area is exit 2.
_devkit_group_runs() {
  local areas_var="GATE_AREAS_$1" areas area run=0
  if declare -p "$areas_var" >/dev/null 2>&1; then areas=${!areas_var}; else areas=$2; fi
  for area in $areas; do
    case " $DEVKIT_AREA_ORDER " in
      *" $area "*) ;;
      *) echo "devkit_default_gate_plan: $areas_var names '$area' (areas: $DEVKIT_AREA_ORDER)" >&2; exit 2 ;;
    esac
    case " $GATE_AREAS " in *" $area "*) run=1 ;; esac
  done
  if [ "$1" = IMAGE ] && [ "$run" = 0 ] && _devkit_image_input_changed; then run=1; fi
  [ "$run" = 1 ]
}

# <GROUP> <default areas> [jobs]: run the group's jobs (GATE_JOBS_<GROUP> unless given) when
# one of its areas changed, else skip them.
_devkit_group() {
  local group=$1 jobs jobs_var="GATE_JOBS_$1" area list=''
  if [ $# -ge 3 ]; then jobs=$3; else jobs=${!jobs_var:-}; fi
  [ -n "$jobs" ] || return 0
  if _devkit_group_runs "$group" "$2"; then
    DEVKIT_GATE_RAN+="$(tr '[:upper:]' '[:lower:]' <<<"$group") "
    _devkit_run_jobs "$jobs"
    return 0
  fi
  group=$(tr '[:upper:]' '[:lower:]' <<<"$group")
  for area in $GATE_AREAS; do list+=${list:+, }$area; done
  _devkit_skip_jobs "$jobs" "only $list paths changed; default for the $group group"
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
