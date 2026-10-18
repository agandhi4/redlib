# shellcheck shell=bash disable=SC2034  # GATE_* are read by the skeleton that sources this
# redlib's gate plan, sourced by devkit/bin/local_gate.sh (contract in its header). Jobs are
# declared per group; devkit_default_gate_plan (devkit/bin/_paths_lib.sh) picks which run from
# the changed paths' areas, the same table the hooks use. Every job is a `make` target (Makefile).
#
#   *.md, docs/** only                   -> docs (docs-check)
#   devkit/, .devkit-rev, hooks only     -> quick (ci-quick runs docs-check and every guard)
#   anything else (src/, static/, templates/, Cargo.*, Makefile, scripts/, .github/, ...)
#                                        -> quick + unit + image, then ci-metrics last
#                                           (scripts/ci/metrics.conf); image skips only when
#                                           every path is in GATE_IMAGE_EXCLUDE_PATHS
# Rust sources sit at the repo root, so the table calls them "other", which runs every group
# whose areas include it; static/ and templates/ are compiled into the binary (include_str!,
# Askama), so they are code like src/.
# There is no smoke job: the listener opens only after OAuth bootstrap against Reddit
# (AGENTS.md "Startup order"), so no health path answers without live Reddit. ci-image asserts
# the image ENV and OCI label carry gate-<pr> instead (release identity).
GATE_SLUG=agandhi4/redlib
GATE_STATE_NAME=redlib-gate

IMAGE="redlib:gate-$PR"

GATE_JOBS_QUICK="quick ci-quick"
GATE_JOBS_DOCS="docs docs-check"
GATE_JOBS_BACKEND="unit ci-unit"
# devkit runs it last and passes METRICS_REBASELINE=1 when the PR carries the
# metrics-rebaseline label. vuln-app queries OSV, so the gate host needs outbound network.
GATE_JOBS_METRICS="metrics ci-metrics"
GATE_JOBS_IMAGE="image ci-image CI_IMAGE=$IMAGE CI_BUILD_VERSION=gate-$PR"
# Every app path builds the image (devkit 2026-10-17: a plan excludes paths, never areas). These
# reach no stage's output: .github/ is in .dockerignore; the rest are copied by `COPY . ./` but
# read by neither cargo build nor the release stage (only src/, static/, templates/, build.rs,
# Cargo.* and rust-toolchain.toml are). .gitattributes stays out of this list: it changes the
# checked-out bytes of the files include_str! embeds.
GATE_IMAGE_EXCLUDE_PATHS='^(\.github/|scripts/|extensions/|docs/metrics/|\.githooks/|clippy\.toml$|rustfmt\.toml$|renovate\.json$|\.env\.example$|\.gitignore$|CREDITS$|LICENSE$)'
# Re-included from the scripts/ exclusion: this file declares the ci-image job.
GATE_IMAGE_PATHS='^scripts/ci/gate_plan\.sh$'

gate_cleanup() {
  docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
}

gate_plan() {
  devkit_default_gate_plan
}
