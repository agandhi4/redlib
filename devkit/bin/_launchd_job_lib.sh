# shellcheck shell=bash
# Installing devkit's scheduled jobs as LaunchAgents. Sourced by install_dependency_merge.sh,
# install_monthly_audit.sh, install_publisher_deadman.sh and install_main_check.sh, after _vendor_paths.sh (DEVKIT_URL, fetch_devkit_main); defines
# functions and runs nothing. Each failure prints one "<installer>: ..." line and exits: 2 for a
# path, a fetch or a file, 1 for launchctl or plutil.
#
# Every job runs devkit main's copy of itself: its plist starts <job-dir>/launcher.sh (bin/job_launcher.sh),
# which moves the job's own clone to DEVKIT_URL's main and execs the script there. Nothing in a
# plist names this checkout, and what install writes is main's too, never this checkout's branch
# or edits, so an install from a lane's worktree or a branch is the install main would make.
#
#   launchd_job_stage <label> <name>
#       Fetch DEVKIT_URL's main into this checkout (FETCH_HEAD) and write from it JOB_DIR
#       (${XDG_STATE_HOME:-~/.local/state}/devkit/jobs/<name>)/launcher.sh, the _gate_env.sh it
#       sources, and JOB_TEMPLATE, that directory's copy of main's templates/launchd/<label>.plist.
#   launchd_job_fill <in> <out> [<sed arg>...]
#       Write <in> (JOB_TEMPLATE, or a caller's edit of it) to <out> with __HOME__, __JOB_DIR__
#       and __DEVKIT_URL__ filled, then the caller's own sed args (its placeholders).
#   launchd_job_load <label> <plist>
#       Lint <plist>, boot out an installed <label>, move <plist> to ~/Library/LaunchAgents and
#       bootstrap it (retrying launchd's refusal while the old job goes away).
#   launchd_job_uninstall <label>
#       Boot it out and delete its plist. The job's directory stays: its clone is the last good copy.
#   launchd_job_install <label> <name> [<sed arg>...]
#       The three in order: stage <name>, fill its plist (plus the sed args) and load it.
#   launchd_job_cli <label> <name> <what it runs> [<arg>...]
#       The whole command line of an installer with no steps of its own (monthly-audit,
#       publisher-deadman): none installs and prints `<label> <what it runs>; its devkit clone
#       …; logs …`, --uninstall removes, -h prints the usage, anything else is exit 2.

readonly LAUNCHD_SAFE_PATH='^/[A-Za-z0-9._/~+@-]+$'
readonly LAUNCHD_SAFE_URL='^[A-Za-z0-9._/~+@:-]+$'
LAUNCHD_WHO=$(basename "$0" .sh)
LAUNCHD_DOMAIN=gui/$(id -u)

_launchd_die() { echo "$LAUNCHD_WHO: $*" >&2; exit 2; }

launchd_job_stage() {
  local label=$1 main
  JOB_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/devkit/jobs/$2
  # Every value goes into XML and a sed replacement unescaped.
  [[ "$JOB_DIR" =~ $LAUNCHD_SAFE_PATH ]] && [[ "$HOME" =~ $LAUNCHD_SAFE_PATH ]] \
    || _launchd_die "the job directory ($JOB_DIR) and HOME ($HOME) must be plain paths"
  [[ "$DEVKIT_URL" =~ $LAUNCHD_SAFE_URL ]] || _launchd_die "DEVKIT_URL ($DEVKIT_URL) must be a plain URL or path"
  main=$(fetch_devkit_main "$DEVKIT") || _launchd_die "cannot fetch devkit's main from $DEVKIT_URL (git above)"
  mkdir -p "$JOB_DIR" || exit 2
  JOB_TEMPLATE=$JOB_DIR/$label.plist
  if ! git -C "$DEVKIT" show "$main:bin/job_launcher.sh" >"$JOB_DIR/launcher.sh.new" \
    || ! git -C "$DEVKIT" show "$main:bin/_gate_env.sh" >"$JOB_DIR/_gate_env.sh.new" \
    || ! git -C "$DEVKIT" show "$main:templates/launchd/$label.plist" >"$JOB_TEMPLATE"; then
    _launchd_die "devkit's main ${main:0:7} has no bin/job_launcher.sh, bin/_gate_env.sh or templates/launchd/$label.plist"
  fi
  mv "$JOB_DIR/_gate_env.sh.new" "$JOB_DIR/_gate_env.sh" && mv "$JOB_DIR/launcher.sh.new" "$JOB_DIR/launcher.sh" || exit 2
}

