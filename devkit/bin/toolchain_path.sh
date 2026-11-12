# shellcheck shell=bash
# Put a tree's pinned toolchains first on PATH: Node from .nvmrc (node_toolchain.sh), pnpm from a
# package.json packageManager (package_manager_toolchain.sh), Rust from
# rust-toolchain.toml or rust-toolchain (rust_toolchain.sh), and devkit's python3 and uv
# (_toolchain_lib.sh) for the vendored tools and a repo's own bare python3 and uv calls. Sourced;
# defines toolchain_path and runs nothing. Used by
# hook_steps.sh (on the hook's checkout), so a hook runs the same node/cargo a job does on a
# machine whose PATH has none (redlib's Mac has no Rust) or the wrong one (the Mac's Node 25).
#
#   toolchain_path <tree>    # 0 ok; 1 a declared toolchain cannot be provided (the box);
#                            # 3 a declaration is the tree's own fault (an inexact .nvmrc, two
#                            # rust declarations, disagreeing packageManager pins: a provisioning
#                            # script's exit 3), which check_tree.sh calls red, never the box's
#
# On 0 it exports PATH, DEVKIT_PYTHON, DEVKIT_TOOLCHAIN_TREE (the tree's physical path:
# toolchain_shell.sh skips a tree already on its pins) and sets TOOLCHAIN_NOTES ("node v22.23.3 from
# .nvmrc; rust 1.99.0 from rust-toolchain.toml", led by "python 3.14.3 from mise; uv 0.9.5 from
# python" for each that PATH lacked; "pnpm 10.32.1 from packageManager" when a package.json
# declares it: package_manager_toolchain.sh; empty when nothing was provided). On 1 it sets
# TOOLCHAIN_FAILED (each of "Python", "Node", "pnpm", "Rust toolchain" that failed, comma-separated: every
# step runs, so one error names them all) and TOOLCHAIN_ERROR (one clause per failure, naming the
# declaration, or every place Python was looked for); a provisioning script's own reason is
# already on stderr. 3 wins over 1: a commit whose pin is wrong is red whatever else the box lacks. A uv not found is no failure here (CI jobs and hooks run without one);
# the gate's preflight (devkit_preflight) requires it where a uv.lock declares it.
# A repo's own Python is not this one: `uv run`/`uv sync` read .python-version themselves.
# Gotcha: PATH changes last only as long as the calling shell; both callers are their own process.

# shellcheck source=bin/_toolchain_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_toolchain_lib.sh"

# _toolchain_fail <what> <reason> [<script exit>]: record one failed step; exit 3 is the tree's.
_toolchain_fail() {
  TOOLCHAIN_FAILED="${TOOLCHAIN_FAILED:+$TOOLCHAIN_FAILED, }$1"
  TOOLCHAIN_ERROR="${TOOLCHAIN_ERROR:+$TOOLCHAIN_ERROR; }$2"
  [ "${3:-1}" != 3 ] || _TOOLCHAIN_TREE_FAULT=1
}

_toolchain_note() { TOOLCHAIN_NOTES="${TOOLCHAIN_NOTES:+$TOOLCHAIN_NOTES; }$1"; }

# _toolchain_run <what> <reason> <script> <tree>: one provisioning script. On success the
# directory it printed (none: PATH already had the pin) goes first on PATH, in _TOOLCHAIN_BIN
# too; on failure the step is recorded (_toolchain_fail) and it returns 1.
_toolchain_run() {
  local rc=0
  _TOOLCHAIN_BIN=$("$_TOOLCHAIN_HERE/$3" "$4") || rc=$?
  [ "$rc" = 0 ] || { _toolchain_fail "$1" "$2" "$rc"; return 1; }
  [ -z "$_TOOLCHAIN_BIN" ] || export PATH="$_TOOLCHAIN_BIN:$PATH"
}

# Its directory holds python3 and/or uv alone, and only what PATH lacks: a box whose PATH has
# them all gets PATH untouched.
_toolchain_python() {
  if ! devkit_toolchain || { [ -n "$DEVKIT_TOOLCHAIN_OFF_LINKS" ] && ! devkit_toolchain_link "$DEVKIT_TOOLCHAIN_OFF_LINKS"; }; then
    _toolchain_fail Python "$DEVKIT_PYTHON_ERROR"
  elif [ -n "$DEVKIT_TOOLCHAIN_OFF_PATH" ]; then
    export PATH="$DEVKIT_TOOLCHAIN_BIN:$PATH"
    _toolchain_note "$DEVKIT_TOOLCHAIN_OFF_PATH"
  fi
}

_toolchain_node() {
  [ -f "$1/.nvmrc" ] || return 0
  _toolchain_run Node "cannot provide node $(tr -d '[:space:]' <"$1/.nvmrc") declared in .nvmrc" node_toolchain.sh "$1" || return 0
  _toolchain_note "node $(node --version) from .nvmrc"
}

# The pinned Node's npm installs it, so never after a failed Node, and never a PATH corepack
# (Node 25+ ships none).
_toolchain_pnpm() {
  [[ "$TOOLCHAIN_FAILED" != *Node* ]] || return 0
  _toolchain_run pnpm "cannot provide the pnpm a package.json packageManager declares" package_manager_toolchain.sh "$1" || return 0
  [ -z "$_TOOLCHAIN_BIN" ] || _toolchain_note "pnpm $(basename "$(dirname "$_TOOLCHAIN_BIN")") from packageManager"
}

_toolchain_rust() {
  local decl='' f
  for f in rust-toolchain.toml rust-toolchain; do [ -f "$1/$f" ] && { decl=$f; break; }; done
  [ -n "$decl" ] || return 0
  _toolchain_run 'Rust toolchain' "cannot provide the rust toolchain declared in $decl" rust_toolchain.sh "$1" || return 0
  # From the tree: a PATH cargo that matched is usually a rustup proxy, which resolves by cwd.
  _toolchain_note "rust $( (cd "$1" && cargo --version) | awk '{print $2}') from $decl"
}

# shellcheck disable=SC2034  # TOOLCHAIN_* are this function's output, read by the caller
toolchain_path() {
  _TOOLCHAIN_HERE=$(dirname "${BASH_SOURCE[0]}")
  TOOLCHAIN_NOTES='' TOOLCHAIN_FAILED='' TOOLCHAIN_ERROR='' _TOOLCHAIN_TREE_FAULT=0
  # In this order: each later directory lands in front of the earlier ones (Python first, so
  # Node and Rust lead), and pnpm needs the pinned Node. Every step runs, so one error names
  # every failure.
  _toolchain_python
  _toolchain_node "$1"
  _toolchain_pnpm "$1"
  _toolchain_rust "$1"
  [ "$_TOOLCHAIN_TREE_FAULT" = 0 ] || return 3
  [ -z "$TOOLCHAIN_FAILED" ] || return 1
  DEVKIT_TOOLCHAIN_TREE=$(cd "$1" && pwd -P)
  export DEVKIT_TOOLCHAIN_TREE
  return 0
}
