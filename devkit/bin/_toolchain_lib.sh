# shellcheck shell=bash
# devkit's toolchain lookup: THE python3 devkit's own tools run on, and the few tools a gate's
# jobs call by bare name that this Mac installs off launchd's PATH (uv), each found independently
# of the caller's PATH. Sourced; defines functions and runs nothing. Used by: python.sh (Makefiles,
# the metrics merge driver), toolchain_path.sh (puts them first on PATH for the gate's jobs, the
# hooks and every toolchain_shell.sh recipe, so a consumer's own bare python3 and uv get them too),
# install_dependency_merge.sh (bakes them into the plist), the gate preflights (local_gate.sh,
# pr_merge.sh, remote_gate.sh, dependency_merge.sh) and every bin/*.sh that runs a devkit .py
# (tests/toolchain_resolver.bats fails on a bare python3 there).
#
#   devkit_python       0: export DEVKIT_PYTHON (an absolute interpreter >= DEVKIT_PYTHON_FLOOR)
#                       and set DEVKIT_PYTHON_SOURCE (DEVKIT_PYTHON, PATH, mise, uv, Homebrew) and
#                       DEVKIT_PYTHON_VERSION. 1: DEVKIT_PYTHON_ERROR, one line naming every place
#                       tried; a box problem, the same for every repo and PR.
#   devkit_tool <name>  one of DEVKIT_TOOLCHAIN_TOOLS. 0: DEVKIT_TOOL (absolute), DEVKIT_TOOL_SOURCE
#                       (DEVKIT_<NAME>, PATH, mise, python, XDG_BIN_HOME, CARGO_HOME, Homebrew)
#                       and DEVKIT_TOOL_VERSION. 1: DEVKIT_TOOL_ERROR, one clause naming every place.
#   devkit_toolchain    devkit_python and devkit_tool for every DEVKIT_TOOLCHAIN_TOOLS entry:
#                       DEVKIT_TOOLCHAIN_LINKS ("python3=<path> uv=<path>"), DEVKIT_TOOLCHAIN_OFF_PATH
#                       the ones PATH did not have ("python 3.14.3 from mise; uv 0.9.5 from
#                       python"), DEVKIT_TOOLCHAIN_MISSING the tools not found (DEVKIT_TOOL_ERROR
#                       each, in DEVKIT_TOOLCHAIN_ERROR). 1 and DEVKIT_PYTHON_ERROR only for no
#                       python3: a missing tool fails only a caller that needs it
#                       (devkit_preflight), since CI jobs and hooks in a uv repo also run where no
#                       uv is installed.
#   devkit_toolchain_link [<links>]
#                       <links> (default DEVKIT_TOOLCHAIN_LINKS; toolchain_path passes
#                       DEVKIT_TOOLCHAIN_OFF_LINKS, the ones PATH lacks: a PATH python3 that is a
#                       venv's or a shim must stay the one a bare call runs) linked by name into
#                       DEVKIT_TOOLCHAIN_BIN, a directory holding those links alone, for PATH.
#                       1 and DEVKIT_PYTHON_ERROR if it cannot.
#   devkit_toolchain_bin
#                       both.
#   devkit_declared_tools <tree>
#                       the DEVKIT_TOOLCHAIN_TOOLS a checkout's own files declare, space-separated:
#                       uv for a tracked uv.lock anywhere (its recipes run uv sync/run).
#   devkit_preflight <tool>... [-- <tree>...]
#                       0 when each <tool> is on PATH (gh, git, make, flock: the skeleton's own),
#                       devkit_python succeeds and each tool a <tree> declares is found; else 1 and
#                       DEVKIT_PREFLIGHT_ERROR, ONE line naming every missing tool and why.
# Not the interpreter's or the tool's own bin/: a mise or uv Python's bin/ also holds whatever pip
# installed there (this Mac's holds uv and ruff), which would shadow the repo's ruff.
#
# Python order: an explicit DEVKIT_PYTHON (one that does not qualify is an error, never skipped),
# PATH's python3, mise (`mise which python3` from $HOME, its global choice, then its installs
# newest first), uv-managed installs newest first, Homebrew. A tool's: DEVKIT_<NAME> (DEVKIT_UV;
# the same error rule), PATH, `mise which`, beside devkit's python3 (a pip install: this Mac's
# uv), its installer's directories (XDG_BIN_HOME or ~/.local/bin, CARGO_HOME/bin), Homebrew.
# mise, uv and Homebrew are found by their own standard variables (MISE_DATA_DIR,
# UV_PYTHON_INSTALL_DIR, HOMEBREW_PREFIX, which also locates a mise binary off PATH), so the
# tests can hide this Mac's.
# Why (2026-10-22): the first launchd dependency run had PATH=/opt/homebrew/bin:...:/usr/bin, where
# python3 is Xcode's 3.9 (this Mac's Python comes from mise shims, which only an interactive shell
# has), and every homelab gate failed on tomllib and datetime.UTC. Every dry run had passed. Then
# an `env -i` gate of devkit under the fixed PATH failed clock_shift_contract: uv is pip-installed
# in mise's Python, so every uv repo's gate (finplat, orbit, locus, kitchen) would have failed too.
# Cache: within a shell the first python success is reused; the exported DEVKIT_PYTHON carries it
# to children, which re-check it with one interpreter start instead of searching again. A tool
# needs none: children find it on PATH, in DEVKIT_TOOLCHAIN_BIN.
# Floor: ruff.toml's target-version; vendored tools use tomllib and datetime.UTC (3.11).
# Bash 3.2 (launchd runs dependency_merge.sh with /bin/bash): no associative arrays, no ${x^^}.

