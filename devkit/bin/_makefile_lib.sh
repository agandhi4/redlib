# shellcheck shell=bash
# Sourced, never run. Reads the root Makefile the way the guards need it, without running make
# (a Makefile's $(shell …) and includes of generated files must not run inside a check).
# Used by: docs_check.sh (rule 9, `make <target>` words in docs), ci_targets_check.sh and
# devkit-check.sh (makefile_raw_docker).

# makefile_files: ./Makefile, then each file it includes by literal path, one per line.
makefile_files() {
  [ -f Makefile ] || return 0
  local inc
  echo Makefile
  while IFS= read -r inc; do
    case "$inc" in *'$'*) continue ;; esac
    [ ! -f "$inc" ] || echo "$inc"
  done < <(awk '/^-?include[[:space:]]/ { for (i = 2; i <= NF; i++) print $i }' Makefile)
}

# makefile_targets: the rule targets of makefile_files, as one line " a b c " (leading and
# trailing space, so `case " $t "` matches whole words).
# Special targets (.PHONY, .DEFAULT_GOAL), assignments and conditionals are not targets; a `%`
# pattern rule is printed as written. Prints nothing when there is no Makefile.
makefile_targets() {
  [ -f Makefile ] || return 0
  local makefiles=() file
  while IFS= read -r file; do makefiles+=("$file"); done < <(makefile_files)
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

# makefile_raw_docker: `<file>:<line>: <recipe line>` for each recipe line of makefile_files
# that runs `docker` itself. Such a call bypasses the daemon probe and per-call bound of
# _timeout_lib.sh (a wedged daemon hung gates for 12+ minutes, 2026-10-17); docker_bounded.sh,
# throwaway_pg.sh and boot_image.sh carry them. Recipe lines are tab-led, plus the continuation
# lines of one. Quoted text is dropped first, so `@echo "… docker build …"` is not a call. A
# variable whose whole value is `docker` (redlib's `DOCKER ?= docker`) counts as the word;
# a shell function or any other indirection is not seen.
makefile_raw_docker() {
  local files=() file
  while IFS= read -r file; do files+=("$file"); done < <(makefile_files)
  [ "${#files[@]}" -gt 0 ] || return 0
  awk '
    FNR == 1 { cont = 0 }
    !/^\t/ && !cont && match($0, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[?:]?=[[:space:]]*docker[[:space:]]*$/) {
      name = $0; sub(/[[:space:]]*[?:]?=.*/, "", name); vars[name] = 1
    }
    { lines[FILENAME, FNR] = $0; recipe[FILENAME, FNR] = (cont || /^\t/); cont = recipe[FILENAME, FNR] && /\\$/
      if (FNR == 1) order[++nfiles] = FILENAME; count[FILENAME] = FNR }
    END {
      for (f = 1; f <= nfiles; f++) {
        file = order[f]
        for (n = 1; n <= count[file]; n++) {
          if (!recipe[file, n]) continue
          line = lines[file, n]
          sub(/^\t[@+-]*/, "", line)
          if (line ~ /^[[:space:]]*#/ || line ~ /(throwaway_pg|boot_image)\.sh/) continue
          bare = line
          gsub(/"[^"]*"/, "", bare); gsub(/\047[^\047]*\047/, "", bare)
          for (v in vars) { gsub("\\$[({]" v "[)}]", "docker", bare) }
          if (bare ~ /(^|[[:space:];&|(])docker[[:space:]]/) {
            sub(/^[[:space:]]+/, "", line)
            printf "%s:%d: %s\n", file, n, line
          }
        }
      }
    }' "${files[@]}"
}
