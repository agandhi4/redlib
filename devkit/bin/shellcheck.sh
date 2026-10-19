#!/usr/bin/env bash
# Runs shellcheck the way the fleet does: devkit's pinned version (release_tool.sh) over devkit's base
# config (lint/shellcheckrc) with the repo's own .shellcheckrc appended. metrics/shell.py and a
# scaffold's lint step both call this, so the hook, the gate and the metric read one config.
# Usage (from the repo root): devkit/bin/shellcheck.sh [shellcheck args...] <files...>
#
# Why a merged --rcfile: shellcheckrc has no include, and shellcheck reads only the first
# .shellcheckrc it finds. Later lines win for scalar keys and disable/enable accumulate, so
# appending is the kit's base-merge rule (lint/README.md "Bases the collectors merge").
# Exit: shellcheck's own (0 clean, 1 findings), 2 when it cannot be provided or run.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=$(mktemp "${TMPDIR:-/tmp}/devkit-shellcheckrc.XXXXXX")
trap 'rm -f "$rc"' EXIT
cat "$here/../lint/shellcheckrc" >"$rc"
[ ! -f .shellcheckrc ] || cat .shellcheckrc >>"$rc"
status=0
"$here/release_tool.sh" shellcheck -- shellcheck --rcfile "$rc" "$@" || status=$?
exit "$status"
