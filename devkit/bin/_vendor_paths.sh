# shellcheck shell=bash
# The VENDOR_PATHS manifest, applied to a git tree. Sourced; defines functions and DEVKIT_URL.
# Used by: devkit-sync.sh (filters upstream's tree before vendoring it), devkit-check.sh
# (a vendored tree must already be its own filtered form), hook_steps.sh and pr_merge.sh (what a
# vendoring-only change is) and dependency_merge.sh (the nightly sync). One code path, so the tree
# hash devkit-sync records in .devkit-rev is the hash every other reader recomputes.
#
# Every function reading tracked files takes <rev>: a commit, or "" for the index (the hooks and
# devkit-sync judge what is staged; pr_merge.sh and the nightly sync judge a PR's head).
#
#   DEVKIT_URL
#       Upstream, where devkit-sync fetches from (overridable, as tests do).
#
#   fetch_devkit_main <dir>
#       Fetch DEVKIT_URL's main into <dir>'s object store and print its commit. Into FETCH_HEAD,
#       no ref: a consumer clone keeps no devkit branch, so the single-branch refspec trap
#       fetch_main exists for (_gate_env.sh) cannot arise. Used by pr_merge.sh and the nightly sync.
#
#   swift_format_copies [<rev>]
#       The repo's tracked .swift-format files (root or nested), one per line.
#       devkit-check holds each byte-equal to lint/swift-format.json; devkit-sync refreshes them.
#
#   base_copies [<rev>]
#       "<base path in devkit> <repo path>" for each tracked file that must be a byte copy of a
#       vendored base: every swift_format_copies line, and .githooks/<hook> for each hook in
#       templates/githooks (the monthly audit's hook-differs), tracked or not once the repo
#       tracks any of them (devkit-sync.sh then creates it). Read by devkit-sync.sh.
#
#   vendor_filter_tree <tree> <manifest text>
#       Print the hash of a tree holding only <tree>'s entries under the manifest's paths (modes,
#       symlinks and blobs unchanged), built in a throwaway index so the caller's is untouched.
#       A manifest path that matches nothing in <tree> is an error (exit status 2): a renamed
#       directory must not silently drop out of every consumer.
#
#   vendor_tree_of <commit>
#       The tree devkit-sync vendors from upstream <commit>: its VENDOR_PATHS filter of the
#       commit's tree, or the whole tree for a commit before the manifest (2026-10-13).
#
#   vendoring_only <rev> <paths>
#       True when <paths> (one per line) only vendor devkit at <rev>, as devkit-sync's own
#       commit does: every path is under devkit/, is .devkit-rev, or is a base copy
#       byte-identical to its base at <rev> and of its mode (a chmod -x of a hook copy disables it), and devkit/ at <rev> is the tree .devkit-rev records.
#       Sets VENDORED_TREE. A hand edit under devkit/ breaks the hash; it proves nothing about
#       where the tree came from (vendored_from does).
#
#   vendored_from <rev> <upstream> [<base rev>]
#       True when <rev>'s .devkit-rev names a commit <upstream> contains and the tree recorded
#       is vendor_tree_of that commit, so devkit/ (once vendoring_only holds) is upstream's own
#       reviewed code and not a hand edit recorded as a sync; with <base rev>, also a commit that
#       contains <base rev>'s vendored one (a sync forward, never back). Needs <upstream>'s
#       objects: `git fetch "$DEVKIT_URL" main` first.

