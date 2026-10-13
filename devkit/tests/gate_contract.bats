#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# Contract tests for bin/local_gate.sh: the GATE/VERDICT output lines, the commit statuses it
# posts, and its cleanup. Everything is local: a bare "origin" repo, a clone standing in for the
# invoking checkout, and a fake `gh` on PATH. No network, no GitHub, no Docker.
#
# Fixture per test (see setup):
#   $ORIGIN  bare repo; refs/pull/<N>/head is created here with `git update-ref`
#   $ROOT    clone with the skeleton vendored at devkit/bin/local_gate.sh and an inert Makefile
#   $GH_LOG  one line per fake-gh invocation ("$*")
#   $CLEANUP_MARK  appended to by the plan's gate_cleanup()

SKELETON="$BATS_TEST_DIRNAME/../bin/local_gate.sh"
PR=7

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/gate.XXXXXX")
  ORIGIN=$TMP/origin.git
  ROOT=$TMP/clone
  BIN=$TMP/bin
  export GH_LOG=$TMP/gh.log
  export CLEANUP_MARK=$TMP/cleanup.mark
  export XDG_STATE_HOME=$TMP/state
  export GATE_LOCK=$TMP/gate.lock
  export PATH=$BIN:$PATH
  export FAKE_GH_API_FAIL=""
  export FAKE_GH_PR_INFO=""
  export FAKE_GH_IS_CROSS=false
  unset GATE_PLAN

  # Isolate git from the developer's global config (signing, hooks, identity).
  export GIT_CONFIG_GLOBAL=$TMP/gitconfig
  git config --file "$GIT_CONFIG_GLOBAL" user.name gate-test
  git config --file "$GIT_CONFIG_GLOBAL" user.email gate-test@local
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  mkdir -p "$BIN" "$XDG_STATE_HOME"
  write_fake_gh
  make_repos
}

teardown() {
  rm -rf "$TMP"
}

write_fake_gh() {
  cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh: logs every invocation; answers the fork check (`pr view --json isCrossRepository`)
# from FAKE_GH_IS_CROSS, exiting 1 when it is "error"; answers other `pr view` calls from
# FAKE_GH_PR_INFO; `api` fails when FAKE_GH_API_FAIL is 1 (every call) or equals the state=
# being posted.
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "pr view")
    if [[ " $* " == *" --json isCrossRepository "* ]]; then
      [ "$FAKE_GH_IS_CROSS" = error ] && exit 1
      printf '%s\n' "$FAKE_GH_IS_CROSS"
    else
      printf '%s\n' "$FAKE_GH_PR_INFO"
    fi
    ;;
  "api "*)
    state=""
    for a in "$@"; do case "$a" in state=*) state=${a#state=} ;; esac; done
    [ "$FAKE_GH_API_FAIL" = 1 ] && exit 1
    [ -n "$FAKE_GH_API_FAIL" ] && [ "$FAKE_GH_API_FAIL" = "$state" ] && exit 1
    ;;
esac
exit 0
EOF
  chmod +x "$BIN/gh"
}

make_repos() {
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$ROOT" 2>/dev/null
  git -C "$ROOT" checkout -q -b main

  mkdir -p "$ROOT/scripts/ci" "$ROOT/devkit/bin"
  cp "$SKELETON" "$ROOT/devkit/bin/local_gate.sh"
  # One-line recipes avoid tab-sensitivity in the heredoc.
  cat >"$ROOT/Makefile" <<'EOF'
ci-a: ; @echo ran-a
ci-fail: ; @echo ran-fail; exit 1
ci-hang: ; @echo started; sh -c 'echo $$$$ >"$$HANG_PID"; exec sleep 60'
ci-chatty: ; @for i in 1 2 3 4 5; do echo tick $$i; sleep 1; done
EOF
  cat >"$ROOT/scripts/ci/gate_plan.sh" <<'EOF'
GATE_SLUG=test/repo
GATE_STATE_NAME=test-gate
gate_cleanup() { echo cleanup-ran >>"$CLEANUP_MARK"; }
gate_plan() {
  if ! grep -qvE '\.md$' <<<"$CHANGED"; then nothing_to_run "docs only"; fi
  job a ci-a
  if changed '^bad/'; then job failing ci-fail; fi
  if changed '^hang/'; then job hang ci-hang; fi
  if changed '^chatty/'; then job chatty ci-chatty; fi
  skip b "not needed"
}
EOF
  printf 'line one\nline two\n' >"$ROOT/file.txt"
  echo '# readme' >"$ROOT/README.md"
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -q -m "initial"
  git -C "$ROOT" push -q -u origin main 2>/dev/null
}

