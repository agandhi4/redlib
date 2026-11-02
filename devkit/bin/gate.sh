#!/usr/bin/env bash
# The retired `make gate`: one line naming the merge path, exit 0. A consumer's Makefile still
# calls `devkit/bin/gate.sh "$(PR)" $(GATE_ARGS)` until it drops the target, and a lane or a
# runbook that still runs it must not fail. Why (owner, 2026-11-02): no pre-merge gate;
# `make merge` decides on review rounds (bin/merge_rules.sh) and every check runs before a deploy.
echo "gate: retired (devkit 2026-11-02); run make review PR=<n>, then make merge PR=<n>"
