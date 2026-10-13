#!/usr/bin/env bash
# Scaffold a new repo that passes every devkit guard on its first commit.
#
# Usage: devkit-new.sh <name> --stack <stack> [--dir <parent>] [--no-image]
#   name        repo, image and container name: lowercase, digits and dashes
#   --stack     a directory under templates/new/stacks/ (python-fastapi, node-service)
#   --dir       parent directory; the repo is <dir>/<name> (default: the current directory)
#   --no-image  no Dockerfile, publish workflow or smoke; ci-image and ci-smoke become stubs
#   --list      print the stacks and exit
#   Exit 0 ok, 1 a step failed (the directory is left for inspection), 2 usage or a missing tool.
# Env: DEVKIT_URL and DEVKIT_REF name what to vendor (devkit-sync.sh; default upstream main).
#      The tests point them at a local checkout.
#
# What a generated repo contains and in what order it is built:
#   1. `git init -b main <dir>/<name>`
#   2. devkit-sync.sh --stage: devkit/ + .devkit-rev in the index (the one tree-replacement
#      implementation; nothing here knows how vendoring works)
#   3. templates/new/common/, then templates/new/stacks/<stack>/, rendered: __NAME__,
#      __DATE__, __DEVKIT_SHA7__, __STACK__ and the stack.conf fields replaced; lines between
#      `#@image` / `#@no-image` and `#@end` kept or dropped by --no-image. CLAUDE.md is a
#      symlink to AGENTS.md (owner decision 2026-10-12).
#   4. the parts that already exist elsewhere in devkit, copied, never re-typed: the git hooks
#      (templates/githooks), the Renovate consumer file (renovate/consumer.example.json), the
#      quick-check caller (templates/workflows; the reusable workflow sets up Node only when
#      .nvmrc exists, so a Python-only repo needs no input)
#   5. the stack's lock command (uv lock, npm install --package-lock-only), so the frozen
#      install in ci-quick has a lockfile to be frozen to
#   6. core.hooksPath=.githooks, then ONE commit with everything. pre-commit runs
#      `make ci-quick` on the scaffold: devkit-check (index tree), toolchain-check, docs-check,
#      release-check, workflows-check, the stack's own guards and linters. A scaffold the hooks
#      refuse is a devkit bug, not a repo to fix by hand.
# The follow-ups GitHub needs (repo settings, labels, Renovate access, the homelab stack) are
# printed at the end and listed in the README ("New project").
#
# Adding a stack: templates/new/README.md.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEVKIT=$(cd "$HERE/.." && pwd)
TEMPLATES=$DEVKIT/templates/new
STACKS=$TEMPLATES/stacks

usage() { echo "usage: $0 <name> --stack <stack> [--dir <parent>] [--no-image] | --list" >&2; exit 2; }
die() { echo "devkit-new: $*" >&2; exit 1; }

