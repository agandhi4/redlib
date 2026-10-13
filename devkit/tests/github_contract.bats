#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# Contract tests for github/labels_sync.sh and github/repo_settings.sh. No network: a fake `gh`
# serves GET responses from $FAKE_GH_DIR/<api path>.json (applying --jq like gh does), logs every
# mutation to $GH_LOG as "<METHOD> <path> <sorted compact body>", and fails any call whose
# "<METHOD> <path>" matches $FAKE_GH_FAIL.

LABELS="$BATS_TEST_DIRNAME/../github/labels_sync.sh"
SETTINGS="$BATS_TEST_DIRNAME/../github/repo_settings.sh"

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/github.XXXXXX")
  TMP=$(cd "$TMP" && pwd -P)
  export FAKE_GH_DIR=$TMP/api
  export GH_LOG=$TMP/gh.log
  export DEVKIT_GITHUB_DATA=$TMP/data
  export FAKE_GH_FAIL=
  export PATH=$TMP/bin:$PATH
  mkdir -p "$TMP/bin" "$FAKE_GH_DIR/repos/acme/app" "$FAKE_GH_DIR/repos/acme/fork" "$DEVKIT_GITHUB_DATA"
  : >"$GH_LOG"
  fake_gh
  cat >"$DEVKIT_GITHUB_DATA/labels.json" <<'JSON'
{ "loop_contract": ["agent-ready"],
  "labels": [
    { "name": "agent-ready", "color": "0e8a16", "description": "Eligible" },
    { "name": "bug", "color": "d73a4a", "description": "Broken" },
    { "name": "epic", "color": "3e4b9e", "description": "Tracks \"children\"" } ] }
JSON
  cat >"$DEVKIT_GITHUB_DATA/repos.json" <<'JSON'
{ "owner": "acme",
  "settings": { "allow_squash_merge": true, "allow_merge_commit": false, "allow_auto_merge": true,
                "squash_merge_commit_title": "PR_TITLE", "squash_merge_commit_message": "PR_BODY" },
  "repos": {
    "app": { "labels": [ { "name": "area/x", "color": "c5def5", "description": "" } ] },
    "fork": { "settings": { "allow_merge_commit": true } } } }
JSON
}

teardown() {
  rm -rf "$TMP"
}

fake_gh() {
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = api ] || { echo "fake gh: unsupported: $*" >&2; exit 64; }
shift
method=GET jq_expr= input= path=
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) method=$2; shift ;;
    --jq|-q) jq_expr=$2; shift ;;
    --input) input=$2; shift ;;
    --paginate) ;;
    -*) echo "fake gh: unsupported flag $1" >&2; exit 64 ;;
    *) path=${1%%\?*} ;;
  esac
  shift
done
if [ -n "$FAKE_GH_FAIL" ] && [ "$method $path" = "$FAKE_GH_FAIL" ]; then echo "HTTP 500" >&2; exit 1; fi
if [ "$method" != GET ]; then
  body=
  [ "$input" != - ] || body=$(jq -cS .)
  echo "$method $path $body" >>"$GH_LOG"
  echo '{}'
  exit 0
fi
f=$FAKE_GH_DIR/$path.json
[ -f "$f" ] || { echo "HTTP 404: Not Found ($path)" >&2; exit 1; }
if [ -n "$jq_expr" ]; then jq -c "$jq_expr" "$f"; else cat "$f"; fi
SH
  chmod +x "$TMP/bin/gh"
}

labels_of() { # <repo> <json array>
  printf '%s\n' "$2" >"$FAKE_GH_DIR/repos/acme/$1/labels.json"
}
repo_is() { # <repo> <json object>
  printf '%s\n' "$2" >"$FAKE_GH_DIR/repos/acme/$1.json"
}
in_sync_app_labels() {
  labels_of app '[{"name":"agent-ready","color":"0E8A16","description":"Eligible"},
                  {"name":"bug","color":"d73a4a","description":"Broken"},
                  {"name":"epic","color":"3e4b9e","description":"Tracks \"children\""},
                  {"name":"area/x","color":"c5def5","description":null}]'
}
mutations() { grep -c . "$GH_LOG" || true; }

# --- labels_sync.sh -------------------------------------------------------------------------

@test "labels: in-sync repo prints only ok and makes no writes (idempotent)" {
  in_sync_app_labels
  run "$LABELS" app
  [ "$status" -eq 0 ]
  [ "$(mutations)" -eq 0 ]
  [ "$(grep -vc '^labels app ok ' <<<"$output")" -eq 0 ]
  [ "$(grep -c '^labels app ok ' <<<"$output")" -eq 4 ]
}

