# shellcheck shell=bash
# Sourced, never run. Reads the root Makefile the way the guards need it, without running make
# (a Makefile's $(shell …) and includes of generated files must not run inside a check).
# Used by: docs_check.sh (rule 9, `make <target>` words in docs) and ci_targets_check.sh.

# makefile_targets: the rule targets of ./Makefile and of the files it includes by literal path,
# as one line " a b c " (leading and trailing space, so `case " $t "` matches whole words).
# Special targets (.PHONY, .DEFAULT_GOAL), assignments and conditionals are not targets; a `%`
# pattern rule is printed as written. Prints nothing when there is no Makefile.
makefile_targets() {
  [ -f Makefile ] || return 0
  local makefiles=(Makefile) inc
  while IFS= read -r inc; do
    case "$inc" in *'$'*) continue ;; esac
    [ -f "$inc" ] && makefiles+=("$inc")
  done < <(awk '/^-?include[[:space:]]/ { for (i = 2; i <= NF; i++) print $i }' Makefile)
  echo " $(awk '
    /^\t/ || /^[[:space:]]*#/ { next }
    {
      i = index($0, ":"); if (i < 2) next
      if (substr($0, i + 1, 1) == "=") next             # := assignment
      head = substr($0, 1, i - 1)
      if (head ~ /[=?+!]/ || head ~ /^(export|override|define|ifeq|ifneq|ifdef|ifndef) /) next
      n = split(head, t, /[[:space:]]+/)
      for (k = 1; k <= n; k++) if (t[k] != "" && t[k] !~ /^\./) printf "%s ", t[k]
    }' "${makefiles[@]}")"
}
