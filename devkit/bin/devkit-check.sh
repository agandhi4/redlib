#!/usr/bin/env bash
# Guard: the vendored devkit/ tree is exactly what devkit-sync.sh recorded in .devkit-rev.
# Runs in ci-quick; offline, milliseconds. A diff means someone edited devkit/ in this repo.
# Usage: devkit/bin/devkit-check.sh [--staged]        or: make devkit-check
#
# Also: a tree that matches .devkit-rev but holds paths outside its own VENDOR_PATHS was vendored
# whole by a devkit-sync older than the manifest (the first `make devkit-sync` after 2026-10-13
# runs the old script). Rerunning make devkit-sync, now the new script, slims it.
#
# Also: every tracked .swift-format must equal devkit/lint/swift-format.json byte for byte.
#
# Also: scripts/ci/gate_plan.sh sets none of the plan variables this devkit retired
# (DEVKIT_RETIRED_PLAN_VARS, bin/_paths_lib.sh). The gate sources main's _paths_lib.sh, so the
# sync PR that retires one would pass its own gate and break the next PR's; this check, run
# from the merged tree, fails the sync PR instead. The plan is read from the WORKING TREE, where a
# fix is made: reading the staged copy kept a manual run failing on a plan already fixed on disk
# (closet #410). --staged reads the index instead, as secrets_check.sh --staged does, for a hook
# that must judge exactly what is about to be committed. CI and the gate see one tree either way.
#
# Also: GATE_CODEX_REVIEW, if the plan sets it, is one literal line `GATE_CODEX_REVIEW=0` or `=1`
# (plan_literal_setting). pr_merge.sh reads that line without sourcing the plan, so any other
# form (`="1"`, `export`, `=yes`, a second line) would leave the setting silently ignored or
# ambiguous. Unset is 1, Codex review required (the fleet default since 2026-10-23); `=0` needs
# one literal `GATE_CODEX_REVIEW_REASON="<why>"` line, which make merge prints, and the reason
# is refused anywhere else (codex_review_setting), so the plan never holds a stale excuse.
# Likewise GATE_CODEX_RUNNING_MAX_MIN, one `GATE_CODEX_RUNNING_MAX_MIN=<minutes>` line (pr_merge.sh).
# Likewise GATE_CODE_PATHS, one unquoted `GATE_CODE_PATHS=<prefix>[,<prefix>...]` line: the gate
# sources it, the hooks and pr_merge.sh read the literal, and they must classify alike.
#
# Also: the baseline files `devkit new` writes and a hand-built repo silently lacks (kitchen had
# no scorecard.json, 2026-10-23), each named with the one command that creates it
# (baseline_file): docs/metrics/scorecard.json, the WIRED ratchet's record, which ci-metrics
# skips when absent, and docs/metrics/ratchet.json where scripts/ci/metrics.conf declares
# collectors. A warning before BASELINE_FAILS_FROM, a failure from it (docs_check's scheme), so
# the sync that brings the rule breaks no consumer's ci-quick. DEVKIT_CHECK_TODAY overrides
# today (tests). The docs set, hooks, Renovate and the gate plan have their own checks.
#
# Also (a WARNING, exit 0): an alternative of the plan's GATE_IMAGE_EXCLUDE_PATHS whose every
# tracked path the root .dockerignore already excludes. The gate reads .dockerignore itself
# (_dockerignore.py), so such an alternative is a hand copy that drifts (redlib #23, locus #133).
# Read from a literal assignment, single-quoted or bare, the fleet's two forms.
#
# Also (a WARNING, exit 0): a repo tracking a tsconfig*.json and a .dockerignore whose build
# context would still see a tsbuildinfo beside a tsconfig (probed with _dockerignore.py, so any
# pattern that excludes it counts). A stale one copied into the image let `tsc -b` call the
# project up to date and skip the image's type-check (locus #145); the fix is `**/*.tsbuildinfo`.
#
# Also (a WARNING, exit 0): a Makefile recipe line that runs `docker` itself (makefile_raw_docker,
# bin/_makefile_lib.sh), naming the line. It bypasses the daemon probe and per-call bound, so a
# wedged daemon hangs the job until the watchdog; route it through devkit/bin/docker_bounded.sh.
#
# Also (WARNINGS, exit 0): a repo that gates through devkit merges through it (bin/pr_merge.sh,
# which refuses a head without a local-gate success) and opens PRs through it (bin/pr_create.sh,
# which names origin's repo). A Makefile with a `gate` target and no `merge` or no `pr` target is
# named, and so is each line of AGENTS.md's `## Workflow` section that tells the reader to run
# `gh pr merge` or `gh pr create`: lanes do what that text says, so the text moves with the
# target. Only an instruction counts (workflow_gh_lines): the line starts with the command, it
# sits in a code fence, or `run`/`then` leads into it. A ban ("never `gh pr merge --auto`",
# closet) is the rule this enforces, not a breach. AGENTS.md is read like the plan: the working
# tree, or the index under --staged.
#
# Also (WARNINGS, exit 0): a throwaway Postgres container name or host port, or a `docker run
# --name`, the Makefile fixes to a literal (makefile_fixed_pg): every worktree then shares one container, and concurrent
# lanes' `up` removed each other's databases mid-suite (2026-10-19). throwaway_pg.sh `name` and
# `port` derive both from the checkout. And a Makefile that does not run its recipes on the
# repo's pinned Node or Rust (no `SHELL := devkit/bin/toolchain_shell.sh` while .nvmrc or
# rust-toolchain.toml is tracked): a hand-run `make metrics-*` then used PATH's Node 25, which
# the gate never does (finplat, 2026-10-19).
# Likewise each recipe line that runs a bare `python3` (makefile_bare_python) in a Makefile
# without that SHELL: toolchain_shell.sh leads PATH with devkit's python3 (>= 3.11), and without
# it the line gets PATH's, Xcode's 3.9 under launchd (devkit decisions 2026-10-23).
#
# Also (WARNINGS, exit 0): the repo's Renovate config extends devkit's preset and automerges
# nothing beyond the declared digest hole (bin/_renovate.py, which the scorecard's `renovate`
# check shares). Renovate merges server-side, so this is the only place a self-merge that skips
# the gate is caught before it is live (homelab #109/#110, 2026-10-19).
#
# Also (WARNINGS, exit 0): a bats assertion errexit never sees (bin/bats_assert_check.py, which
# devkit's ci-lint fails on): `[[ ]]` mid-test passes untested on macOS bash 3.2, where lanes run
# bats (devkit #212). `bats_assert_check.py --fix` appends the `|| false` that fixes most.
# It reads the working tree even under --staged: a warning judges the files a lane edits next.
#
# Also (WARNINGS, exit 0): a tracked stylesheet whose Tailwind v4 scan covers devkit/: an
# `@import "tailwindcss"` with no source(...) built from the repo root (the scan starts at the
# building package, tw_build_root), or a source()/@source path that reaches it
# (tailwind_unscoped). Unscoped, v4 scans every file under that start .gitignore keeps, so a word
# in devkit's comments ("shadow") became a CSS class and moved rollcall's bundle bound with no
# src/ change (#81). Working tree, like the bats check.
#
# Also (WARNINGS, exit 0): a tracked file outside devkit/ that imports a lint base and names one
# of its exports devkit/lint/exports.txt marks deprecated, with that line's migration. The
# deprecation window is how devkit retires an export a repo-owned config imports (the sync cannot
# edit those configs, so a removal broke three repos' sync PRs, #227). The working tree, or the
# index under --staged. A `docs` path in _paths_lib.sh's table (docs/*, any *.md: decisions.md,
# CHANGELOG.md) is prose, never an import, and dated history may name what was retired: it is
# never scanned. Why (2026-10-26): closet reworded a past decisions.md entry just to silence it.
#
# Also, the publish contract (bin/publish.sh, which linux-box's timer runs as `make publish`): a
# plan's PUBLISH_IMAGE is one literal line `PUBLISH_IMAGE=ghcr.io/<owner>/<name>` (publish.sh
# reads it without sourcing the plan). With it, the Makefile has `publish` running
# devkit/bin/publish.sh, `ci-image` that only builds (no ci-smoke, ci-e2e or boot_image.sh in its
# rule: the publisher runs `ci-image ci-smoke`, never Playwright) and `ci-smoke`, and the plan runs
# ci-smoke as a gate job. A publish rule with no PUBLISH_IMAGE fails too: it would refuse every
# run. Why (2026-10-27): `ci-image` meant three things across the fleet.
#
# Also, where origin is a GitHub repo (bin/_gh_repo_lib.sh): the plan's literal GATE_SLUG is
# origin's (owner and name without case), since the gate and make merge act on GATE_SLUG alone;
# and gh's default repo in this clone is origin (gh_default_heal, one line when it sets it, a
# WARNING when git cannot). Why (2026-10-26): in redlib, a fork, a bare `gh pr create` opened
# its PR on the public parent. Healed, not failed: it is clone config no commit carries.
#
# Also healed, likewise: this clone's merge drivers for the paths .gitattributes gives them
# (merge_drivers_heal, bin/_gitattributes_lib.sh), so a clone no hook has run in yet still
# merges docs/decisions.md and docs/metrics/*.json with them on a local rebase.
set -euo pipefail
STAGED=0
case "${1:-}" in
  --staged) STAGED=1 ;;
  '') ;;
  *) echo "usage: devkit-check.sh [--staged]" >&2; exit 2 ;;