# commit_on_branch <branch> <path> <content>: branch from main, commit, push. Sets BRANCH_SHA.
commit_on_branch() {
  local branch=$1 path=$2 content=$3
  git -C "$ROOT" checkout -q -b "$branch" main
  mkdir -p "$ROOT/$(dirname "$path")"
  printf '%s\n' "$content" >"$ROOT/$path"
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -q -m "change $path"
  git -C "$ROOT" push -q origin "$branch" 2>/dev/null
  BRANCH_SHA=$(git -C "$ROOT" rev-parse HEAD)
  git -C "$ROOT" checkout -q main
}

# make_pr <path> <content>: a PR branch plus the refs/pull/$PR/head GitHub would create.
make_pr() {
  commit_on_branch "pr-$PR" "$1" "$2"
  git -C "$ORIGIN" update-ref "refs/pull/$PR/head" "$BRANCH_SHA"
  HEAD_SHA=$BRANCH_SHA
}

main_sha() { git -C "$ROOT" rev-parse origin/main; }

run_gate() { run "$ROOT/devkit/bin/local_gate.sh" "$@"; }

has_line() { grep -qxF -- "$1" <<<"$output"; }
# Negations live in functions: a bare `!` in a bats test body does not fail the test (SC2314).
no_output_line_matching() { ! grep -q -- "$1" <<<"$output"; }
no_gh_call_matching() { [ ! -e "$GH_LOG" ] || ! grep -q -- "$1" "$GH_LOG"; }
ref_absent() { ! git -C "$ROOT" show-ref --verify --quiet "$1"; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }

# status_posted <state> [substring...]: a gh api call posting <state> on the PR head.
status_posted() {
  local state=$1 line
  shift
  line=$(grep -F "api repos/test/repo/statuses/$HEAD_SHA" "$GH_LOG" | grep -F "state=$state") || return 1
  [[ "$line" == *"context=local-gate"* ]] || return 1
  local s
  for s in "$@"; do [[ "$line" == *"$s"* ]] || return 1; done
}

@test "happy path: GATE lines, VERDICT PASS with current SHAs, statuses, cleanup" {
  make_pr src/app.txt "hello"
  run_gate "$PR"
  [ "$status" -eq 0 ]
  has_line "GATE pr=$PR head=$HEAD_SHA main=$(main_sha)"
  grep -qE '^GATE a PASS \([0-9]+s\)$' <<<"$output"
  has_line "GATE b SKIPPED (not needed)"
  has_line "VERDICT PASS head=$HEAD_SHA main=$(main_sha)"

  status_posted pending "Local gate running on main"
  status_posted success "Passed on main"
  # pending must precede success
  [ "$(grep -c 'state=' "$GH_LOG")" -eq 2 ]
  [[ "$(grep state= "$GH_LOG" | head -1)" == *"state=pending"* ]]

  [ "$(cat "$CLEANUP_MARK")" = cleanup-ran ]
  [ ! -e "$XDG_STATE_HOME/test-gate/wt-$PR" ]
  ref_absent "refs/gate/pr-$PR"
}

@test "docs-only PR: nothing_to_run short-circuits before any job" {
  make_pr docs/guide.md "# guide"
  run_gate "$PR"
  [ "$status" -eq 0 ]
  has_line "GATE all SKIPPED (docs only)"
  has_line "VERDICT PASS head=$HEAD_SHA main=$(main_sha)"
  no_output_line_matching '^GATE a '
  status_posted success "docs only; nothing to run"
}

@test "failing job: GATE FAIL with log path, VERDICT FAIL, failure status names the job" {
  make_pr bad/thing.txt "oops"
  run_gate "$PR"
  [ "$status" -eq 1 ]
  local log=$XDG_STATE_HOME/test-gate/logs/$PR/failing.log
  grep -qE '^GATE a PASS \([0-9]+s\)$' <<<"$output"
  has_line "GATE failing FAIL (log: $log)"
  has_line "VERDICT FAIL head=$HEAD_SHA main=$(main_sha)"
  status_posted failure "Failed: failing"
  [ -f "$log" ]
  grep -qx ran-fail "$log"
}

@test "merge conflict with main: GATE merge FAIL, VERDICT FAIL, failure status" {
  make_pr file.txt $'line one (pr)\nline two'
  commit_on_branch main-edit file.txt $'line one (main)\nline two'
  git -C "$ORIGIN" update-ref refs/heads/main "$BRANCH_SHA"
  run_gate "$PR"
  [ "$status" -eq 1 ]
  grep -q '^GATE merge FAIL (conflicts with main; log: ' <<<"$output"
  has_line "VERDICT FAIL head=$HEAD_SHA main=$BRANCH_SHA"
  status_posted failure "Conflicts with main"
  no_output_line_matching '^GATE a '
}

