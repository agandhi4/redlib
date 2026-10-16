#!/usr/bin/env bash
# Guard for ci-quick: no credential is committed. Scans the TRACKED files (git ls-files, so a
# .env the ignore file keeps out never counts and Actions sees what a laptop sees) for
# high-confidence secret shapes, the way gitleaks' default rules do, without the binary:
#   - private key blocks            -----BEGIN (RSA|EC|DSA|OPENSSH|PGP|) PRIVATE KEY-----
#   - AWS access key ids            AKIA[0-9A-Z]{16}
#   - GitHub tokens                 ghp_|gho_|ghu_|ghs_|ghr_ + 36 chars, github_pat_ + 22_59 chars
#   - Slack tokens                  xox[abprs]-...
#   - Google API keys               AIza[0-9A-Za-z_-]{35}
#   - Stripe live keys              sk_live_[0-9a-zA-Z]{24,}
#   - Anthropic / OpenAI keys       sk-ant-..., sk-proj-... (40+ chars)
#   - age secret keys               AGE-SECRET-KEY-1[0-9A-Z]{58}
#   - assignments of a long literal to a secret-named variable, where the name ENDS with the
#     secret word (TOKEN, api_key, passwords; not TOKEN_INPUT_ID or secretName) and the literal
#     is not a path or URL (no leading `/`, no `://`). Test paths include Swift/Kotlin/Go
#     conventions (`*Tests/`, `*Tests.swift`, `*_test.go`): a fixture UUID under "token" is not a leak.
#     (api[_-]?key|secret|token|password|passwd)s?["']?\s*[:=]\s*['"][A-Za-z0-9+_=.-][A-Za-z0-9+/_=.-]{19,}['"]
#     unless the literal is a placeholder (contains example|placeholder|changeme|dummy|test|
#     xxx|<|>|\$\{), or the file is a test or fixture (tests/, test/, e2e/, *.test.*, *.spec.*,
#     test_*): a 20-character literal handed to `password` in a test is a fixture. The
#     key-shaped rules above still apply to tests: a real AWS key in a fixture is still a leak.
# Skipped: binary files (grep -I), lock files, minified bundles (*.min.*), the allow file itself (its
# reasons may quote what they allow), and the paths in scripts/ci/secrets_allow.txt (`<path-glob> <reason>` per line; a fixture with a deliberately
# fake key names itself there, and the reason is reviewed). The allow file is for fixtures,
# never for a real credential: rotate that and remove it from history.
# Output: `secrets-check: <file>:<line>: <rule>` per hit on stderr (the matched text is NEVER
# printed: the log must not become the leak), then `secrets-check: ok (<n> files)` on stdout or
# `secrets-check: FAIL` on stderr. Exit 0 ok, 1 hits, 2 usage.
# Cost: the file list is built in bash with no process per file, then one grep per rule over the
# list (nine processes in all): ~1 s for 1,000 files. The first version spawned four processes
# per file to detect binaries and took 28 s on closet, which pushed the check out of pre-commit.
# `--staged` scans only the paths staged for commit (added, copied, modified, renamed), for a
# pre-commit hook that wants the check's cost to follow the change; the gate's full scan stays
# authoritative. The working-tree content is what is read, as every hook step reads it.
# Usage: devkit/bin/secrets_check.sh [--staged] [repo-root]    (part of ci-quick; scorecard T11 sec.secrets)
set -uo pipefail
STAGED=0
if [ "${1:-}" = --staged ]; then STAGED=1; shift; fi
ROOT=${1:-$(git rev-parse --show-toplevel 2>/dev/null)} || { echo "usage: secrets_check.sh [--staged] [repo-root]" >&2; exit 2; }
cd "$ROOT" || exit 2
ALLOW=scripts/ci/secrets_allow.txt

rc=0 nfiles=0
fail() { rc=1; echo "secrets-check: $*" >&2; }

allowed() { # <path> -> 0 when an allow line's glob matches
  local glob _reason
  [ -f "$ALLOW" ] || return 1
  while read -r glob _reason; do
    case "$glob" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # the glob is the point
    case "$1" in $glob) return 0 ;; esac
  done <"$ALLOW"
  return 1
}

# One extended regex per rule, applied with grep -nE; the rule name is what gets printed.
RULES='private-key|-----BEGIN [A-Z ]*PRIVATE KEY-----
aws-access-key|\bAKIA[0-9A-Z]{16}\b
github-token|\bgh[pousr]_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b
slack-token|\bxox[abprs]-[A-Za-z0-9-]{10,}\b
google-api-key|\bAIza[0-9A-Za-z_-]{35}\b
stripe-live-key|\bsk_live_[0-9a-zA-Z]{24,}\b
llm-api-key|\bsk-(ant|proj)-[A-Za-z0-9_-]{40,}\b
age-secret-key|\bAGE-SECRET-KEY-1[0-9A-Z]{58}\b
secret-assignment|(api[_-]?key|secret|token|password|passwd)s?["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9+_=.-][A-Za-z0-9+/_=.-]{19,}["'"'"']'
PLACEHOLDER='example|placeholder|changeme|change-me|dummy|test|fake|xxx|<|>|\$\{|your[_-]'

# The scan list, built once: tracked (or staged), present, not skipped, not allowed. Pure bash per
# file; binaries are left to grep -I. Then one grep per rule over the whole list.
list_paths() {
  if [ "$STAGED" = 1 ]; then
    git diff --cached --name-only --diff-filter=ACMR -z | tr '\0' '\n'
  else
    git ls-files
  fi
}
LIST=$(mktemp) || exit 2
trap 'rm -f "$LIST"' EXIT
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  case "$f" in
    "$ALLOW"|*.min.js|*.min.css|*.map|*.lock|package-lock.json|pnpm-lock.yaml|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.woff|*.woff2|*.ttf|*.zip|*.gz|*.sqlite|*.db) continue ;;
  esac
  if allowed "$f"; then continue; fi
  printf '%s\0' "$f" >>"$LIST"
  nfiles=$((nfiles + 1))
done < <(list_paths)

is_test_path() {
  case "$1" in
    tests/*|*/tests/*|test/*|*/test/*|e2e/*|*/e2e/*|*.test.*|*.spec.*|test_*|*/test_*|*Tests/*|*Tests.swift|*Test.swift|*Spec.swift|*_test.go|*Test.kt) return 0 ;;
  esac
  return 1
}

if [ "$nfiles" -gt 0 ]; then
  while IFS='|' read -r rule re; do
    [ -n "$rule" ] || continue
    # Variable names come in any case (DB_PASSWORD); key shapes are case-exact (AKIA, ghp_).
    ci=""; [ "$rule" = secret-assignment ] && ci=i
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      f=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}; text=${rest#*:}
      if [ "$rule" = secret-assignment ]; then
        is_test_path "$f" && continue
        LC_ALL=C grep -qiE "$PLACEHOLDER" <<<"$text" && continue
        LC_ALL=C grep -qE '://' <<<"$text" && continue
      fi
      fail "$f:$line: $rule"
    done < <(LC_ALL=C xargs -0 grep -In"$ci"HE -e "$re" -- <"$LIST" 2>/dev/null)
  done <<<"$RULES"
fi

if [ $rc = 0 ]; then
  echo "secrets-check: ok ($nfiles files$([ "$STAGED" = 1 ] && echo ', staged'))"
else
  echo "secrets-check: FAIL (a committed credential is rotated, then removed from history; a fixture's fake key is named in $ALLOW with its reason)" >&2
fi
exit $rc
