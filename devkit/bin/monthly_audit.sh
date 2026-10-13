#!/usr/bin/env bash
# Monthly fleet audit: keeps the standard true between PRs. Design: standardization
# phase4-audit-design.md. Deterministic code reads and writes; the LLM only reads and proposes;
# this script, not the LLM, files issues.
#
# Usage: bin/monthly_audit.sh [--repos a,b] [--report-dir <dir>] [--file-issues 0|1] [--llm 0|1]
#                             [--dry-run]
#   --repos        repos.json keys; default: every key with a `.devkit-rev` on GitHub and a commit
#                  on its default branch in the last 35 days. An explicit list skips both filters.
#   --report-dir   default ${XDG_STATE_HOME:-~/.local/state}/devkit/audit/<YYYY-MM>
#   --file-issues  default 0 until two runs are recorded in .../devkit/audit/runs, then 1.
#                  AUDIT_FILE_ISSUES=0 forces 0 whatever the flag says.
#   --llm          default 1: one read-only `claude -p` proposes <= 3 structural findings.
#   --dry-run      every remote write (issue, push, PR, ntfy) is printed, not run.
# Kill switch: ${XDG_CONFIG_HOME:-~/.config}/devkit/audit.off -> one line, exit 0.
#
# Phases:
#   1. Per repo, in a fresh shallow clone of the default branch (never a developer checkout):
#      the devkit guards NOT already reachable from the Makefile's `ci-quick` (transitive
#      prerequisites, or a recipe calling the script); `.devkit-rev` skew vs devkit main; the
#      metrics ratchet; the re-invention diff (memo §4). Guards run from THIS devkit checkout,
#      so the audit measures each repo against the current standard, not its vendored copy.
#      The repo's own code never runs: Makefiles are parsed, not executed.
#   2. Fleet: labels_sync/repo_settings --dry-run, dead_alert_audit.py, gate ledger digest.
#   3. report.md (+ summary.tsv, findings.json = FAIL/ERROR rows, raw/ step outputs).
#   4. LLM proposals; 5. issue filing; 6. report PR to homelab docs/audits/fleet-<YYYY-MM>.md.
#
# Remote writes go only through remote_write() (dry-run guard). The only push is the report
# branch `audit/<YYYY-MM>`; nothing merges. tests/monthly_audit_contract.bats asserts both.
# A rerun in the same month fails at that push (branch exists) instead of overwriting it.
#
# Env: DEVKIT_ROOT (devkit checkout; default this script's), DEVKIT_GITHUB_DATA (repos.json,
# labels.json dir), AUDIT_HOMELAB_RULES (vmalert rules dir), AUDIT_VM_URL (live dead-alert pass;
# unset = static only), AUDIT_LEDGER_DIR (default ~/.local/state; reads */*-gate/ledger.tsv),
# AUDIT_RATCHET_SNAPSHOT (repo-relative, default docs/metrics/snapshot.json), AUDIT_REPORT_REPO
# (default homelab), AUDIT_NTFY_URL (full topic URL; unset = no post), AUDIT_MONTH (YYYY-MM).
#
# Output: progress on stderr; stdout ends with `AUDIT report=<path>` and
# `AUDIT findings=<llm findings> filed=<issues filed> deterministic=<FAIL+ERROR rows>`.
# Exit 0 audit ran (findings or not), 1 missing tool or unreadable fleet data, 2 usage.
set -uo pipefail # no -e: a failing step is a finding, never an abort

usage() {
  echo "usage: monthly_audit.sh [--repos a,b] [--report-dir <dir>] [--file-issues 0|1] [--llm 0|1] [--dry-run]" >&2
  exit 2
}
log() { echo "monthly_audit: $*" >&2; }
die() { log "$*"; exit 1; }

