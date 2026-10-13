#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031,SC2016  # each @test is its own subshell by design; fakes and greps of the script text hold literal $
# Contract tests for bin/monthly_audit.sh. No network and no real devkit: DEVKIT_ROOT is a fake
# tree whose guards and fleet scripts are stubs that log their calls. Fakes on PATH:
#   gh      `api <path>` serves $FAKE_GH_DIR/<path without query>.json (404 when absent);
#           `repo clone o/r dir` copies $FIXTURES/<r>; `issue list -R o/r` serves
#           $FAKE_GH_DIR/issues/<r>.json; `issue create` / `pr create` are logged to $GH_LOG.
#   git     logs every call to $GIT_LOG; `ls-remote` answers $DEVKIT_MAIN_SHA.
#   claude  logs its args, prints $FAKE_CLAUDE_OUT.
#   make    fails the test if called: the audit parses Makefiles, it never runs repo code.

AUDIT="$BATS_TEST_DIRNAME/../bin/monthly_audit.sh"
MAIN_SHA=869778b000000000000000000000000000000000
OLD_SHA=34a6252000000000000000000000000000000000

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/audit.XXXXXX")
  TMP=$(cd "$TMP" && pwd -P)
  export DEVKIT_ROOT=$TMP/devkit
  export FAKE_GH_DIR=$TMP/api FIXTURES=$TMP/fixtures
  export GH_LOG=$TMP/gh.log GH_CALLS=$TMP/gh-calls.log GIT_LOG=$TMP/git.log GUARD_LOG=$TMP/guards.log
  export MAKE_LOG=$TMP/make.log CLAUDE_LOG=$TMP/claude.log FAKE_CLAUDE_OUT=$TMP/claude.out
  export DEVKIT_MAIN_SHA=$MAIN_SHA
  export XDG_STATE_HOME=$TMP/state XDG_CONFIG_HOME=$TMP/config
  export AUDIT_HOMELAB_RULES=$TMP/rules AUDIT_LEDGER_DIR=$TMP/ledgers AUDIT_MONTH=2026-11
  export PATH=$TMP/bin:$PATH
  unset AUDIT_FILE_ISSUES AUDIT_VM_URL AUDIT_NTFY_URL DEVKIT_GITHUB_DATA
  mkdir -p "$TMP/bin" "$FAKE_GH_DIR/issues" "$FIXTURES" "$AUDIT_HOMELAB_RULES" "$AUDIT_LEDGER_DIR"
  : >"$GH_LOG"; : >"$GH_CALLS"; : >"$GIT_LOG"; : >"$GUARD_LOG"; : >"$MAKE_LOG"; : >"$CLAUDE_LOG"
  fake_devkit
  fake_tools
  fixture_app
  mkdir -p "$FIXTURES/homelab/docs"
  llm_says '[]'
}

teardown() {
  rm -rf "$TMP"
}

