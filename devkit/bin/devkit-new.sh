#!/usr/bin/env bash
# Scaffold a new repo that passes every devkit guard on its first commit.
#
# Usage: devkit-new.sh <name> --stack <stack> [--dir <parent>] [--no-image]
#   name        repo, image and container name: lowercase, digits and dashes
#   --stack     a directory under templates/new/stacks/ (python-fastapi, node-service, rust,
#               next-vercel, swift-app)
#   --dir       parent directory; the repo is <dir>/<name> (default: the current directory)
#   --no-image  no Dockerfile, publish workflow or smoke; ci-image and ci-smoke become stubs.
#               Implied for a stack whose stack.conf says STACK_IMAGE=0 (next-vercel: Vercel builds;
#               swift-app: Xcode and TestFlight ship it)
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
#      __PASCAL_NAME__, __DATE__, __DEVKIT_SHA7__, __STACK__, __HOOKS__ and the stack.conf
#      fields replaced; lines between `#@image` / `#@no-image` / `#@no-image-chosen` and `#@end`
#      kept or dropped by --no-image (templates/new/README.md, "Rendering"). CLAUDE.md is a
#      symlink to AGENTS.md (owner decision 2026-10-12). A stack's .gitignore is appended to
#      the common one (every other stack file with a common path replaces it).
#   4. the parts that already exist elsewhere in devkit, copied, never re-typed: the git hooks
#      (templates/githooks), the Renovate consumer file (renovate/consumer.example.json), the
#      quick-check caller (templates/workflows; the reusable workflow sets up Node only when
#      .nvmrc exists, so a Python-only repo needs no input; a stack whose ci-quick cannot run on
#      Linux names its target in STACK_QUICK_CHECK_TARGET, passed as the caller's make-target)
#   5. the stack's lock command (uv lock, npm install --package-lock-only), so the frozen
#      install in ci-quick has a lockfile to be frozen to; none for a stack without one
#   6. metrics_collect.sh rebaseline: the collectors scripts/ci/metrics.conf declares fill
#      docs/metrics/ratchet.json, so `make ci-metrics` holds from the first commit
#   7. core.hooksPath=.githooks, then ONE commit with everything. pre-commit runs
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
# shellcheck source=/dev/null  # bin/toolchain_path.sh: toolchain_path, shared with the gate and hooks
. "$HERE/toolchain_path.sh"
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
# shellcheck disable=SC2016  # Markdown backticks, rendered into AGENTS.md as written
STACK_IMAGE=1 STACK_NO_IMAGE_NOTE='`devkit new --no-image`' STACK_QUICK_CHECK_TARGET=ci-quick \
  STACK_ARCHITECTURE='A '"$STACK"' service scaffolded with health endpoints (`/health/live`, `/health/ready`) and nothing else yet.'
# shellcheck source=/dev/null
. "$STACK_DIR/stack.conf"
for key in STACK_CONVENTIONS STACK_PINS STACK_TOOL; do
  [ -n "${!key}" ] || die "$STACK/stack.conf must set $key"
done
case "$STACK_IMAGE" in
  1) ;;
  # The stack cannot have an image (it ships no Dockerfile); --no-image is implied, not asked.
  0) [ "$IMAGE" = 0 ] || echo "devkit-new: $STACK publishes no image; --no-image is implied"
     IMAGE=0 ;;
  *) die "$STACK/stack.conf: STACK_IMAGE must be 0 or 1 (got '$STACK_IMAGE')" ;;
esac
command -v "$STACK_TOOL" >/dev/null || { echo "devkit-new: '$STACK_TOOL' not found on PATH; the $STACK stack needs it for its lockfile or the first commit's ci-quick" >&2; exit 2; }
command -v make >/dev/null || { echo "devkit-new: make not found on PATH; the first commit runs make ci-quick" >&2; exit 2; }

DATE=$(date +%F)
# The name as a Swift/Kotlin-style type name (my-app -> MyApp), for stacks whose targets and
# types cannot hold a dash. Valid as an identifier: the name starts with a letter.
PASCAL_NAME=$(printf '%s' "$NAME" | awk -F- '{ for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2) }')
# AGENTS.md names the hook steps; they are read from the hooks.conf the repo will have (the
# stack's, else common's), so the doc cannot disagree with what the hooks run.
HOOKS_CONF=$STACK_DIR/scripts/ci/hooks.conf
[ -f "$HOOKS_CONF" ] || HOOKS_CONF=$TEMPLATES/common/scripts/ci/hooks.conf
HOOKS=$(
  PRE_COMMIT_STEPS=() PRE_PUSH_STEPS=()
  # shellcheck source=/dev/null  # format in bin/hook_steps.sh
  . "$HOOKS_CONF"
  targets() { local s out=''; for s in "$@"; do out+="${out:+, }\`${s#*=}\`"; done; printf '%s' "${out:-nothing}"; }
  printf 'pre-commit %s, pre-push %s' "$(targets ${PRE_COMMIT_STEPS[@]+"${PRE_COMMIT_STEPS[@]}"})" \
    "$(targets ${PRE_PUSH_STEPS[@]+"${PRE_PUSH_STEPS[@]}"})"
)

# A stack.conf value as a sed replacement: `/`, `&` and `\` are literal, not sed syntax.
sed_literal() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

