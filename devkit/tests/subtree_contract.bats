#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# Contract tests for bin/devkit-sync.sh and bin/devkit-check.sh. Everything is local: a bare
# "upstream" repo stands in for agandhi4/devkit (git subtree accepts a path as DEVKIT_URL) and a
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
squash_trailer() {
  git -C "$CONSUMER" log -1 --grep='^git-subtree-dir: devkit$' --format=%B | sed -n 's/^git-subtree-split: //p'
}

vendor_first() {
  git -C "$CONSUMER" subtree add --prefix=devkit "$UPSTREAM" main --squash >/dev/null 2>&1
}

run_sync() { cd "$CONSUMER" && run "$SYNC"; }
run_check() { cd "$CONSUMER" && run "$CHECK"; }

@test "first vendoring: sync records upstream commit + vendored tree, check passes" {
  vendor_first
  run_sync
  [ "$status" -eq 0 ]
  [ -f "$CONSUMER/.devkit-rev" ]
  [ "$(rev_field 1)" = "$(upstream_sha)" ]
  [ "$(rev_field 2)" = "$(vendored_tree)" ]
  [[ "${lines[${#lines[@]}-1]}" == "devkit at $(upstream_sha | cut -c1-7) (tree "* ]]  # last line: Ubuntu git also prints the subtree merge status
  git -C "$CONSUMER" log -1 --format=%s | grep -q "^Record devkit $(upstream_sha | cut -c1-7) in .devkit-rev$"
  run_check
  [ "$status" -eq 0 ]
  [ "$output" = "devkit-check: ok ($(upstream_sha | cut -c1-7))" ]
}

@test "upstream advances: sync pulls the new commit, content and .devkit-rev follow" {
  vendor_first
  run_sync
  [ "$status" -eq 0 ]
  local old_sha
  old_sha=$(upstream_sha)
  advance_upstream 'echo v2'
  [ "$(upstream_sha)" != "$old_sha" ]

  run_sync
  [ "$status" -eq 0 ]
  [ "$(rev_field 1)" = "$(upstream_sha)" ]
  [ "$(rev_field 2)" = "$(vendored_tree)" ]
  [ "$(cat "$CONSUMER/devkit/bin/tool.sh")" = 'echo v2' ]
  run_check
  [ "$status" -eq 0 ]
}

@test "recorded commit is the squash commit's git-subtree-split trailer, not a fresh ls-remote" {
  vendor_first
  run_sync
  advance_upstream 'echo v2'
  run_sync
  [ "$status" -eq 0 ]
  [ -n "$(squash_trailer)" ]
  [ "$(rev_field 1)" = "$(squash_trailer)" ]
  # Upstream moving after the pull must not change what the recording would report.
  advance_upstream 'echo v3'
  [ "$(rev_field 1)" = "$(squash_trailer)" ]
  [ "$(rev_field 1)" != "$(upstream_sha)" ]
}

@test "drift: an in-repo edit under devkit/ fails check and points at devkit-sync" {
  vendor_first
  run_sync
  echo 'echo hacked' >"$CONSUMER/devkit/bin/tool.sh"
  git -C "$CONSUMER" commit -q -am "local edit to devkit"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs from the vendored"* ]]
  [[ "$output" == *"make devkit-sync"* ]]
}

@test "dirty tree: sync refuses before pulling" {
  vendor_first
  run_sync
  echo 'dirty' >>"$CONSUMER/app.txt"
  run_sync
  [ "$status" -eq 2 ]
  [[ "$output" == *"commit or stash first"* ]]
}

@test "missing .devkit-rev: check exits 1" {
  vendor_first
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".devkit-rev missing"* ]]
}

@test "no devkit/ subtree: sync exits 2" {
  run_sync
  [ "$status" -eq 2 ]
  [[ "$output" == *"no devkit/ subtree"* ]]
}
