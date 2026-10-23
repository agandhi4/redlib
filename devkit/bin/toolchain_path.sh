# shellcheck shell=bash
# Put a tree's pinned toolchains first on PATH: Node from .nvmrc (node_toolchain.sh), Rust from
# rust-toolchain.toml or rust-toolchain (rust_toolchain.sh), and devkit's python3 and uv
# (_toolchain_lib.sh) for the vendored tools and a repo's own bare python3 and uv calls. Sourced;
# defines toolchain_path and runs nothing. Used by local_gate.sh (on the merged worktree) and
# hook_steps.sh (on the hook's checkout), so a hook runs the same node/cargo the gate does on a
# machine whose PATH has none (redlib's Mac has no Rust) or the wrong one (the Mac's Node 25).
#
#   toolchain_path <tree>    # 0 ok; 1 a declared toolchain cannot be provided
#
# On 0 it exports PATH, DEVKIT_PYTHON, DEVKIT_TOOLCHAIN_TREE (the tree's physical path:
# toolchain_shell.sh skips a tree already on its pins) and COREPACK_ENABLE_DOWNLOAD_PROMPT=0 with
# Node (a corepack prompt hangs an unattended run) and sets TOOLCHAIN_NOTES ("node v22.23.3 from
# .nvmrc; rust 1.99.0 from rust-toolchain.toml", led by "python 3.14.3 from mise; uv 0.9.5 from
# python" for each that PATH lacked; empty when nothing was provided). On 1 it sets
# TOOLCHAIN_FAILED (each of "Python", "Node", "Rust toolchain" that failed, comma-separated: every
# step runs, so one error names them all) and TOOLCHAIN_ERROR (one clause per failure, naming the
# declaration, or every place Python was looked for); a provisioning script's own reason is
# already on stderr. A uv not found is no failure here (CI jobs and hooks run without one);
# the gate's preflight (devkit_preflight) requires it where a uv.lock declares it.
# A repo's own Python is not this one: `uv run`/`uv sync` read .python-version themselves.
# Gotcha: PATH changes last only as long as the calling shell; both callers are their own process.

# shellcheck source=bin/_toolchain_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_toolchain_lib.sh"

# _toolchain_fail <what> <reason>: record one failed step.
_toolchain_fail() {
  TOOLCHAIN_FAILED="${TOOLCHAIN_FAILED:+$TOOLCHAIN_FAILED, }$1"
  TOOLCHAIN_ERROR="${TOOLCHAIN_ERROR:+$TOOLCHAIN_ERROR; }$2"
}

# shellcheck disable=SC2034  # TOOLCHAIN_* are this function's output, read by the caller
toolchain_path() {
  local tree=$1 bin decl='' f here
  here=$(dirname "${BASH_SOURCE[0]}")
  TOOLCHAIN_NOTES='' TOOLCHAIN_FAILED='' TOOLCHAIN_ERROR=''

  # First, so Node and Rust land in front of it: its directory holds python3 and/or uv alone.
  # Only what PATH lacks: a box whose PATH has them all gets PATH untouched.
  if ! devkit_toolchain || { [ -n "$DEVKIT_TOOLCHAIN_OFF_LINKS" ] && ! devkit_toolchain_link "$DEVKIT_TOOLCHAIN_OFF_LINKS"; }; then
    _toolchain_fail Python "$DEVKIT_PYTHON_ERROR"
  elif [ -n "$DEVKIT_TOOLCHAIN_OFF_PATH" ]; then
    export PATH="$DEVKIT_TOOLCHAIN_BIN:$PATH"
    TOOLCHAIN_NOTES=$DEVKIT_TOOLCHAIN_OFF_PATH
  fi

  if [ -f "$tree/.nvmrc" ]; then
    if ! bin=$("$here/node_toolchain.sh" "$tree"); then
      _toolchain_fail Node "cannot provide node $(tr -d '[:space:]' <"$tree/.nvmrc") declared in .nvmrc"
    else
      [ -z "$bin" ] || export PATH="$bin:$PATH"
      export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
      TOOLCHAIN_NOTES="${TOOLCHAIN_NOTES:+$TOOLCHAIN_NOTES; }node $(node --version) from .nvmrc"
    fi
  fi

  for f in rust-toolchain.toml rust-toolchain; do [ -f "$tree/$f" ] && { decl=$f; break; }; done
  if [ -n "$decl" ]; then
    if ! bin=$("$here/rust_toolchain.sh" "$tree"); then
      _toolchain_fail 'Rust toolchain' "cannot provide the rust toolchain declared in $decl"
    else
      [ -z "$bin" ] || export PATH="$bin:$PATH"
      # From the tree: a PATH cargo that matched is usually a rustup proxy, which resolves by cwd.
      TOOLCHAIN_NOTES="${TOOLCHAIN_NOTES:+$TOOLCHAIN_NOTES; }rust $( (cd "$tree" && cargo --version) | awk '{print $2}') from $decl"
    fi
  fi
  [ -z "$TOOLCHAIN_FAILED" ] || return 1
  DEVKIT_TOOLCHAIN_TREE=$(cd "$tree" && pwd -P)
  export DEVKIT_TOOLCHAIN_TREE
  return 0
}