fake_devkit() {
  mkdir -p "$DEVKIT_ROOT/bin" "$DEVKIT_ROOT/github" "$DEVKIT_ROOT/templates/githooks"
  printf '# devkit\n\n```make\ngate:  ## x\n\tdevkit/bin/local_gate.sh\ndevkit-check:\ntoolchain-check:\ndocs-check:\nworkflows-check:\nhooks-check:\n```\n' >"$DEVKIT_ROOT/README.md"
  local s
  for s in devkit-check.sh toolchain_check.sh docs_check.sh workflows_check.sh release_check.sh hooks_check.sh; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"$GUARD_LOG"\necho "%s: ok"\n' "$s" "$s" >"$DEVKIT_ROOT/bin/$s"
  done
  for s in throwaway_pg.sh boot_image.sh quiet_run.sh; do printf '#!/bin/sh\n' >"$DEVKIT_ROOT/bin/$s"; done
  chmod +x "$DEVKIT_ROOT"/bin/*
  printf 'print("dead-alert medium JobFailed missing-runbook")\nprint("dead_alert_audit: 1 findings over 1 alerts")\n' >"$DEVKIT_ROOT/bin/dead_alert_audit.py"
  printf '#!/usr/bin/env bash\necho "dry-run: labels app ok bug"\n' >"$DEVKIT_ROOT/github/labels_sync.sh"
  printf '#!/usr/bin/env bash\necho "dry-run: settings app ok"\n' >"$DEVKIT_ROOT/github/repo_settings.sh"
  chmod +x "$DEVKIT_ROOT"/github/*.sh
  printf '#!/bin/sh\necho template\n' >"$DEVKIT_ROOT/templates/githooks/pre-commit"
  cat >"$DEVKIT_ROOT/github/repos.json" <<'JSON'
{ "owner": "acme", "repos": { "app": {}, "other": {}, "homelab": {}, "devkit": {} } }
JSON
}

fake_tools() {
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$GH_CALLS"
case "$1 ${2:-}" in
  "repo clone")
    src=$FIXTURES/${3#*/}
    [ -d "$src" ] || { echo "fake gh: no fixture $3" >&2; exit 1; }
    cp -R "$src" "$4"; exit 0 ;;
  "issue list")
    shift 2; repo= jq_expr=
    while [ $# -gt 0 ]; do case "$1" in -R) repo=${2#*/}; shift ;; --jq) jq_expr=$2; shift ;; esac; shift; done
    f=$FAKE_GH_DIR/issues/$repo.json; [ -f "$f" ] || f=/dev/null
    { [ "$f" = /dev/null ] && echo '[]' || cat "$f"; } | jq -r "$jq_expr"; exit 0 ;;
  "issue create"|"pr create") # one log line per call: multi-line bodies are flattened
    args="${*:3}"; echo "$1 $2 ${args//$'\n'/ }" >>"$GH_LOG"; echo "https://github.com/acme/x/issues/1"; exit 0 ;;
  "pr list") echo 0; exit 0 ;;
  "api "*)
    shift; path= jq_expr= silent=0
    while [ $# -gt 0 ]; do case "$1" in --jq) jq_expr=$2; shift ;; --silent) silent=1 ;; -*) echo "fake gh: flag $1" >&2; exit 64 ;; *) path=${1%%\?*} ;; esac; shift; done
    f=$FAKE_GH_DIR/$path.json
    [ -f "$f" ] || { echo "HTTP 404: Not Found ($path)" >&2; exit 1; }
    [ "$silent" -eq 0 ] || exit 0
    if [ -n "$jq_expr" ]; then jq -r "$jq_expr" "$f"; else cat "$f"; fi; exit 0 ;;
esac
echo "fake gh: unsupported: $*" >&2; exit 64
SH
  cat >"$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$GIT_LOG"
case "$1" in
  ls-remote) printf '%s\trefs/heads/main\n' "$DEVKIT_MAIN_SHA" ;;
  -C) [ "$3" != rev-parse ] || echo "$DEVKIT_MAIN_SHA" ;;
esac
exit 0
SH
  cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$CLAUDE_LOG"
cat "$FAKE_CLAUDE_OUT"
SH
  printf '#!/bin/sh\necho "make $*" >>"$MAKE_LOG"\nexit 99\n' >"$TMP/bin/make"
  chmod +x "$TMP/bin/gh" "$TMP/bin/git" "$TMP/bin/claude" "$TMP/bin/make"
}

# app vendors devkit two revs behind; ci-quick reaches docs-check through `lint`.
fixture_app() {
  local d=$FIXTURES/app
  mkdir -p "$d/scripts/ci" "$d/.githooks" "$FAKE_GH_DIR/repos/acme/app/contents"
  echo "$OLD_SHA abcdef" >"$d/.devkit-rev"
  cat >"$d/Makefile" <<'MK'
ci-quick: devkit-check toolchain-check lint ## runs on every PR
	@echo done
lint: \
	docs-check
	ruff check .
gate:
devkit-check:   ## part of ci-quick
	devkit/bin/devkit-check.sh
toolchain-check:
docs-check:
workflows-check:
hooks-check:
with-test-pg:
	scripts/ci/with_test_pg.sh
MK
  printf '#!/bin/sh\n' >"$d/scripts/ci/with_test_pg.sh"
  printf '#!/bin/sh\n' >"$d/scripts/ci/gate_plan.sh"
  printf '#!/bin/sh\n' >"$d/scripts/ci/browser_smoke.sh"
  cp "$DEVKIT_ROOT/templates/githooks/pre-commit" "$d/.githooks/pre-commit"
  printf '# app\n\n## Convention deltas\n- browser_smoke.sh: needs the real Chrome profile.\n\n## Other\nwith_test_pg.sh is mentioned here, outside the section.\n' >"$d/AGENTS.md"
  echo '{}' >"$FAKE_GH_DIR/repos/acme/app/contents/.devkit-rev.json"
  jq -n --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[{commit: {committer: {date: $d}}}]' >"$FAKE_GH_DIR/repos/acme/app/commits.json"
}

