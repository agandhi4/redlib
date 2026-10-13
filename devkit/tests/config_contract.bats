#!/usr/bin/env bats
# shellcheck shell=bash
# Contract tests for devkit's config-shaped files: the Renovate preset, the reusable quick-check
# workflow and its caller template, the shared ruff base. They parse, and consumers can rely on
# the names they reference. Offline; parsers are whatever the machine has (jq, ruby or PyYAML,
# python3 tomllib), with a skip naming the missing one rather than a silent pass.

ROOT="$BATS_TEST_DIRNAME/.."
PRESET="$ROOT/renovate/default.json"
CONSUMER="$ROOT/renovate/consumer.example.json"
QUICK_CHECK="$ROOT/.github/workflows/quick-check.yml"
CALLER="$ROOT/templates/workflows/quick-check-caller.yml"
RUFF="$ROOT/lint/ruff.toml"

parse_yaml() { # <file>: exit 0 iff the file is valid YAML
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$1"
  elif python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$1"
  else
    skip "no YAML parser (ruby or python3 PyYAML)"
  fi
}

# Every `uses:` value that is not a 40-hex SHA followed by a `# vX` tag comment.
unpinned_uses() { # <file>...
  grep -hE '^[[:space:]-]*uses:' "$@" |
    grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]' || true
}

@test "renovate preset and consumer example are valid JSON" {
  jq -e . "$PRESET" >/dev/null
  jq -e . "$CONSUMER" >/dev/null
}

@test "consumer example extends exactly the devkit preset" {
  run jq -r '.extends | join(",")' "$CONSUMER"
  [ "$status" -eq 0 ]
  [ "$output" = "github>agandhi4/devkit//renovate/default" ]
}

@test "renovate preset never automerges: Renovate PRs never get the local-gate status" {
  run jq -r '[.automerge, .lockFileMaintenance.automerge, (.packageRules[] | .automerge // false)] | any' "$PRESET"
  [ "$output" = "false" ]
}

@test "renovate preset groups every node copy into one PR, after the category groups" {
  run jq -r '.packageRules | map(.matchDepNames // [] | index("node") != null) | index(true)' "$PRESET"
  node_rule=$output
  [ "$node_rule" != "null" ]
  run jq -r --argjson i "$node_rule" '.packageRules[$i].groupName' "$PRESET"
  [ "$output" = "node toolchain" ]
  # packageRules apply in order, so the node group must come after every category group.
  run jq -r --argjson i "$node_rule" '[.packageRules | to_entries[] | select(.value.matchCategories) | .key] | max < $i' "$PRESET"
  [ "$output" = "true" ]
}

@test "reusable quick-check is valid YAML and a workflow_call" {
  parse_yaml "$QUICK_CHECK"
  parse_yaml "$CALLER"
  grep -qE '^  workflow_call:' "$QUICK_CHECK"
}

@test "every action in devkit workflows is SHA-pinned with a version comment" {
  run unpinned_uses "$ROOT"/.github/workflows/*.yml
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "unpinned: $output"; false; }
}

@test "reusable quick-check sets up Node only when the repo pins it" {
  # homelab has no .nvmrc; an unconditional setup-node fails at "file does not exist".
  grep -B1 -F 'uses: actions/setup-node@' "$QUICK_CHECK" | grep -qF "if: hashFiles(inputs.node-version-file) != ''"
}

@test "caller template pins its actions and calls the devkit reusable workflow" {
  run unpinned_uses "$CALLER"
  [ "$output" = "    uses: agandhi4/devkit/.github/workflows/quick-check.yml@main" ]
  grep -qF "if: github.event.pull_request.draft == false" "$CALLER"
  grep -qE '^concurrency:' "$CALLER"
}

@test "devkit CI runs its own guards, even on a PR that only touches the docs they judge" {
  local ci="$ROOT/.github/workflows/ci.yml" paths
  # The pull_request `paths` line: markdown is excluded, then the files docs_check judges are
  # re-included after it (GitHub applies the list in order). Ignoring them let devkit ship
  # without its CLAUDE.md symlink and break every consumer's docs-check (2026-10-13).
  paths=$(grep -E "^[[:space:]]*paths:.*'!\*\*\.md'" "$ci")
  [[ "$paths" == *"'!**.md', "*"'**/AGENTS.md'"* ]]
  [[ "$paths" == *"'!**.md', "*"'**/CLAUDE.md'"* ]]
  [[ "$paths" == *"'!docs/**', "*"'docs/decisions.md'"* ]]
  grep -qE '^[[:space:]]*bin/docs_check\.sh \. ' "$ci"
  grep -qE '^[[:space:]]*bin/workflows_check\.sh \. ' "$ci"
}

@test "devkit CI runs when a draft PR is marked ready, not only on its next push" {
  local ci="$ROOT/.github/workflows/ci.yml"
  # The job skips drafts, and pull_request's default types omit ready_for_review, so without it
  # a PR opened as a draft got no CI run until another push (2026-10-13).
  grep -qxF '    types: [opened, synchronize, reopened, ready_for_review]' "$ci"
  grep -qF "github.event.pull_request.draft == false" "$ci"
}

@test "ruff base is valid TOML with the shared keys and no project-specific ones" {
  python3 -c 'import tomllib' 2>/dev/null || skip "python3 lacks tomllib (needs 3.11+)"
  run python3 -c '
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))
assert c["target-version"] == "py313" and c["line-length"] == 100, c
assert c["lint"]["select"] == ["E", "F", "I", "N", "W", "UP"], c
assert "src" not in c and "isort" not in c["lint"], "per-project keys belong in the consumer"
' "$RUFF"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