DEVKIT_URL=${DEVKIT_URL:-https://github.com/agandhi4/devkit.git}

vendor_filter_tree() { # <tree> <manifest text>
  local tree=$1 line path index status=0
  local paths=()
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [ -n "$line" ] || continue
    case "$line" in
      /*|*..*|*'*'*|*'?'*|*'['*) echo "VENDOR_PATHS: '$line' must be a plain relative path" >&2; return 2 ;;
    esac
    path=${line%/}
    if [ -z "$(git ls-tree -r --name-only "$tree" -- "$path" | head -1)" ]; then
      echo "VENDOR_PATHS: '$path' matches nothing in tree ${tree:0:7}" >&2
      return 2
    fi
    paths+=("$path")
  done <<<"$2"
  [ "${#paths[@]}" -gt 0 ] || { echo "VENDOR_PATHS: no paths listed" >&2; return 2; }
  index=$(mktemp "${TMPDIR:-/tmp}/vendor-index.XXXXXX")
  rm -f "$index"   # git refuses an empty file as an index; it creates its own
  git ls-tree -r "$tree" -- "${paths[@]}" | GIT_INDEX_FILE=$index git update-index --index-info \
    && GIT_INDEX_FILE=$index git write-tree || status=2
  rm -f "$index"
  return "$status"
}

fetch_devkit_main() { # <dir>
  git -C "$1" fetch -q --no-tags "$DEVKIT_URL" main && git -C "$1" rev-parse FETCH_HEAD
}

# _vendor_entry <rev> <path>: "<mode> <blob>" of <path> at <rev>, or in the index for "".
_vendor_entry() {
  if [ -z "$1" ]; then
    git ls-files -s -- "$2" | awk '{ print $1, $2 }'
  else
    git ls-tree "$1" -- "$2" | awk '{ print $1, $3 }'
  fi
}

# _vendor_files <rev>: every path tracked at <rev>, or in the index when <rev> is "".
_vendor_files() {
  if [ -z "$1" ]; then git ls-files; else git ls-tree -r --name-only "$1"; fi
}

swift_format_copies() { # [<rev>]
  _vendor_files "${1:-}" | awk '/(^|\/)\.swift-format$/'
}

base_copies() { # [<rev>]
  local rev=${1:-} files copy hook
  while IFS= read -r copy; do
    [ -z "$copy" ] || echo "lint/swift-format.json $copy"
  done <<<"$(swift_format_copies "$rev")"
  # The template names come from the repo's own vendored devkit/ (in the index, the tree a sync
  # has just replaced). A repo that tracks one hook copy has adopted the hooks, so a hook upstream
  # adds is listed too and the sync creates it; a repo with none gets none.
  local templates adopted=0
  files=$(_vendor_files "$rev")
  templates=$(awk '/^devkit\/templates\/githooks\//' <<<"$files")
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    ! grep -qxF -- ".githooks/${hook##*/}" <<<"$files" || adopted=1
  done <<<"$templates"
  [ "$adopted" = 1 ] || return 0
  while IFS= read -r hook; do
    [ -z "$hook" ] || echo "templates/githooks/${hook##*/} .githooks/${hook##*/}"
  done <<<"$templates"
}

vendor_tree_of() { # <commit>
  local tree manifest
  tree=$(git rev-parse -q --verify "$1^{tree}") || return 2
  if manifest=$(git show "$1:VENDOR_PATHS" 2>/dev/null); then
    vendor_filter_tree "$tree" "$manifest"
  else
    echo "$tree"
  fi
}

vendoring_only() { # <rev> <paths>
  local rev=$1 record path base bases copy
  VENDORED_TREE=
  [ -n "$2" ] || return 1
  record=$(git show "$rev:.devkit-rev" 2>/dev/null) || return 1
  if [ -z "$rev" ]; then
    VENDORED_TREE=$(git write-tree --prefix=devkit/ 2>/dev/null) || return 1
  else
    VENDORED_TREE=$(git rev-parse -q --verify "$rev:devkit") || return 1
  fi
  [ "$VENDORED_TREE" = "${record#* }" ] || return 1
  bases=$(base_copies "$rev")
  while IFS= read -r path; do
    case "$path" in ''|devkit/*|.devkit-rev) continue ;; esac
    base=$(awk -v c="$path" '$2 == c { print $1; exit }' <<<"$bases")
    [ -n "$base" ] || return 1
    copy=$(_vendor_entry "$rev" "$path")
    [ -n "$copy" ] && [ "$copy" = "$(_vendor_entry "$rev" "devkit/$base")" ] || return 1
  done <<<"$2"
}

vendored_from() { # <rev> <upstream> [<base rev>]
  local record commit base
  record=$(git show "$1:.devkit-rev" 2>/dev/null) || return 1
  commit=${record%% *}
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  git merge-base --is-ancestor "$commit" "$2" 2>/dev/null || return 1
  [ "$(vendor_tree_of "$commit" 2>/dev/null)" = "${record#* }" ] || return 1
  [ -n "${3:-}" ] || return 0
  git cat-file -e "$3^{commit}" 2>/dev/null || return 1
  # A base with no .devkit-rev is a first vendoring: any upstream commit is forward of it. Only
  # an absent file counts as none; one git cannot read fails closed.
  base=$(git ls-tree "$3" -- .devkit-rev) || return 1
  [ -n "$base" ] || return 0
  base=$(git show "$3:.devkit-rev") || return 1
  git merge-base --is-ancestor "${base%% *}" "$commit" 2>/dev/null
}
