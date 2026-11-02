#!/usr/bin/env bash
# Schedule (or remove) the Mac's main check (bin/main_check.sh): fills devkit main's
# templates/launchd/com.agandhi4.devkit.main-check.plist and bootstraps it as a LaunchAgent that
# runs main's copy (bin/_launchd_job_lib.sh), never this checkout's.
#
# Usage: bin/install_main_check.sh                install, or replace the installed job
#        bin/install_main_check.sh --uninstall    boot it out and delete its plist
# The plist names no repo or root: each run scans _checkouts_lib.sh's DEVKIT_CHECKOUT_PARENTS, so
# a repo cloned later is covered with no reinstall. check_tree.sh runs each repo's plan as a gate
# would, so devkit's python3 and uv lead the plist's PATH, resolved here
# (install_dependency_merge.sh's reason: launchd's python3 is Xcode's 3.9).
# Install and uninstall both retire the Apple-only job it replaced (2026-11-02):
# com.agandhi4.devkit.apple-check is booted out and its plist and job dir deleted, so two jobs
# never check the same repo, and its state becomes main_check.sh's (retire_apple_check). Its open
# `main is red on the Mac` issues keep their title, and main_check.sh closes them.
# Exit 0 done, 1 launchctl or plutil failed, 2 usage, a bad path or devkit's main unreadable.
set -uo pipefail

readonly LABEL=com.agandhi4.devkit.main-check
readonly RETIRED_LABEL=com.agandhi4.devkit.apple-check
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
# shellcheck source=bin/_toolchain_lib.sh  # devkit_toolchain_bin
. "$HERE/_toolchain_lib.sh"
# shellcheck source=bin/_vendor_paths.sh  # DEVKIT_URL, fetch_devkit_main
. "$HERE/_vendor_paths.sh"
# shellcheck source=bin/_launchd_job_lib.sh
. "$HERE/_launchd_job_lib.sh"
# shellcheck source=bin/_checkouts_lib.sh  # DEVKIT_CHECKOUT_PARENTS, for the install line
. "$HERE/_checkouts_lib.sh"
DEVKIT=$(cd "$HERE/.." && pwd -P) || exit 2

usage() { echo "usage: install_main_check.sh [--uninstall]"; }
die() { echo "install_main_check: $*" >&2; exit 2; }

# Its verdicts move to main_check.sh's state (devkit #378): a red repo's `<sha> fail <first bad>`
# keeps its first bad commit, so no second main-red issue is filed for a later sha, and the logs
# the open issue names move with it. The .synced marks go, so the first tick posts each judged
# main's main-check status, which apple-check never did (its issue sync reruns as a no-op).
retire_apple_check() {
  local state=${XDG_STATE_HOME:-$HOME/.local/state}
  [ -e "$(_launchd_dest "$RETIRED_LABEL")" ] || [ -d "$state/devkit-apple-check" ] || return 0
  launchd_job_uninstall "$RETIRED_LABEL"
  rm -rf "$state/devkit/jobs/apple-check"
  [ -d "$state/devkit-apple-check" ] || return 0
  if [ -e "$state/devkit-main-check" ]; then
    rm -rf "$state/devkit-apple-check"
  else
    rm -f "$state/devkit-apple-check"/*.synced "$state/devkit-apple-check/lock"
    mv "$state/devkit-apple-check" "$state/devkit-main-check" || exit 2
  fi
}

install() {
  devkit_toolchain_bin || die "$DEVKIT_PYTHON_ERROR"
  [[ "$DEVKIT_TOOLCHAIN_BIN" =~ $LAUNCHD_SAFE_PATH ]] || die "the toolchain directory $DEVKIT_TOOLCHAIN_BIN is not a plain path"
  launchd_job_stage "$LABEL" main-check
  launchd_job_fill "$JOB_TEMPLATE" "$JOB_DIR/filled.plist" -e "s|__TOOLCHAIN_BIN__|$DEVKIT_TOOLCHAIN_BIN|g"
  retire_apple_check
  launchd_job_load "$LABEL" "$JOB_DIR/filled.plist"
  echo "install_main_check: $LABEL runs devkit main's bin/main_check.sh every 10 min (a check at most once per repo window) over every checkout under ${DEVKIT_CHECKOUT_PARENTS[*]} whose plan is not image alone, found at each run (python $DEVKIT_PYTHON_VERSION); its devkit clone $JOB_DIR/devkit; logs ~/Library/Logs/devkit/main-check.*.log"
}

case "${1:-}" in
  --uninstall) [ $# -eq 1 ] || { usage >&2; exit 2; }; retire_apple_check; launchd_job_uninstall "$LABEL" ;;
  -h|--help) usage ;;
  '') install ;;
  *) usage >&2; exit 2 ;;
esac