REPOS_ARG=
REPORT_DIR=
FILE_ISSUES=
LLM=1
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repos) [ $# -ge 2 ] || usage; REPOS_ARG=$2; shift ;;
    --report-dir) [ $# -ge 2 ] || usage; REPORT_DIR=$2; shift ;;
    --file-issues) [ $# -ge 2 ] || usage; case "$2" in 0|1) FILE_ISSUES=$2 ;; *) usage ;; esac; shift ;;
    --llm) [ $# -ge 2 ] || usage; case "$2" in 0|1) LLM=$2 ;; *) usage ;; esac; shift ;;
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
  esac
  shift
done

OFF_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/devkit/audit.off
if [ -e "$OFF_FILE" ]; then
  echo "AUDIT skipped (off: $OFF_FILE)"
  exit 0
fi

HERE=$(cd "$(dirname "$0")" && pwd)
DEVKIT_ROOT=${DEVKIT_ROOT:-$(cd "$HERE/.." && pwd)}
DATA=${DEVKIT_GITHUB_DATA:-$DEVKIT_ROOT/github}
REPOS_FILE=$DATA/repos.json
MONTH=${AUDIT_MONTH:-$(date +%Y-%m)}
case "$MONTH" in [0-9][0-9][0-9][0-9]-[0-1][0-9]) ;; *) log "AUDIT_MONTH must be YYYY-MM: $MONTH"; usage ;; esac
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/devkit/audit
RUNS_FILE=$STATE/runs
REPORT_DIR=${REPORT_DIR:-$STATE/$MONTH}
REPORT_REPO=${AUDIT_REPORT_REPO:-homelab}
RULES_DIR=${AUDIT_HOMELAB_RULES:-$HOME/projects/homelab/stacks/homeinfra/vmalert/rules}
LEDGER_DIR=${AUDIT_LEDGER_DIR:-$HOME/.local/state}
RATCHET_SNAPSHOT=${AUDIT_RATCHET_SNAPSHOT:-docs/metrics/snapshot.json}
# Issues are filed only while fewer than this many fleet-audit issues are open (memo §7a).
BACKLOG_CAP=3

for tool in jq gh git python3; do
  command -v "$tool" >/dev/null || die "$tool not found (brew install $tool)"
done
[ "$LLM" -eq 0 ] || command -v claude >/dev/null || die "claude not found (install Claude Code, or pass --llm 0)"
[ -f "$REPOS_FILE" ] || die "$REPOS_FILE missing"
OWNER=$(jq -er '.owner' "$REPOS_FILE") || die "$REPOS_FILE: no owner"

if [ -z "$FILE_ISSUES" ]; then
  runs=0
  [ ! -f "$RUNS_FILE" ] || runs=$(sort -u "$RUNS_FILE" | grep -c .)
  if [ "$runs" -ge 2 ]; then FILE_ISSUES=1; else FILE_ISSUES=0; fi
fi
[ "${AUDIT_FILE_ISSUES:-}" != 0 ] || FILE_ISSUES=0

WORK=$REPORT_DIR/work
RAW=$REPORT_DIR/raw
SUMMARY=$REPORT_DIR/summary.tsv
REPORT=$REPORT_DIR/report.md
FINDINGS=$REPORT_DIR/findings.json
LLM_FINDINGS=$REPORT_DIR/llm_findings.json
FILED_LOG=$RAW/filing.txt
mkdir -p "$REPORT_DIR" || die "cannot create $REPORT_DIR"
# Only the subdirectories this script owns are reset; a rerun replaces the month's results.
rm -rf "$WORK" "$RAW"
mkdir -p "$WORK" "$RAW"
: >"$SUMMARY"
: >"$FILED_LOG"
rm -f "$LLM_FINDINGS"
trap 'rm -rf "$WORK"' EXIT
log "month=$MONTH report-dir=$REPORT_DIR file-issues=$FILE_ISSUES llm=$LLM dry-run=$DRY_RUN"

# The single choke point for anything that changes state outside this machine.
remote_write() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: would run: $1 $2 $3"
    return 0
  fi
  "$@"
}

record() { # <scope> <step> <PASS|FAIL|SKIP|INFO|ERROR> <detail>
  local detail
  detail=$(printf '%s' "$4" | tr '\t\n' '  ')
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$detail" >>"$SUMMARY"
}

first_lines() { # <file> -> up to 3 non-empty lines joined by " | "
  grep -v '^[[:space:]]*$' "$1" | head -3 | awk 'NR > 1 { printf " | " } { printf "%s", $0 }'
}

resolve_repo() { # <name> -> repos.json key (case-insensitive, optional owner/ prefix); 1 if unknown
  local key
  key=$(jq -r --arg r "${1#"$OWNER"/}" '.repos | keys_unsorted[] | select(ascii_downcase == ($r | ascii_downcase))' "$REPOS_FILE")
  [ -n "$key" ] || return 1
  echo "$key"
}

# --- repo selection ------------------------------------------------------------------------

select_repos() {
  local r cutoff last err
  if [ -n "$REPOS_ARG" ]; then
    for r in $(printf '%s' "$REPOS_ARG" | tr ',' ' '); do
      resolve_repo "$r" || { log "--repos: $r is not in $REPOS_FILE"; exit 2; }
    done
    return
  fi
  cutoff=$(jq -rn 'now - 35 * 86400 | todate')
  for r in $(jq -r '.repos | keys_unsorted[]' "$REPOS_FILE"); do
    if ! err=$(gh api "repos/$OWNER/$r/contents/.devkit-rev" --silent 2>&1); then
      case "$err" in
        *404*) log "$r: no .devkit-rev, not vendoring devkit" ;;
        *) record "$r" select ERROR "checking .devkit-rev failed: $err" ;;
      esac
      continue
    fi
    last=$(gh api "repos/$OWNER/$r/commits?per_page=1" --jq '.[0].commit.committer.date' 2>/dev/null)
    if [ -z "$last" ]; then
      record "$r" select ERROR "could not read the latest default-branch commit"
      continue
    fi
    if [[ "$last" < "$cutoff" ]]; then
      record "$r" select SKIP "inactive: last default-branch commit $last"
      continue
    fi
    echo "$r"
  done
}

