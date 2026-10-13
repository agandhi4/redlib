#!/usr/bin/env bash
# Install the Playwright browsers a project's lockfile pins, from one call site for gates, hooks
# and CI. Replaces per-repo habits that drifted: Orbit's e2e/run.sh installed on every run, finplat
# and closet never installed locally (a @playwright/test bump failed the Mac gate with "Executable
# doesn't exist" until someone ran the install by hand), and CI repeated the step five times.
#
# Usage: devkit/bin/playwright_browsers.sh [--with-deps] [--project-dir <dir>] [browser...]
#   browser...      default: chromium
#   --project-dir   the package dir holding the lockfile; default: cwd
#   --with-deps     also install system packages; Linux only, ignored with a warning on macOS
#                   so CI steps and the Mac can pass the same flags
#   Exit 0 ok, 1 install, version or Node provisioning failure, 2 usage or no lockfile.
#
# The runner follows the lockfile (pnpm-lock.yaml, package-lock.json, yarn.lock, bun.lock[b]), so
# the playwright that runs is the one the project pins. PLAYWRIGHT_RUNNER overrides it with a
# command prefix that ends in playwright, word-split on whitespace (e.g. "npx --no-install
# playwright"); paths containing spaces are not supported there.
# Idempotency is Playwright's: install skips revisions already in its cache. This script keeps no
# cache of its own and never inspects Playwright's.
# Node comes from the nearest .nvmrc between the project dir and the git toplevel, via
# node_toolchain.sh, the same way local_gate.sh provisions it; without one, PATH's node is used.
set -euo pipefail

usage() { echo "usage: $0 [--with-deps] [--project-dir <dir>] [browser...]" >&2; exit 2; }

WITH_DEPS=0
PROJECT_DIR=.
BROWSERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --with-deps) WITH_DEPS=1 ;;
    --project-dir) [ $# -ge 2 ] || usage; PROJECT_DIR=$2; shift ;;
    --project-dir=*) PROJECT_DIR=${1#--project-dir=} ;;
    -h|--help) usage ;;
    -*) echo "playwright_browsers: unknown option $1" >&2; usage ;;
    *) BROWSERS+=("$1") ;;
  esac
  shift
done
[ ${#BROWSERS[@]} -gt 0 ] || BROWSERS=(chromium)

[ -d "$PROJECT_DIR" ] || { echo "playwright_browsers: project dir $PROJECT_DIR does not exist" >&2; exit 2; }
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd -P)

if [ -n "${PLAYWRIGHT_RUNNER:-}" ]; then
  read -r -a RUNNER <<<"$PLAYWRIGHT_RUNNER"
elif [ -f "$PROJECT_DIR/pnpm-lock.yaml" ]; then
  RUNNER=(corepack pnpm exec playwright)
elif [ -f "$PROJECT_DIR/package-lock.json" ]; then
  RUNNER=(npx --no-install playwright)
elif [ -f "$PROJECT_DIR/yarn.lock" ]; then
  RUNNER=(yarn playwright)
elif [ -f "$PROJECT_DIR/bun.lock" ] || [ -f "$PROJECT_DIR/bun.lockb" ]; then
  RUNNER=(bunx playwright)
else
  echo "playwright_browsers: no lockfile (pnpm-lock.yaml, package-lock.json, yarn.lock, bun.lock) in $PROJECT_DIR" >&2
  exit 2
fi

# Nearest .nvmrc from the project dir up to the git toplevel (a monorepo's web/ package inherits
# the root's). Outside a git repo only the project dir itself is checked.
TOP=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")
TOP=$(cd "$TOP" && pwd -P)
NODE_ROOT=
DIR=$PROJECT_DIR
while :; do
  if [ -f "$DIR/.nvmrc" ]; then NODE_ROOT=$DIR; break; fi
  if [ "$DIR" = "$TOP" ] || [ "$DIR" = / ]; then break; fi
  DIR=$(dirname "$DIR")
done
if [ -n "$NODE_ROOT" ]; then
  if ! NODE_BIN=$("$(dirname "${BASH_SOURCE[0]}")/node_toolchain.sh" "$NODE_ROOT"); then
    echo "playwright_browsers: cannot provide node $(tr -d '[:space:]' < "$NODE_ROOT/.nvmrc") declared in $NODE_ROOT/.nvmrc" >&2
    exit 1
  fi
  [ -n "$NODE_BIN" ] && export PATH="$NODE_BIN:$PATH"
fi
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0   # a corepack prompt would hang an unattended run

INSTALL_FLAGS=()
if [ "$WITH_DEPS" = 1 ]; then
  if [ "$(uname -s)" = Linux ]; then
    INSTALL_FLAGS=(--with-deps)
  else
    echo "playwright_browsers: --with-deps ignored on macOS (no system deps to install)" >&2
  fi
fi

cd "$PROJECT_DIR"
if ! "${RUNNER[@]}" install ${INSTALL_FLAGS[@]+"${INSTALL_FLAGS[@]}"} "${BROWSERS[@]}"; then
  echo "playwright_browsers: '${RUNNER[*]} install' failed in $PROJECT_DIR" >&2
  exit 1
fi
if ! VERSION_OUT=$("${RUNNER[@]}" --version); then
  echo "playwright_browsers: '${RUNNER[*]} --version' failed in $PROJECT_DIR" >&2
  exit 1
fi
VERSION=$(printf '%s\n' "$VERSION_OUT" | awk 'NF { v = $NF } END { print v }')   # "Version 1.63.0"
[ -n "$VERSION" ] || { echo "playwright_browsers: empty version from '${RUNNER[*]} --version'" >&2; exit 1; }
echo "playwright_browsers: ${BROWSERS[*]} ready (playwright $VERSION)"
