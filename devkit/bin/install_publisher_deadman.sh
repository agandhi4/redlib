#!/usr/bin/env bash
# Schedule (or remove) the publisher dead-man switch on this Mac: fills devkit main's
# templates/launchd/com.kashhq.devkit.publisher-deadman.plist and bootstraps it as a LaunchAgent
# that runs main's bin/publisher_deadman.sh (bin/_launchd_job_lib.sh), never this checkout's.
#
# Usage: bin/install_publisher_deadman.sh               install, or replace the installed job
#        bin/install_publisher_deadman.sh --uninstall   boot it out and delete its plist
# Exit 0 done, 1 launchctl or plutil failed, 2 usage, a bad path or devkit's main unreadable.
set -uo pipefail

readonly LABEL=com.kashhq.devkit.publisher-deadman
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
# shellcheck source=bin/_vendor_paths.sh  # DEVKIT_URL, fetch_devkit_main
. "$HERE/_vendor_paths.sh"
# shellcheck source=bin/_launchd_job_lib.sh
. "$HERE/_launchd_job_lib.sh"
DEVKIT=$(cd "$HERE/.." && pwd -P) || exit 2

launchd_job_cli "$LABEL" publisher-deadman "runs devkit main's bin/publisher_deadman.sh hourly (GitHub only, never the publisher host)" "$@"
