#!/usr/bin/env bash
# Schedule (or remove) the publisher dead-man switch on this Mac: fills devkit main's
# templates/launchd/com.agandhi4.devkit.publisher-deadman.plist and bootstraps it as a LaunchAgent
# that runs main's bin/publisher_deadman.sh (bin/_launchd_job_lib.sh), never this checkout's.
#
# Usage: bin/install_publisher_deadman.sh               install, or replace the installed job
#        bin/install_publisher_deadman.sh --uninstall   boot it out and delete its plist
# Exit 0 done, 1 launchctl or plutil failed, 2 usage, a bad path or devkit's main unreadable.
set -uo pipefail

readonly LABEL=com.agandhi4.devkit.publisher-deadman
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
# shellcheck source=bin/_vendor_paths.sh  # DEVKIT_URL, fetch_devkit_main
. "$HERE/_vendor_paths.sh"
# shellcheck source=bin/_launchd_job_lib.sh
. "$HERE/_launchd_job_lib.sh"
DEVKIT=$(cd "$HERE/.." && pwd -P) || exit 2

install() {
  launchd_job_stage "$LABEL" publisher-deadman
  launchd_job_fill "$JOB_TEMPLATE" "$JOB_DIR/filled.plist"
  launchd_job_load "$LABEL" "$JOB_DIR/filled.plist"
  echo "install_publisher_deadman: $LABEL runs devkit main's bin/publisher_deadman.sh hourly (GitHub only, never linux-box); its devkit clone $JOB_DIR/devkit; logs ~/Library/Logs/devkit/publisher-deadman.*.log"
}

case "${1:-}" in
  '') install ;;
  --uninstall) [ $# -eq 1 ] || exit 2; launchd_job_uninstall "$LABEL" ;;
  -h|--help) echo "usage: install_publisher_deadman.sh [--uninstall]" ;;
  *) echo "usage: install_publisher_deadman.sh [--uninstall]" >&2; exit 2 ;;
esac
