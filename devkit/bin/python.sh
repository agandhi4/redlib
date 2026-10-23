#!/usr/bin/env bash
# Run devkit's python3 (bin/_toolchain_lib.sh: >= 3.11, found without trusting PATH) with these
# arguments, for callers that are not bash: a Makefile (`PYTHON := bin/python.sh`) and the
# metrics merge driver git runs (bin/_gitattributes_lib.sh).
# Usage: devkit/bin/python.sh [python args...]
# Exit: python's own status, or 2 when this box has no qualifying python3 (the reason on stderr).
set -uo pipefail

# shellcheck source=bin/_toolchain_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_toolchain_lib.sh"
devkit_python || { echo "python.sh: $DEVKIT_PYTHON_ERROR" >&2; exit 2; }
exec "$DEVKIT_PYTHON" "$@"