# shellcheck disable=SC2034  # DEVKIT_PYTHON_*, DEVKIT_TOOL* and DEVKIT_PREFLIGHT_ERROR are this file's output
DEVKIT_PYTHON_FLOOR=3.11
# The tools devkit_tool knows: each also needs a devkit_declared_tools marker.
DEVKIT_TOOLCHAIN_TOOLS='uv'
_DEVKIT_PYTHON_RESOLVED=''

# _devkit_python_probe <interpreter>: "<version> <real interpreter path>", or fail.
_devkit_python_probe() {
  "$1" -I -c 'import os, sys; print("%d.%d.%d" % sys.version_info[:3], os.path.realpath(sys.executable))' 2>/dev/null
}

# _devkit_python_try <source> <candidate>: 0 and DEVKIT_PYTHON set when the candidate runs, is
# >= the floor; else 1 and one clause appended to _DEVKIT_PYTHON_TRIED (an empty candidate,
# PATH with no python3, adds none).
_devkit_python_try() {
  local source=$1 cand=$2 out version real major minor
  [ -n "$cand" ] || return 1
  [ -x "$cand" ] || { _DEVKIT_PYTHON_TRIED+="; $source $cand is not executable"; return 1; }
  out=$(_devkit_python_probe "$cand") || { _DEVKIT_PYTHON_TRIED+="; $source $cand does not run"; return 1; }
  version=${out%% *} real=${out#* }
  IFS=. read -r major minor _ <<<"$version"
  if [ "$major" -lt "${DEVKIT_PYTHON_FLOOR%.*}" ] \
    || { [ "$major" -eq "${DEVKIT_PYTHON_FLOOR%.*}" ] && [ "$minor" -lt "${DEVKIT_PYTHON_FLOOR#*.}" ]; }; then
    _DEVKIT_PYTHON_TRIED+="; $source $cand is $version"
    return 1
  fi
  export DEVKIT_PYTHON=$real
  DEVKIT_PYTHON_SOURCE=$source DEVKIT_PYTHON_VERSION=$version
}

# _devkit_python_glob <source> <pattern>: try each match, newest version first.
_devkit_python_glob() {
  local source=$1 cand
  while IFS= read -r cand; do
    _devkit_python_try "$source" "$cand" && return 0
  done < <(compgen -G "$2" | sort -rV)
  return 1
}

# _devkit_mise_which <name>: mise's choice of <name>, or fail. From $HOME: `mise which` resolves
# by the current directory's config, and a repo's .python-version may name a Python mise has not
# installed. Only the first mise binary found is asked.
_devkit_mise_which() {
  local mise prefix candidates=("$(command -v mise)" "${HOME:-}/.local/bin/mise")
  for prefix in $_DEVKIT_HOMEBREW_PREFIXES; do candidates+=("$prefix/bin/mise"); done
  for mise in "${candidates[@]}"; do
    [ -x "$mise" ] || continue
    (cd "${HOME:-/}" 2>/dev/null && "$mise" which "$1" 2>/dev/null)
    return
  done
  return 1
}

_devkit_python_mise() {
  local cand
  cand=$(_devkit_mise_which python3) && _devkit_python_try mise "$cand" && return 0
  _devkit_python_glob mise "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/installs/python/*/bin/python3"
}

_devkit_python_homebrew() {
  local prefix
  for prefix in $_DEVKIT_HOMEBREW_PREFIXES; do
    _devkit_python_try Homebrew "$prefix/bin/python3" && return 0
    _devkit_python_glob Homebrew "$prefix/opt/python@3.*/libexec/bin/python3" && return 0
  done
  return 1
}

devkit_python() {
  if [ -n "$_DEVKIT_PYTHON_RESOLVED" ] && [ "$_DEVKIT_PYTHON_RESOLVED" = "${DEVKIT_PYTHON:-}" ]; then
    return 0
  fi
  DEVKIT_PYTHON_ERROR='' _DEVKIT_PYTHON_TRIED='' _DEVKIT_HOMEBREW_PREFIXES=${HOMEBREW_PREFIX:-/opt/homebrew /usr/local}
  if [ -n "${DEVKIT_PYTHON:-}" ]; then
    local wanted=$DEVKIT_PYTHON
    # A bare name (DEVKIT_PYTHON=python3.13) is looked up on PATH.
    [[ "$wanted" == */* ]] || wanted=$(command -v "$wanted") || wanted=$DEVKIT_PYTHON
    if ! _devkit_python_try DEVKIT_PYTHON "$wanted"; then
      DEVKIT_PYTHON_ERROR="DEVKIT_PYTHON must be a python3 >= $DEVKIT_PYTHON_FLOOR (${_DEVKIT_PYTHON_TRIED#; })"
      return 1
    fi
    # Usually a parent's resolution, exported: when PATH's python3 runs the same interpreter it
    # is PATH's, so toolchain_path adds no directory and no note.
    local path_python out
    path_python=$(command -v python3) && out=$(_devkit_python_probe "$path_python") \
      && [ "${out#* }" = "$DEVKIT_PYTHON" ] && DEVKIT_PYTHON_SOURCE=PATH
  elif ! { _devkit_python_try PATH "$(command -v python3)" || _devkit_python_mise \
    || _devkit_python_glob uv "${UV_PYTHON_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/python}/cpython-*/bin/python3" \
    || _devkit_python_homebrew; }; then
    DEVKIT_PYTHON_ERROR="no python3 >= $DEVKIT_PYTHON_FLOOR on this box (tried PATH, mise, uv, Homebrew${_DEVKIT_PYTHON_TRIED:+: ${_DEVKIT_PYTHON_TRIED#; }}); install one (mise use -g python@3.14) or set DEVKIT_PYTHON"
    return 1
  fi
  _DEVKIT_PYTHON_RESOLVED=$DEVKIT_PYTHON
}

# _devkit_tool_try <source> <candidate>: 0 and DEVKIT_TOOL set when the candidate answers
# --version; else 1 and one clause appended to _DEVKIT_TOOL_TRIED (an empty or absent candidate,
# the usual case for a fixed directory, adds none).
_devkit_tool_try() {
  local source=$1 cand=$2 out
  [ -n "$cand" ] && [ -e "$cand" ] || return 1
  [ -x "$cand" ] || { _DEVKIT_TOOL_TRIED+="; $source $cand is not executable"; return 1; }
  out=$("$cand" --version </dev/null 2>/dev/null) || { _DEVKIT_TOOL_TRIED+="; $source $cand does not run"; return 1; }
  read -r _ DEVKIT_TOOL_VERSION _ <<<"$out"
  DEVKIT_TOOL=$cand DEVKIT_TOOL_SOURCE=$source
}

devkit_tool() {
  local name=$1 var prefix explicit on_path
  DEVKIT_TOOL='' DEVKIT_TOOL_ERROR='' _DEVKIT_TOOL_TRIED='' _DEVKIT_HOMEBREW_PREFIXES=${HOMEBREW_PREFIX:-/opt/homebrew /usr/local}
  var=DEVKIT_$(printf %s "$name" | tr '[:lower:]-' '[:upper:]_')
  explicit=${!var:-}
  if [ -n "$explicit" ]; then
    [[ "$explicit" == */* ]] || explicit=$(command -v "$explicit") || explicit=${!var}
    _devkit_tool_try "$var" "$explicit" && return 0
    _DEVKIT_TOOL_TRIED=${_DEVKIT_TOOL_TRIED:-; $var $explicit does not exist}
    DEVKIT_TOOL_ERROR="$var must be a $name that runs (${_DEVKIT_TOOL_TRIED#; })"
    return 1
  fi
  # PATH's is taken unprobed, as a bare call would run it: no process per recipe line when PATH
  # has it, and no version, since nothing notes a tool PATH already had.
  on_path=$(command -v "$name") && [[ "$on_path" == /* ]] && [ -x "$on_path" ] \
    && { DEVKIT_TOOL=$on_path DEVKIT_TOOL_SOURCE=PATH DEVKIT_TOOL_VERSION=''; return 0; }
  _devkit_tool_try mise "$(_devkit_mise_which "$name")" && return 0
  # A pip install beside the interpreter (this Mac's uv); the realpath, not a shim's directory.
  devkit_python 2>/dev/null && _devkit_tool_try python "$(dirname "$DEVKIT_PYTHON")/$name" && return 0
  # ${HOME:-}: under set -u a HOME-less environment (env -i, a bare unit) must not abort the caller.
  _devkit_tool_try XDG_BIN_HOME "${XDG_BIN_HOME:-${HOME:-}/.local/bin}/$name" && return 0
  _devkit_tool_try CARGO_HOME "${CARGO_HOME:-${HOME:-}/.cargo}/bin/$name" && return 0
  for prefix in $_DEVKIT_HOMEBREW_PREFIXES; do
    _devkit_tool_try Homebrew "$prefix/bin/$name" && return 0
  done
  DEVKIT_TOOL_ERROR="no $name on this box (tried PATH, mise, python, XDG_BIN_HOME, CARGO_HOME, Homebrew${_DEVKIT_TOOL_TRIED:+: ${_DEVKIT_TOOL_TRIED#; }}); install one (brew install $name) or set $var"
  return 1
}

# _devkit_link <dir> <name> <target>: <dir>/<name> -> <target>, replaced atomically.
_devkit_link() {
  [ "$1/$2" -ef "$3" ] && return 0
  ln -sf "$3" "$1/$2.$$" && mv -f "$1/$2.$$" "$1/$2"
}

devkit_toolchain() {
  local tool off='' missing='' errors=''
  devkit_python || return 1
  [ "$DEVKIT_PYTHON_SOURCE" = PATH ] || off="python $DEVKIT_PYTHON_VERSION from $DEVKIT_PYTHON_SOURCE"
  DEVKIT_TOOLCHAIN_LINKS="python3=$DEVKIT_PYTHON" DEVKIT_TOOLCHAIN_OFF_LINKS=''
  [ -z "$off" ] || DEVKIT_TOOLCHAIN_OFF_LINKS=$DEVKIT_TOOLCHAIN_LINKS
  for tool in $DEVKIT_TOOLCHAIN_TOOLS; do
    if devkit_tool "$tool"; then
      DEVKIT_TOOLCHAIN_LINKS+=" $tool=$DEVKIT_TOOL"
      [ "$DEVKIT_TOOL_SOURCE" = PATH ] && continue
      off="${off:+$off; }$tool $DEVKIT_TOOL_VERSION from $DEVKIT_TOOL_SOURCE"
      DEVKIT_TOOLCHAIN_OFF_LINKS="${DEVKIT_TOOLCHAIN_OFF_LINKS:+$DEVKIT_TOOLCHAIN_OFF_LINKS }$tool=$DEVKIT_TOOL"
    else
      missing="${missing:+$missing }$tool" errors="${errors:+$errors; }$DEVKIT_TOOL_ERROR"
    fi
  done
  DEVKIT_TOOLCHAIN_OFF_PATH=$off DEVKIT_TOOLCHAIN_MISSING=$missing DEVKIT_TOOLCHAIN_ERROR=$errors
}

devkit_toolchain_link() {
  local links=${1:-$DEVKIT_TOOLCHAIN_LINKS} dir link
  # One directory per set of targets: two gates resolving different tools never share a link.
  dir=${XDG_STATE_HOME:-${HOME:-}/.local/state}/devkit/toolchain/$(printf %s "$links" | cksum | cut -d' ' -f1)
  mkdir -p "$dir" || { DEVKIT_PYTHON_ERROR="cannot create $dir"; return 1; }
  for link in $links; do
    _devkit_link "$dir" "${link%%=*}" "${link#*=}" \
      || { DEVKIT_PYTHON_ERROR="cannot link $dir/${link%%=*} to ${link#*=}"; return 1; }
  done
  DEVKIT_TOOLCHAIN_BIN=$dir
}

devkit_toolchain_bin() { devkit_toolchain && devkit_toolchain_link; }

devkit_declared_tools() {
  local declared=''
  [ -n "$(git -C "$1" ls-files -- uv.lock '*/uv.lock' 2>/dev/null | head -n 1)" ] && declared=uv
  printf '%s' "$declared"
}

devkit_preflight() {
  local tool tree missing='' needed=''
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    command -v "$1" >/dev/null || missing="${missing:+$missing, }$1 (not on PATH; brew install $1)"
    shift
  done
  [ $# -eq 0 ] || shift
  devkit_python || missing="${missing:+$missing, }python3 ($DEVKIT_PYTHON_ERROR)"
  for tree in "$@"; do
    for tool in $(devkit_declared_tools "$tree"); do
      case " $needed " in *" $tool "*) continue ;; esac
      needed+=" $tool"
      devkit_tool "$tool" || missing="${missing:+$missing, }$tool (declared by $tree; $DEVKIT_TOOL_ERROR)"
    done
  done
  DEVKIT_PREFLIGHT_ERROR=${missing:+missing on this box: $missing}
  [ -z "$missing" ]
}
