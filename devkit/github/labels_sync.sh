#!/usr/bin/env bash
# Make every fleet repo's issue labels match github/labels.json plus its own labels in
# github/repos.json. Replaces hand-made labels that drifted (rollcall's agent labels, finplat's
# area colours aliasing agent states, labels the gates read existing in one repo only).
#
# Usage: github/labels_sync.sh [--prune] [--dry-run] [repo...]
#   repo...     keys of repos.json, case-insensitive, optional "owner/" prefix; default: all
#   --prune     also delete labels defined in neither file; never done otherwise
#   --dry-run   read only; print the same lines prefixed "dry-run: "
#   Prints one line per label: "labels <repo> created|updated|deleted|ok <name>". A clean run
#   prints only "ok" lines and makes no writes. Exit 0 ok, 1 any gh failure, 2 usage or bad data.
#
# Run from the devkit checkout, not from a vendored copy: labels are a fleet operation over
# repos that never vendor devkit (redlib, rollcall, homelab), and editing GitHub from inside
# each clone gains nothing. This supersedes homelab #67's homelab/scripts/github/ placement.
# Names match case-insensitively, as GitHub does; a case difference is fixed by an update.
# DEVKIT_GITHUB_DATA overrides the directory holding labels.json and repos.json (tests).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DATA=${DEVKIT_GITHUB_DATA:-$HERE}
LABELS_FILE=$DATA/labels.json
REPOS_FILE=$DATA/repos.json

usage() { echo "usage: $0 [--prune] [--dry-run] [repo...]" >&2; exit 2; }
die() { echo "labels_sync: $*" >&2; exit 1; }
bad_data() { echo "labels_sync: $*" >&2; exit 2; }

PRUNE=0
DRY_RUN=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --prune) PRUNE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    -*) echo "labels_sync: unknown option $1" >&2; usage ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

command -v jq >/dev/null || die "jq not found (brew install jq)"
command -v gh >/dev/null || die "gh not found (brew install gh && gh auth login)"

# Validate the data before touching any repo: a malformed file must not half-apply.
jq -e '
  (.labels | type == "array" and length > 0)
  and all(.labels[]; (.name | type == "string") and (.color | test("^[0-9a-f]{6}$"))
                     and (.description | type == "string"))
  and ([.labels[].name | ascii_downcase] | length == (unique | length))
  and ((.labels | map(.name)) as $n | all(.loop_contract[]; . as $c | $n | index($c)))
' "$LABELS_FILE" >/dev/null || bad_data "$LABELS_FILE: invalid (needs unique names, lowercase 6-hex colours, string descriptions, every loop_contract name defined)"
jq -e --slurpfile canon "$LABELS_FILE" '
  ($canon[0].labels | map(.name | ascii_downcase)) as $c
  | (.owner | type == "string")
  and all(.repos[]; (.labels // []) | all(.[]; (.color | test("^[0-9a-f]{6}$"))
                                              and (.description | type == "string")
                                              and ((.name | ascii_downcase) as $n | $c | index($n) | not)))
' "$REPOS_FILE" >/dev/null || bad_data "$REPOS_FILE: invalid (needs owner; per-repo labels need lowercase 6-hex colours, string descriptions, and names not in labels.json)"

OWNER=$(jq -r '.owner' "$REPOS_FILE")

resolve_repo() { # <arg> -> repos.json key, or exit 2
  local key
  key=$(jq -r --arg r "${1#"$OWNER"/}" '.repos | keys_unsorted[] | select(ascii_downcase == ($r | ascii_downcase))' "$REPOS_FILE")
  [ -n "$key" ] || { echo "labels_sync: $1 is not in $REPOS_FILE" >&2; exit 2; }
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

uri() { jq -rn --arg s "$1" '$s | @uri'; }

write() { # <method> <path> [json body]
  [ "$DRY_RUN" -eq 0 ] || return 0
  if [ $# -ge 3 ]; then
    gh api -X "$1" "$2" --input - <<<"$3" >/dev/null || die "$1 $2 failed"
  else
    gh api -X "$1" "$2" >/dev/null || die "$1 $2 failed"
  fi
}

sync_repo() { # <repo>
  local repo=$1 base desired current plan row action name
  base="repos/$OWNER/$repo/labels"
  desired=$(jq -c --arg r "$repo" --slurpfile canon "$LABELS_FILE" \
    '$canon[0].labels + (.repos[$r].labels // [])' "$REPOS_FILE")
  current=$(gh api --paginate "$base?per_page=100" --jq '.[] | {name, color, description}') \
    || die "listing labels of $OWNER/$repo failed"
  current=$(printf '%s\n' "$current" | jq -cs '.')

  # One JSON object per decision: action, name as it exists (the URL key), body to send.
  # Computed up front so a jq failure stops the run before any write.
  plan=$(jq -cn --argjson want "$desired" --argjson have "$current" --argjson prune "$PRUNE" '
    def norm: {name, color: (.color | ascii_downcase), description: (.description // "")};
    def key: .name | ascii_downcase;
    ($have | map(norm)) as $h
    | ($want | map(norm)) as $w
    | ( $w[] as $d
        | ($h | map(select(key == ($d | key))) | first) as $cur
        | if $cur == null then {action: "create", name: $d.name, body: $d}
          elif $cur == $d then {action: "ok", name: $d.name}
          else {action: "update", name: $cur.name, body: ($d | {new_name: .name, color, description})}
          end ),
      ( if $prune == 1
        then ($w | map(key)) as $keep | $h[] | select(key as $k | $keep | index($k) | not)
             | {action: "delete", name}
        else empty end )') || die "planning labels for $OWNER/$repo failed"

  while IFS= read -r row; do
    action=$(jq -r '.action' <<<"$row")
    name=$(jq -r '.name' <<<"$row")
    case "$action" in
      create) write POST "$base" "$(jq -c '.body' <<<"$row")"; echo "${PREFIX}labels $repo created $name" ;;
      update) write PATCH "$base/$(uri "$name")" "$(jq -c '.body' <<<"$row")"; echo "${PREFIX}labels $repo updated $name" ;;
      delete) write DELETE "$base/$(uri "$name")"; echo "${PREFIX}labels $repo deleted $name" ;;
      ok) echo "${PREFIX}labels $repo ok $name" ;;
    esac
  done <<<"$plan"
}

for repo in "${REPOS[@]}"; do
  sync_repo "$repo"
done
