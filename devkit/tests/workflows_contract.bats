#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031  # each @test is its own subshell by design; nothing leaks between tests
# shellcheck disable=SC2016  # fixtures hold literal ${{ }} text on purpose
# Contract tests for bin/workflows_check.sh. Each test writes workflows into a temp repo; `@PIN`
# in a fixture becomes a 40-hex SHA. The two base fixtures (quick-check, publish) pass every
# rule, so a test that changes one thing proves that one rule.

CHECK="$BATS_TEST_DIRNAME/../bin/workflows_check.sh"
SHA=0123456789abcdef0123456789abcdef01234567

setup() {
  TMP=$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/workflows.XXXXXX")
  REPO=$TMP/repo
  WF=$REPO/.github/workflows
  mkdir -p "$WF"
}

teardown() {
  rm -rf "$TMP"
}

wf() { # <file name>; workflow body on stdin
  sed "s/@PIN/@$SHA/g" >"$WF/$1"
}
edit() { # <sed script> <file name>; BSD and GNU sed alike
  sed -i.bak "$1" "$WF/$2" && rm -f "$WF/$2.bak"
}

quick_check() { # [job-level if] — the template caller's shape, one job
  wf quick-check.yml <<EOF
name: Quick check
on:
  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened, ready_for_review]
    paths-ignore:
      - '**.md'
      - 'docs/**'
concurrency:
  group: quick-check-\${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  quick-check:
    if: ${1:-github.event.pull_request.draft == false}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@PIN # v7.0.1
      - run: make ci-quick
EOF
}

publish() { # [cancel-in-progress value]
  wf publish.yml <<EOF
name: Publish
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  publish:
    if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'
    concurrency:
      group: publish-main
      cancel-in-progress: ${1:-false}
    steps:
      - uses: actions/checkout@PIN # v7.0.1
      - uses: docker/build-push-action@PIN # v7.4.0
        with:
          push: true
          build-args: APP_VERSION=\${{ github.sha }}
EOF
}

# --- baseline -------------------------------------------------------------------------------

@test "no workflows dir: note and exit 0" {
  rm -rf "$REPO/.github"
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "workflows-check: no .github/workflows; nothing to check" ]
}

@test "compliant quick-check and publish pass with the workflow count" {
  quick_check; publish
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "workflows-check: ok (2 workflows)" ]
}

@test "a .yaml workflow is checked too" {
  quick_check
  mv "$WF/quick-check.yml" "$WF/quick-check.yaml"
  edit "s/@$SHA/@v4/" quick-check.yaml
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"quick-check.yaml:17: actions/checkout@v4 is not pinned"* ]]
}

# --- rule 1: SHA pins -----------------------------------------------------------------------

@test "pins: a tag ref fails with file and line" {
  wf x.yml <<'EOF'
on: workflow_dispatch
jobs:
  a:
    steps:
      - uses: actions/checkout@v4
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workflows-check: .github/workflows/x.yml:5: actions/checkout@v4 is not pinned to a 40-hex commit SHA"* ]]
  [[ "$output" == *"workflows-check: FAIL"* ]]
}

@test "pins: a SHA without a version comment fails; a major-only comment fails" {
  wf x.yml <<'EOF'
on: workflow_dispatch
jobs:
  a:
    steps:
      - uses: actions/checkout@PIN
      - uses: actions/setup-node@PIN # v4
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"x.yml:5: actions/checkout SHA pin needs a '# vX.Y.Z' comment (got 'none')"* ]]
  [[ "$output" == *"x.yml:6: actions/setup-node SHA pin needs a '# vX.Y.Z' comment (got 'v4')"* ]]
}

@test "pins: SHA + vX.Y.Z, quoted uses, sub-path actions and local actions pass" {
  wf x.yml <<'EOF'
on: workflow_dispatch
jobs:
  a:
    steps:
      - uses: actions/checkout@PIN # v7.0.1
      - name: restore
        uses: "actions/cache/restore@PIN" # v4.2.3
      - uses: ./.github/actions/setup
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "workflows-check: ok (1 workflows)" ]
}