@test "missing pull ref: falls back to the branch when gh's headRefOid matches" {
  commit_on_branch feature src/app.txt "hello"
  HEAD_SHA=$BRANCH_SHA
  export FAKE_GH_PR_INFO=$'false\tfeature\t'"$BRANCH_SHA"
  run_gate "$PR"
  [ "$status" -eq 0 ]
  has_line "GATE note: pull/$PR/head missing; fetched branch feature @ $BRANCH_SHA"
  has_line "VERDICT PASS head=$BRANCH_SHA main=$(main_sha)"
  grep -q "^pr view $PR --repo test/repo --json headRefName,headRefOid,isCrossRepository" "$GH_LOG"
}

@test "missing pull ref: refuses the branch when gh's headRefOid differs" {
  commit_on_branch feature src/app.txt "hello"
  export FAKE_GH_PR_INFO=$'false\tfeature\t0000000000000000000000000000000000000000'
  run_gate "$PR"
  [ "$status" -eq 1 ]
  has_line "GATE fetch FAIL"
  has_line "VERDICT FAIL head= main="
  no_output_line_matching '^GATE pr='
  no_gh_call_matching '^api '
}

@test "--no-post: no gh api calls, verdict unchanged" {
  make_pr src/app.txt "hello"
  run_gate "$PR" --no-post
  [ "$status" -eq 0 ]
  has_line "VERDICT PASS head=$HEAD_SHA main=$(main_sha)"
  no_gh_call_matching '^api '
}

@test "usage: no args, non-numeric PR, and a missing plan all exit 2" {
  run_gate
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]

  run_gate abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]

  GATE_PLAN=/nonexistent run_gate "$PR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no plan at /nonexistent"* ]]

  GATE_SILENT_MINUTES=soon run_gate "$PR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"GATE_SILENT_MINUTES must be a number of minutes (got 'soon')"* ]]
}

@test "GATE_SLOTS: junk, zero and negative values are usage errors before any work" {
  local junk
  for junk in two 0 -1 1.5; do
    GATE_SLOTS=$junk run_gate "$PR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"GATE_SLOTS must be an integer >= 1 (got '$junk')"* ]]
  done
  no_gh_call_matching '.'
}

# 0.05 min = 3s. The OrbStack incident (2026-10-13): a job blocked forever, its log stopped growing.
@test "watchdog: a silent job is stopped, error status, cleanup runs, later jobs do not, exit 2" {
  make_pr hang/x.txt "zzz"
  export HANG_PID=$TMP/hang.pid
  GATE_SILENT_MINUTES=0.05 run_gate "$PR"
  [ "$status" -eq 2 ]
  local log=$XDG_STATE_HOME/test-gate/logs/$PR/hang.log
  grep -qE '^GATE a PASS \([0-9]+s\)$' <<<"$output"
  has_line "GATE hang WATCHDOG (silent for 0.05 min; log: $log)"
  has_line "VERDICT FAIL head=$HEAD_SHA main=$(main_sha)"
  no_output_line_matching '^GATE b '
  grep -qx started "$log"

  status_posted error "Job hang silent for 0.05 min"
  [ "$(grep -c 'state=error' "$GH_LOG")" -eq 1 ]   # not followed by an "interrupted" error
  pid_gone "$(cat "$HANG_PID")"                    # the whole process group, not just make
  [ "$(cat "$CLEANUP_MARK")" = cleanup-ran ]
  [ ! -e "$XDG_STATE_HOME/test-gate/wt-$PR" ]
  ref_absent "refs/gate/pr-$PR"
}

@test "watchdog: a slow job that keeps logging outlives the silence window and passes" {
  make_pr chatty/x.txt "zzz"
  GATE_SILENT_MINUTES=0.05 run_gate "$PR"
  [ "$status" -eq 0 ]
  grep -qE '^GATE chatty PASS \([0-9]+s\)$' <<<"$output"
  no_output_line_matching 'WATCHDOG'
  has_line "VERDICT PASS head=$HEAD_SHA main=$(main_sha)"
}

@test "interrupted gate: TERM mid-job stops the job's process group and posts error" {
  make_pr hang/x.txt "zzz"
  export HANG_PID=$TMP/hang.pid
  "$ROOT/devkit/bin/local_gate.sh" "$PR" >"$TMP/out" 2>&1 &
  local gate=$! _
  for _ in $(seq 50); do [ -s "$HANG_PID" ] && break; sleep 0.2; done
  [ -s "$HANG_PID" ]
  kill -TERM "$gate"
  wait "$gate" || true
  pid_gone "$(cat "$HANG_PID")"
  status_posted error "Local gate interrupted before a verdict"
  [ ! -e "$XDG_STATE_HOME/test-gate/wt-$PR" ]
}

@test "status posting retries three times before giving up (~30s of backoff)" {
  make_pr src/app.txt "hello"
  export FAKE_GH_API_FAIL=pending
  run_gate "$PR"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'state=pending' "$GH_LOG")" -eq 3 ]
  [[ "$output" == *"could not post local-gate=pending on $HEAD_SHA after 3 attempts"* ]]
  has_line "VERDICT PASS head=$HEAD_SHA main=$(main_sha)"
  status_posted success "Passed on main"
}

