# shellcheck shell=bash
# The `main-check` commit status: the Mac's main check's verdict on a commit, on GitHub, where a
# job that acts only on a proven main reads it, and so can a person (the commit's checks list).
# Sourced; defines functions and runs nothing.
# Used by: main_check.sh (posts it on every commit it judges) and dependency_merge.sh (syncs only
# a devkit main commit it shows green).
#
#   MAIN_CHECK_CONTEXT
#       The status context, `main-check`: one name for the writer and every reader.
#   devkit_main_check_post <slug> <sha> pass|fail <description>
#       Post `success` or `failure` under MAIN_CHECK_CONTEXT on <sha>. GitHub keeps the newest
#       post per context, so a recheck's verdict replaces the last one. <description> is cut to
#       GitHub's 140 characters. Exit 1 when gh fails (the caller retries at its next tick).
#   devkit_main_check_state <slug> <sha>
#       Print <sha>'s MAIN_CHECK_CONTEXT state, GitHub's newest post under it (success, failure,
#       pending or error), or `none` when it has none. Exit 1 when gh fails.
# Only a judged commit gets one: a box failure (check_tree exit 2) posts nothing, and a commit
# the check never reached (main moved twice inside a window) has none, so a reader treats no
# status as unchecked, never as green.

# shellcheck disable=SC2034  # read by the sourcing job
readonly MAIN_CHECK_CONTEXT=main-check

devkit_main_check_post() { # <slug> <sha> pass|fail <description>
  local state=success
  [ "$3" = pass ] || state=failure
  gh api --method POST "repos/$1/statuses/$2" -f state="$state" -f context="$MAIN_CHECK_CONTEXT" \
    -f description="${4:0:140}" --silent
}

devkit_main_check_state() { # <slug> <sha>
  gh api "repos/$1/commits/$2/status" \
    --jq "[.statuses[] | select(.context == \"$MAIN_CHECK_CONTEXT\")][0].state // \"none\""
}