esac
# shellcheck source=bin/_vendor_paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/_vendor_paths.sh"
# shellcheck source=bin/_paths_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_paths_lib.sh"
# shellcheck source=bin/_makefile_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_makefile_lib.sh"
# shellcheck source=bin/_gate_env.sh  # gate_plan_literal: GATE_SLUG as the gate reads it
. "$(dirname "${BASH_SOURCE[0]}")/_gate_env.sh"
# shellcheck source=bin/_gh_repo_lib.sh  # origin_slug, slug_same, gh_default_heal
. "$(dirname "${BASH_SOURCE[0]}")/_gh_repo_lib.sh"
# shellcheck source=bin/_gitattributes_lib.sh  # merge_drivers_heal
. "$(dirname "${BASH_SOURCE[0]}")/_gitattributes_lib.sh"
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
HERE=$(dirname "${BASH_SOURCE[0]}")
warn() { echo "devkit-check: WARNING: $*" >&2; }
# warn_each <prefix> <suffix>: one warning per non-empty stdin line, between the two.
warn_each() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] || warn "$1$line$2"
  done
}
# What --staged changes (header): the index, else the working tree. The vendored tree, its rev
# and the .swift-format copies are the index's either way (check_vendored_tree).
tracked_text() {
  if [ "$STAGED" = 1 ]; then git show ":$1" 2>/dev/null || true; else cat "$1" 2>/dev/null || true; fi
}
tracked_exists() {
  if [ "$STAGED" = 1 ]; then git cat-file -e ":$1" 2>/dev/null; else [ -f "$1" ]; fi
}
# Assignments only: a comment naming a retired variable is history, not a setting.
plan_src=$(tracked_text scripts/ci/gate_plan.sh)

