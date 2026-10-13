# shellcheck shell=bash
# Put a tree's pinned toolchains first on PATH: Node from .nvmrc (node_toolchain.sh), Rust from
# rust-toolchain.toml or rust-toolchain (rust_toolchain.sh). Sourced; defines toolchain_path and
# runs nothing. Used by local_gate.sh (on the merged worktree) and hook_steps.sh (on the hook's
# checkout), so a hook runs the same node/cargo the gate does on a machine whose PATH has none
# (redlib's Mac has no Rust) or the wrong one (the Mac's Node 25).
#
#   toolchain_path <tree>    # 0 ok; 1 a declared toolchain cannot be provided
#
# On 0 it exports PATH (and COREPACK_ENABLE_DOWNLOAD_PROMPT=0 with Node: a corepack prompt hangs
# an unattended run) and sets TOOLCHAIN_NOTES ("node v22.23.3 from .nvmrc; rust 1.99.0 from
# rust-toolchain.toml", empty when nothing is declared). On 1 it sets TOOLCHAIN_FAILED ("Node" or
# "Rust toolchain") and TOOLCHAIN_ERROR (one line naming the declaration); the provisioning
# script's own reason is already on stderr. Python needs nothing here: `uv run`/`uv sync` read
# .python-version themselves.
# Gotcha: PATH changes last only as long as the calling shell; both callers are their own process.

# shellcheck disable=SC2034  # TOOLCHAIN_* are this function's output, read by the caller
toolchain_path() {
  local tree=$1 bin decl='' f here
  here=$(dirname "${BASH_SOURCE[0]}")
  TOOLCHAIN_NOTES='' TOOLCHAIN_FAILED='' TOOLCHAIN_ERROR=''

  if [ -f "$tree/.nvmrc" ]; then
    if ! bin=$("$here/node_toolchain.sh" "$tree"); then
      TOOLCHAIN_FAILED=Node
      TOOLCHAIN_ERROR="cannot provide node $(tr -d '[:space:]' <"$tree/.nvmrc") declared in .nvmrc"
      return 1
    fi
    [ -z "$bin" ] || export PATH="$bin:$PATH"
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    TOOLCHAIN_NOTES="node $(node --version) from .nvmrc"
  fi

  for f in rust-toolchain.toml rust-toolchain; do [ -f "$tree/$f" ] && { decl=$f; break; }; done
  if [ -n "$decl" ]; then
    if ! bin=$("$here/rust_toolchain.sh" "$tree"); then
      TOOLCHAIN_FAILED='Rust toolchain'
      TOOLCHAIN_ERROR="cannot provide the rust toolchain declared in $decl"
      return 1
    fi
    [ -z "$bin" ] || export PATH="$bin:$PATH"
    # From the tree: a PATH cargo that matched is usually a rustup proxy, which resolves by cwd.
    TOOLCHAIN_NOTES="${TOOLCHAIN_NOTES:+$TOOLCHAIN_NOTES; }rust $( (cd "$tree" && cargo --version) | awk '{print $2}') from $decl"
  fi
  return 0
}
