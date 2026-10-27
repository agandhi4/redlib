# shellcheck shell=bash
# The repo gh acts on: origin's, never gh's own default. Sourced; defines functions and runs
# nothing. Used by: devkit-check.sh (holds the plan's GATE_SLUG to origin, heals the default),
# merge_rules.sh (refuses a plan slug that is not origin's), pr_create.sh (`make pr`) and
# devkit-sync.sh. devkit-check is every consumer's ci-guards, so a commit, `make install` and the
# gate's ci-quick each heal the clone; hook_steps.sh does not repeat it (one more lib per hook).
#
# Why (redlib, 2026-10-26): redlib is a fork with an `upstream` remote and had no gh default, so
# a lane's bare `gh pr create` opened redlib-org/redlib#605 on the public parent. gh ranks an
# `upstream` remote ahead of origin and, with no default, resolves a fork to its parent. So every
# devkit gh call names its repo (`--repo`/`-R`, or a `repos/<slug>/…` API path; never `{owner}` or
# `{repo}`, which gh fills from the default: tests/gh_repo_contract.bats greps bin/*.sh and
# github/*.sh), and every checkout's default is pinned to origin for whoever calls gh bare.
#
# gh keeps the default in git config: `remote.<name>.gh-resolved` is `base` on the default's
# remote, or an `owner/repo` naming another repo (a parent) on it; `gh repo set-default` unsets
# every other remote's key first (gh 2.102). gh_default_heal writes those keys itself: offline,
# with no gh (CI runs devkit-check without one), and alike in a fork and a non-fork, whose
# default origin already is, so no API call has to ask which it is.

# origin_slug <dir>: owner/name of <dir>'s origin when its URL is github.com's (https, ssh:// or
# scp-like), else exit 1 (no origin, or a path such as a test fixture's). The URL as configured,
# before any insteadOf: the name gh and a person read.
origin_slug() {
  local url path
  local re='^(https?://([^@/]*@)?github\.com/|ssh://([^@/]*@)?github\.com(:[0-9]+)?/|[^@/:]+@github\.com:)(.+)$'
  url=$(git -C "$1" config --get remote.origin.url) || return 1
  [[ "$url" =~ $re ]] || return 1
  path=${BASH_REMATCH[5]%/}
  path=${path%.git}
  [[ "$path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s\n' "$path"
}

# slug_same <a> <b>: the same GitHub repo; owner and name compare without case, as GitHub's do
# (Orbit's plan says agandhi4/Orbit).
slug_same() {
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]
}

# gh_default_heal <dir> <label>: make origin gh's default repo in <dir>'s clone, with one
# `<label>: …` line naming what it replaced; silent when it already is, or when origin is not a
# GitHub repo. Exit 1 when git cannot write the config.
gh_default_heal() {
  local slug entries key value was=""
  slug=$(origin_slug "$1") || return 0
  entries=$(git -C "$1" config --get-regexp '^remote\..*\.gh-resolved$') || entries=""
  [ "$entries" != "remote.origin.gh-resolved base" ] || return 0
  while read -r key value; do
    [ -n "$key" ] || continue
    git -C "$1" config --unset-all "$key" || return 1
    key=${key#remote.}
    was+="${was:+, }${key%.gh-resolved}=$value"
  done <<<"$entries"
  git -C "$1" config remote.origin.gh-resolved base || return 1
  echo "$2: set gh's default repo to origin, $slug (was ${was:-unset}; a fork's bare gh resolves to its parent)"
}
