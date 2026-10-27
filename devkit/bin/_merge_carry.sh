# shellcheck shell=bash
# Sourced by merge_rules.sh, never run: whether a gate's result carries to a PR's merge into a
# main other than the one it ran on, and the merge commit that carries it (merge_rules.sh header,
# "Carry"). Pure git on a clone's objects; pushing and the statuses are merge_rules.sh's.
#
# Why: docs/decisions.md is append-only and nearly every PR appends to it, so any two open PRs
# conflict there on GitHub, whose merge ignores the union driver the gate's local merge uses
# (bin/_gitattributes_lib.sh). devkit #234 was re-gated three times and closet #434/#435 both
# rebased for a conflict no gate job could judge differently. A merge whose every other path is
# the gated tree's needs no new gate: the gate already tested that code, so the merge resolves
# the log itself and moves on.
#
# The test is on trees, never on what a commit message or the PR says: CARRY_PATH is the only
# path whose content may differ from the gated merge's, every conflict GitHub's merge would hit
# must be in it, and both sides of it may only append entries (decisions_merge.py, which also
# writes the blank line and the date order the union driver loses).
# Requires git 2.40 (`merge-tree --write-tree`, `--attr-source`).
# Sets CARRY_* globals for its caller to read:
# shellcheck disable=SC2034

CARRY_PATH=docs/decisions.md
# git's well-known empty tree: as the attribute source it gives every path no attributes, so
# merge-tree merges as GitHub does, with no union driver, whatever this clone's .gitattributes.
CARRY_NO_ATTRS=4b825dc642cb6eb9a060e54bf8d69288fbee4904
CARRY_BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# carry_merge <root> <ours> <theirs>: GitHub's merge of the two commits (no attributes). Sets
# CARRY_MERGED (the tree; a conflicted file holds its markers) and CARRY_CONFLICTS (the
# `<mode> <object> <stage>\t<path>` lines, none when clean). 1 when git cannot merge them at all.
carry_merge() {
  local out
  local rc
  out=$(git -C "$1" --attr-source="$CARRY_NO_ATTRS" merge-tree --write-tree --no-messages "$2" "$3")
  rc=$?
  [ "$rc" -le 1 ] || { CARRY_GIT_RC=$rc; return 1; }
  CARRY_MERGED=$(head -1 <<<"$out")
  CARRY_CONFLICTS=$(tail -n +2 <<<"$out")
}

# carry_stage <n>: the object of CARRY_PATH's stage <n> (1 base, 2 ours, 3 theirs) in
# CARRY_CONFLICTS, or nothing.
carry_stage() {
  awk -F'\t' -v s="$1" -v p="$CARRY_PATH" '$2 == p { split($1, f, " "); if (f[3] == s) print f[2] }' <<<"$CARRY_CONFLICTS"
}