list_stacks() {
  local conf
  for conf in "$STACKS"/*/stack.conf; do
    [ -f "$conf" ] || continue
    STACK_DESCRIPTION=''
    # shellcheck source=/dev/null  # the stack's own config; keys in templates/new/README.md
    . "$conf"
    printf '%-16s %s\n' "$(basename "$(dirname "$conf")")" "$STACK_DESCRIPTION"
  done
}

NAME='' STACK='' PARENT=$PWD IMAGE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) [ $# -ge 2 ] || usage; STACK=$2; shift ;;
    --dir) [ $# -ge 2 ] || usage; PARENT=$2; shift ;;
    --no-image) IMAGE=0 ;;
    --list) list_stacks; exit 0 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$NAME" ] || usage; NAME=$1 ;;
  esac
  shift
done
[ -n "$NAME" ] && [ -n "$STACK" ] || usage
case "$NAME" in
  [a-z]*) [[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || die "name '$NAME' must be lowercase letters, digits and dashes" ;;
  *) die "name '$NAME' must start with a lowercase letter" ;;
esac
STACK_DIR=$STACKS/$STACK
[ -f "$STACK_DIR/stack.conf" ] || { echo "devkit-new: unknown stack '$STACK'; stacks:" >&2; list_stacks >&2; exit 2; }
PARENT=$(cd "$PARENT" 2>/dev/null && pwd) || die "parent directory does not exist: $PARENT"
REPO=$PARENT/$NAME
[ ! -e "$REPO" ] || die "$REPO already exists; devkit new never writes into an existing directory"

# Stack config: every key is documented in templates/new/README.md.
STACK_DESCRIPTION='' STACK_CONVENTIONS='' STACK_PINS='' STACK_TOOL='' STACK_LOCK_CMD='' STACK_IMAGE_FILES='' STACK_STUBS=''
# shellcheck source=/dev/null
. "$STACK_DIR/stack.conf"
for key in STACK_CONVENTIONS STACK_PINS STACK_TOOL STACK_LOCK_CMD; do
  [ -n "${!key}" ] || die "$STACK/stack.conf must set $key"
done
command -v "$STACK_TOOL" >/dev/null || { echo "devkit-new: '$STACK_TOOL' not found on PATH; the $STACK stack needs it to write the lockfile" >&2; exit 2; }
command -v make >/dev/null || { echo "devkit-new: make not found on PATH; the first commit runs make ci-quick" >&2; exit 2; }

DATE=$(date +%F)

# render <src> <dst>: substitute placeholders, keep or drop #@image / #@no-image blocks, keep
# the execute bit. Markers must start at column 0; they are never emitted.
render() {
  local src=$1 dst=$2
  mkdir -p "$(dirname "$dst")"
  awk -v image="$IMAGE" '
    /^#@image$/    { skip = !image; next }
    /^#@no-image$/ { skip = image + 0 == 1; next }
    /^#@end$/      { skip = 0; next }
    !skip { print }
  ' "$src" |
  sed -e "s/__NAME__/$NAME/g" -e "s/__DATE__/$DATE/g" -e "s/__DEVKIT_SHA7__/$DEVKIT_SHA7/g" \
      -e "s/__STACK__/$STACK/g" -e "s/__CONVENTIONS__/$STACK_CONVENTIONS/g" \
      -e "s/__PINS__/$STACK_PINS/g" -e "s/__STUBS__/$STACK_STUBS/g" > "$dst"
  [ ! -x "$src" ] || chmod +x "$dst"
}

# render_tree <template dir>: every regular file, dotfiles included; symlinks are recreated
# with the same target (CLAUDE.md -> AGENTS.md).
render_tree() {
  local dir=$1 path rel
  while IFS= read -r path; do
    rel=${path#"$dir"/}
    case "$rel" in stack.conf) continue ;; esac
    if [ -L "$path" ]; then
      mkdir -p "$(dirname "$REPO/$rel")"
      ln -s "$(readlink "$path")" "$REPO/$rel"
    else
      render "$path" "$REPO/$rel"
    fi
  done < <(find "$dir" \( -type f -o -type l \) | LC_ALL=C sort)
}

echo "devkit-new: creating $REPO ($STACK, image=$IMAGE)"
git init -q -b main "$REPO"
cd "$REPO"

"$HERE/devkit-sync.sh" --stage "${DEVKIT_REF:-main}"
DEVKIT_SHA7=$(cut -c1-7 .devkit-rev)

render_tree "$TEMPLATES/common"
render_tree "$STACK_DIR"

mkdir -p .githooks .github/workflows
cp "$DEVKIT/templates/githooks/pre-commit" "$DEVKIT/templates/githooks/pre-push" .githooks/
chmod +x .githooks/pre-commit .githooks/pre-push
cp "$DEVKIT/renovate/consumer.example.json" renovate.json
cp "$DEVKIT/templates/workflows/quick-check-caller.yml" .github/workflows/quick-check.yml

if [ "$IMAGE" = 0 ]; then
  rm -f .github/workflows/publish.yml
  for f in $STACK_IMAGE_FILES; do rm -f "$f"; done
fi

echo "devkit-new: $STACK_LOCK_CMD"
$STACK_LOCK_CMD

# Set directly rather than through hooks_check.sh --fix: that script is a no-op under CI, and
# the first commit must run the hooks there too (the bats contract test runs in Actions).
git config core.hooksPath .githooks
git add -A
echo "devkit-new: first commit, through the hooks (pre-commit runs make ci-quick)"
git commit -q -m "Create $NAME with devkit new ($STACK, devkit $DEVKIT_SHA7)

Scaffolded by devkit/bin/devkit-new.sh: vendored devkit/, the standard ci-* Makefile,
scripts/ci/gate_plan.sh, git hooks, the quick-check caller, Renovate's shared preset,
AGENTS.md and docs/decisions.md. This commit passed make ci-quick in its pre-commit hook."

cat <<MSG
devkit-new: $REPO is ready ($(git rev-parse --short=7 HEAD)).
Next, from the devkit checkout, once the GitHub repo exists (gh repo create agandhi4/$NAME --private --source $REPO --push):
  1. add "$NAME": {} to github/repos.json, then github/repo_settings.sh $NAME and github/labels_sync.sh $NAME
  2. grant the Mend Renovate app access to agandhi4/$NAME (renovate.json extends devkit's preset)
  3. write the Architecture section of AGENTS.md; add a homelab stack under stacks/$NAME when it deploys
MSG