# --- per-repo checks -----------------------------------------------------------------------

# Targets reachable from ci-quick (prerequisites, transitively) one per line, then every recipe
# line of those targets prefixed "RECIPE ". Comments and `\` continuations are understood;
# `include`d makefiles and variables are not expanded (no repo code runs).
ci_quick_closure() { # <Makefile>
  awk '
    {
      line = $0
      while (line ~ /\\$/ && (getline nxt) > 0) line = substr(line, 1, length(line) - 1) " " nxt
    }
    line ~ /^\t/ { for (i = 1; i <= ncur; i++) recipe[cur[i]] = recipe[cur[i]] "\n" line; next }
    line ~ /^[^\t#=]+:([^=]|$)/ {
      sub(/#.*/, "", line)
      split(line, parts, ":")
      targets = parts[1]
      deps = substr(line, length(targets) + 2)
      sub(/;.*/, "", deps); gsub(/\|/, " ", deps)
      ncur = split(targets, cur, " ")
      for (i = 1; i <= ncur; i++) prereq[cur[i]] = prereq[cur[i]] " " deps
      next
    }
    /^[^[:space:]]/ { ncur = 0 }
    END {
      if (!("ci-quick" in prereq)) exit
      q[1] = "ci-quick"; seen["ci-quick"] = 1; head = 1; tail = 1
      while (head <= tail) {
        t = q[head++]; print t
        n = split(prereq[t], ds, " ")
        for (i = 1; i <= n; i++) if (!(ds[i] in seen)) { seen[ds[i]] = 1; q[++tail] = ds[i] }
      }
      for (t in seen) if (t in recipe) { m = split(recipe[t], rs, "\n"); for (i = 1; i <= m; i++) if (rs[i] != "") print "RECIPE " rs[i] }
    }' "$1"
}

makefile_targets() { # <Makefile> -> every explicit target name
  awk '/^[^\t#=.%][^\t#=%]*:([^=]|$)/ { sub(/:.*/, ""); n = split($0, ts, " "); for (i = 1; i <= n; i++) print ts[i] }' "$1" | sort -u
}

# The canonical targets are the ones README.md's vendoring snippet tells every repo to add.
canonical_targets() {
  awk '/^```make/ { inb = 1; next } inb && /^```/ { exit } inb && /^[a-z][a-z-]*:/ { sub(/:.*/, ""); print }' "$DEVKIT_ROOT/README.md"
}

# A repo file that copies a devkit capability under its own name. Each alias is a copy the
# 2026-10-13 scan found (memo §4); extend this list when the audit misses one.
devkit_alias() { # <basename> -> devkit path
  case "$1" in
    with_test_pg.sh) echo bin/throwaway_pg.sh ;;
    smoke_image.sh) echo bin/boot_image.sh ;;
    _quiet_lib.sh) echo bin/quiet_run.sh ;;
    *) return 1 ;;
  esac
}

nearest_devkit() { # <basename> -> devkit path with the same name or a known alias; 1 if none
  if [ -f "$DEVKIT_ROOT/bin/$1" ]; then echo "bin/$1"
  elif [ -f "$DEVKIT_ROOT/templates/githooks/$1" ]; then echo "templates/githooks/$1"
  else devkit_alias "$1"
  fi
}

# AGENTS.md's "Convention deltas" section: naming a file there states why it is local, which
# silences its re-invention line (PLAN.md:261).
convention_deltas() { # <repo dir>
  [ -f "$1/AGENTS.md" ] || return 0
  awk 'tolower($0) ~ /^#+ .*convention deltas/ { on = 1; next } on && /^#/ { exit } on' "$1/AGENTS.md"
}