# carry_plan <root> <head> <gated main> <main now>: 0 when the gate of <head> merged into <gated
# main> decides its merge into <main now> too (header), setting CARRY_TREE to that merge's tree
# with CARRY_PATH resolved (CARRY_RESOLVED=1 when GitHub's merge conflicts there, so the tree
# needs a commit of its own; else GitHub's merge of the head is that tree); else 1, with why in
# CARRY_WHY. All four commits must be in <root>.
carry_plan() {
  local root=$1 head=$2 gated=$3 now=$4 gated_tree others tmp rc
  CARRY_TREE="" CARRY_WHY="" CARRY_RESOLVED=""
  carry_merge "$root" "$gated" "$head" \
    || { CARRY_WHY="git merge-tree of ${head:0:12} into the gated main ${gated:0:12} exited $CARRY_GIT_RC (needs git 2.40+; above)"; return 1; }
  gated_tree=$CARRY_MERGED
  carry_merge "$root" "$now" "$head" \
    || { CARRY_WHY="git merge-tree of ${head:0:12} into main ${now:0:12} exited $CARRY_GIT_RC (above)"; return 1; }
  others=$(cut -f2 <<<"$CARRY_CONFLICTS" | grep -vxF "$CARRY_PATH" | sort -u | paste -sd ' ' -)
  [ -z "$others" ] || { CARRY_WHY="it conflicts with main in $others"; return 1; }
  CARRY_TREE=$CARRY_MERGED
  if [ -n "$CARRY_CONFLICTS" ]; then
    CARRY_RESOLVED=1
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/devkit-carry.XXXXXX") || return 1
    carry_resolve "$root" "$tmp"
    rc=$?
    rm -rf "$tmp"
    [ "$rc" = 0 ] || return 1
  fi
  # Plumbing, no renames: a user's diff.renames could pair a deleted file onto CARRY_PATH. A git
  # failure must refuse, never read as "nothing differs".
  others=$(git -C "$root" diff-tree -r --no-renames --name-only "$gated_tree" "$CARRY_TREE") \
    || { CARRY_WHY="cannot compare the trees (git above)"; return 1; }
  others=$(grep -vxF "$CARRY_PATH" <<<"$others" | head -3 | paste -sd ' ' -)
  [ -z "$others" ] || { CARRY_WHY="main changed $others since the gated main"; return 1; }
  # A clean merge never ran decisions_merge.py: main must still only have appended (#238 Codex).
  git -C "$root" diff --quiet "$gated" "$now" -- "$CARRY_PATH" && return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/devkit-carry.XXXXXX") || return 1
  carry_appended "$root" "$gated" "$now" "$tmp"
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# carry_appended <root> <gated main> <main now> <scratch dir>: 0 when main now's CARRY_PATH is the
# gated main's with entries appended (decisions_merge.py, the gated one as base and theirs); else
# 1, with why in CARRY_WHY.
carry_appended() {
  local root=$1 tmp=$4
  git -C "$root" show "$2:$CARRY_PATH" >"$tmp/gated" 2>/dev/null || : >"$tmp/gated"
  git -C "$root" show "$3:$CARRY_PATH" >"$tmp/now" 2>/dev/null || { CARRY_WHY="main deleted $CARRY_PATH"; return 1; }
  "$DEVKIT_PYTHON" -I "$CARRY_BIN/decisions_merge.py" "$tmp/gated" "$tmp/now" "$tmp/gated" >/dev/null 2>"$tmp/why" && return 0
  CARRY_WHY="main's $CARRY_PATH since the gated main: $(sed 's/^decisions_merge: //; s/ours /main /' "$tmp/why" | head -1)"
  return 1
}

# carry_resolve <root> <scratch dir>: set CARRY_TREE to CARRY_MERGED with CARRY_PATH's conflict
# resolved by decisions_merge.py; else 1, with why in CARRY_WHY.
carry_resolve() {
  local root=$1 tmp=$2 base ours theirs blob
  base=$(carry_stage 1) ours=$(carry_stage 2) theirs=$(carry_stage 3)
  [ -n "$ours" ] && [ -n "$theirs" ] || { CARRY_WHY="one side deleted $CARRY_PATH"; return 1; }
  # No base (both sides added the file) merges against an empty one.
  if [ -n "$base" ]; then git -C "$root" cat-file blob "$base" >"$tmp/base"; else : >"$tmp/base"; fi
  if ! git -C "$root" cat-file blob "$ours" >"$tmp/ours" || ! git -C "$root" cat-file blob "$theirs" >"$tmp/theirs"; then
    CARRY_WHY="cannot read $CARRY_PATH's sides (git above)"
    return 1
  fi
  if ! "$DEVKIT_PYTHON" -I "$CARRY_BIN/decisions_merge.py" "$tmp/base" "$tmp/ours" "$tmp/theirs" \
      >"$tmp/merged" 2>"$tmp/why"; then
    CARRY_WHY="$CARRY_PATH: $(sed 's/^decisions_merge: //' "$tmp/why" | head -1)"
    return 1
  fi
  if ! blob=$(git -C "$root" hash-object -w "$tmp/merged") \
      || ! CARRY_TREE=$(GIT_INDEX_FILE=$tmp/index git -C "$root" read-tree "$CARRY_MERGED" \
        && GIT_INDEX_FILE=$tmp/index git -C "$root" update-index --cacheinfo "100644,$blob,$CARRY_PATH" \
        && GIT_INDEX_FILE=$tmp/index git -C "$root" write-tree); then
    CARRY_WHY="cannot write the resolved tree (git above)"
    return 1
  fi
}

# carry_commit <root> <tree> <head> <main now> <pr>: print the merge commit of <main now> into
# <head> with <tree>, as devkit's own commits are signed (devkit_commit_trailer).
carry_commit() {
  printf 'Merge main %s into PR #%s: only %s differs from the gated tree\n\nmake merge carried the gate of %s (bin/_merge_carry.sh): every other path is the tree\nthat gate tested, and both sides only appended entries to %s.\n\n%s\n' \
    "${4:0:12}" "$5" "$CARRY_PATH" "${3:0:12}" "$CARRY_PATH" "$(devkit_commit_trailer)" \
    | git -C "$1" commit-tree "$2" -p "$3" -p "$4" -F -
}