launchd_job_fill() {
  local in=$1 out=$2
  shift 2
  sed -e "s|__HOME__|$HOME|g" -e "s|__JOB_DIR__|$JOB_DIR|g" -e "s|__DEVKIT_URL__|$DEVKIT_URL|g" "$@" "$in" >"$out" || exit 2
}

_launchd_dest() { echo "$HOME/Library/LaunchAgents/$1.plist"; }

_launchd_boot_out() {
  launchctl print "$LAUNCHD_DOMAIN/$1" >/dev/null 2>&1 || return 0
  launchctl bootout "$LAUNCHD_DOMAIN/$1" || { echo "$LAUNCHD_WHO: launchctl bootout $LAUNCHD_DOMAIN/$1 failed (above)" >&2; exit 1; }
}

# Right after a bootout launchd may still be tearing the old job down and refuses with error 5
# (Input/output error), which a rerun fixes.
_launchd_bootstrap() {
  local try dest
  dest=$(_launchd_dest "$1")
  for try in 1 2 3 4 5; do
    launchctl bootstrap "$LAUNCHD_DOMAIN" "$dest" 2>/dev/null && return 0
    sleep "${INSTALL_RETRY_SECONDS:-1}"
  done
  launchctl bootstrap "$LAUNCHD_DOMAIN" "$dest" \
    || { echo "$LAUNCHD_WHO: launchctl bootstrap $LAUNCHD_DOMAIN $dest failed $((try + 1)) times (above)" >&2; exit 1; }
}

launchd_job_load() {
  local label=$1 plist=$2
  if command -v plutil >/dev/null; then
    plutil -lint -s "$plist" || { echo "$LAUNCHD_WHO: the filled plist does not lint (above)" >&2; exit 1; }
  fi
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/devkit" || exit 2
  _launchd_boot_out "$label"
  mv "$plist" "$(_launchd_dest "$label")" || exit 2
  _launchd_bootstrap "$label"
}

launchd_job_uninstall() {
  # Uninstalling a job by its current label retires its legacy label too, whichever script
  # asked (install_*.sh each have their own --uninstall; #472).
  [[ "$1" == "$LABEL_PREFIX"* ]] && launchd_job_retire_legacy "${1#"$LABEL_PREFIX"}"
  _launchd_boot_out "$1"
  rm -f "$(_launchd_dest "$1")"
  echo "$LAUNCHD_WHO: removed $1 ($(_launchd_dest "$1"))"
}

# The account was renamed on 2026-11-12 and the labels with it (kashhq): a job still installed
# under the old owner's label is booted out and its plist removed once the new label has loaded
# (as apple-check was retired, #383: a failed load must leave the old job running, not nothing),
# and on --uninstall. The job dir is keyed by name, so its clone and logs carry over.
LABEL_PREFIX=com.kashhq.devkit.
LEGACY_LABEL_PREFIX=com.agandhi4.devkit.  # retired name
launchd_job_retire_legacy() { # <name>
  [ -e "$(_launchd_dest "$LEGACY_LABEL_PREFIX$1")" ] || return 0
  launchd_job_uninstall "$LEGACY_LABEL_PREFIX$1"
}

launchd_job_install() {
  local label=$1 name=$2
  shift 2
  launchd_job_stage "$label" "$name"
  launchd_job_fill "$JOB_TEMPLATE" "$JOB_DIR/filled.plist" "$@"
  launchd_job_load "$label" "$JOB_DIR/filled.plist" || return
  launchd_job_retire_legacy "$name"
}

launchd_job_cli() {
  local label=$1 name=$2 what=$3 usage="usage: $LAUNCHD_WHO.sh [--uninstall]"
  shift 3
  case "${1:-}" in
    '')
      launchd_job_install "$label" "$name"
      echo "$LAUNCHD_WHO: $label $what; its devkit clone $JOB_DIR/devkit; logs ~/Library/Logs/devkit/$name.*.log"
      ;;
    --uninstall) [ $# -eq 1 ] || { echo "$usage" >&2; exit 2; }; launchd_job_uninstall "$label" ;;
    -h|--help) echo "$usage" ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
}