reinvent() { # <repo> <dir>
  local repo=$1 dir=$2 deltas f b near targets t line
  deltas=$(convention_deltas "$dir")
  emit() { # <path> <kind> <nearest|->
    line="reinvent $repo $1 $2 $3"
    echo "$line" >>"$RAW/$repo.reinvent.txt"
    if [ -n "$deltas" ] && printf '%s' "$deltas" | grep -qF "$(basename "$1")"; then
      record "$repo" reinvent INFO "silenced by AGENTS.md convention deltas: $1 $2"
    else
      record "$repo" reinvent FAIL "$1 $2 $3"
    fi
  }
  : >"$RAW/$repo.reinvent.txt"

  for f in "$dir"/scripts/ci/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    case "$b" in gate_plan.sh|hooks.conf|docs_rules.sh|docs_oversize.txt) continue ;; esac # extension points
    if near=$(nearest_devkit "$b"); then emit "scripts/ci/$b" local-copy "$near"
    else emit "scripts/ci/$b" repo-only -
    fi
  done

  for f in "$dir"/.githooks/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if [ -f "$DEVKIT_ROOT/templates/githooks/$b" ]; then
      cmp -s "$f" "$DEVKIT_ROOT/templates/githooks/$b" || emit ".githooks/$b" hook-differs "templates/githooks/$b"
    elif near=$(nearest_devkit "$b"); then emit ".githooks/$b" local-copy "$near"
    else emit ".githooks/$b" extra-hook -
    fi
  done

  if [ -f "$dir/Makefile" ]; then
    targets=$(makefile_targets "$dir/Makefile")
    for t in $(canonical_targets) ci-quick; do
      [ "$t" != release-check ] || [ -f "$dir/Dockerfile" ] || continue
      printf '%s\n' "$targets" | grep -qx "$t" || emit "Makefile:$t" missing-target -
    done
    for t in $targets; do
      if near=$(devkit_alias "$(printf '%s' "$t" | tr - _).sh"); then emit "Makefile:$t" local-copy "$near"; fi
    done
  else
    emit Makefile missing -
  fi

  for f in "$dir"/.github/workflows/*.yml "$dir"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    if grep -q 'pull_request' "$f" && ! grep -qF "$OWNER/devkit/.github/workflows/quick-check.yml" "$f"; then
      emit ".github/workflows/$(basename "$f")" pr-workflow templates/workflows/quick-check-caller.yml
    fi
  done
}

# Guard target -> script. A guard reachable from ci-quick already runs on every PR; skip it.
GUARDS="devkit-check:devkit-check.sh toolchain-check:toolchain_check.sh docs-check:docs_check.sh workflows-check:workflows_check.sh release-check:release_check.sh hooks-check:hooks_check.sh"

run_guards() { # <repo> <dir>
  local repo=$1 dir=$2 closure pair target script out rc
  closure=
  if [ -f "$dir/Makefile" ]; then closure=$(ci_quick_closure "$dir/Makefile"); fi
  [ -n "$closure" ] || record "$repo" ci-quick FAIL "no ci-quick target in Makefile; every guard runs"
  for pair in $GUARDS; do
    target=${pair%%:*}
    script=${pair#*:}
    if printf '%s\n' "$closure" | grep -qx "$target" \
      || printf '%s\n' "$closure" | grep '^RECIPE ' | grep -qF "$script"; then
      record "$repo" "$target" SKIP "already in ci-quick"
      continue
    fi
    if [ "$target" = devkit-check ] && [ ! -f "$dir/.devkit-rev" ]; then
      record "$repo" "$target" SKIP "no .devkit-rev"
      continue
    fi
    out=$RAW/$repo.$target.txt
    log "$repo: $target"
    case "$target" in
      devkit-check) (cd "$dir" && "$DEVKIT_ROOT/bin/$script") >"$out" 2>&1 ;;
      # The clone is throwaway, so --fix only sets its hooksPath; what is left is whether the
      # tracked hooks exist, are executable and chain LFS.
      hooks-check) (cd "$dir" && "$DEVKIT_ROOT/bin/$script" --fix .) >"$out" 2>&1 ;;
      *) (cd "$dir" && "$DEVKIT_ROOT/bin/$script" .) >"$out" 2>&1 ;;
    esac
    rc=$?
    if [ "$rc" -eq 0 ]; then record "$repo" "$target" PASS "$(tail -1 "$out")"
    else record "$repo" "$target" FAIL "exit $rc: $(first_lines "$out")"
    fi
  done
}

check_skew() { # <repo> <dir>
  local repo=$1 dir=$2 rev
  if [ ! -f "$dir/.devkit-rev" ]; then record "$repo" devkit-rev SKIP "not vendored"; return; fi
  read -r rev _ <"$dir/.devkit-rev"
  echo "$rev" >>"$RAW/devkit-revs.txt"
  if [ -z "$DEVKIT_MAIN" ]; then record "$repo" devkit-rev ERROR "vendored ${rev:0:7}; devkit main unknown"
  elif [ "$rev" = "$DEVKIT_MAIN" ]; then record "$repo" devkit-rev PASS "${rev:0:7} = devkit main"
  else record "$repo" devkit-rev FAIL "vendored ${rev:0:7}, devkit main ${DEVKIT_MAIN:0:7}"
  fi
}

check_ratchet() { # <repo> <dir>
  local repo=$1 dir=$2 out changes rebaselines since
  if [ ! -f "$dir/docs/metrics/ratchet.json" ]; then record "$repo" ratchet SKIP "no docs/metrics/ratchet.json"; return; fi
  if [ -f "$dir/$RATCHET_SNAPSHOT" ]; then
    out=$RAW/$repo.ratchet.txt
    if python3 -I "$DEVKIT_ROOT/bin/metrics_ratchet.py" check --snapshot "$dir/$RATCHET_SNAPSHOT" \
      --bounds "$dir/docs/metrics/ratchet.json" >"$out" 2>&1; then
      record "$repo" ratchet PASS "$(tail -1 "$out")"
    else
      record "$repo" ratchet FAIL "$(first_lines "$out")"
    fi
  else
    record "$repo" ratchet SKIP "no committed snapshot at $RATCHET_SNAPSHOT"
  fi
  # The gate sees one PR at a time; only a monthly view shows bounds drifting looser.
  since=$MONTH-01T00:00:00Z
  changes=$(gh api "repos/$OWNER/$repo/commits?path=docs/metrics/ratchet.json&since=$since" --jq 'length' 2>/dev/null) || changes=unknown
  rebaselines=$(gh pr list -R "$OWNER/$repo" --label metrics-rebaseline --state merged \
    --search "merged:>=$MONTH-01" --json number --jq 'length' 2>/dev/null) || rebaselines=unknown
  if [ "$rebaselines" = 0 ]; then
    record "$repo" ratchet-history INFO "ratchet.json commits this month: $changes; no metrics-rebaseline PRs"
  else
    record "$repo" ratchet-history FAIL "ratchet.json commits this month: $changes; metrics-rebaseline PRs merged: $rebaselines"
  fi
}

audit_repo() { # <repo>
  local repo=$1 dir=$WORK/$1
  log "$repo: cloning $OWNER/$repo"
  if ! gh repo clone "$OWNER/$repo" "$dir" -- --depth 1 --quiet >"$RAW/$repo.clone.txt" 2>&1; then
    record "$repo" clone ERROR "$(first_lines "$RAW/$repo.clone.txt")"
    return
  fi
  run_guards "$repo" "$dir"
  check_skew "$repo" "$dir"
  check_ratchet "$repo" "$dir"
  reinvent "$repo" "$dir"
  rm -rf "$dir"
}

# --- fleet checks --------------------------------------------------------------------------

fleet_tool() { # <step> <ok-line regex> <cmd...>: one FAIL row per drift line
  local step=$1 ok=$2 out=$RAW/fleet.$1.txt rc line
  shift 2
  log "fleet: $step"
  "$@" >"$out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then record fleet "$step" ERROR "exit $rc: $(first_lines "$out")"; return; fi
  grep -Ev "$ok" "$out" | while IFS= read -r line; do
    [ -n "$line" ] && record fleet "$step" FAIL "$line"
  done
  grep -Evq "$ok" "$out" || record fleet "$step" PASS "no drift"
}

dead_alerts() {
  local out=$RAW/fleet.dead-alerts.txt rc args
  if [ ! -d "$RULES_DIR" ]; then record fleet dead-alerts ERROR "rules dir missing: $RULES_DIR (set AUDIT_HOMELAB_RULES)"; return; fi
  args=(--rules "$RULES_DIR" --runbook-required)
  [ -z "${AUDIT_VM_URL:-}" ] || args+=(--vm-url "$AUDIT_VM_URL")
  log "fleet: dead-alerts"
  python3 -I "$DEVKIT_ROOT/bin/dead_alert_audit.py" "${args[@]}" >"$out" 2>"$RAW/fleet.dead-alerts.stderr"
  rc=$?
  if [ "$rc" -ne 0 ]; then record fleet dead-alerts ERROR "exit $rc: $(first_lines "$RAW/fleet.dead-alerts.stderr")"; return; fi
  grep '^dead-alert ' "$out" | while IFS= read -r line; do record fleet dead-alerts FAIL "${line#dead-alert }"; done
  if [ -n "${AUDIT_VM_URL:-}" ]; then record fleet dead-alerts INFO "$(tail -1 "$out") (live pass)"
  else record fleet dead-alerts INFO "$(tail -1 "$out"); static only, AUDIT_VM_URL unset"
  fi
}

# Gate ledgers: rows and PRs this month per repo. The schema is recorded because the ledgers
# disagree on it, which is what blocks actual-vs-estimate metrics today (memo §6).
ledgers() {
  local f name key header prcol rows prs schemas=$RAW/ledger-schemas.txt n
  : >"$schemas"
  for f in "$LEDGER_DIR"/*-gate/ledger.tsv; do
    [ -f "$f" ] || continue
    name=$(basename "$(dirname "$f")"); name=${name%-gate}
    key=$(resolve_repo "$name") && name=$key # repos.json casing (Orbit)
    header=$(head -1 "$f")
    case "$header" in
      date*) prcol=$(printf '%s\n' "$header" | awk -F'\t' '{ for (i = 1; i <= NF; i++) if ($i == "pr") print i }') ;;
      *) header="(no header)"; prcol= ;;
    esac
    echo "$header" >>"$schemas"
    rows=$(awk -F'\t' -v m="$MONTH" 'index($1, m) == 1' "$f" | grep -c .)
    if [ -n "$prcol" ]; then
      prs=$(awk -F'\t' -v m="$MONTH" -v c="$prcol" 'index($1, m) == 1 && $c != "-" && $c != ""' "$f" | grep -c .)
    else
      prs="? (no pr column)"
    fi
    record "$name" ledger INFO "rows this month: $rows; with a PR: $prs; schema: $(printf '%s' "$header" | tr '\t' ',')"
  done
  n=$(sort -u "$schemas" | grep -c .)
  if [ "$n" -eq 0 ]; then record fleet ledgers INFO "no ledgers under $LEDGER_DIR/*-gate/"
  elif [ "$n" -gt 1 ]; then record fleet ledgers FAIL "gate ledgers use $n different schemas"
  else record fleet ledgers PASS "one ledger schema"
  fi
}

# --- report --------------------------------------------------------------------------------

render_summary() { # summary.tsv -> markdown, one section per scope in first-seen order
  awk -F'\t' '
    { if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 }
      gsub(/\|/, "\\|", $4); rows[$1] = rows[$1] "| " $2 " | " $3 " | " $4 " |\n" }
    END { for (i = 1; i <= n; i++) printf "## %s\n\n| step | status | detail |\n|---|---|---|\n%s\n", order[i], rows[order[i]] }
  ' "$SUMMARY"
}

write_report() {
  local devkit_head
  devkit_head=$(git -C "$DEVKIT_ROOT" rev-parse HEAD 2>/dev/null) || devkit_head=unknown
  {
    echo "# Fleet audit $MONTH"
    echo
    echo "Generated by devkit \`bin/monthly_audit.sh\` at devkit ${devkit_head:0:7} (devkit main ${DEVKIT_MAIN:0:7})."
    echo "Repos: ${AUDITED:-none}. Deterministic findings (FAIL or ERROR): $(det_count). Raw outputs: \`$RAW\`."
    echo
    render_summary
  } >"$REPORT"
}

det_count() { awk -F'\t' '$3 == "FAIL" || $3 == "ERROR"' "$SUMMARY" | grep -c .; }

write_findings_json() {
  jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {scope: .[0], step: .[1], status: .[2], detail: .[3]})
            | map(select(.status == "FAIL" or .status == "ERROR"))' "$SUMMARY" >"$FINDINGS"
}

# --- issues and LLM ------------------------------------------------------------------------

ISSUES_TSV=$RAW/fleet-audit-issues.tsv
ISSUES_KNOWN=1
# Open and recently closed (183 days) fleet-audit issues: the dedupe set and the LLM's
# "already filed" list. One unreadable repo makes the backlog unknown, so nothing is filed.
load_issues() {
  local r
  : >"$ISSUES_TSV"
  for r in $(jq -r '.repos | keys_unsorted[]' "$REPOS_FILE"); do
    gh issue list -R "$OWNER/$r" --label fleet-audit --state all --limit 200 --json title,state,closedAt \
      --jq '.[] | select(.state == "OPEN" or ((.closedAt // "") != "" and (.closedAt | fromdateiso8601) > (now - 183 * 86400)))
            | [.state, .title] | @tsv' 2>"$RAW/issues.$r.stderr" \
      | sed "s|^|$r	|" >>"$ISSUES_TSV" || {
        ISSUES_KNOWN=0
        log "listing fleet-audit issues in $r failed: $(first_lines "$RAW/issues.$r.stderr")"
      }
  done
}

LLM_STATUS="not run (--llm 0)"
run_llm() {
  local prompt result keys already rc
  keys=$(jq -r '.repos | keys_unsorted | join(", ")' "$REPOS_FILE")
  already=$(cut -f3 "$ISSUES_TSV" | sed 's/^/- /')
  prompt="You are reviewing a monthly audit of the ${OWNER} app fleet against its shared delivery standard (devkit).
You are read-only: do not modify any file. The report below is deterministic output; raw step outputs are in ./raw.

Propose AT MOST 3 structural findings. Structural means one fix removes copies or a cause shared across repos;
rank by how many copies or repos the fix removes. One-off nits are out. Every finding must cite a report line
or a file:line as evidence. A fleet-wide fix belongs to repo \"devkit\".

Do not repeat any of these existing fleet-audit issues:
${already:-(none)}

Reply with ONLY a JSON array, no prose and no code fence:
[{\"title\": \"<imperative sentence>\", \"repo\": \"<one of: ${keys}>\", \"size\": \"S|M|L\",
  \"evidence\": [\"<report line or file:line>\"], \"root_cause\": \"...\", \"proposed_fix\": \"...\",
  \"acceptance\": \"...\", \"why_structural\": \"...\"}]

$(cat "$REPORT")"
  log "llm: claude -p (opus, max 3 turns, max \$2)"
  (cd "$REPORT_DIR" && claude -p "$prompt" --output-format json --model opus --max-turns 3 --max-budget-usd 2 \
    --allowedTools "Read,Grep,Glob" --disallowedTools "Bash,Edit,Write,NotebookEdit" \
    </dev/null >"$RAW/llm.json" 2>"$RAW/llm.stderr")
  rc=$?
  if [ "$rc" -ne 0 ]; then LLM_STATUS="failed (exit $rc): $(first_lines "$RAW/llm.stderr")"; return; fi
  # A model that wraps the array in a code fence anyway is still understood.
  result=$(jq -r '.result // empty' "$RAW/llm.json" 2>/dev/null | sed '/^[[:space:]]*```/d')
  if printf '%s' "$result" | jq -e 'type == "array" and all(.[]; type == "object"
        and (.title | type == "string" and length > 0) and (.repo | type == "string")
        and ((.size // "") | tostring | test("^[SML]$")))' >/dev/null 2>&1; then
    printf '%s' "$result" | jq '.[:3]' >"$LLM_FINDINGS"
    LLM_STATUS="ok ($(jq length "$LLM_FINDINGS") findings)"
  else
    LLM_STATUS="unparsable (see raw/llm.json)"
  fi
  log "llm: $LLM_STATUS"
}

issue_body() { # <index>
  jq -r --argjson i "$1" --arg month "$MONTH" '.[$i] |
    def lines: if type == "array" then map("- " + tostring) | join("\n") else "- " + tostring end;
    "## Problem\n\(.title)\n\nEvidence:\n\((.evidence // "-") | lines)\n\n## Root cause\n\(.root_cause // "-")\n\n" +
    "## Proposed fix\n\(.proposed_fix // .fix // "-")\n\n## Acceptance criteria\n\(.acceptance // "-")\n\n" +
    "## Out of scope\nAnything the acceptance criteria do not need.\n\n## Why structural\n\(.why_structural // "-")\n\n" +
    "---\nFiled by devkit `bin/monthly_audit.sh`, fleet audit \($month), size \(.size)."' "$LLM_FINDINGS"
}

FILED=0
file_issues() {
  local n i title repo key size open slots url labels
  [ -f "$LLM_FINDINGS" ] || return 0
  if [ "$ISSUES_KNOWN" -eq 0 ]; then echo "not filed: fleet-audit backlog unreadable" >>"$FILED_LOG"; return 0; fi
  open=$(awk -F'\t' '$2 == "OPEN"' "$ISSUES_TSV" | grep -c .)
  slots=$((BACKLOG_CAP - open))
  n=$(jq length "$LLM_FINDINGS")
  i=0
  while [ "$i" -lt "$n" ]; do
    title=$(jq -r ".[$i].title" "$LLM_FINDINGS")
    repo=$(jq -r ".[$i].repo" "$LLM_FINDINGS")
    size=$(jq -r ".[$i].size" "$LLM_FINDINGS")
    i=$((i + 1))
    if ! key=$(resolve_repo "$repo"); then echo "not filed (unknown repo $repo): $title" >>"$FILED_LOG"; continue; fi
    # Exact title, fleet-wide: the same fix proposed against another repo is still a repeat.
    if cut -f3 "$ISSUES_TSV" | grep -qxF "$title"; then echo "not filed (duplicate): $title" >>"$FILED_LOG"; continue; fi
    if [ "$slots" -le 0 ]; then echo "not filed (backlog full: $open open fleet-audit issues): $key: $title" >>"$FILED_LOG"; continue; fi
    labels=(-l fleet-audit)
    case "$size" in S|M) labels+=(-l agent-ready) ;; esac
    log "filing $key: $title"
    if url=$(remote_write gh issue create -R "$OWNER/$key" -t "$title" -b "$(issue_body $((i - 1)))" "${labels[@]}"); then
      slots=$((slots - 1))
      if [ "$DRY_RUN" -eq 1 ]; then echo "dry-run, would file $key ($size): $title" >>"$FILED_LOG"
      else FILED=$((FILED + 1)); echo "filed $key ($size): $title $url" >>"$FILED_LOG"
      fi
    else
      echo "not filed (issue create failed): $key: $title" >>"$FILED_LOG"
    fi
  done
}

PR_URL=
publish_report() {
  local dir=$WORK/$REPORT_REPO branch=audit/$MONTH dest=docs/audits/fleet-$MONTH.md
  log "report: committing $dest to $OWNER/$REPORT_REPO on $branch"
  if ! gh repo clone "$OWNER/$REPORT_REPO" "$dir" -- --depth 1 --quiet >"$RAW/report-clone.txt" 2>&1; then
    log "report: cloning $REPORT_REPO failed; report stays local"; return
  fi
  if ! { mkdir -p "$dir/docs/audits" && cp "$REPORT" "$dir/$dest" && git -C "$dir" checkout -q -b "$branch" \
    && git -C "$dir" add "$dest" && git -C "$dir" commit -q -m "Fleet audit $MONTH"; }; then
    log "report: local commit failed; report stays local"; return
  fi
  # Only ever the audit branch; never main, never --force.
  remote_write git -C "$dir" push -q origin "HEAD:refs/heads/$branch" || { log "report: push of $branch failed"; return; }
  PR_URL=$(remote_write gh pr create -R "$OWNER/$REPORT_REPO" --head "$branch" --title "Fleet audit $MONTH" \
    --body "Monthly fleet audit (devkit bin/monthly_audit.sh). $FILED issues filed; $(det_count) deterministic findings.") \
    || log "report: PR create failed"
}

notify() { # <line>
  [ -n "${AUDIT_NTFY_URL:-}" ] || return 0
  remote_write curl -fsS -m 10 -d "$1" "$AUDIT_NTFY_URL" >/dev/null || log "ntfy post failed"
}

# --- main ----------------------------------------------------------------------------------

DEVKIT_MAIN=$(git ls-remote "https://github.com/$OWNER/devkit.git" refs/heads/main 2>/dev/null | cut -f1)
[ -n "$DEVKIT_MAIN" ] || record fleet devkit-main ERROR "git ls-remote of $OWNER/devkit main failed"
: >"$RAW/devkit-revs.txt"

REPOS=$(select_repos) || exit $?
AUDITED=$(printf '%s' "$REPOS" | tr '\n' ' ' | sed 's/ *$//')
for repo in $REPOS; do audit_repo "$repo"; done
revs=$(sort -u "$RAW/devkit-revs.txt" | grep -c .)
[ "$revs" -le 1 ] || record fleet devkit-rev FAIL "$revs different devkit revs vendored across the fleet"

fleet_tool labels ' ok ' "$DEVKIT_ROOT/github/labels_sync.sh" --dry-run
fleet_tool settings ' ok$' "$DEVKIT_ROOT/github/repo_settings.sh" --dry-run
dead_alerts
ledgers

write_report
write_findings_json

if [ "$LLM" -eq 1 ] || [ "$FILE_ISSUES" -eq 1 ]; then load_issues; fi
[ "$LLM" -eq 0 ] || run_llm
if [ "$FILE_ISSUES" -eq 1 ]; then file_issues
elif [ -f "$LLM_FINDINGS" ]; then echo "not filed: --file-issues 0" >>"$FILED_LOG"
fi

NLLM=0
[ ! -f "$LLM_FINDINGS" ] || NLLM=$(jq length "$LLM_FINDINGS")
{
  echo "## Structural findings (LLM)"
  echo
  echo "LLM: $LLM_STATUS."
  echo
  if [ -f "$LLM_FINDINGS" ]; then
    jq -r '.[] | "- **\(.title)** (\(.repo), \(.size)): \(.proposed_fix // .fix // "-")"' "$LLM_FINDINGS"
    echo
  fi
  echo "## Filing"
  echo
  if [ -s "$FILED_LOG" ]; then sed 's/^/- /' "$FILED_LOG"; else echo "- nothing to file"; fi
} >>"$REPORT"

if [ "$FILE_ISSUES" -eq 1 ]; then publish_report
else log "report not committed (--file-issues 0): $REPORT"
fi

NDET=$(det_count)
notify "fleet audit $MONTH: $FILED filed, $NDET deterministic findings, report ${PR_URL:-$REPORT}"
[ "$DRY_RUN" -eq 1 ] || { mkdir -p "$STATE" && echo "$MONTH" >>"$RUNS_FILE"; }

echo "AUDIT report=$REPORT"
echo "AUDIT findings=$NLLM filed=$FILED deterministic=$NDET"
