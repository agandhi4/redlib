#!/usr/bin/env bash
# Schedule (or remove) the nightly gated dependency merge on this Mac: fills devkit main's
# templates/launchd/com.agandhi4.devkit.dependency-merge.plist and bootstraps it as a LaunchAgent.
#
# Usage: bin/install_dependency_merge.sh <repo-root>...   install, or replace the installed job
#        bin/install_dependency_merge.sh --uninstall      boot it out and delete its plist
# Idempotent: an installed job is booted out before the new plist is bootstrapped, so a rerun
# with another repo list replaces the old one. The plist runs devkit main's copy of the job, not
# this checkout's (bin/_launchd_job_lib.sh), so any checkout or worktree installs the same job.
# The toolchain is resolved here, into the plist, not left to launchd's PATH: devkit's python3
# and uv (bin/_toolchain_lib.sh) go first on its PATH, and no python3 >= 3.11 refuses the install
# (2026-10-22: the first run found only Xcode's 3.9 and errored every PR). Node needs nothing
# here: each gate provisions its repo's .nvmrc pin (node_toolchain.sh) on any PATH.
# Repo roots' origin/main must hold scripts/ci/gate_plan.sh with a literal GATE_SLUG and
# GATE_STATE_NAME (gate_plan_main, the job's own check), and every path must be plain
# ([A-Za-z0-9._/~+@-]): it goes into XML and a sed replacement unescaped.
# Exit 0 done, 1 launchctl or plutil failed, 2 usage, a bad path or devkit's main unreadable.
set -uo pipefail

readonly LABEL=com.agandhi4.devkit.dependency-merge
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_toolchain_lib.sh
. "$HERE/_toolchain_lib.sh"
# shellcheck source=bin/_vendor_paths.sh  # DEVKIT_URL, fetch_devkit_main
. "$HERE/_vendor_paths.sh"
# shellcheck source=bin/_launchd_job_lib.sh
. "$HERE/_launchd_job_lib.sh"
DEVKIT=$(cd "$HERE/.." && pwd -P) || exit 2

usage() { echo "usage: install_dependency_merge.sh <repo-root>... | --uninstall"; }
die() { echo "install_dependency_merge: $*" >&2; exit 2; }

# collect_repos <repo-root>...: set ROOTS to their absolute paths, or die naming the bad one.
collect_repos() {
  local repo root
  ROOTS=()
  for repo in "$@"; do
    root=$(cd "$repo" 2>/dev/null && pwd -P) || die "$repo is not a directory"
    [[ "$root" =~ $LAUNCHD_SAFE_PATH ]] || die "$root is not a plain path"
    # The job's own check, on origin/main: a repo it would refuse is an error every night.
    gate_plan_main "$root" || die "$root: $PLAN_ERROR"
    ROOTS+=("$root")
  done
}

# resolve_toolchain: TOOLCHAIN_BIN, the directory the plist's PATH leads with (python3, and uv
# when this box has one: each gate's preflight requires it where a repo declares it), or die.
resolve_toolchain() {
  devkit_toolchain_bin || die "$DEVKIT_PYTHON_ERROR"
  [[ "$DEVKIT_TOOLCHAIN_BIN" =~ $LAUNCHD_SAFE_PATH ]] || die "the toolchain directory $DEVKIT_TOOLCHAIN_BIN is not a plain path"
  TOOLCHAIN_BIN=$DEVKIT_TOOLCHAIN_BIN
}

install() {
  local plist lines
  launchd_job_stage "$LABEL" dependency-merge
  plist=$JOB_DIR/filled.plist
  lines=$(printf '    <string>%s</string>\n' "${ROOTS[@]}")
  REPO_LINES=$lines awk '/<string>__REPOS__<\/string>/ { print ENVIRON["REPO_LINES"]; next } { print }' \
    "$JOB_TEMPLATE" >"$plist.repos" || exit 2
  launchd_job_fill "$plist.repos" "$plist" -e "s|__TOOLCHAIN_BIN__|$TOOLCHAIN_BIN|g"
  launchd_job_load "$LABEL" "$plist"
  echo "install_dependency_merge: $LABEL runs devkit main's bin/dependency_merge.sh nightly at 02:30 over ${ROOTS[*]} (python $DEVKIT_PYTHON_VERSION, $DEVKIT_PYTHON)"
  [ -z "$DEVKIT_TOOLCHAIN_MISSING" ] \
    || echo "install_dependency_merge: WARNING: $DEVKIT_TOOLCHAIN_ERROR; a repo declaring it (a uv.lock) refuses to gate" >&2
  echo "install_dependency_merge: plist ~/Library/LaunchAgents/$LABEL.plist; its devkit clone $JOB_DIR/devkit; logs ~/Library/Logs/devkit/dependency-merge.*.log; pause: touch ~/.config/devkit/dependency-merge.off"
}

case "${1:-}" in
  '') usage >&2; exit 2 ;;
  -h|--help) usage ;;
  --uninstall) [ $# -eq 1 ] || { usage >&2; exit 2; }; launchd_job_uninstall "$LABEL" ;;
  -*) usage >&2; exit 2 ;;
  *) resolve_toolchain; collect_repos "$@"; install ;;
esac