llm_says() { # <result string>
  jq -n --arg r "$1" '{type: "result", is_error: false, result: $r}' >"$FAKE_CLAUDE_OUT"
}
open_issues() { # <repo> <title...>: open fleet-audit issues
  local repo=$1; shift
  printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0) | {title: ., state: "OPEN", closedAt: null})' \
    >"$FAKE_GH_DIR/issues/$repo.json"
}
summary() { cat "$XDG_STATE_HOME/devkit/audit/2026-11/summary.tsv"; }
# Negations live in functions: a bare `!` in a bats test body does not fail the test (SC2314).
lacks() { ! grep -q "$@"; }   # lacks <grep args...>: no line matches (reads stdin when no file)
filing() { cat "$XDG_STATE_HOME/devkit/audit/2026-11/raw/filing.txt"; }

TWO_FINDINGS='[{"title":"Wire docs-check into every ci-quick","repo":"devkit","size":"S","evidence":["app docs-check FAIL"],"root_cause":"r","proposed_fix":"f","acceptance":"a","why_structural":"w"},
              {"title":"Move with_test_pg into throwaway_pg","repo":"app","size":"L","evidence":["reinvent app"],"proposed_fix":"f"}]'

@test "kill switch: audit.off exits 0 with one line and touches nothing" {
  mkdir -p "$XDG_CONFIG_HOME/devkit"
  touch "$XDG_CONFIG_HOME/devkit/audit.off"
  run "$AUDIT" --file-issues 1
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "AUDIT skipped (off: "* ]]
  [ ! -s "$GH_CALLS" ] && [ ! -s "$GIT_LOG" ] && [ ! -s "$CLAUDE_LOG" ]
}

@test "dry-run: default repo selection audits the active vendoring repo and files nothing" {
  llm_says "$TWO_FINDINGS"
  run "$AUDIT" --file-issues 1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUDIT findings=2 filed=0 "* ]]
  [[ "$output" == *"AUDIT report=$XDG_STATE_HOME/devkit/audit/2026-11/report.md"* ]]
  [ ! -s "$GH_LOG" ]
  lacks push "$GIT_LOG"
  [ "$(filing | grep -c '^dry-run, would file')" -eq 2 ]
  summary | grep -q "^app	devkit-rev	FAIL	vendored 34a6252, devkit main 869778b"
  summary | lacks '^other	'
  [ ! -f "$XDG_STATE_HOME/devkit/audit/runs" ]
}

@test "guards: one reachable from ci-quick (directly or transitively) is skipped, the rest run" {
  run "$AUDIT" --repos app --llm 0
  [ "$status" -eq 0 ]
  summary | grep -q '^app	devkit-check	SKIP	already in ci-quick'
  summary | grep -q '^app	toolchain-check	SKIP	already in ci-quick'
  summary | grep -q '^app	docs-check	SKIP	already in ci-quick'
  summary | grep -q '^app	workflows-check	PASS'
  lacks -E '^(devkit-check|toolchain_check|docs_check)\.sh' "$GUARD_LOG"
  grep -q '^workflows_check.sh \.$' "$GUARD_LOG"
  grep -q '^hooks_check.sh --fix \.$' "$GUARD_LOG"
  [ ! -s "$MAKE_LOG" ]
}

@test "re-invention: flags scripts/ci/with_test_pg.sh as a local throwaway_pg; extension points and deltas are silent" {
  run "$AUDIT" --repos app --llm 0
  [ "$status" -eq 0 ]
  summary | grep -q '^app	reinvent	FAIL	scripts/ci/with_test_pg.sh local-copy bin/throwaway_pg.sh$'
  summary | grep -q '^app	reinvent	FAIL	Makefile:with-test-pg local-copy bin/throwaway_pg.sh$'
  summary | grep -q '^app	reinvent	INFO	silenced by AGENTS.md convention deltas: scripts/ci/browser_smoke.sh'
  summary | lacks 'gate_plan.sh'
  summary | lacks '\.githooks/pre-commit'
  jq -e 'any(.[]; .step == "reinvent" and (.detail | startswith("scripts/ci/with_test_pg.sh")))' \
    "$XDG_STATE_HOME/devkit/audit/2026-11/findings.json"
}

