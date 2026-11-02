# shellcheck shell=bash
# The fleet's checkouts on this box, found at run time so a repo cloned after a job's install is
# covered with no reinstall (2026-11-02: instalite-relay was never synced by the nightly job,
# whose plist held the repo list of its install day). Sourced; defines functions only.
# Used by main_check.sh and dependency_merge.sh (both scan DEVKIT_CHECKOUT_PARENTS by default); each job
# then judges a checkout by its origin/main, never by this list.
#
#   DEVKIT_CHECKOUT_PARENTS
#       Where this Mac keeps the fleet's checkouts: the directories devkit_checkouts scans when
#       a job is given none.
#   devkit_checkouts <dir>...
#       Print each git checkout, one per line: <dir> itself when it is one (homelab), else every
#       direct child that is one, in name order. A missing <dir> prints nothing.
#   devkit_claim_checkout <dir>
#       True the first time a run meets <dir>'s origin slug (devkit_origin_slug), false for any
#       later checkout of it, which the job then leaves out; DEVKIT_SLUG is the slug either way.
#       The rule (devkit #365): a job claims its explicit roots first (each one given runs), then
#       the scan's checkouts in devkit_checkouts' order, and the first claim wins. Two clones of
#       one origin share its main, so they would get the same verdict and the same work twice
#       (the nightly job's sync and --max). Keyed by the remote, not the path or the plan's
#       GATE_SLUG, so it is known before any fetch and a duplicate is never fetched. A checkout
#       with no origin is keyed by its real path.
#   devkit_origin_slug <dir>
#       origin's owner/repo (devkit_url_slug of its URL). No network.
#   devkit_url_slug <url>
#       A git URL's owner/repo, lowercased (GitHub's are case-blind): scp-like, ssh://, https://
#       or a local path (the last two components). dependency_merge.sh reads DEVKIT_URL's with it.

# shellcheck disable=SC2034  # read by the sourcing job
DEVKIT_CHECKOUT_PARENTS=("$HOME/projects/solo" "$HOME/projects/homelab")

devkit_checkouts() {
  local dir child
  for dir in "$@"; do
    dir=${dir%/}
    if [ -e "$dir/.git" ]; then echo "$dir"; continue; fi
    # A glob sorts by name and, unlike find -type d, follows a symlinked checkout.
    for child in "$dir"/*/; do
      child=${child%/}
      [ ! -e "$child/.git" ] || echo "$child"
    done
  done
}

devkit_origin_slug() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  devkit_url_slug "$url"
}

devkit_url_slug() {
  local url=${1%/} rest
  url=${url%.git}
  rest=${url%[/:]*}
  printf '%s/%s\n' "${rest##*[/:]}" "${url##*[/:]}" | tr '[:upper:]' '[:lower:]'
}

DEVKIT_CLAIMED=$'\n'
devkit_claim_checkout() {
  DEVKIT_SLUG=$(devkit_origin_slug "$1") || DEVKIT_SLUG=path:$(cd "$1" 2>/dev/null && pwd -P)
  case "$DEVKIT_CLAIMED" in *$'\n'"$DEVKIT_SLUG"$'\n'*) return 1 ;; esac
  DEVKIT_CLAIMED+="$DEVKIT_SLUG"$'\n'
}
