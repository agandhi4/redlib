# shellcheck shell=bash
# The VENDOR_PATHS manifest, applied to a git tree. Sourced; defines functions and runs nothing.
# Used by: devkit-sync.sh (filters upstream's tree before vendoring it) and devkit-check.sh
# (a vendored tree must already be its own filtered form). One code path, so the tree hash
# devkit-sync records in .devkit-rev is the hash devkit-check can recompute.
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