# The vendored tree, .devkit-rev and the .swift-format copies: both sides come from the INDEX,
# not HEAD or the working copy, with or without --staged (devkit-sync stages all of them). In CI the index equals HEAD; in
# the pre-commit hook it is exactly what is about to be committed. Comparing HEAD made the
# devkit-sync commit itself fail its own hook (new .devkit-rev vs the old committed tree), and
# let a staged local edit under devkit/ through. Reading .devkit-rev from disk let an unstaged
# edit to it vouch for a staged devkit/ tree it would never be committed with. Unstaged edits
# are the hooks' business.
check_vendored_tree() {
  local rev expected actual manifest slim
  rev=$(git show :.devkit-rev 2>/dev/null) || {
    echo "devkit-check: .devkit-rev missing from the index; run make devkit-sync" >&2
    exit 1
  }
  read -r _commit expected <<<"$rev"
  actual=$(git write-tree --prefix=devkit/ 2>/dev/null) || {
    echo "devkit-check: cannot read devkit/ from the index (missing or unmerged); run make devkit-sync" >&2
    exit 1
  }
  if [ "$actual" != "$expected" ]; then
    echo "devkit-check: devkit/ (tree ${actual:0:7}) differs from the vendored ${expected:0:7}." >&2
    echo "  Change it upstream in agandhi4/devkit, then run: make devkit-sync" >&2
    exit 1
  fi
  if manifest=$(git show :devkit/VENDOR_PATHS 2>/dev/null); then
    slim=$(vendor_filter_tree "$actual" "$manifest") || exit 1
    if [ "$slim" != "$actual" ]; then
      echo "devkit-check: devkit/ holds paths outside devkit/VENDOR_PATHS (vendored whole by an older devkit-sync)." >&2
      echo "  Run: make devkit-sync   (again, if you just ran it: the new script is now in place)" >&2
      exit 1
    fi
  fi
}
# swift-format has no `extends`, so a repo's .swift-format (root or nested, e.g. ios/) is a copy of
# devkit/lint/swift-format.json and this is what keeps the copies one base. Index blobs, like the
# tree check: equal blob ids are equal bytes.
check_swift_format() {
  local base_blob="" copies=0 copy
  while IFS= read -r copy; do
    [ -n "$copy" ] || continue
    if [ -z "$base_blob" ]; then
      base_blob=$(git rev-parse -q --verify ":devkit/lint/swift-format.json" 2>/dev/null) || {
        echo "devkit-check: $copy exists but devkit/lint/swift-format.json does not; run make devkit-sync" >&2
        exit 1
      }
    fi
    if [ "$(git rev-parse ":$copy")" != "$base_blob" ]; then
      echo "devkit-check: $copy differs from devkit/lint/swift-format.json (swift-format has no extends; the repo file is a copy)." >&2
      echo "  Restore it: cp devkit/lint/swift-format.json $copy   A rule change goes upstream in agandhi4/devkit." >&2
      copies=$((copies + 1))
    fi
  done <<<"$(swift_format_copies)"
  [ "$copies" -eq 0 ] || exit 1
}
# plan_literal_setting <plan, comments stripped> <NAME> <value ERE> <the form, for the message>:
# exit 1 unless every NAME assignment is the one literal line a reader that never sources the
# plan sees: GATE_CODEX_REVIEW and GATE_CODEX_RUNNING_MAX_MIN (gate_plan_literal, pr_merge.sh) and
# GATE_CODE_PATHS (devkit_load_code_paths, _paths_lib.sh).
plan_literal_setting() {
  local all literal
  all=$(grep -cE "(^|[^A-Za-z0-9_])$2=" <<<"$1" || true)
  literal=$(grep -cE "^$2=$3[[:space:]]*\$" <<<"$1" || true)
  [ "$all" != "$literal" ] || [ "$all" -gt 1 ] || return 0
  echo "devkit-check: scripts/ci/gate_plan.sh: $2 must be one literal line, $4 (read without sourcing the plan)" >&2
  exit 1
}
# codex_review_setting <plan, comments stripped>: exit 1 unless GATE_CODEX_REVIEW=0 has its
# reason and the reason has its 0 (header).
codex_review_setting() {
  local off=0 reason=0
  grep -qE '^GATE_CODEX_REVIEW=0[[:space:]]*$' <<<"$1" && off=1
  grep -qE '^GATE_CODEX_REVIEW_REASON=' <<<"$1" && reason=1
  [ "$off" != "$reason" ] || return 0
  if [ "$off" = 1 ]; then
    echo "devkit-check: scripts/ci/gate_plan.sh: GATE_CODEX_REVIEW=0 needs a GATE_CODEX_REVIEW_REASON=\"<why>\" line (make merge prints it; Codex review is the fleet default)" >&2
  else
    echo "devkit-check: scripts/ci/gate_plan.sh: GATE_CODEX_REVIEW_REASON explains GATE_CODEX_REVIEW=0 only; drop it, Codex review is on" >&2
  fi
  exit 1
}
# plan_image_excludes <plan, comments stripped>: the header's GATE_IMAGE_EXCLUDE_PATHS warning.
plan_image_excludes() {
  local exclude_re="^[[:space:]]*GATE_IMAGE_EXCLUDE_PATHS=('([^']*)'|([^[:space:]'\"]+))" line exclude redundant
  while IFS= read -r line; do
    [[ "$line" =~ $exclude_re ]] || continue
    exclude=${BASH_REMATCH[2]}${BASH_REMATCH[3]}
    if redundant=$(git ls-files | "$HERE/python.sh" -I "$HERE/_dockerignore.py" redundant . "$exclude"); then
      warn_each "GATE_IMAGE_EXCLUDE_PATHS '" "' is already excluded by .dockerignore, which the gate reads itself; drop it from the ERE" <<<"$redundant"
    else
      warn "could not hold GATE_IMAGE_EXCLUDE_PATHS to .dockerignore (above)"
    fi
    break
  done <<<"$1"
}
check_plan() {
  [ -n "$plan_src" ] || return 0
  local plan retired_set=0 var
  plan=$(awk '{ sub(/#.*/, "") } 1' <<<"$plan_src")
  for var in $DEVKIT_RETIRED_PLAN_VARS; do
    if grep -qE "(^|[^A-Za-z0-9_])$var=" <<<"$plan"; then
      echo "devkit-check: scripts/ci/gate_plan.sh sets $var; $DEVKIT_RETIRED_PLAN_ADVICE" >&2
      retired_set=1
    fi
  done
  [ "$retired_set" -eq 0 ] || exit 1
  plan_literal_setting "$plan" GATE_CODEX_REVIEW '[01]' 'GATE_CODEX_REVIEW=0 or GATE_CODEX_REVIEW=1'
  # pr_merge.sh's gate_plan_text form (bin/_gate_env.sh). The comment strip above cuts a reason
  # at a `#`, so one holding it fails here, as gate_plan_text would not read it.
  plan_literal_setting "$plan" GATE_CODEX_REVIEW_REASON '"[^"$`\\]+"' \
    'GATE_CODEX_REVIEW_REASON="<why>", double-quoted, with no $, `, \, " or #'
  codex_review_setting "$plan"
  plan_literal_setting "$plan" GATE_CODEX_RUNNING_MAX_MIN '[1-9][0-9]{0,5}' \
    'GATE_CODEX_RUNNING_MAX_MIN=<whole minutes, 1-999999>, unquoted (45)'
  plan_literal_setting "$plan" GATE_CODE_PATHS '[A-Za-z0-9._/-]+(,[A-Za-z0-9._/-]+)*' \
    'GATE_CODE_PATHS=<prefix>[,<prefix>...], unquoted (plugins/,templates/)'
  plan_image_excludes "$plan"
}
# check_publish_contract: the header's publish contract.
publish_contract_fail() { echo "devkit-check: publish contract: $*" >&2; publish_failed=1; }
check_publish_contract() {
  local plan image publish_rule image_rule publish_failed=0
  plan=$(awk '{ sub(/#.*/, "") } 1' <<<"$plan_src")
  plan_literal_setting "$plan" PUBLISH_IMAGE 'ghcr\.io/[a-z0-9_.-]+/[a-z0-9_.-]+' 'PUBLISH_IMAGE=ghcr.io/<owner>/<name>'
  image=$(gate_plan_literal <(printf '%s\n' "$plan_src") PUBLISH_IMAGE)
  publish_rule=$(makefile_rule_text publish)
  if [ -z "$image" ]; then
    ! grep -q 'publish\.sh' <<<"$publish_rule" \
      || publish_contract_fail "Makefile's publish runs publish.sh but scripts/ci/gate_plan.sh has no PUBLISH_IMAGE= line"
    [ "$publish_failed" = 0 ] || exit 1
    return 0
  fi
  grep -q 'devkit/bin/publish\.sh' <<<"$publish_rule" \
    || publish_contract_fail "PUBLISH_IMAGE is set, so the Makefile needs 'publish: ; devkit/bin/publish.sh .'"
  case "$(makefile_targets)" in *" ci-smoke "*) ;; *) publish_contract_fail "no ci-smoke target: it boots CI_IMAGE and asserts CI_BUILD_VERSION" ;; esac
  image_rule=$(makefile_rule_text ci-image)
  [ -n "$image_rule" ] || publish_contract_fail "no ci-image target: it builds CI_IMAGE with APP_VERSION=CI_BUILD_VERSION"
  ! grep -qE '(^|[^A-Za-z0-9_.-])(ci-smoke|ci-e2e|boot_image\.sh)([^A-Za-z0-9_.-]|$)' <<<"$image_rule" \
    || publish_contract_fail "ci-image must only build: it runs a smoke or browser tier, so the publisher would run it twice or run Playwright; the gate plan runs ci-smoke (and ci-e2e) as their own jobs"
  grep -qE '(^|[^A-Za-z0-9_.-])ci-smoke([^A-Za-z0-9_.-]|$)' <<<"$plan" \
    || publish_contract_fail "scripts/ci/gate_plan.sh runs no ci-smoke job; with ci-image build-only, no gate would boot the image"
  [ "$publish_failed" = 0 ] || exit 1
}
check_clone_config() {
  local origin plan_slug
  merge_drivers_heal . "$HERE" devkit-check || warn "cannot set a merge driver's config (git above)"
  origin=$(origin_slug .) || return 0
  gh_default_heal . devkit-check || warn "cannot make origin gh's default repo (git above)"
  plan_slug=$(gate_plan_literal <(printf '%s\n' "$plan_src") GATE_SLUG)
  if [ -n "$plan_slug" ] && ! slug_same "$plan_slug" "$origin"; then
    echo "devkit-check: scripts/ci/gate_plan.sh: GATE_SLUG=$plan_slug is not origin's repo ($origin); the gate and make merge act on GATE_SLUG, so set it to origin's" >&2
    exit 1
  fi
}
# baseline_file <path> <the command that creates it> <why>: the header's warn-then-fail rule. The
# index under --staged, else the working tree, as the plan is read.
readonly BASELINE_FAILS_FROM=2026-11-01
baseline_missing=0
baseline_file() {
  tracked_exists "$1" && return 0
  if [[ "${DEVKIT_CHECK_TODAY:-$(date +%F)}" < "$BASELINE_FAILS_FROM" ]]; then
    warn "no $1 ($3); create it with \`$2\` and commit it (fails from $BASELINE_FAILS_FROM)"
  else
    echo "devkit-check: no $1 ($3); create it with \`$2\` and commit it" >&2
    baseline_missing=1
  fi
}
check_baselines() {
  baseline_file docs/metrics/scorecard.json 'devkit/bin/python.sh -I devkit/bin/scorecard.py . --mode rebaseline' \
    "the WIRED ratchet's record, which devkit new writes; ci-metrics holds no check without it"
  if tracked_exists scripts/ci/metrics.conf; then
    baseline_file docs/metrics/ratchet.json 'make metrics-rebaseline' \
      "the bounds scripts/ci/metrics.conf's collectors are held to; ci-metrics cannot run without it"
  fi
  [ "$baseline_missing" = 0 ] || exit 1
}
check_tsbuildinfo() {
  git ls-files --error-unmatch .dockerignore >/dev/null 2>&1 || return 0
  local probes seen
  # One probe per tsconfig: where `tsc -b` writes its tsbuildinfo by default, named after the
  # config (tsconfig.build.json -> tsconfig.build.tsbuildinfo), so an ignore line naming only
  # tsconfig.tsbuildinfo still warns (Codex, orbit #116).
  probes=$(git ls-files -- 'tsconfig*.json' '**/tsconfig*.json' \
    | awk '{ sub(/\.json$/, ".tsbuildinfo"); print }' | sort -u)
  [ -n "$probes" ] || return 0
  if seen=$("$HERE/python.sh" -I "$HERE/_dockerignore.py" keep . <<<"$probes"); then
    [ -z "$seen" ] || warn ".dockerignore lets the image build see $(head -n 1 <<<"$seen"): a stale tsbuildinfo makes tsc -b skip the image's type-check (locus #145); add: **/*.tsbuildinfo"
  else
    warn "could not hold .dockerignore to **/*.tsbuildinfo (above)"
  fi
}
check_makefile_recipes() {
  local raw kind value what f mk_files=()
  while IFS= read -r raw; do
    [ -z "$raw" ] || warn "${raw%%: *}: docker runs unbounded (no daemon probe, no per-call timeout); use devkit/bin/docker_bounded.sh: ${raw#*: }"
  done <<<"$(makefile_raw_docker)"
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    kind=${raw#*: }; value=${kind#* }; kind=${kind%% *}
    what="throwaway Postgres $kind"
    [ "$kind" != container ] || { what="docker run container name"; kind=name; }
    warn "${raw%%: *}: $what $value is fixed, so every worktree shares it and concurrent lanes break each other; derive it: \$(shell devkit/bin/throwaway_pg.sh $kind <base name>)"
  done <<<"$(makefile_fixed_pg)"
  while IFS= read -r f; do mk_files+=("$f"); done < <(makefile_files)
  [ "${#mk_files[@]}" -gt 0 ] || return 0
  grep -qE '^SHELL[[:space:]]*:?=[[:space:]]*devkit/bin/toolchain_shell\.sh[[:space:]]*$' "${mk_files[@]}" && return 0
  [ -z "$(git ls-files .nvmrc rust-toolchain.toml rust-toolchain)" ] \
    || warn "Makefile: a hand-run make uses PATH's node/cargo, not the repo's pins; add: SHELL := devkit/bin/toolchain_shell.sh"
  while IFS= read -r raw; do
    [ -z "$raw" ] || warn "${raw%%: *}: a bare python3 is PATH's (Xcode's 3.9 under launchd), not devkit's >= 3.11; add: SHELL := devkit/bin/toolchain_shell.sh (or call devkit/bin/python.sh): ${raw#*: }"
  done <<<"$(makefile_bare_python)"
}
# workflow_gh_lines <gh pr subcommand>: the line numbers of the Workflow section's lines that
# instruct `gh pr <subcommand>`, from stdin.
workflow_gh_lines() {
  awk -v cmd="gh pr $1" '
    /^## / { wf = ($0 ~ /^## Workflow/); fence = 0; next }
    !wf { next }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    {
      l = tolower($0)
      if (index(l, cmd) == 0) next
      if (fence || l ~ ("^[ \t]*([-*+]|[0-9]+\\.)?[ \t]*`?" cmd)) { print NR; next }
      if (l ~ ("(^|[^a-z])(run|then)[ \t]+`?" cmd) && l !~ ("(never|not|n.t)[ \t]+(run|then)[ \t]+`?" cmd)) print NR
    }'
}
check_merge_path() {
  local targets agents_src
  targets=$(makefile_targets)
  if [[ "$targets" == *" gate "* && "$targets" != *" merge "* ]]; then
    # shellcheck disable=SC2016  # $(PR) is make's variable, printed literally
    warn 'the Makefile has a gate target but no merge target; add: merge: ; devkit/bin/pr_merge.sh "$(PR)"'
  fi
  if [[ "$targets" == *" gate "* && "$targets" != *" pr "* ]]; then
    warn "the Makefile has a gate target but no pr target; add: pr: ; devkit/bin/pr_create.sh (it opens the PR on origin, never a fork's parent)"
  fi
  agents_src=$(tracked_text AGENTS.md)
  warn_each "AGENTS.md:" ": the Workflow section merges with gh pr merge; say make merge PR=<n> (it refuses a head without a local-gate success)" \
    <<<"$(workflow_gh_lines merge <<<"$agents_src")"
  warn_each "AGENTS.md:" ": the Workflow section opens PRs with gh pr create; say make pr BODY_FILE=<file> (gh's default in a fork is its parent)" \
    <<<"$(workflow_gh_lines create <<<"$agents_src")"
}
check_audits() {
  local renovate_args=(audit)
  [ "$STAGED" = 0 ] || renovate_args+=(--staged)
  warn_each "" " (README \"Renovate\": every Renovate PR waits for make merge)" \
    <<<"$("$HERE/python.sh" -I "$HERE/_renovate.py" "${renovate_args[@]}")"
  warn_each "" " (devkit/bin/bats_assert_check.py --fix)" <<<"$("$HERE/python.sh" -I "$HERE/bats_assert_check.py" --root .)"
}
top=$(pwd -P)
# tailwind_unscoped: "<css>:<line>\t<dir>" for each place a tracked stylesheet (outside devkit/)
# has Tailwind v4 scan devkit/, <dir> being where that scan starts: an `@import "tailwindcss"`
# with no source(...) (from tw_build_root), or a source() or `@source` path (source(none)'s
# explicit list) whose tw_dir tw_reaches_devkit. A path that does not resolve is Tailwind's own
# error, not this check's.
# tw_build_root <top> <css>: where an unscoped scan starts. That is the `base` @tailwindcss/postcss
# and the CLI default to (the build's cwd) or @tailwindcss/vite's (vite's root, the cwd by
# default): the package that builds <css>, the nearest directory at or above it holding a
# package.json, else <top>. Why (orbit #128): frontend/src/assets/main.css, unscoped, scans
# frontend/ only; judging every unscoped import as the repo root's warned there falsely. A vite
# `root:` or postcss `base:` set in a config is not read; none in the fleet sets one.
tw_build_root() {
  local d
  d=$(cd "$(dirname "$2")" && pwd -P)
  while [[ "$d" == "$1/"* ]] && [ ! -f "$d/package.json" ]; do d=$(dirname "$d"); done
  [[ "$d" == "$1/"* ]] || d=$1
  echo "$d"
}
# tw_dir <css> <path>: the directory <path> names from <css>'s (a glob's part before its first
# wildcard; a file's directory), symlinks resolved; 1 when it does not exist.
tw_dir() {
  local d
  d=$(dirname "$1")/${2%%[\*\?\{\[]*}
  [ -d "$d" ] || d=$(dirname "$d")
  cd "$d" 2>/dev/null && pwd -P
}
# tw_reaches_devkit <top> <dir> [auto]: a scan from <dir> covers devkit/: <dir> is <top>, above it
# or inside <top>/devkit/. auto: Tailwind's automatic detection (no source(), or source()), which
# skips what .gitignore ignores, so not when devkit/ is ignored; an @source path is scanned
# regardless (Tailwind's docs: the way to scan an ignored tree).
tw_reaches_devkit() {
  case "$2/" in "$1/devkit/"*) ;; "$1/"?*) return 1 ;; esac
  [ -z "${3:-}" ] || ! git check-ignore -q --no-index devkit/
}
tailwind_unscoped() {
  local css hit dir
  while IFS= read -r css; do
    [ -f "$css" ] || continue
    hit=$(grep -nE "^[[:space:]]*@import[[:space:]]+[\"']tailwindcss(/utilities(\\.css)?)?[\"']" "$css" | head -n 1) || hit=""
    if [ -n "$hit" ] && [[ ! "$hit" =~ source\([[:space:]]*none[[:space:]]*\) ]]; then
      if [[ "$hit" =~ source\([[:space:]]*[\"\']([^\"\']*)[\"\'] ]]; then
        dir=$(tw_dir "$css" "${BASH_REMATCH[1]}") || dir=""
      else
        dir=$(tw_build_root "$top" "$css")
      fi
      [ -z "$dir" ] || ! tw_reaches_devkit "$top" "$dir" auto || printf '%s:%s\t%s\n' "$css" "${hit%%:*}" "$dir"
    fi
    # `@source not "<path>"` excludes and `@source inline(...)` names classes: neither matches.
    while IFS= read -r hit; do
      [[ "$hit" =~ @source[[:space:]]+[\"\']([^\"\']*)[\"\'] ]] || continue
      dir=$(tw_dir "$css" "${BASH_REMATCH[1]}") || continue
      ! tw_reaches_devkit "$top" "$dir" || printf '%s:%s\t%s\n' "$css" "${hit%%:*}" "$dir"
    done < <(grep -nE "^[[:space:]]*@source[[:space:]]+[\"']" "$css" || true)
  done < <(git ls-files -- '*.css' ':!:devkit/')
}
check_tailwind() {
  local place dir
  while IFS=$'\t' read -r place dir; do
    [ -n "$place" ] || continue
    case "$dir" in "$top") dir="the repo root" ;; "$top/"*) dir=${dir#"$top/"}/ ;; esac
    warn "$place: Tailwind v4's scan from $dir covers devkit/ (an unscoped @import \"tailwindcss\" scans the package that builds it; a source() or @source path, what it names), and a word in its comments becomes a CSS class (rollcall #81: .shadow); scope it to the app's sources: @import \"tailwindcss\" source(\"<dir>\")"
  done <<<"$(tailwind_unscoped)"
}
check_deprecated_exports() {
  local grep_args=(-lwF --all-match) module name state since migration file
  [ "$STAGED" = 0 ] || grep_args+=(--cached)
  while read -r module name state since migration; do
    [ "$state" = deprecated ] || continue
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      _devkit_area "$file"
      [ "$DEVKIT_AREA" = docs ] || warn "$file: $name (devkit/lint/$module) is deprecated since $since; $migration"
    done <<<"$(git grep "${grep_args[@]}" -e "$name" -e "devkit/lint/$module" -- ':!devkit/' || true)"
  done <<<"$(git show :devkit/lint/exports.txt 2>/dev/null | grep -v '^#' || true)"
}

# The header's checks, in its order; a failing one exits 1 with its message, a warning prints.
check_vendored_tree
check_swift_format
check_plan
check_publish_contract
check_clone_config
check_baselines
check_tsbuildinfo
check_makefile_recipes
check_merge_path
check_audits
check_tailwind
check_deprecated_exports
echo "devkit-check: ok (${_commit:0:7})"