# render <src> <dst>: substitute placeholders, keep or drop #@image / #@no-image /
# #@no-image-chosen blocks, keep the execute bit. Markers must start at column 0; they are
# never emitted. #@no-image-chosen survives only when --no-image was a choice, not the stack's
# nature (STACK_IMAGE=0): advice on adding an image is noise in an iOS or Vercel repo.
render() {
  local src=$1 dst=$2
  mkdir -p "$(dirname "$dst")"
  awk -v image="$IMAGE" -v stack_image="$STACK_IMAGE" '
    /^#@image$/            { skip = !image; next }
    /^#@no-image$/         { skip = image + 0 == 1; next }
    /^#@no-image-chosen$/  { skip = image + 0 == 1 || stack_image + 0 == 0; next }
    /^#@end$/              { skip = 0; next }
    !skip { print }
  ' "$src" |
  sed -e "s/__NAME__/$NAME/g" -e "s/__PASCAL_NAME__/$PASCAL_NAME/g" -e "s/__DATE__/$DATE/g" -e "s/__DEVKIT_SHA7__/$DEVKIT_SHA7/g" \
      -e "s/__STACK__/$STACK/g" -e "s/__CONVENTIONS__/$(sed_literal "$STACK_CONVENTIONS")/g" \
      -e "s/__PINS__/$(sed_literal "$STACK_PINS")/g" -e "s/__STUBS__/$(sed_literal "$STACK_STUBS")/g" \
      -e "s/__NO_IMAGE_NOTE__/$(sed_literal "$STACK_NO_IMAGE_NOTE")/g" \
      -e "s/__ARCHITECTURE__/$(sed_literal "$STACK_ARCHITECTURE")/g" -e "s/__HOOKS__/$(sed_literal "$HOOKS")/g" \
      -e "s/__QUICK_CHECK_TARGET__/$STACK_QUICK_CHECK_TARGET/g" > "$dst"
  [ ! -x "$src" ] || chmod +x "$dst"
}

# render_tree <template dir>: every regular file, dotfiles included; symlinks are recreated
# with the same target (CLAUDE.md -> AGENTS.md). A .gitignore that already exists (common's)
# is appended to, so a stack adds its build output without restating the shared entries.
render_tree() {
  local dir=$1 path rel
  while IFS= read -r path; do
    rel=${path#"$dir"/}
    case "$rel" in stack.conf) continue ;; esac
    if [ "$rel" = .gitignore ] && [ -f "$REPO/.gitignore" ]; then
      render "$path" "$REPO/.gitignore.stack"
      { echo; cat "$REPO/.gitignore.stack"; } >>"$REPO/.gitignore"
      rm "$REPO/.gitignore.stack"
    elif [ -L "$path" ]; then
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
# The caller's only input that varies by stack; the template ends inside the job, at its indent.
if [ "$STACK_QUICK_CHECK_TARGET" != ci-quick ]; then
  printf '    with:\n      make-target: %s\n' "$STACK_QUICK_CHECK_TARGET" >>.github/workflows/quick-check.yml
fi

if [ "$IMAGE" = 0 ]; then
  rm -f .github/workflows/publish.yml
  for f in $STACK_IMAGE_FILES; do rm -f "$f"; done
fi

# On the pins (toolchain_path), so the lockfile comes from the npm or cargo that the first
# commit's hooks and the gate then install from, not whatever PATH holds. Subshell: PATH
# returns to the caller's for the rest of the script.
if [ -n "$STACK_LOCK_CMD" ]; then
  echo "devkit-new: $STACK_LOCK_CMD"
  (
    toolchain_path "$PWD" || die "$TOOLCHAIN_ERROR"
    $STACK_LOCK_CMD
  )
fi

# The bounds for the first commit: metrics.conf's collectors (whatever the stack declares) run
# once and fill docs/metrics/ratchet.json, so `make ci-metrics` holds on this tree. On the
# pins, as the lock step: a collector may need the stack's node.
echo "devkit-new: devkit/bin/metrics_collect.sh rebaseline"
(
  toolchain_path "$PWD" || die "$TOOLCHAIN_ERROR"
  devkit/bin/metrics_collect.sh rebaseline
) || die "metrics_collect.sh rebaseline failed; the stack's metrics.conf names a collector its scaffold cannot run"

# Set directly rather than through hooks_check.sh --fix: that script is a no-op under CI, and
# the first commit must run the hooks there too (the bats contract test runs in Actions).
git config core.hooksPath .githooks
git add -A
echo "devkit-new: first commit, through the hooks (pre-commit runs make ci-quick)"
git commit -q -m "Create $NAME with devkit new ($STACK, devkit $DEVKIT_SHA7)

Scaffolded by devkit/bin/devkit-new.sh: vendored devkit/, the standard ci-* Makefile,
scripts/ci/gate_plan.sh, git hooks, the quick-check caller, Renovate's shared preset and
the standard docs (README.md, AGENTS.md, docs/decisions.md, docs/architecture.md). This
commit passed make ci-quick in its pre-commit hook."

cat <<MSG
devkit-new: $REPO is ready ($(git rev-parse --short=7 HEAD)).
Next, from the devkit checkout, once the GitHub repo exists (gh repo create agandhi4/$NAME --private --source $REPO --push):
  1. add "$NAME": {} to github/repos.json, then github/repo_settings.sh $NAME and github/labels_sync.sh $NAME
  2. grant the Mend Renovate app access to agandhi4/$NAME (renovate.json extends devkit's preset)
  3. replace the <!-- --> placeholders in README.md, docs/architecture.md and AGENTS.md's Architecture; add a homelab stack under stacks/$NAME when it deploys
MSG
