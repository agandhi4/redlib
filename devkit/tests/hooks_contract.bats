#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# Contract tests for bin/quiet_run.sh, bin/push_ranges.sh, bin/hooks_check.sh, bin/hook_steps.sh and the
# templates/githooks hooks. Repos are throwaway `git init`s; `make` is a PATH stub that logs
# each target and fails the one named in $FAIL_TARGET.

DEVKIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
QUIET="$DEVKIT/bin/quiet_run.sh"
RANGES="$DEVKIT/bin/push_ranges.sh"
CHECK="$DEVKIT/bin/hooks_check.sh"
ZERO=0000000000000000000000000000000000000000

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/hooks.XXXXXX")
  export TMPDIR=$TMP
  REPO=$TMP/repo
  BIN=$TMP/bin
  mkdir -p "$BIN"
  export PATH=$BIN:$PATH
  unset CI GITHUB_ACTIONS QUIET_TAIL QUIET_VERBOSE HOOK_ENV_FILE VITEST_MAX_WORKERS
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
}

teardown() {
  rm -rf "$TMP"
}

commit() { # <message>; prints the new sha
  git -C "$REPO" commit -q --allow-empty -m "$1"
  git -C "$REPO" rev-parse HEAD
}

# A consumer repo with the templates installed, devkit/bin linked in, and a logging make.
install_templates() { # <conf body>
  mkdir -p "$REPO/.githooks" "$REPO/devkit" "$REPO/scripts/ci"
  ln -s "$DEVKIT/bin" "$REPO/devkit/bin"
  cp "$DEVKIT/templates/githooks/pre-commit" "$DEVKIT/templates/githooks/pre-push" "$REPO/.githooks/"
  printf '%s\n' "$1" >"$REPO/scripts/ci/hooks.conf"
  cat >"$BIN/make" <<'MAKE'
#!/usr/bin/env bash
target=${!#}
echo "$target VITEST_MAX_WORKERS=${VITEST_MAX_WORKERS:-} DATABASE_URL=${DATABASE_URL:-}" >>"$MAKE_LOG"
echo "running $target"
[ "$target" != "${FAIL_TARGET:-}" ] || exit 7
MAKE
  chmod +x "$BIN/make"
  export MAKE_LOG=$TMP/make.log
  : >"$MAKE_LOG"
}

# --- quiet_run.sh ---

@test "quiet_run: a passing command prints one line and exits 0" {
  run "$QUIET" "unit" -- sh -c 'echo noise; echo more noise'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" =~ ^✓\ unit\ \([0-9]+s\)$ ]]
  [ -z "$(find "$TMP" -name 'devkit-quiet.*')" ]
}

@test "quiet_run: a pass surfaces the tool's summary line" {
  run "$QUIET" "tests" -- printf '\033[32m  Tests  12 passed\033[0m\ntip: try --ui\n'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^✓\ tests\ \([0-9]+s\)\ —\ Tests\ \ 12\ passed$ ]]
}

@test "quiet_run: a failure prints exactly the last QUIET_TAIL lines, keeps the log, propagates the code" {
  export QUIET_TAIL=5
  run "$QUIET" "lint" -- sh -c 'seq 1 100 | sed "s/^/line /"; exit 3'
  [ "$status" -eq 3 ]
  [[ "${lines[0]}" =~ ^✗\ lint\ \([0-9]+s\)$ ]]
  [[ "${lines[1]}" == "--- last 5 lines (full log: "* ]]
  [ "${lines[2]}" = "line 96" ]
  [ "${lines[6]}" = "line 100" ]
  [[ "${lines[7]}" == "--- end log: "* ]]
  [ "${#lines[@]}" -eq 8 ]
  log=${lines[7]#--- end log: }; log=${log% ---}
  [ "$(wc -l <"$log" | tr -d ' ')" -eq 100 ]
}

@test "quiet_run: QUIET_VERBOSE=1 streams the output" {
  QUIET_VERBOSE=1 run "$QUIET" "v" -- echo streamed
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "streamed" ]
  [[ "${lines[1]}" =~ ^✓\ v ]]
}

@test "quiet_run: usage error without the -- separator" {
  run "$QUIET" "x" echo hi
  [ "$status" -eq 2 ]
}

@test "quiet_run: sourcing defines run_step, runs nothing, leaves caller options alone" {
  run bash -c ". '$QUIET'; type run_step >/dev/null && echo defined; case \$- in *e*) echo errexit;; esac"
  [ "$status" -eq 0 ]
  [ "$output" = "defined" ]
}