@test "filing: three open fleet-audit issues across the fleet means nothing is filed" {
  open_issues app "a" "b"
  open_issues other "c"
  llm_says "$TWO_FINDINGS"
  run "$AUDIT" --repos app --file-issues 1
  [ "$status" -eq 0 ]
  lacks '^issue create' "$GH_LOG"
  [ "$(filing | grep -c 'backlog full: 3 open')" -eq 2 ]
  [[ "$output" == *"filed=0 "* ]]
}

@test "filing: dedupes by exact title, labels S/M agent-ready, commits the report on audit/<month> only" {
  open_issues other "Move with_test_pg into throwaway_pg"
  llm_says "$TWO_FINDINGS"
  run "$AUDIT" --repos app --file-issues 1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^issue create' "$GH_LOG")" -eq 1 ]
  grep -q '^issue create -R acme/devkit -t Wire docs-check into every ci-quick -b .* -l fleet-audit -l agent-ready$' "$GH_LOG"
  filing | grep -q '^not filed (duplicate): Move with_test_pg into throwaway_pg'
  grep -q '^pr create -R acme/homelab --head audit/2026-11 ' "$GH_LOG"
  [ "$(grep -c push "$GIT_LOG")" -eq 1 ]
  grep -q 'push -q origin HEAD:refs/heads/audit/2026-11$' "$GIT_LOG"
  [[ "$output" == *"AUDIT findings=2 filed=1 "* ]]
  grep -qx 2026-11 "$XDG_STATE_HOME/devkit/audit/runs"
}

@test "filing: off by default for the first two runs, on from the third; AUDIT_FILE_ISSUES=0 wins" {
  llm_says "$TWO_FINDINGS"
  run "$AUDIT" --repos app
  [ "$status" -eq 0 ]
  lacks 'create' "$GH_LOG"
  printf '2026-09\n2026-10\n' >"$XDG_STATE_HOME/devkit/audit/runs"
  AUDIT_FILE_ISSUES=0 run "$AUDIT" --repos app --file-issues 1
  lacks 'create' "$GH_LOG"
  run "$AUDIT" --repos app
  [ "$status" -eq 0 ]
  grep -q '^issue create' "$GH_LOG"
}

@test "llm: an unparsable answer is recorded and the audit still completes" {
  llm_says "Here are my findings: none really."
  run "$AUDIT" --repos app --file-issues 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUDIT findings=0 filed=0 "* ]]
  grep -q 'LLM: unparsable' "$XDG_STATE_HOME/devkit/audit/2026-11/report.md"
  lacks '^issue create' "$GH_LOG"
  grep -qx -- '--max-turns' "$CLAUDE_LOG"
  grep -qx -- 'Read,Grep,Glob' "$CLAUDE_LOG"
}

@test "safety: no merge, no mutating gh api, every remote write goes through the dry-run guard" {
  local code
  code=$(grep -v '^[[:space:]]*#' "$AUDIT")
  lacks 'gh pr merge' <<<"$code"
  lacks -E 'gh api .*(-X|--method)' <<<"$code"
  lacks -E -- '--force|push -f' <<<"$code"
  # Every line that pushes, creates an issue or PR, or posts goes through remote_write ...
  [ "$(grep -E 'git .*push|gh (issue|pr) create|curl ' <<<"$code" | grep -vc 'remote_write ')" -eq 0 ]
  # ... the only push targets the audit branch ...
  [ "$(grep -cE 'git .*push' <<<"$code")" -eq 1 ]
  grep -E 'git .*push' <<<"$code" | grep -q 'HEAD:refs/heads/\$branch'
  grep -q 'branch=audit/\$MONTH' <<<"$code"
  # ... and remote_write runs nothing under --dry-run.
  awk '/^remote_write\(\)/,/^}/' "$AUDIT" | grep -q 'if \[ "\$DRY_RUN" -eq 1 \]; then'
}
