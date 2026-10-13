#!/usr/bin/env bash
# Make every fleet repo's merge settings match github/repos.json: squash-only, PR title and body
# as the squash commit, head branches deleted on merge. Before this only closet was configured;
# every other repo offered merge and rebase and titled squashes COMMIT_OR_PR_TITLE, which turned
# a one-commit PR's "Closes #n" commit subject into the squash title.
#
# Usage: github/repo_settings.sh [--dry-run] [repo...]
#   repo...     keys of repos.json, case-insensitive, optional "owner/" prefix; default: all
#   --dry-run   read only; print the same lines prefixed "dry-run: "
#   Prints "settings <repo> <field>: <old> -> <new>" per changed field, or "settings <repo> ok".
#   Exit 0 ok, 1 any gh failure, 2 usage or bad data.
#
# Run from the devkit checkout, not from a vendored copy: settings are a fleet operation over
# repos that never vendor devkit (redlib, rollcall, homelab), and editing GitHub from inside
# each clone gains nothing. This supersedes homelab #67's homelab/scripts/github/ placement.
# allow_auto_merge is dropped for private repos: on the free plan GitHub ignores it there, so
# it would show as drift forever. Branch protection is out of scope for the same reason.
# DEVKIT_GITHUB_DATA overrides the directory holding repos.json (tests).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DATA=${DEVKIT_GITHUB_DATA:-$HERE}
REPOS_FILE=$DATA/repos.json

usage() { echo "usage: $0 [--dry-run] [repo...]" >&2; exit 2; }
die() { echo "repo_settings: $*" >&2; exit 1; }

DRY_RUN=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    -*) echo "repo_settings: unknown option $1" >&2; usage ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

command -v jq >/dev/null || die "jq not found (brew install jq)"
command -v gh >/dev/null || die "gh not found (brew install gh && gh auth login)"

jq -e '
  (.owner | type == "string")
  and all(.settings, (.repos[] | .settings // {}); type == "object" and all(.[]; type != "object" and type != "array"))
' "$REPOS_FILE" >/dev/null || { echo "repo_settings: $REPOS_FILE: invalid (needs owner; settings must map fields to scalars)" >&2; exit 2; }

OWNER=$(jq -r '.owner' "$REPOS_FILE")

resolve_repo() { # <arg> -> repos.json key, or exit 2
  local key
  key=$(jq -r --arg r "${1#"$OWNER"/}" '.repos | keys_unsorted[] | select(ascii_downcase == ($r | ascii_downcase))' "$REPOS_FILE")
  [ -n "$key" ] || { echo "repo_settings: $1 is not in $REPOS_FILE" >&2; exit 2; }
  echo "$key"
}

REPOS=()
if [ ${#ARGS[@]} -eq 0 ]; then
  while IFS= read -r r; do REPOS+=("$r"); done < <(jq -r '.repos | keys_unsorted[]' "$REPOS_FILE")
else
  for a in "${ARGS[@]}"; do REPOS+=("$(resolve_repo "$a")"); done
fi

PREFIX=
[ "$DRY_RUN" -eq 0 ] || PREFIX="dry-run: "

apply_repo() { # <repo>
  local repo=$1 current desired plan
  current=$(gh api "repos/$OWNER/$repo") || die "reading $OWNER/$repo failed"
  desired=$(jq -c --arg r "$repo" '.settings + (.repos[$r].settings // {})' "$REPOS_FILE")

  # GitHub validates the commit title/message pairs together (COMMIT_OR_PR_TITLE allows only
  # COMMIT_MESSAGES), so when either half of a pair changes the PATCH carries both halves.
  plan=$(jq -cn --argjson cur "$current" --argjson want "$desired" '
    def pairs: [["squash_merge_commit_title", "squash_merge_commit_message"],
                ["merge_commit_title", "merge_commit_message"]];
    (if $cur.private then $want | del(.allow_auto_merge) else $want end) as $w
    | [$w | to_entries[] | select($cur[.key] != .value)] as $changed
    | ($changed | map(.key)) as $keys
    | (pairs | map(select(any(.[]; . as $k | $keys | index($k))) | .[]) | map(. as $k | select($w | has($k)))) as $paired
    | { changed: [$changed[] | {key, old: ($cur[.key] | tostring), new: (.value | tostring)}],
        body: ($w | with_entries(select(.key as $k | ($keys + $paired) | index($k)))) }') \
    || die "planning settings for $OWNER/$repo failed"

  if [ "$(jq '.changed | length' <<<"$plan")" -eq 0 ]; then
    echo "${PREFIX}settings $repo ok"
    return 0
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    jq -c '.body' <<<"$plan" | gh api -X PATCH "repos/$OWNER/$repo" --input - >/dev/null \
      || die "PATCH repos/$OWNER/$repo failed"
  fi
  jq -r --arg p "$PREFIX" --arg r "$repo" '.changed[] | "\($p)settings \($r) \(.key): \(.old) -> \(.new)"' <<<"$plan"
}

for repo in "${REPOS[@]}"; do
  apply_repo "$repo"
done