@test "labels: creates a missing label with its JSON body intact" {
  labels_of app '[{"name":"agent-ready","color":"0e8a16","description":"Eligible"},
                  {"name":"bug","color":"d73a4a","description":"Broken"},
                  {"name":"area/x","color":"c5def5","description":""}]'
  run "$LABELS" app
  [ "$status" -eq 0 ]
  [[ "$output" == *"labels app created epic"* ]]
  [ "$(mutations)" -eq 1 ]
  grep -qF 'POST repos/acme/app/labels {"color":"3e4b9e","description":"Tracks \"children\"","name":"epic"}' "$GH_LOG"
}

@test "labels: updates a drifted colour by URL-encoded name, leaves identical ones" {
  in_sync_app_labels
  labels_of app '[{"name":"agent-ready","color":"b60205","description":"Eligible"},
                  {"name":"bug","color":"d73a4a","description":"Broken"},
                  {"name":"epic","color":"3e4b9e","description":"Tracks \"children\""},
                  {"name":"area/x","color":"FBCA04","description":""}]'
  run "$LABELS" app
  [ "$status" -eq 0 ]
  [[ "$output" == *"labels app updated agent-ready"* ]]
  [[ "$output" == *"labels app updated area/x"* ]]
  [[ "$output" == *"labels app ok bug"* ]]
  [ "$(mutations)" -eq 2 ]
  grep -qF 'PATCH repos/acme/app/labels/agent-ready {"color":"0e8a16","description":"Eligible","new_name":"agent-ready"}' "$GH_LOG"
  grep -qF 'PATCH repos/acme/app/labels/area%2Fx ' "$GH_LOG"
}

@test "labels: colour case and a name-case difference are matched like GitHub does" {
  labels_of app '[{"name":"Agent-Ready","color":"0E8A16","description":"Eligible"},
                  {"name":"bug","color":"D73A4A","description":"Broken"},
                  {"name":"epic","color":"3e4b9e","description":"Tracks \"children\""},
                  {"name":"area/x","color":"c5def5","description":""}]'
  run "$LABELS" app
  [ "$status" -eq 0 ]
  [[ "$output" == *"labels app ok bug"* ]]
  [[ "$output" == *"labels app updated Agent-Ready"* ]]
  [ "$(mutations)" -eq 1 ]
  grep -qF 'PATCH repos/acme/app/labels/Agent-Ready {"color":"0e8a16","description":"Eligible","new_name":"agent-ready"}' "$GH_LOG"
}

@test "labels: an extra label survives without --prune" {
  in_sync_app_labels
  labels_of app "$(jq -c '. + [{"name":"good first issue","color":"7057ff","description":"x"}]' "$FAKE_GH_DIR/repos/acme/app/labels.json")"
  run "$LABELS" app
  [ "$status" -eq 0 ]
  [[ "$output" != *"good first issue"* ]]
  [ "$(mutations)" -eq 0 ]
}

@test "labels: --prune deletes the extra label by URL-encoded name" {
  in_sync_app_labels
  labels_of app "$(jq -c '. + [{"name":"good first issue","color":"7057ff","description":"x"}]' "$FAKE_GH_DIR/repos/acme/app/labels.json")"
  run "$LABELS" --prune app
  [ "$status" -eq 0 ]
  [[ "$output" == *"labels app deleted good first issue"* ]]
  [ "$(mutations)" -eq 1 ]
  grep -qx 'DELETE repos/acme/app/labels/good%20first%20issue ' "$GH_LOG"
}

@test "labels: --dry-run --prune reports every change and writes nothing" {
  labels_of app '[{"name":"bug","color":"000000","description":"Broken"},{"name":"stale","color":"ffffff","description":""}]'
  run "$LABELS" --dry-run --prune app
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: labels app created agent-ready"* ]]
  [[ "$output" == *"dry-run: labels app updated bug"* ]]
  [[ "$output" == *"dry-run: labels app deleted stale"* ]]
  [ "$(mutations)" -eq 0 ]
}

@test "labels: no repo args means every repo in repos.json, per-repo labels only where declared" {
  in_sync_app_labels
  labels_of fork '[]'
  run "$LABELS" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"labels app ok area/x"* ]]
  [[ "$output" == *"dry-run: labels fork created epic"* ]]
  [[ "$output" != *"fork created area/x"* ]]
}

@test "labels: a gh failure exits 1 and stops" {
  in_sync_app_labels
  labels_of app '[]'
  export FAKE_GH_FAIL="POST repos/acme/app/labels"
  run "$LABELS" app
  [ "$status" -eq 1 ]
  [[ "$output" == *"POST repos/acme/app/labels failed"* ]]
}

@test "labels: unknown repo exits 2; owner/ prefix and case are accepted" {
  run "$LABELS" nope
  [ "$status" -eq 2 ]
  in_sync_app_labels
  run "$LABELS" acme/APP
  [ "$status" -eq 0 ]
  [[ "$output" == *"labels app ok bug"* ]]
}