@test "pins: devkit reusable workflow passes at @main or a SHA, fails at a tag" {
  wf a.yml <<'EOF'
on: workflow_dispatch
jobs:
  quick-check:
    uses: agandhi4/devkit/.github/workflows/quick-check.yml@main
  again:
    uses: agandhi4/devkit/.github/workflows/quick-check.yml@PIN
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
  wf a.yml <<'EOF'
on: workflow_dispatch
jobs:
  quick-check:
    uses: agandhi4/devkit/.github/workflows/quick-check.yml@v1
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.yml:4: devkit reusable workflow must be @main or a commit SHA (got @v1)"* ]]
}

@test "pins: another repo's reusable workflow follows the SHA rule" {
  wf a.yml <<'EOF'
on: workflow_dispatch
jobs:
  x:
    uses: someone/else/.github/workflows/w.yml@main
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.yml:4: someone/else/.github/workflows/w.yml@main is not pinned"* ]]
}

@test "pins: a docker:// action needs a digest" {
  wf a.yml <<'EOF'
on: workflow_dispatch
jobs:
  x:
    steps:
      - uses: docker://alpine:3.20
      - uses: docker://alpine@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.yml:5: docker://alpine:3.20 is not pinned by @sha256: digest"* ]]
  [[ "$output" != *"a.yml:6:"* ]]
}

# --- rule 2: draft skip, concurrency, paths-ignore ------------------------------------------

@test "pr: a job without a draft skip fails" {
  quick_check "github.actor != 'bot'"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"quick-check.yml:13: job quick-check runs on pull_request without a draft skip"* ]]
}

@test "pr: '!github.event.pull_request.draft' in \${{ }} is a draft skip" {
  quick_check '${{ !github.event.pull_request.draft }}'
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "pr: a step-level draft skip counts" {
  wf q.yml <<'EOF'
on:
  pull_request:
    paths-ignore: ['**/*.md']
concurrency:
  group: q-${{ github.ref }}
  cancel-in-progress: true
jobs:
  q:
    steps:
      - if: github.event.pull_request.draft == false
        run: make ci-quick
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "pr: types limited to ready_for_review need no draft skip" {
  wf q.yml <<'EOF'
on:
  pull_request:
    types: [ready_for_review]
    paths-ignore: ['**.md']
concurrency:
  group: q
  cancel-in-progress: true
jobs:
  q:
    steps:
      - run: make ci-quick
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "pr: a merged-only job (no draft is ever merged) counts as a draft skip" {
  wf t.yml <<'EOF'
on:
  pull_request:
    types: [closed]
    paths-ignore: ['**.md']
concurrency:
  group: t
  cancel-in-progress: true
jobs:
  tag:
    if: github.event.pull_request.merged == true
    steps:
      - run: echo tag
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "pr: no concurrency fails; job-level cancel-in-progress true passes" {
  quick_check
  edit '/^concurrency:/,/cancel-in-progress/d' quick-check.yml
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"job quick-check runs on pull_request without concurrency cancel-in-progress: true (job or workflow level)"* ]]
  rm "$WF/quick-check.yml"
  wf q.yml <<'EOF'
on:
  pull_request:
    paths-ignore: ['**.md']
jobs:
  q:
    if: github.event.pull_request.draft == false
    concurrency:
      group: q-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - run: make ci-quick
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "pr: cancel-in-progress false fails; the pull_request-only expression passes" {
  quick_check
  edit 's/cancel-in-progress: true/cancel-in-progress: false/' quick-check.yml
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  edit "s/cancel-in-progress: false/cancel-in-progress: \${{ github.event_name == 'pull_request' }}/" quick-check.yml
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "pr: an unevaluable cancel-in-progress expression fails" {
  quick_check
  edit 's/cancel-in-progress: true/cancel-in-progress: ${{ inputs.cancel }}/' quick-check.yml
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cancel-in-progress is an expression this check cannot evaluate"* ]]
}

@test "pr: missing paths-ignore for markdown fails at the trigger line" {
  quick_check
  edit "/'\*\*.md'/d" quick-check.yml
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"quick-check.yml:3: pull_request has no paths-ignore for '**.md'"* ]]
}

@test "pr: a positive paths: list excluding markdown passes" {
  quick_check
  edit "s/paths-ignore:/paths:/; s/- '\*\*.md'/- '!**.md'/" quick-check.yml
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "pr: inline 'on: [pull_request]' is a pull_request trigger" {
  wf q.yml <<'EOF'
on: [pull_request, workflow_dispatch]
jobs:
  q:
    steps:
      - run: make ci-quick
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"q.yml:1: pull_request has no paths-ignore"* ]]
  [[ "$output" == *"q.yml:3: job q runs on pull_request without a draft skip"* ]]
}

@test "workflow_call-only: warns that the caller owns the trigger rules, exit 0" {
  wf reusable.yml <<'EOF'
on:
  workflow_call:
    inputs:
      t: { type: string }
jobs:
  r:
    steps:
      - run: make "$T"
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflows-check: warning: .github/workflows/reusable.yml:1: workflow_call-only"* ]]
  [[ "$output" == *"workflows-check: ok (1 workflows)"* ]]
}

# --- rule 3: one job per PR -----------------------------------------------------------------

two_pr_jobs() { # [top-level comment]
  wf q.yml <<EOF
$1
on:
  pull_request:
    paths-ignore: ['**.md']
concurrency:
  group: q
  cancel-in-progress: true
jobs:
  lint:
    if: github.event.pull_request.draft == false
    steps:
      - run: make lint
  test:
    if: github.event.pull_request.draft == false
    steps:
      - run: make test
  heavy:
    if: github.event_name == 'workflow_dispatch'
    steps:
      - run: make ci-db
EOF
}

@test "one job: two jobs on pull_request fail; a dispatch-only job is not counted" {
  two_pr_jobs
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"q.yml:13: pull_request runs 2 jobs (lint, test); one quick-check job per PR"* ]]
}

