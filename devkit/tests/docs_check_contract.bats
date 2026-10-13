#!/usr/bin/env bats
# shellcheck shell=bash
# Contract tests for bin/docs_check.sh. Each test builds a temp git repo whose good shape is a
# root AGENTS.md + CLAUDE.md symlink, an `app/` pair, and docs/decisions.md, all committed; the
# test then breaks one thing and commits it (the check reads the index, not the working tree).

DOCS_CHECK="$BATS_TEST_DIRNAME/../bin/docs_check.sh"

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/docs.XXXXXX")
  REPO=$TMP/repo
  unset DOCS_CHECK_BANNED
  git init -q "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  echo "# root rules" >"$REPO/AGENTS.md"
  ln -s AGENTS.md "$REPO/CLAUDE.md"
  mkdir -p "$REPO/app" "$REPO/docs"
  echo "# app rules" >"$REPO/app/AGENTS.md"
  ln -s AGENTS.md "$REPO/app/CLAUDE.md"
  echo "# decisions" >"$REPO/docs/decisions.md"
  commit
}

teardown() {
  rm -rf "$TMP"
}

commit() { git -C "$REPO" add -A && git -C "$REPO" commit -qm fixture; }
# fill <path> <bytes>: a file of exactly that many bytes
fill() { mkdir -p "$(dirname "$REPO/$1")"; head -c "$2" /dev/zero | tr '\0' x >"$REPO/$1"; }
allow() { mkdir -p "$REPO/scripts/ci"; printf '%s\n' "$@" >"$REPO/scripts/ci/docs_oversize.txt"; }
rules() { mkdir -p "$REPO/scripts/ci"; printf '%s\n' "$@" >"$REPO/scripts/ci/docs_rules.sh"; }
run_check() { run "$DOCS_CHECK" "$REPO"; }

@test "all good: ok with the AGENTS.md count" {
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs-check: ok (2 AGENTS.md files)"* ]]
}

@test "no repo root argument uses the enclosing git repo" {
  cd "$REPO/app"
  run "$DOCS_CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok (2 AGENTS.md files)"* ]]
}

@test "too many arguments is usage, exit 2" {
  run "$DOCS_CHECK" "$REPO" extra
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "a CLAUDE.md-only directory fails" {
  mkdir -p "$REPO/lib"
  echo "# lib" >"$REPO/lib/CLAUDE.md"
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"lib: CLAUDE.md without AGENTS.md; make it AGENTS.md and symlink CLAUDE.md"* ]]
  [[ "$output" == *"docs-check: FAIL"* ]]
}

@test "a reversed pair fails naming the directory" {
  rm "$REPO/app/AGENTS.md" "$REPO/app/CLAUDE.md"
  echo "# app rules" >"$REPO/app/CLAUDE.md"
  ln -s CLAUDE.md "$REPO/app/AGENTS.md"
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"app: AGENTS.md is a symlink (reversed pair)"* ]]
}

@test "a CLAUDE.md symlink to anything but AGENTS.md fails" {
  echo x >"$REPO/app/OTHER.md"
  rm "$REPO/app/CLAUDE.md"
  ln -s OTHER.md "$REPO/app/CLAUDE.md"
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"app: CLAUDE.md points to 'OTHER.md'"* ]]
}

@test "root AGENTS.md over 30 KB fails" {
  fill AGENTS.md $((30 * 1024 + 1))
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"AGENTS.md: 30721 bytes, over the 30720-byte cap"* ]]
}

@test "root AGENTS.md at exactly 30 KB passes" {
  fill AGENTS.md $((30 * 1024))
  commit
  run_check
  [ "$status" -eq 0 ]
}

@test "nested AGENTS.md over 16 KB fails" {
  fill app/AGENTS.md $((16 * 1024 + 1))
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"app/AGENTS.md: 16385 bytes, over the 16384-byte cap"* ]]
}

@test "nested AGENTS.md over 16 KB but allowlisted passes" {
  fill app/AGENTS.md 20000
  allow "# grandfathered" "app/AGENTS.md 21000"
  commit
  run_check
  [ "$status" -eq 0 ]
}

@test "allowlisted file that grew past its allowance fails" {
  fill app/AGENTS.md 22000
  allow "app/AGENTS.md 21000"
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"over its 21000-byte allowance"* ]]
}

@test "allowlisted file under 90% of its allowance fails with tighten" {
  fill app/AGENTS.md 17000
  allow "app/AGENTS.md 21000"
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"tighten scripts/ci/docs_oversize.txt to 17000"* ]]
}

@test "allowlisted file now within the default cap fails as a stale entry" {
  allow "app/AGENTS.md 21000"
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"remove it from scripts/ci/docs_oversize.txt"* ]]
}

@test "allowlist entry for an untracked path fails" {
  allow "gone/AGENTS.md 21000"
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'gone/AGENTS.md' is not a tracked AGENTS.md"* ]]
}

@test "missing docs/decisions.md fails" {
  git -C "$REPO" rm -q docs/decisions.md
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/decisions.md is missing"* ]]
}

@test "a retired tool in AGENTS.md fails; the same word in README.md passes" {
  printf '# app\nUse Serena for symbols.\n' >"$REPO/app/AGENTS.md"
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"app/AGENTS.md:2: names retired tool 'serena'"* ]]

  echo "# app" >"$REPO/app/AGENTS.md"
  echo "We used serena once." >"$REPO/README.md"
  commit
  run_check
  [ "$status" -eq 0 ]
}

@test "retired tools match whole words only" {
  echo "see serenade.md" >>"$REPO/AGENTS.md"
  commit
  run_check
  [ "$status" -eq 0 ]
}

@test "DOCS_CHECK_BANNED replaces the default list" {
  printf 'Use serena and acmetool.\n' >>"$REPO/AGENTS.md"
  commit
  DOCS_CHECK_BANNED="acmetool" run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"names retired tool 'acmetool'"* ]]
  [[ "$output" != *"'serena'"* ]]
}

@test "docs_rules.sh calling docs_fail fails the run" {
  # shellcheck disable=SC2016  # $ROOT expands inside docs_check.sh, not here
  rules '[ -f "$ROOT/docs/areas.md" ] || docs_fail "docs/areas.md is required here"'
  commit
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs-check: docs/areas.md is required here"* ]]
  [[ "$output" == *"docs-check: FAIL"* ]]
}

@test "docs_rules.sh calling only docs_warn passes and prints the warning" {
  rules 'docs_warn "area index is getting long"'
  commit
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs-check: warning: area index is getting long"* ]]
  [[ "$output" == *"docs-check: ok (2 AGENTS.md files)"* ]]
}

@test "an untracked AGENTS.md is ignored" {
  mkdir -p "$REPO/scratch"
  fill scratch/AGENTS.md 40000
  echo "# scratch" >"$REPO/scratch/CLAUDE.md"
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok (2 AGENTS.md files)"* ]]
}