@test "quiet_run: sourced run_step returns the step's code under the caller's set -e" {
  run bash -c "set -e; . '$QUIET'; rc=0; run_step one true; run_step two sh -c 'exit 4' || rc=\$?; echo rc=\$rc"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^✓\ one ]]
  [[ "${lines[1]}" =~ ^✗\ two ]]
  [ "${lines[${#lines[@]}-1]}" = "rc=4" ]
}

# --- push_ranges.sh ---

@test "push_ranges: new branch with origin/main uses origin/main..sha" {
  base=$(commit base); sha=$(commit feature)
  git -C "$REPO" update-ref refs/remotes/origin/main "$base"
  cd "$REPO"
  run "$RANGES" <<<"refs/heads/f $sha refs/heads/f $ZERO"
  [ "$status" -eq 0 ]
  [ "$output" = "origin/main..$sha" ]
}

@test "push_ranges: new branch without origin/main prints the bare sha" {
  sha=$(commit only)
  cd "$REPO"
  run "$RANGES" <<<"refs/heads/f $sha refs/heads/f $ZERO"
  [ "$status" -eq 0 ]
  [ "$output" = "$sha" ]
}

@test "push_ranges: an update prints remote..local" {
  old=$(commit one); new=$(commit two)
  cd "$REPO"
  run "$RANGES" <<<"refs/heads/main $new refs/heads/main $old"
  [ "$status" -eq 0 ]
  [ "$output" = "$old..$new" ]
}

@test "push_ranges: deletions and tags print nothing" {
  sha=$(commit one)
  cd "$REPO"
  run "$RANGES" <<<"(delete) $ZERO refs/heads/gone $sha
refs/tags/v1 $sha refs/tags/v1 $ZERO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "push_ranges: multiple lines give one range each, and an unknown remote sha falls back" {
  base=$(commit base); a=$(commit a); b=$(commit b)
  git -C "$REPO" update-ref refs/remotes/origin/main "$base"
  cd "$REPO"
  unknown=1111111111111111111111111111111111111111
  run "$RANGES" <<<"refs/heads/x $a refs/heads/x $base
refs/heads/y $b refs/heads/y $ZERO
refs/heads/z $b refs/heads/z $unknown"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$base..$a" ]
  [ "${lines[1]}" = "origin/main..$b" ]
  [ "${lines[2]}" = "origin/main..$b" ]
  [ "${#lines[@]}" -eq 3 ]
}

# --- hooks_check.sh ---

make_hooks() {
  mkdir -p "$REPO/.githooks"
  printf '#!/bin/sh\n' >"$REPO/.githooks/pre-commit"
  printf '#!/bin/sh\n' >"$REPO/.githooks/pre-push"
  chmod +x "$REPO/.githooks/pre-commit" "$REPO/.githooks/pre-push"
}

@test "hooks_check: relative and absolute .githooks are ok" {
  make_hooks
  git -C "$REPO" config core.hooksPath .githooks
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "hooks-check: ok" ]
  git -C "$REPO" config core.hooksPath "$REPO/.githooks"
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "hooks_check: a repointed hooksPath fails with the reason" {
  make_hooks
  git -C "$REPO" config core.hooksPath .git/hooks
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == "hooks-check: core.hooksPath is '.git/hooks'"* ]]
  git -C "$REPO" config --unset core.hooksPath
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == "hooks-check: core.hooksPath is unset"* ]]
}

@test "hooks_check: a missing or non-executable hook fails" {
  make_hooks
  git -C "$REPO" config core.hooksPath .githooks
  chmod -x "$REPO/.githooks/pre-push"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == "hooks-check: .githooks/pre-push is not executable"* ]]
  rm "$REPO/.githooks/pre-commit"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == "hooks-check: .githooks/pre-commit is missing"* ]]
}

@test "hooks_check: an LFS repo whose pre-push does not chain git lfs fails" {
  make_hooks
  git -C "$REPO" config core.hooksPath .githooks
  echo '*.sqlite filter=lfs diff=lfs merge=lfs -text' >"$REPO/.gitattributes"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git lfs pre-push"* ]]
  echo 'git lfs pre-push "$@"' >>"$REPO/.githooks/pre-push"
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
  cp "$DEVKIT/templates/githooks/pre-push" "$REPO/.githooks/pre-push"
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "hooks_check: --fix sets core.hooksPath to .githooks" {
  make_hooks
  git -C "$REPO" config core.hooksPath /somewhere/else
  run "$CHECK" --fix "$REPO"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "hooks-check: ok" ]
  [ "$(git -C "$REPO" config --get core.hooksPath)" = .githooks ]
}

