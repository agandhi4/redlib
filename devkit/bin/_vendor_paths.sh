# shellcheck shell=bash
# The VENDOR_PATHS manifest, applied to a git tree. Sourced; defines functions and runs nothing.
# Used by: devkit-sync.sh (filters upstream's tree before vendoring it) and devkit-check.sh
# (a vendored tree must already be its own filtered form). One code path, so the tree hash
# devkit-sync records in .devkit-rev is the hash devkit-check can recompute.
#
#   swift_format_copies
#       The repo's tracked .swift-format files (root or nested), one per line, from the index.
#       devkit-check holds each byte-equal to lint/swift-format.json; devkit-sync refreshes them.
#
#   base_copies
#       "<base path in devkit> <repo path>" for each tracked file that must be a byte copy of a
#       vendored base: every swift_format_copies line, and .githooks/<hook> for each hook in
#       templates/githooks (the monthly audit's hook-differs). Read by devkit-sync.sh.
#
#   vendor_filter_tree <tree> <manifest text>
#       Print the hash of a tree holding only <tree>'s entries under the manifest's paths (modes,
#       symlinks and blobs unchanged), built in a throwaway index so the caller's is untouched.
#       A manifest path that matches nothing in <tree> is an error (exit status 2): a renamed
#       directory must not silently drop out of every consumer.

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

swift_format_copies() {
  git ls-files -- ':(glob)**/.swift-format'
}

base_copies() {
  local copy hook
  while IFS= read -r copy; do
    [ -z "$copy" ] || echo "lint/swift-format.json $copy"
  done <<<"$(swift_format_copies)"
  # The template names come from the repo's own vendored devkit/ (the index): a hook upstream
  # adds is not tracked yet, so it has no copy to refresh either way.
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    hook=${hook##*/}
    if git ls-files --error-unmatch -- ".githooks/$hook" >/dev/null 2>&1; then
      echo "templates/githooks/$hook .githooks/$hook"
    fi
  done <<<"$(git ls-files -- devkit/templates/githooks/)"
}