@test "labels: a per-repo label redefining a canonical name is rejected before any call" {
  jq '.repos.app.labels += [{"name":"BUG","color":"000000","description":""}]' "$DEVKIT_GITHUB_DATA/repos.json" >"$TMP/r.json"
  mv "$TMP/r.json" "$DEVKIT_GITHUB_DATA/repos.json"
  run "$LABELS" app
  [ "$status" -eq 2 ]
  [ "$(mutations)" -eq 0 ]
}

# --- repo_settings.sh -----------------------------------------------------------------------

@test "settings: PATCHes only changed fields and prints old -> new" {
  repo_is app '{"private":false,"allow_squash_merge":true,"allow_merge_commit":true,"allow_auto_merge":true,
                "squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  run "$SETTINGS" app
  [ "$status" -eq 0 ]
  [ "$output" = "settings app allow_merge_commit: true -> false" ]
  grep -qx 'PATCH repos/acme/app {"allow_merge_commit":false}' "$GH_LOG"
}

@test "settings: one half of a commit title/message pair changing sends both halves" {
  repo_is app '{"private":false,"allow_squash_merge":true,"allow_merge_commit":false,"allow_auto_merge":true,
                "squash_merge_commit_title":"COMMIT_OR_PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  run "$SETTINGS" app
  [ "$status" -eq 0 ]
  [ "$output" = "settings app squash_merge_commit_title: COMMIT_OR_PR_TITLE -> PR_TITLE" ]
  grep -qx 'PATCH repos/acme/app {"squash_merge_commit_message":"PR_BODY","squash_merge_commit_title":"PR_TITLE"}' "$GH_LOG"
}

@test "settings: auto-merge is set on a public repo and skipped on a private one" {
  repo_is app '{"private":false,"allow_squash_merge":true,"allow_merge_commit":false,"allow_auto_merge":false,
                "squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  run "$SETTINGS" app
  [ "$output" = "settings app allow_auto_merge: false -> true" ]
  repo_is app '{"private":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_auto_merge":false,
                "squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  : >"$GH_LOG"
  run "$SETTINGS" app
  [ "$status" -eq 0 ]
  [ "$output" = "settings app ok" ]
  [ "$(mutations)" -eq 0 ]
}

@test "settings: a per-repo override wins over the default (fork keeps merge commits)" {
  repo_is fork '{"private":false,"allow_squash_merge":true,"allow_merge_commit":true,"allow_auto_merge":true,
                 "squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  run "$SETTINGS" fork
  [ "$status" -eq 0 ]
  [ "$output" = "settings fork ok" ]
  [ "$(mutations)" -eq 0 ]
}

@test "settings: --dry-run prints the changes and writes nothing" {
  repo_is app '{"private":true,"allow_squash_merge":false,"allow_merge_commit":true,"allow_auto_merge":false,
                "squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}'
  run "$SETTINGS" --dry-run app
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run: settings app allow_squash_merge: false -> true"* ]]
  [[ "$output" == *"dry-run: settings app allow_merge_commit: true -> false"* ]]
  [ "$(mutations)" -eq 0 ]
}

@test "settings: a gh failure exits 1" {
  repo_is app '{"private":true,"allow_merge_commit":true}'
  export FAKE_GH_FAIL="PATCH repos/acme/app"
  run "$SETTINGS" app
  [ "$status" -eq 1 ]
  [[ "$output" == *"PATCH repos/acme/app failed"* ]]
  run "$SETTINGS" fork
  [ "$status" -eq 1 ]
}

# --- the real fleet data ---------------------------------------------------------------------

@test "fleet data: valid, loop-contract labels defined, area labels share one colour, redlib keeps merge commits" {
  real="$BATS_TEST_DIRNAME/../github"
  jq -e '.loop_contract - [.labels[].name] == []' "$real/labels.json"
  jq -e '[.loop_contract[]] | contains(["agent-ready","agent-in-progress","agent-blocked","priority","api-breaking","metrics-rebaseline"])' "$real/labels.json"
  jq -e '[.repos[].labels[]? | select(.name | startswith("area/")) | .color] | unique | length == 1' "$real/repos.json"
  jq -e '.repos.redlib.settings.allow_merge_commit == true and .settings.allow_merge_commit == false' "$real/repos.json"
  jq -e '.repos | keys | contains(["finplat","Orbit","locus","closet","rollcall","redlib","homelab","devkit"])' "$real/repos.json"
  # Both scripts accept the real data (validation runs before any gh call).
  export DEVKIT_GITHUB_DATA=$real
  mkdir -p "$FAKE_GH_DIR/repos/agandhi4/devkit"
  printf '[]\n' >"$FAKE_GH_DIR/repos/agandhi4/devkit/labels.json"
  printf '{"private":true}\n' >"$FAKE_GH_DIR/repos/agandhi4/devkit.json"
  run "$LABELS" --dry-run devkit
  [ "$status" -eq 0 ]
  run "$SETTINGS" --dry-run devkit
  [ "$status" -eq 0 ]
}