@test "hooks_check: skipped under CI" {
  CI=true run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "hooks-check: skipped (CI)" ]
}

# --- templates (bodies in bin/hook_steps.sh) ---

@test "templates: both stay thin wrappers under 15 lines" {
  for hook in pre-commit pre-push; do
    [ "$(wc -l <"$DEVKIT/templates/githooks/$hook" | tr -d ' ')" -lt 15 ]
    grep -q "run_hook_steps $hook" "$DEVKIT/templates/githooks/$hook"
  done
}

@test "template pre-commit: runs every conf step in order with the vitest cap" {
  install_templates 'PRE_COMMIT_STEPS=("backend: static=ci-backend-static" "frontend: static=ci-frontend-static")'
  cd "$REPO"
  run .githooks/pre-commit
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^✓\ backend:\ static ]]
  [[ "${lines[1]}" =~ ^✓\ frontend:\ static ]]
  [ "${lines[2]}" = "✓ pre-commit passed" ]
  [ "$(cut -d' ' -f1 "$MAKE_LOG" | tr '\n' ' ')" = "ci-backend-static ci-frontend-static " ]
  grep -q 'VITEST_MAX_WORKERS=4' "$MAKE_LOG"
  [[ "$output" != *no-verify* ]]
}

@test "template pre-commit: stops at the first failing step and propagates its code" {
  install_templates 'PRE_COMMIT_STEPS=("one=ci-one" "two=ci-two" "three=ci-three")'
  cd "$REPO"
  FAIL_TARGET=ci-two run .githooks/pre-commit
  [ "$status" -eq 7 ]
  [ "$(cut -d' ' -f1 "$MAKE_LOG" | tr '\n' ' ')" = "ci-one ci-two " ]
  [[ "$output" == *"✗ two"* ]]
  [[ "$output" == *"running ci-two"* ]]
  [[ "$output" != *no-verify* ]]
}

@test "template pre-push: runs PRE_PUSH_STEPS for a branch push and nothing for a deletion" {
  install_templates 'PRE_PUSH_STEPS=("unit=ci-unit")'
  sha=$(commit one)
  cd "$REPO"
  run .githooks/pre-push origin url <<<"refs/heads/f $sha refs/heads/f $ZERO"
  [ "$status" -eq 0 ]
  [ "$(cut -d' ' -f1 "$MAKE_LOG")" = "ci-unit" ]
  : >"$MAKE_LOG"
  run .githooks/pre-push origin url <<<"(delete) $ZERO refs/heads/f $sha"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to check"* ]]
  [ ! -s "$MAKE_LOG" ]
}

@test "template pre-push: skips with a note when a required .env is missing, honours HOOK_ENV_FILE" {
  install_templates 'PRE_PUSH_STEPS=("unit=ci-unit")
ENV_REQUIRED_HOOKS="pre-push"'
  sha=$(commit one)
  cd "$REPO"
  run .githooks/pre-push origin url <<<"refs/heads/f $sha refs/heads/f $ZERO"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "pre-push: checks skipped, no env file at "* ]]
  [ ! -s "$MAKE_LOG" ]
  echo 'DATABASE_URL=postgres://stub' >"$TMP/main.env"
  HOOK_ENV_FILE=$TMP/main.env run .githooks/pre-push origin url <<<"refs/heads/f $sha refs/heads/f $ZERO"
  [ "$status" -eq 0 ]
  grep -q 'DATABASE_URL=postgres://stub' "$MAKE_LOG"
}

@test "template pre-push: an LFS repo chains git lfs pre-push with the hook's args and stdin" {
  install_templates 'PRE_PUSH_STEPS=()'
  echo '*.sqlite filter=lfs diff=lfs merge=lfs -text' >"$REPO/.gitattributes"
  real_git=$(command -v git)
  cat >"$BIN/git" <<GIT
#!/usr/bin/env bash
if [ "\$1" = lfs ]; then
  [ "\$2" = version ] && exit 0
  echo "lfs \$* stdin=\$(cat)" >>"$TMP/lfs.log"; exit 0
fi
exec "$real_git" "\$@"
GIT
  chmod +x "$BIN/git"
  sha=$(commit one)
  cd "$REPO"
  run .githooks/pre-push origin url <<<"(delete) $ZERO refs/heads/f $sha"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/lfs.log")" = "lfs lfs pre-push origin url stdin=(delete) $ZERO refs/heads/f $sha" ]
}