@test "lock: waits for another gate holding GATE_LOCK, then runs" {
  make_pr src/app.txt "hello"
  flock "$GATE_LOCK" sleep 3 >/dev/null 2>&1 &
  local holder=$!
  sleep 0.5
  run_gate "$PR"
  wait "$holder"
  [ "$status" -eq 0 ]
  has_line "GATE waiting for another repo's gate to finish"
  has_line "VERDICT PASS head=$HEAD_SHA main=$(main_sha)"
}

@test "slots: the default takes the plain GATE_LOCK path, never a numbered slot" {
  make_pr src/app.txt "hello"
  run_gate "$PR"
  [ "$status" -eq 0 ]
  has_line "GATE slot 1/1"
  [ -e "$GATE_LOCK" ]
  [ ! -e "$GATE_LOCK.1" ]
}

# hold_lock <path>: a stand-in gate holding <path> until release_lock; sets HOLDER. `flock -o`
# keeps the lock in flock itself, so killing its sleep releases it.
hold_lock() {
  flock -o "$1" sleep 60 >/dev/null 2>&1 &
  HOLDER=$!
  sleep 0.5
}
release_lock() { pkill -P "$1" sleep || true; wait "$1" 2>/dev/null || true; }

@test "slots: GATE_SLOTS=2 runs beside one busy gate, and a third waits for a slot to free" {
  make_pr src/app.txt "hello"
  hold_lock "$GATE_LOCK.1"
  local first=$HOLDER

  GATE_SLOTS=2 run_gate "$PR"
  [ "$status" -eq 0 ]
  has_line "GATE slot 2/2"
  no_output_line_matching '^GATE waiting'
  [ ! -e "$GATE_LOCK" ]

  hold_lock "$GATE_LOCK.2"
  local second=$HOLDER
  GATE_SLOTS=2 "$ROOT/devkit/bin/local_gate.sh" "$PR" >"$TMP/third.out" 2>&1 &
  local third=$!
  sleep 2
  grep -qxF "GATE waiting for another repo's gate to finish" "$TMP/third.out"
  kill -0 "$third"   # still blocked: both slots are held
  release_lock "$second"
  local rc=0
  wait "$third" || rc=$?
  release_lock "$first"
  output=$(cat "$TMP/third.out")
  [ "$rc" -eq 0 ]
  has_line "GATE slot 2/2"
  has_line "VERDICT PASS head=$HEAD_SHA main=$(main_sha)"
}

# refused_before_fetch: the fork-guard outcome. Nothing fetched, no state dir (so no worktree
# or logs), no status posted.
refused_before_fetch() {
  [ "$status" -eq 1 ]
  has_line "GATE fork FAIL (PR #$PR is from a fork; set GATE_ALLOW_FORKS=1 in the plan to gate forks deliberately)"
  has_line "VERDICT FAIL head= main="
  no_output_line_matching '^GATE pr='
  no_gh_call_matching '^api '
  [ ! -e "$XDG_STATE_HOME/test-gate" ]
  ref_absent "refs/gate/pr-$PR"
}

@test "fork PR: refused before fetch, no status, no worktree" {
  make_pr src/app.txt "hello"
  export FAKE_GH_IS_CROSS=true
  run_gate "$PR"
  refused_before_fetch
  grep -q "^pr view $PR --repo test/repo --json isCrossRepository" "$GH_LOG"
}

@test "fork check: a gh error fails closed like a fork" {
  make_pr src/app.txt "hello"
  export FAKE_GH_IS_CROSS=error
  run_gate "$PR"
  refused_before_fetch
}

@test "fork check: an empty answer fails closed like a fork" {
  make_pr src/app.txt "hello"
  export FAKE_GH_IS_CROSS=""
  run_gate "$PR"
  refused_before_fetch
}

@test "GATE_ALLOW_FORKS=1 in the plan: a fork PR is gated normally" {
  make_pr src/app.txt "hello"
  export FAKE_GH_IS_CROSS=true
  echo 'GATE_ALLOW_FORKS=1' >>"$ROOT/scripts/ci/gate_plan.sh"
  run_gate "$PR"
  [ "$status" -eq 0 ]
  has_line "VERDICT PASS head=$HEAD_SHA main=$(main_sha)"
  no_gh_call_matching '--json isCrossRepository'
}

@test "GATE_ALLOW_FORKS=1 in the environment does not bypass the fork check" {
  make_pr src/app.txt "hello"
  export FAKE_GH_IS_CROSS=true
  GATE_ALLOW_FORKS=1 run_gate "$PR"
  refused_before_fetch
}
