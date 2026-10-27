# shellcheck shell=bash
# scripts/ci/metrics.conf, read: its collectors and the tier outputs they read. Sourced; defines
# functions and constants and runs nothing. The conf's format is metrics_collect.sh's header.
# Used by: metrics_collect.sh (runs the collectors, checks their inputs exist and are fresh),
# tier_guard.sh (a shifted tier puts every input back as it found it: the clock shift's runs
# must never be what a collector reads, devkit decisions 2026-10-22) and _paths_lib.sh (the
# METRICS group runs for every area a collector names). One table, so a new artefact-reading
# flag is guarded the day it is read.
#
#   metrics_conf_parse <conf>
#       Sets NAMES, COLLECTOR_AREAS and COMMANDS, one entry per collector, in conf order. A
#       malformed line calls the caller's die() naming <conf>:<line>. An area is `repo`,
#       `job:<name>` or a comma-separated list of fleet areas (`backend,native`: one jscpd run
#       over the Python and the Swift sources), kept as written.
#   metrics_conf_areas <conf>
#       The fleet areas the conf's area collectors name, each once, space-separated (neither
#       `repo` nor `job:`, which run whenever the metrics job does); nothing when <conf> does
#       not exist. A malformed conf calls die() as metrics_conf_parse does.
#   tier_inputs <command>
#       The files a collector command reads that a build or test tier writes, one per line,
#       relative to the repo root (collectors run there). tier_input_rows: "<kind> <file>".
#   metrics_conf_tier_inputs <conf>
#       Every collector's tier_input_rows, each once; nothing when <conf> does not exist.
#
# Portability: macOS bash 3.2 and GNU bash.

readonly METRICS_AREAS="docs backend frontend native tooling other"
# Tier inputs: every devkit collector flag that reads a build or test artefact, one
# row each; a new artefact-reading collector or flag is a new row, read by tier_inputs.
#   collector      flag                the input checked for, and its kind
#   coverage.py    --coverage-json     value: the flag's file (coverage.py `coverage json`)
#   coverage.py    --istanbul-summary  value: the flag's file (istanbul coverage-summary.json)
#   coverage.py    --llvm-cov-json     value: the flag's file (cargo llvm-cov --json export)
#   statements.py  --in                value: the flag's file (the statement fixture's output)
#   ts.mjs         --bundle            next-build: <--root>/.next/build-manifest.json in a Next
#                                      app (a .next/ or a next.config.*: ts.mjs's own test);
#                                      `next build` rewrites it every build, while the .next/
#                                      dir's own mtime moves only when an entry is added. A vite
#                                      app is built by ts.mjs itself and has no input
readonly TIER_INPUTS="coverage.py --coverage-json value
coverage.py --istanbul-summary value
coverage.py --llvm-cov-json value
statements.py --in value
ts.mjs --bundle next-build"
readonly TIER_INPUT_COLLECTOR='[[:space:]/]metrics/([a-z_]+\.(py|mjs))[[:space:]]'

metrics_conf_parse() {
  local conf=$1 line line_no=0 name area command seen one where
  NAMES=()
  COLLECTOR_AREAS=()
  COMMANDS=()
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*) continue ;; esac
    read -r name area command <<<"$line"
    where=$conf:$line_no
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] \
      || die "$conf:$line_no: collector name '$name' must match [A-Za-z0-9_-]+ (it names build/metrics/<name>.json)"
    for seen in ${NAMES[@]+"${NAMES[@]}"}; do
      [ "$seen" != "$name" ] || die "$conf:$line_no: collector '$name' declared twice"
    done
    case "${area:-}" in
      repo) ;;
      job:*)
        [[ "${area#job:}" =~ ^[A-Za-z0-9_-]+$ ]] \
          || die "$conf:$line_no: '${area}' must name a gate job, job:<name> with [A-Za-z0-9_-]+" ;;
      *)
        [[ "${area:-}" =~ ^[a-z]+(,[a-z]+)*$ ]] || area_error "$where" "${area:-}"
        for one in ${area//,/ }; do
          case " $METRICS_AREAS " in *" $one "*) ;; *) area_error "$where" "$area" ;; esac
        done ;;
    esac
    [ -n "${command:-}" ] || die "$conf:$line_no: collector '$name' has no command"
    NAMES+=("$name")
    COLLECTOR_AREAS+=("$area")
    COMMANDS+=("$command")
  done <"$conf"
}

area_error() { # <conf>:<line> <area>
  die "$1: area '$2' must be repo, job:<gate job name>, or comma-separated areas of: $METRICS_AREAS"
}

metrics_conf_areas() {
  [ -f "$1" ] || return 0
  # Local: metrics_conf_parse sets these by dynamic scope, so the caller's own parse is untouched.
  local area one seen=' ' NAMES COLLECTOR_AREAS COMMANDS
  metrics_conf_parse "$1"
  for area in ${COLLECTOR_AREAS[@]+"${COLLECTOR_AREAS[@]}"}; do
    case "$area" in repo | job:*) continue ;; esac
    for one in ${area//,/ }; do
      case "$seen" in *" $one "*) ;; *) seen+="$one " ;; esac
    done
  done
  seen=${seen# }
  echo "${seen% }"
}

# flag_values <flag> <word>...: each value the words give <flag> (`--f v` or `--f=v`).
flag_values() {
  local flag=$1 w prev=""
  shift
  for w in "$@"; do
    if [ "$prev" = "$flag" ]; then echo "$w"; elif [[ "$w" == "$flag="?* ]]; then echo "${w#*=}"; fi
    prev=$w
  done
}
# next_build_input <root>: the Next build manifest under <root> when <root> is a Next app. The
# names are ts.mjs's NEXT_CONFIGS: keep the two in step.
next_build_input() {
  local root=${1%/} c
  [ -n "$root" ] || return 0
  if [ "$root" = . ]; then root=""; else root="$root/"; fi
  for c in .next next.config.js next.config.mjs next.config.ts next.config.cjs; do
    if [ -e "$root$c" ]; then echo "${root}.next/build-manifest.json"; return; fi
  done
}
# tier_input_rows <command>: "<kind> <file>" per input (TIER_INPUTS), kind value or next-build.
tier_input_rows() {
  [[ " $1 " =~ $TIER_INPUT_COLLECTOR ]] || return 0
  local collector=${BASH_REMATCH[1]} words row_collector flag kind w
  read -ra words <<<"$1"
  while read -r row_collector flag kind; do
    [ "$row_collector" = "$collector" ] || continue
    case "$kind" in
      value) while read -r w; do echo "value $w"; done < <(flag_values "$flag" "${words[@]}") ;;
      next-build)
        case " ${words[*]} " in *" $flag "*) ;; *) continue ;; esac
        while read -r w; do next_build_input "$w"; done < <(flag_values --root "${words[@]}") \
          | while read -r w; do echo "next-build $w"; done ;;
    esac
  done <<<"$TIER_INPUTS"
}
tier_inputs() { tier_input_rows "$1" | cut -d' ' -f2-; }

# metrics_conf_tier_inputs reads next_build_input's paths from the working directory: call it
# from the repo root.
metrics_conf_tier_inputs() {
  [ -f "$1" ] || return 0
  local i
  metrics_conf_parse "$1"
  for ((i = 0; i < ${#COMMANDS[@]}; i++)); do tier_input_rows "${COMMANDS[$i]}"; done | awk 'NF && !seen[$0]++'
}
