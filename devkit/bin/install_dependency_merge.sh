#!/usr/bin/env bash
# Schedule (or remove) the nightly gated dependency merge on this Mac: fills
# templates/launchd/com.agandhi4.devkit.dependency-merge.plist and bootstraps it as a LaunchAgent.
#
# Usage: bin/install_dependency_merge.sh <repo-root>...   install, or replace the installed job
#        bin/install_dependency_merge.sh --uninstall      boot it out and delete its plist
# Idempotent: an installed job is booted out before the new plist is bootstrapped, so a rerun
# with another repo list replaces the old one.
# Refuses a devkit linked worktree: the plist names this checkout's absolute path, and a lane's
# worktree is deleted when its lane ends, which would leave launchd running a missing script.
# The toolchain is resolved here, into the plist, not left to launchd's PATH: devkit's python3
# and uv (bin/_toolchain_lib.sh) go first on its PATH, and no python3 >= 3.11 refuses the install
# (2026-10-22: the first run found only Xcode's 3.9 and errored every PR). Node needs nothing
# here: each gate provisions its repo's .nvmrc pin (node_toolchain.sh) on any PATH.
# Repo roots' origin/main must hold scripts/ci/gate_plan.sh with a literal GATE_SLUG and
# GATE_STATE_NAME (gate_plan_main, the job's own check), and every path must be plain
# ([A-Za-z0-9._/~+@-]): it goes into XML and a sed replacement unescaped.
# Exit 0 done, 1 launchctl or plutil failed, 2 usage or a bad path.
set -uo pipefail

readonly LABEL=com.agandhi4.devkit.dependency-merge
readonly SAFE_PATH='^/[A-Za-z0-9._/~+@-]+$'
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"
# shellcheck source=bin/_toolchain_lib.sh
. "$HERE/_toolchain_lib.sh"
DEVKIT=$(cd "$HERE/.." && pwd -P) || exit 2
TEMPLATE=$DEVKIT/templates/launchd/$LABEL.plist
DEST=$HOME/Library/LaunchAgents/$LABEL.plist
DOMAIN=gui/$(id -u)

usage() { echo "usage: install_dependency_merge.sh <repo-root>... | --uninstall"; }
die() { echo "install_dependency_merge: $*" >&2; exit 2; }

boot_out() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
  launchctl bootout "$DOMAIN/$LABEL" || { echo "install_dependency_merge: launchctl bootout $DOMAIN/$LABEL failed (above)" >&2; exit 1; }
}

# bootstrap: load DEST, retrying for a few seconds. Right after a bootout launchd may still be
# tearing the old job down and refuses with error 5 (Input/output error), which a rerun fixes.
bootstrap() {
  local try
  for try in 1 2 3 4 5; do
    launchctl bootstrap "$DOMAIN" "$DEST" 2>/dev/null && return 0
    sleep "${INSTALL_RETRY_SECONDS:-1}"
  done
  launchctl bootstrap "$DOMAIN" "$DEST" \
    || { echo "install_dependency_merge: launchctl bootstrap $DOMAIN $DEST failed $((try + 1)) times (above)" >&2; exit 1; }
}

uninstall() {
  boot_out
  rm -f "$DEST"
  echo "install_dependency_merge: removed $LABEL ($DEST)"
}

# check_devkit: refuse a linked worktree (header) and paths the plist cannot carry unescaped.
check_devkit() {
  local common
  common=$(cd "$DEVKIT" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || die "$DEVKIT is not a git checkout"
  [ "$common" = "$(cd "$(git -C "$DEVKIT" rev-parse --absolute-git-dir)" && pwd -P)" ] \
    || die "$DEVKIT is a linked worktree; run this from the devkit main checkout ($(dirname "$common"))"
  [[ "$DEVKIT" =~ $SAFE_PATH ]] && [[ "$HOME" =~ $SAFE_PATH ]] || die "devkit ($DEVKIT) and HOME ($HOME) must be plain paths"
}

# collect_repos <repo-root>...: set ROOTS to their absolute paths, or die naming the bad one.
collect_repos() {
  local repo root
  ROOTS=()
  for repo in "$@"; do
    root=$(cd "$repo" 2>/dev/null && pwd -P) || die "$repo is not a directory"
    [[ "$root" =~ $SAFE_PATH ]] || die "$root is not a plain path"
    # The job's own check, on origin/main: a repo it would refuse is an error every night.
    gate_plan_main "$root" || die "$root: $PLAN_ERROR"
    ROOTS+=("$root")
  done
}

# resolve_toolchain: TOOLCHAIN_BIN, the directory the plist's PATH leads with (python3, and uv
# when this box has one: each gate's preflight requires it where a repo declares it), or die.
resolve_toolchain() {
  devkit_toolchain_bin || die "$DEVKIT_PYTHON_ERROR"
  [[ "$DEVKIT_TOOLCHAIN_BIN" =~ $SAFE_PATH ]] || die "the toolchain directory $DEVKIT_TOOLCHAIN_BIN is not a plain path"
  TOOLCHAIN_BIN=$DEVKIT_TOOLCHAIN_BIN
}

# fill_plist <out>: the template with this checkout, HOME, TOOLCHAIN_BIN and one <string> per ROOTS
# entry.
fill_plist() {
  local lines
  lines=$(printf '    <string>%s</string>\n' "${ROOTS[@]}")
  REPO_LINES=$lines awk '/<string>__REPOS__<\/string>/ { print ENVIRON["REPO_LINES"]; next } { print }' "$TEMPLATE" \
    | sed -e "s|__DEVKIT__|$DEVKIT|g" -e "s|__HOME__|$HOME|g" -e "s|__TOOLCHAIN_BIN__|$TOOLCHAIN_BIN|g" >"$1"
}

# PLIST_TMP is script-global, not local: the EXIT trap runs after install returns, where a
# local is out of scope and set -u aborted the trap with "tmp: unbound variable" (exit stayed 0).
install() {
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/devkit" || exit 2
  PLIST_TMP=$(mktemp "$DEST.XXXXXX") || exit 2
  trap 'rm -f "$PLIST_TMP"' EXIT
  fill_plist "$PLIST_TMP" || exit 2
  if command -v plutil >/dev/null; then
    plutil -lint -s "$PLIST_TMP" || { echo "install_dependency_merge: the filled plist does not lint (above)" >&2; exit 1; }
  fi
  boot_out
  mv "$PLIST_TMP" "$DEST" || exit 2
  bootstrap
  echo "install_dependency_merge: $LABEL runs nightly at 02:30 over ${ROOTS[*]} (python $DEVKIT_PYTHON_VERSION, $DEVKIT_PYTHON)"
  [ -z "$DEVKIT_TOOLCHAIN_MISSING" ] \
    || echo "install_dependency_merge: WARNING: $DEVKIT_TOOLCHAIN_ERROR; a repo declaring it (a uv.lock) refuses to gate" >&2
  echo "install_dependency_merge: plist $DEST; logs ~/Library/Logs/devkit/dependency-merge.*.log; pause: touch ~/.config/devkit/dependency-merge.off"
}

case "${1:-}" in
  '') usage >&2; exit 2 ;;
  -h|--help) usage ;;
  --uninstall) [ $# -eq 1 ] || { usage >&2; exit 2; }; uninstall ;;
  -*) usage >&2; exit 2 ;;
  *) check_devkit; resolve_toolchain; collect_repos "$@"; install ;;
esac
