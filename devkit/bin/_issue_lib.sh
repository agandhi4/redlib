# shellcheck shell=bash
# Filing an issue once. Sourced; defines functions and runs nothing.
#
#   devkit_issue_file <slug> <label> <title> <body>
#       Open an issue in <slug> with <label>, unless an open issue with that label already has
#       exactly <title>: the title is the dedup key, so a caller puts in it what makes one
#       problem one issue (a job and test, a commit). Prints `filed <url>` or `open already:
#       <title>`; exit 1 when gh fails (a caller reports it and goes on: a missed issue never
#       changes a verdict).
#       Used by: check_tree.sh (flaky, ratchet) and publish.sh (main-red).
#   devkit_issue_upsert <slug> <label> <title> <body>
#       devkit_issue_file, except that an open issue with <title> gets <body> as its new body.
#       Prints `filed <url>` or `updated #<n>`. Used by: publisher_deadman.sh.
#   devkit_issue_close <slug> <label> <comment> [<keep title>] [<title prefix>]
#       Close every open <label> issue but the one titled <keep title>, with <comment>; with a
#       prefix, only those whose title starts with it. Prints `closed #<n> ...` or `closed none`;
#       exit 1 when gh fails. Used by: devkit_main_red_heal and publisher_deadman.sh.
#   devkit_main_red_title <evidence> <commit> [<where>]
#       `main is red [<where> ]at <sha7>: <failed jobs>`, the jobs from check_tree's VERDICT line
#       in <evidence> (its saved output). <where> keeps each checker's issues apart: publish.sh
#       has none, main_check.sh is `on the Mac`, so a green publish (which skips the Xcode jobs)
#       never closes the Mac's issue, nor the Mac's green the publisher's.
#   devkit_main_red_file <slug> <commit> <evidence> <lead> [<where>]
#       One main-red issue for <commit>, the first bad one: <lead>, then <evidence> less its
#       passing lines, last 40. Prints and exits as devkit_issue_file.
#   devkit_main_red_heal <slug> <comment> [<keep title>] [<where>]
#       Close <where>'s open main-red issues but <keep title>. Used by: publish.sh, main_check.sh.
# The labels are in github/labels.json; the `gh label create` covers a repo not yet synced to it
# (it fails, harmlessly, when the label exists).

devkit_issue_file() { # <slug> <label> <title> <body>
  local titles url
  titles=$(gh issue list --repo "$1" --label "$2" --state open --limit 200 --json title --jq '.[].title') || return 1
  if grep -qxF -- "$3" <<<"$titles"; then echo "open already: $3"; return 0; fi
  gh label create "$2" --repo "$1" >/dev/null 2>&1 || :
  url=$(gh issue create --repo "$1" --label "$2" --title "$3" --body "$4") || return 1
  echo "filed $url"
}

_devkit_open_issues() { # <slug> <label>: "<number>\t<title>" per open issue
  gh issue list --repo "$1" --label "$2" --state open --limit 200 --json number,title --jq '.[] | "\(.number)\t\(.title)"'
}

devkit_issue_upsert() { # <slug> <label> <title> <body>
  local rows n
  rows=$(_devkit_open_issues "$1" "$2") || return 1
  n=$(awk -F '\t' -v t="$3" '$2 == t { print $1; exit }' <<<"$rows")
  [ -n "$n" ] || { devkit_issue_file "$@"; return; }
  gh issue edit "$n" --repo "$1" --body "$4" >/dev/null || return 1
  echo "updated #$n"
}

devkit_issue_close() { # <slug> <label> <comment> [<keep title>] [<title prefix>]
  local rows n title closed=''
  rows=$(_devkit_open_issues "$1" "$2") || return 1
  while IFS=$'\t' read -r n title; do
    [ -n "$n" ] && [ "$title" != "${4:-}" ] && [[ "$title" == "${5:-}"* ]] || continue
    gh issue close "$n" --repo "$1" --comment "$3" >/dev/null || return 1
    closed="$closed #$n"
  done <<<"$rows"
  echo "closed${closed:- none}"
}

_devkit_main_red_prefix() { echo "main is red ${1:+$1 }at "; }

devkit_main_red_title() { # <evidence> <commit> [<where>]
  echo "$(_devkit_main_red_prefix "${3:-}")${2:0:7}: $(sed -n 's/^CHECK VERDICT FAIL .*failed=//p' "$1")"
}

devkit_main_red_file() { # <slug> <commit> <evidence> <lead> [<where>]
  devkit_issue_file "$1" main-red "$(devkit_main_red_title "$3" "$2" "${5:-}")" "$4

\`\`\`
$(grep -vE '^CHECK (.* PASS|.* SKIPPED|areas:|tree:)' "$3" | tail -n 40)
\`\`\`"
}

devkit_main_red_heal() { # <slug> <comment> [<keep title>] [<where>]
  devkit_issue_close "$1" main-red "$2" "${3:-}" "$(_devkit_main_red_prefix "${4:-}")"
}
