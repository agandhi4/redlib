# shellcheck shell=bash
# Sourced, never run. Reads the root Makefile the way the guards need it, without running make
# (a Makefile's $(shell …) and includes of generated files must not run inside a check).
# Used by: docs_check.sh (rule 9, `make <target>` words in docs), ci_targets_check.sh,
# devkit-check.sh (makefile_raw_docker, makefile_bare_python, makefile_fixed_pg,
# makefile_rule_text: the publish contract), hook_steps.sh
# (the docs-check fallback) and hooks_check.sh (a ci-lint no pre-commit step runs).

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

# makefile_rule_text <target>: the rule of <target> in makefile_files as one line per rule line:
# the text after its `:` (prerequisites and an inline `; recipe`), then each recipe line (tab-led,
# plus the continuation lines of one). Nothing when no rule names it. Comments are dropped.
makefile_rule_text() {
  local files=() file
  while IFS= read -r file; do files+=("$file"); done < <(makefile_files)
  [ "${#files[@]}" -gt 0 ] || return 0
  awk -v t="$1" '
    FNR == 1 { inrule = 0; cont = 0 }
    /^[[:space:]]*#/ { next }
    inrule && (/^\t/ || cont) { cont = /\\$/; print; next }
    { inrule = 0; cont = 0 }
    !/^\t/ {
      i = index($0, ":"); if (i < 2 || substr($0, i + 1, 1) == "=") next
      n = split(substr($0, 1, i - 1), w, /[[:space:]]+/)
      for (k = 1; k <= n; k++) if (w[k] == t) { inrule = 1; print substr($0, i + 1); next }
    }' "${files[@]}"
}

# makefile_recipe_calls <command> [<skip ERE>]: `<file>:<line>: <recipe line>` for each recipe
# line of makefile_files that runs <command> itself as a word. Recipe lines are tab-led, plus the
# continuation lines of one. Quoted text is dropped first, so `@echo "… docker build …"` is not a
# call; a line matching <skip ERE> is not one either. A variable whose whole value is <command>
# (redlib's `DOCKER ?= docker`) counts as the word; a shell function, a `$(shell …)` outside a
# recipe or any other indirection is not seen.
makefile_recipe_calls() {
  local files=() file
  while IFS= read -r file; do files+=("$file"); done < <(makefile_files)
  [ "${#files[@]}" -gt 0 ] || return 0
  awk -v w="$1" -v skip="${2:-}" '
    FNR == 1 { cont = 0 }
    !/^\t/ && !cont && match($0, "^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[?:]?=[[:space:]]*" w "[[:space:]]*$") {
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
          if (line ~ /^[[:space:]]*#/ || (skip != "" && line ~ skip)) continue
          bare = line
          gsub(/"[^"]*"/, "", bare); gsub(/\047[^\047]*\047/, "", bare)
          for (v in vars) { gsub("\\$[({]" v "[)}]", w, bare) }
          if (bare ~ "(^|[[:space:];&|(])" w "([[:space:]]|$)") {
            sub(/^[[:space:]]+/, "", line)
            printf "%s:%d: %s\n", file, n, line
          }
        }
      }
    }' "${files[@]}"
}

# makefile_raw_docker: makefile_recipe_calls for `docker`. Such a call bypasses the daemon probe
# and per-call bound of _timeout_lib.sh (a wedged daemon hung gates for 12+ minutes, 2026-10-17);
# docker_bounded.sh, throwaway_pg.sh and boot_image.sh carry them.
makefile_raw_docker() { makefile_recipe_calls docker '(throwaway_pg|boot_image)[.]sh'; }

# makefile_bare_python: makefile_recipe_calls for a bare `python3` (a `uv run` line is uv's own
# interpreter). Only toolchain_shell.sh as make's SHELL puts devkit's python3 (>= 3.11) first on a
# recipe's PATH; without it a hand-run or launchd make gets PATH's, Xcode's 3.9 on this Mac.
makefile_bare_python() { makefile_recipe_calls python3 '(^|[[:space:];&|(])uv[[:space:]]+run[[:space:]]'; }

