#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# Contract tests for bin/devkit-sync.sh and bin/devkit-check.sh. Everything is local: a bare
# "upstream" repo stands in for agandhi4/devkit (git fetch accepts a path as DEVKIT_URL) and a
# "consumer" repo vendors it under devkit/. Both scripts resolve the repo from the cwd, so they are
# run from $CONSUMER; the copies under test are this repo's bin/, not the vendored fixture's.

SYNC="$BATS_TEST_DIRNAME/../bin/devkit-sync.sh"
CHECK="$BATS_TEST_DIRNAME/../bin/devkit-check.sh"

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/subtree.XXXXXX")
  UPSTREAM=$TMP/upstream.git
  UPSTREAM_WC=$TMP/upstream-wc
  CONSUMER=$TMP/consumer
  export DEVKIT_URL=$UPSTREAM

  # Isolate git from the developer's global config (signing, hooks, identity).
  export GIT_CONFIG_GLOBAL=$TMP/gitconfig
  git config --file "$GIT_CONFIG_GLOBAL" user.name subtree-test
  git config --file "$GIT_CONFIG_GLOBAL" user.email subtree-test@local
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  git init -q --bare "$UPSTREAM"
  git clone -q "$UPSTREAM" "$UPSTREAM_WC" 2>/dev/null
  git -C "$UPSTREAM_WC" checkout -q -b main
  mkdir -p "$UPSTREAM_WC/bin"
  echo 'echo v1' >"$UPSTREAM_WC/bin/tool.sh"
  echo '# devkit' >"$UPSTREAM_WC/README.md"
  git -C "$UPSTREAM_WC" add -A
  git -C "$UPSTREAM_WC" commit -q -m "devkit v1"
  git -C "$UPSTREAM_WC" push -q -u origin main 2>/dev/null

  git init -q "$CONSUMER"
  git -C "$CONSUMER" checkout -q -b main
  echo 'app' >"$CONSUMER/app.txt"
  git -C "$CONSUMER" add -A
  git -C "$CONSUMER" commit -q -m "consumer initial"
}

teardown() {
  rm -rf "$TMP"
}

# advance_upstream <tool content>: a new upstream commit on main.
advance_upstream() {
  echo "$1" >"$UPSTREAM_WC/bin/tool.sh"
  git -C "$UPSTREAM_WC" commit -q -am "devkit: $1"
  git -C "$UPSTREAM_WC" push -q origin main 2>/dev/null
}

upstream_sha() { git -C "$UPSTREAM" rev-parse main; }
vendored_tree() { git -C "$CONSUMER" rev-parse HEAD:devkit; }
rev_field() { cut -d' ' -f"$1" "$CONSUMER/.devkit-rev"; }
upstream_tree() { git -C "$UPSTREAM" rev-parse 'main^{tree}'; }

run_sync() { cd "$CONSUMER" && run "$SYNC"; }
run_check() { cd "$CONSUMER" && run "$CHECK"; }

@test "first vendoring: sync creates devkit/ from upstream, records commit + tree, check passes" {
  run_sync
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/devkit/bin/tool.sh" ]
  [ "$(rev_field 1)" = "$(upstream_sha)" ]
  [ "$(rev_field 2)" = "$(vendored_tree)" ]
  [ "$(vendored_tree)" = "$(upstream_tree)" ]
  [[ "${lines[${#lines[@]}-1]}" == "devkit at $(upstream_sha | cut -c1-7) (tree "* ]]
  git -C "$CONSUMER" log -1 --format=%s | grep -q "^Update devkit to $(upstream_sha | cut -c1-7)$"
  [ -z "$(git -C "$CONSUMER" status --porcelain)" ]
  run_check
  [ "$status" -eq 0 ]
  [ "$output" = "devkit-check: ok ($(upstream_sha | cut -c1-7))" ]
}

@test "upstream advances: sync replaces the tree, content and .devkit-rev follow, no conflict possible" {
  run_sync; [ "$status" -eq 0 ]
  advance_upstream 'echo v2'
  run_sync
  [ "$status" -eq 0 ]
  [ "$(cat "$CONSUMER/devkit/bin/tool.sh")" = 'echo v2' ]
  [ "$(rev_field 1)" = "$(upstream_sha)" ]
  [ "$(vendored_tree)" = "$(upstream_tree)" ]
  run_check; [ "$status" -eq 0 ]
}

@test "sync survives a squash of the vendoring commit (no subtree trailers needed)" {
  run_sync; [ "$status" -eq 0 ]
  # Simulate a squash-merge: rewrite the last commit without any trailer lines.
  git -C "$CONSUMER" commit -q --amend -m "Vendor devkit (squashed PR)"
  advance_upstream 'echo v3'
  run_sync
  [ "$status" -eq 0 ]
  [ "$(cat "$CONSUMER/devkit/bin/tool.sh")" = 'echo v3' ]
  [ "$(rev_field 1)" = "$(upstream_sha)" ]
}

@test "already current: sync is a no-op and makes no commit" {
  run_sync; [ "$status" -eq 0 ]
  before=$(git -C "$CONSUMER" rev-parse HEAD)
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"already current"* ]]
  [ "$(git -C "$CONSUMER" rev-parse HEAD)" = "$before" ]
}

@test "drift: a local edit under devkit/ fails devkit-check and names the fix" {
  run_sync; [ "$status" -eq 0 ]
  echo 'echo hacked' >"$CONSUMER/devkit/bin/tool.sh"
  git -C "$CONSUMER" commit -q -am "local edit to devkit"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs from the vendored"* ]]
  [[ "$output" == *"make devkit-sync"* ]]
}

@test "pre-commit: a staged sync passes devkit-check before it is committed" {
  run_sync; [ "$status" -eq 0 ]
  advance_upstream 'echo v5'
  # What the sync stages, checked the way the consumer's pre-commit hook sees it (HEAD still old).
  git -C "$CONSUMER" fetch -q "$UPSTREAM" main
  git -C "$CONSUMER" rm -rq devkit
  git -C "$CONSUMER" read-tree --prefix=devkit/ -u "$(upstream_tree)"
  echo "$(upstream_sha) $(upstream_tree)" >"$CONSUMER/.devkit-rev"
  git -C "$CONSUMER" add .devkit-rev
  run_check
  [ "$status" -eq 0 ]
}

@test "drift: a staged (uncommitted) local edit under devkit/ fails devkit-check" {
  run_sync; [ "$status" -eq 0 ]
  echo 'echo hacked' >"$CONSUMER/devkit/bin/tool.sh"
  git -C "$CONSUMER" add devkit/bin/tool.sh
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs from the vendored"* ]]
}

@test "drift is repaired by the next sync (upstream wins)" {
  run_sync; [ "$status" -eq 0 ]
  echo 'echo hacked' >"$CONSUMER/devkit/bin/tool.sh"
  git -C "$CONSUMER" commit -q -am "local edit to devkit"
  advance_upstream 'echo v4'
  run_sync
  [ "$status" -eq 0 ]
  [ "$(cat "$CONSUMER/devkit/bin/tool.sh")" = 'echo v4' ]
  run_check; [ "$status" -eq 0 ]
}

@test "dirty tree: sync refuses before touching anything" {
  echo 'wip' >>"$CONSUMER/app.txt"
  run_sync
  [ "$status" -eq 2 ]
  [[ "$output" == *"commit or stash first"* ]]
  [ ! -e "$CONSUMER/devkit" ]
}

@test "missing .devkit-rev: check exits 1" {
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".devkit-rev missing"* ]]
}
