# shellcheck shell=bash
# How often main is checked, per repo, and in which minute. Sourced; defines functions and runs
# nothing. Callers source _load_lib.sh (devkit_epoch) and _gate_env.sh (gate_plan_literal) first.
# Used by: publish.sh (linux-box's check_tree runs) and apple_check.sh (the Mac's, its own stamp
# per repo); every scheduled check of main goes through it.
#
# Why (owner 2026-11-02): linux-box's publisher ticks every 5 min for every repo at once, and each
# tick after a merge started a whole check_tree run, so fast merges meant a full check per merge
# with every repo's starting together. Now a repo's checks start at most once per window of
# MAIN_CHECK_MINUTES (a literal plan line, default 180: owner, 3 h), and its windows open at its
# own minute, cksum(<owner/repo>) mod MAIN_CHECK_MINUTES (0-179 by default), counted from the epoch
# in UTC: the repos spread over the whole window with no coordination, and a repo has the same
# minute on every host. Shipping sooner is the owner's publish.sh --recheck or --ungated.
#
#   cadence_minutes <plan>        sets CADENCE_MINUTES to the plan's MAIN_CHECK_MINUTES, else 180;
#                                 1 with CADENCE_ERROR set when it is not a whole number from 5 to
#                                 1440 (variables, not output: call it outside $(...))
#   cadence_minute <slug> <minutes>
#                                 prints the slug's offset into each window, in minutes
#   cadence_due <slug> <minutes> <stamp>
#                                 0 when no check has started since the current window opened
#                                 (<stamp> missing, or naming an earlier second), else 1; sets
#                                 CADENCE_OPEN and CADENCE_NEXT (epoch seconds: this window's
#                                 opening and the next's) and CADENCE_MINUTE either way
#   cadence_mark <stamp>          records now as a check's start (one line, epoch seconds)
#   cadence_utc <epoch>           prints `HH:MMZ`, by arithmetic, so a test's clock formats too
# The clock is devkit_epoch (DEVKIT_CLOCK_CMD in tests, tests/clock_helpers.bash). The stamp holds
# the second, not the file's mtime, so a test steps the window by moving the clock alone.

readonly CADENCE_DEFAULT_MINUTES=180

# shellcheck disable=SC2034  # CADENCE_MINUTES and CADENCE_ERROR are its output, read by its callers
cadence_minutes() { # <plan>
  local m
  m=$(gate_plan_literal "$1" MAIN_CHECK_MINUTES)
  m=${m:-$CADENCE_DEFAULT_MINUTES}
  if [[ "$m" =~ ^[1-9][0-9]{0,3}$ ]] && [ "$m" -ge 5 ] && [ "$m" -le 1440 ]; then
    CADENCE_MINUTES=$m
    return 0
  fi
  CADENCE_ERROR="$1: MAIN_CHECK_MINUTES must be a whole number of minutes, 5 to 1440 (got '$m')"
  return 1
}

cadence_minute() { # <slug> <minutes>
  local sum
  sum=$(printf '%s' "$1" | cksum)
  echo $(( ${sum%% *} % $2 ))
}

# shellcheck disable=SC2034  # CADENCE_NEXT is this function's output, read by its callers
cadence_due() { # <slug> <minutes> <stamp>
  local now window started=''
  now=$(devkit_epoch)
  window=$(( $2 * 60 ))
  CADENCE_MINUTE=$(cadence_minute "$1" "$2")
  CADENCE_OPEN=$(( now - (now - CADENCE_MINUTE * 60) % window ))
  CADENCE_NEXT=$(( CADENCE_OPEN + window ))
  [ ! -f "$3" ] || started=$(head -n 1 "$3")
  # An unreadable stamp is no start: a check too many beats a repo never checked again.
  [[ "$started" =~ ^[0-9]+$ ]] || return 0
  [ "$started" -lt "$CADENCE_OPEN" ]
}

cadence_mark() { # <stamp>
  devkit_epoch >"$1"
}

cadence_utc() { # <epoch>
  printf '%02d:%02dZ\n' $(( $1 % 86400 / 3600 )) $(( $1 % 3600 / 60 ))
}