# makefile_fixed_pg: `<file>:<line>: <name|port|container> <value>` for each throwaway Postgres container
# name or host port that makefile_files fix to a literal: the name argument of a
# `throwaway_pg.sh up|url|down` call (the script named directly or through a variable set to
# its path, closet's `PG := devkit/bin/throwaway_pg.sh` then `$(PG) up $(PG_CONTAINER)`), the
# `--name` of a `docker run` or `docker_bounded.sh run` on the same line (kind `container`: any
# image, since a fixed name collides across worktrees whatever runs in it), and each `PG_PORT=`
# value, read either inline or through one `$(VAR)` to VAR's assignment (the line printed is
# the assignment's, `=`, `:=`, `?=` or `+=`). A literal is one container and one port for every
# worktree of the repo, so concurrent lanes remove each other's databases or fail on the port
# (2026-10-19); `throwaway_pg.sh name|port <base>` derives both from the checkout. Comment
# lines are skipped; any other indirection (`$(shell …)`, a nested variable) counts as derived.
# Each value may be quoted, `"x"` or `'x'` (`--name "x"` once read as no name at all).
makefile_fixed_pg() {
  local files=() file
  while IFS= read -r file; do files+=("$file"); done < <(makefile_files)
  [ "${#files[@]}" -gt 0 ] || return 0
  awk '
    # ARG: one whole shell word, optionally single- or double-quoted (`"x"$(SUFFIX)` is not one);
    # judge drops the quotes and the separator after it, from the word and from a variable value.
    BEGIN { ARG = "[\"\047]?[^ \t;&|\"\047]+[\"\047]?([ \t;&|]|$)" }
    function judge(kind, arg, file, n,    v, value, at) {
      sub(/[ \t;&|]$/, "", arg)
      gsub(/["\047]/, "", arg)
      value = arg; at = file ":" n
      if (match(arg, /^\$[({][A-Za-z_][A-Za-z0-9_]*[)}]$/)) {
        v = substr(arg, 3, length(arg) - 3)
        if (!(v in val)) return
        value = val[v]; at = loc[v]
        gsub(/^["\047]|["\047]$/, "", value)
      }
      if (kind != "port" && value !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/) return
      if (kind == "port" && value !~ /^[0-9]+$/) return
      if (!seen[at, kind]++) out[++nout] = at ": " kind " " value
    }
    { lines[FILENAME, FNR] = $0; if (FNR == 1) order[++nfiles] = FILENAME; count[FILENAME] = FNR }
    !/^\t/ && /^[A-Za-z_][A-Za-z0-9_]*[ \t]*[?:+]?=/ {
      name = $0; sub(/[ \t]*[?:+]?=.*/, "", name)
      value = $0; sub(/^[^=]*=[ \t]*/, "", value); sub(/[ \t]*(#.*)?$/, "", value)
      val[name] = value; loc[name] = FILENAME ":" FNR
      if (value ~ /(^|\/)throwaway_pg\.sh$/) pg[name] = 1
    }
    END {
      for (f = 1; f <= nfiles; f++) {
        file = order[f]
        for (n = 1; n <= count[file]; n++) {
          line = lines[file, n]
          if (line ~ /^[ \t]*#/) continue
          for (v in pg) gsub("\\$[({]" v "[)}]", "throwaway_pg.sh", line)
          rest = line
          while (match(rest, "throwaway_pg\\.sh[ \t]+(up|url|down)[ \t]+" ARG)) {
            call = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
            sub(/^throwaway_pg\.sh[ \t]+(up|url|down)[ \t]+/, "", call)
            judge("name", call, file, n)
          }
          rest = line
          if (match(rest, /(^|[^A-Za-z0-9_.-])docker(_bounded\.sh)?[ \t]+run[ \t]/)) {
            rest = substr(rest, RSTART + RLENGTH)
            if (match(rest, "(^|[ \t])--name([ \t]+|=)" ARG)) {
              call = substr(rest, RSTART, RLENGTH)
              sub(/^[ \t]*--name([ \t]+|=)/, "", call)
              judge("container", call, file, n)
            }
          }
          rest = line
          while (match(rest, "(^|[^A-Za-z0-9_])PG_PORT=" ARG)) {
            call = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
            sub(/^.*PG_PORT=/, "", call)
            judge("port", call, file, n)
          }
        }
      }
      for (i = 1; i <= nout; i++) print out[i]
    }' "${files[@]}"
}

# makefile_tier_target <tier>: the rule a gate would run to get `tier_guard.sh <tier>` run: the
# first rule of makefile_files whose recipe (tab-led lines, or inline after `target: ;`) runs it,
# the script named directly or through a variable set to its path (finplat's `TIER_GUARD =
# $(CURDIR)/devkit/bin/tier_guard.sh`, closet's `TIER := devkit/bin/tier_guard.sh`), or the
# first rule whose recipe runs that one as the one goal of `$(MAKE) ... <rule>`, one level up (finplat's
# test-db brings Postgres and runs ci-db with its URL: ci-db alone has no database); nothing when
# none does. Continuation lines are joined first, so a call split over lines is one. Used by:
# metrics_collect.sh (the tier a floor's file comes from).
makefile_tier_target() {
  local files=() file
  while IFS= read -r file; do files+=("$file"); done < <(makefile_files)
  [ "${#files[@]}" -gt 0 ] || return 0
  awk -v tier="$1" '
    { lines[++n] = $0 }
    !/^\t/ && match($0, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[?:+]?=/) {
      value = $0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]+$/, "", value)
      if (value ~ /(^|\/)tier_guard\.sh$/) { name = $0; sub(/[[:space:]]*[?:+]?=.*/, "", name); vars[name] = 1 }
    }
    END {
      # Pass 1: every (rule, logical recipe line), inline recipes included. Tab-led lines belong
      # to a rule only: a define body or an assignment continued onto tab-led lines resets it.
      for (i = 1; i <= n; i++) {
        line = lines[i]
        if (indef) { if (line ~ /^[[:space:]]*endef/) indef = 0; continue }
        if (skip) { skip = (line ~ /\\$/); continue }
        if (line !~ /^\t/) {
          if (line ~ /^[[:space:]]*(#|$)/ || line ~ /^[[:space:]]*(ifn?eq|ifn?def|else|endif)([[:space:]]|$)/) continue
          if (line ~ /^(export[[:space:]]+|override[[:space:]]+)?define[[:space:]]/) { indef = 1; target = ""; continue }
          if (line ~ /^[^:=]*[?+!]?=/ || line ~ /^[^=]*::?=/ || line !~ /:/) {
            target = ""; skip = (line ~ /\\$/); continue
          }
          target = line; sub(/:.*/, "", target); sub(/[[:space:]].*/, "", target)
          if (!match(line, /:[^;]*;/)) continue
          line = substr(line, RSTART + RLENGTH)
        }
        while (line ~ /\\$/ && i < n) { sub(/\\$/, " ", line); line = line lines[++i] }
        for (v in vars) gsub("\\$[({]" v "[)}]", "tier_guard.sh", line)
        if (target != "") { rule[++m] = target; call[m] = line }
      }
      for (k = 1; k <= m; k++)
        if (call[k] ~ ("(^|[^A-Za-z0-9_.-])tier_guard\\.sh[[:space:]]+" tier "([[:space:]]|$)")) { inner = rule[k]; break }
      if (inner == "") exit
      # Pass 2: a wrapper whose $(MAKE) call has the inner rule as its one goal (options and
      # VAR=value aside): a catch-all `ci` making several tiers is no wrapper of one.
      for (k = 1; k <= m; k++) {
        # A computed target (the `$(COV_UNIT):` file rule of kitchen) is no goal a make call names.
        if (rule[k] == inner || rule[k] ~ /\$/ || !match(call[k], /\$[({]MAKE[)}][^;&|]*/)) continue
        nw = split(substr(call[k], RSTART + 7, RLENGTH - 7), w, /[[:space:]]+/)
        goals = 0; goal = ""
        for (j = 1; j <= nw; j++) if (w[j] != "" && w[j] !~ /^-/ && w[j] !~ /=/) { goals++; goal = w[j] }
        if (goals == 1 && goal == inner) { print rule[k]; exit }
      }
      print inner
    }' "${files[@]}"
}
