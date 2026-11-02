#!/usr/bin/env bash
# Schedule (or remove) the Mac's proof of main for the Apple apps (bin/apple_check.sh):
# fills devkit main's templates/launchd/com.agandhi4.devkit.apple-check.plist and bootstraps it as
# a LaunchAgent that runs main's copy (bin/_launchd_job_lib.sh), never this checkout's.
#
# Usage: bin/install_apple_check.sh [<root>]       install, or replace the installed job; <root>
#                                                  holds the checkouts (default ~/projects/solo)
#        bin/install_apple_check.sh --uninstall    boot it out and delete its plist
# check_tree.sh runs each repo's plan as a gate would, so devkit's python3 and uv lead the plist's
# PATH, resolved here (install_dependency_merge.sh's reason: launchd's python3 is Xcode's 3.9).
# Exit 0 done, 1 launchctl or plutil failed, 2 usage, a bad path or devkit's main unreadable.
set -uo pipefail

readonly LABEL=com.agandhi4.devkit.apple-check
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
# shellcheck source=bin/_toolchain_lib.sh  # devkit_toolchain_bin
. "$HERE/_toolchain_lib.sh"
# shellcheck source=bin/_vendor_paths.sh  # DEVKIT_URL, fetch_devkit_main
. "$HERE/_vendor_paths.sh"
# shellcheck source=bin/_launchd_job_lib.sh
. "$HERE/_launchd_job_lib.sh"
DEVKIT=$(cd "$HERE/.." && pwd -P) || exit 2

usage() { echo "usage: install_apple_check.sh [<root>] | --uninstall"; }
die() { echo "install_apple_check: $*" >&2; exit 2; }

install() {
  local root
  root=$(cd "${1:-$HOME/projects/solo}" 2>/dev/null && pwd -P) || die "${1:-$HOME/projects/solo} is not a directory"
  [[ "$root" =~ $LAUNCHD_SAFE_PATH ]] || die "$root is not a plain path"
  devkit_toolchain_bin || die "$DEVKIT_PYTHON_ERROR"
  [[ "$DEVKIT_TOOLCHAIN_BIN" =~ $LAUNCHD_SAFE_PATH ]] || die "the toolchain directory $DEVKIT_TOOLCHAIN_BIN is not a plain path"
  launchd_job_stage "$LABEL" apple-check
  launchd_job_fill "$JOB_TEMPLATE" "$JOB_DIR/filled.plist" \
    -e "s|__TOOLCHAIN_BIN__|$DEVKIT_TOOLCHAIN_BIN|g" -e "s|__ROOT__|$root|g"
  launchd_job_load "$LABEL" "$JOB_DIR/filled.plist"
  echo "install_apple_check: $LABEL runs devkit main's bin/apple_check.sh every 10 min (a check at most once per repo window) over $root (python $DEVKIT_PYTHON_VERSION); its devkit clone $JOB_DIR/devkit; logs ~/Library/Logs/devkit/apple-check.*.log"
}

case "${1:-}" in
  --uninstall) [ $# -eq 1 ] || { usage >&2; exit 2; }; launchd_job_uninstall "$LABEL" ;;
  -h|--help) usage ;;
  -*) usage >&2; exit 2 ;;
  *) [ $# -le 1 ] || { usage >&2; exit 2; }; install "${1:-}" ;;
esac