@test "one job: the multi-job comment with a reason exempts the workflow" {
  two_pr_jobs "# workflows-check: multi-job ok: fork keeps upstream's CI"
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

@test "one job: the multi-job comment without a reason does not exempt" {
  two_pr_jobs "# workflows-check: multi-job ok:"
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
}

@test "one job: a combined PR + push workflow counts only the jobs a PR can run" {
  wf build.yml <<'EOF'
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
    paths-ignore: ['**/*.md']
  push:
    branches: [main]
concurrency:
  group: ${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  quick-check:
    if: >-
      (github.event_name == 'pull_request' && !github.event.pull_request.draft)
    steps:
      - run: make ci-quick
  image:
    if: >-
      github.event_name == 'push'
    concurrency:
      group: publish-main
      cancel-in-progress: false
    steps:
      - run: docker build -t x --build-arg APP_VERSION=1 . && docker push x
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
}

# --- rule 4: publish never cancels mid-push -------------------------------------------------

@test "publish: cancel-in-progress true on the pushing job fails" {
  publish true
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"publish.yml:7: job publish pushes an image on push to main under cancel-in-progress: true"* ]]
}

@test "publish: a workflow-level cancel-in-progress true fails the pushing job" {
  wf publish.yml <<'EOF'
on:
  push:
    branches: [main]
concurrency:
  group: all
  cancel-in-progress: true
jobs:
  publish:
    steps:
      - run: docker push ghcr.io/x/y:sha-1
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"publish.yml:8: job publish pushes an image on push to main under cancel-in-progress: true"* ]]
}

@test "publish: no concurrency at all fails" {
  wf publish.yml <<'EOF'
on:
  push:
    branches: [main]
jobs:
  publish:
    steps:
      - uses: docker/build-push-action@PIN # v7.4.0
        with:
          push: true
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"publish.yml:5: job publish pushes an image on push to main without concurrency cancel-in-progress: false"* ]]
}

@test "publish: a non-pushing build, a tags-only trigger and a dispatch-only job are not judged" {
  wf a.yml <<'EOF'
on:
  push:
    branches: [main]
jobs:
  build:
    steps:
      - uses: docker/build-push-action@PIN # v7.4.0
        with:
          push: false
EOF
  wf b.yml <<'EOF'
on:
  push:
    tags: ['v*']
jobs:
  release:
    steps:
      - run: docker push x
EOF
  wf c.yml <<'EOF'
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  republish:
    if: github.event_name == 'workflow_dispatch'
    steps:
      - run: docker push x
EOF
  run "$CHECK" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "workflows-check: ok (3 workflows)" ]
}
