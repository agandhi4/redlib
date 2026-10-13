#!/usr/bin/env bash
# `make gate` entry point: runs the PR gate on this machine (local_gate.sh) or on the gate host
# (remote_gate.sh). Every repo's Makefile calls this one line, so where gates run is a property
# of the machine, not of the repo:
#
#   gate: ; devkit/bin/gate.sh "$(PR)" $(GATE_ARGS)
#
# Remote when GATE_REMOTE_HOST is set (environment, or ~/.config/devkit/gate.env), unless:
#   - the repo's plan has a literal `GATE_REMOTE=0` line: the repo cannot be gated elsewhere
#     (an Xcode gate needs this Mac). The plan wins over everything below.
#   - GATE_REMOTE=0 (environment or gate.env): this run, or this machine, stays local.
#   - GATE_PLAN is set: a plan file outside the repo exists only on this machine.
# GATE_REMOTE=1 with no host is a usage error, never a silent local run.
# Exit codes are those of the gate that runs (0 pass, 1 fail, 2 usage or environment).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
# shellcheck source=bin/_gate_env.sh
. "$HERE/_gate_env.sh"

gate_env_load gate "$GATE_REMOTE_KEYS" "$GATE_LOCAL_KEYS"
gate_remote_settings_check

ROOT=$(git -C "$HERE" rev-parse --show-toplevel) || exit 2
PLAN=$ROOT/scripts/ci/gate_plan.sh

where=local
if [ -n "${GATE_PLAN:-}" ]; then
  where=local
elif [ -f "$PLAN" ] && [ "$(gate_plan_literal "$PLAN" GATE_REMOTE)" = 0 ]; then
  where=local
elif [ "${GATE_REMOTE:-}" = 0 ]; then
  where=local
elif [ -n "${GATE_REMOTE_HOST:-}" ]; then
  where=remote
elif [ "${GATE_REMOTE:-}" = 1 ]; then
  echo "gate: GATE_REMOTE=1 but GATE_REMOTE_HOST is not set (environment or gate.env)" >&2
  exit 2
fi

if [ "$where" = remote ]; then exec "$HERE/remote_gate.sh" "$@"; fi
exec "$HERE/local_gate.sh" "$@"
