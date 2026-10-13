#!/usr/bin/env bash
# Provide the exact Rust toolchain a repo declares, for gates and hooks on machines whose PATH
# cargo differs or is missing (the Mac has no Rust at all; redlib verified in `rust:latest`).
#
# Usage: devkit/bin/rust_toolchain.sh <repo-root>
#          Prints the bin directory to prepend to PATH, or nothing when PATH's cargo already matches.
#        devkit/bin/rust_toolchain.sh --declared <repo-root>
#          Prints the declared version only (toolchain_check.sh uses this: one parser).
#   Exit 0 ok, 1 cannot provide (no declaration, inexact channel, install failure), 2 usage.
#
# Declaration: `rust-toolchain.toml` (`[toolchain] channel = "1.83.0"`, optional `components`),
# or a legacy `rust-toolchain` file holding either that TOML or the bare version. The channel
# must be exact MAJOR.MINOR.PATCH: `stable` or `1.83` resolve to different compilers on two
# machines, which is the drift this script exists to end (same reasoning as .nvmrc).
#
# Provisioning goes through rustup, which verifies every component against the release
# manifest's sha256 over HTTPS. rustup on PATH is used as-is (~/.rustup). Without one, rustup is
# bootstrapped once into $XDG_DATA_HOME/devkit/rust (RUSTUP_HOME=rustup/, CARGO_HOME=cargo/)
# from https://sh.rustup.rs with --no-modify-path, and that private rustup is reused afterwards.
# The printed directory is the toolchain's own sysroot bin (real cargo/rustc, not rustup
# proxies), so callers export PATH only: no RUSTUP_HOME/CARGO_HOME needed, and the version does
# not depend on the caller's cwd. Declared components (rustfmt, clippy) are installed with it.
# Gotcha: a PATH cargo that matches is usually a rustup proxy, which resolves the toolchain file
# from cwd; the gate runs `make -C <worktree>`, so the proxy sees the repo's own declaration.
# DEVKIT_OFFLINE=1 refuses to download and fails loudly when the toolchain is not installed.
set -euo pipefail

usage() { echo "usage: $0 [--declared] <repo-root>" >&2; exit 2; }
DECLARED_ONLY=0
if [ "${1:-}" = --declared ]; then DECLARED_ONLY=1; shift; fi
[ $# -eq 1 ] || usage
ROOT=$1
die() { echo "rust_toolchain: $*" >&2; exit 1; }

# ---- declaration ------------------------------------------------------------------------------
if [ -f "$ROOT/rust-toolchain.toml" ] && [ -f "$ROOT/rust-toolchain" ]; then
  die "both rust-toolchain and rust-toolchain.toml exist in $ROOT; keep one"
elif [ -f "$ROOT/rust-toolchain.toml" ]; then DECL=rust-toolchain.toml
elif [ -f "$ROOT/rust-toolchain" ]; then DECL=rust-toolchain
else die "no rust-toolchain.toml or rust-toolchain in $ROOT"
fi

# Prints `<field> <value>` lines from the [toolchain] table: one `channel`, one `component` per
# entry. Handles single- and multi-line `components = [...]`.
toml_fields() {
  awk '
    /^[[:space:]]*\[/ { in_tc = ($0 ~ /^[[:space:]]*\[toolchain\][[:space:]]*$/); next }
    !in_tc { next }
    /^[[:space:]]*channel[[:space:]]*=/ {
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/["\047[:space:]]/, "", v); sub(/#.*/, "", v)
      print "channel " v; next
    }
    /^[[:space:]]*components[[:space:]]*=/ { in_comp = 1; sub(/^[^=]*=/, "") }
    in_comp {
      line = $0; sub(/#.*/, "", line)
      n = split(line, parts, /["\047]/)
      for (i = 2; i <= n; i += 2) print "component " parts[i]
      if (line ~ /\]/) in_comp = 0
    }
  ' "$1"
}

COMPONENTS=()
if grep -q '^[[:space:]]*\[toolchain\]' "$ROOT/$DECL"; then
  VERSION=""
  while read -r field value; do
    case "$field" in
      channel) VERSION=$value ;;
      component) COMPONENTS+=("$value") ;;
    esac
  done < <(toml_fields "$ROOT/$DECL")
  [ -n "$VERSION" ] || die "$DECL has no [toolchain] channel"
else
  VERSION=$(grep -v '^[[:space:]]*\(#\|$\)' "$ROOT/$DECL" | head -n1 | tr -d '[:space:]')
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "$DECL must pin an exact channel like 1.83.0 (got '$VERSION'); stable/nightly/MAJOR.MINOR drift between machines"

if [ "$DECLARED_ONLY" = 1 ]; then echo "$VERSION"; exit 0; fi

# ---- PATH already right -----------------------------------------------------------------------
# cwd = ROOT so a rustup proxy resolves the repo's declaration; RUSTUP_AUTO_INSTALL=0 keeps the
# probe from downloading a toolchain behind DEVKIT_OFFLINE's back.
cargo_version() { # <cargo> -> MAJOR.MINOR.PATCH or empty
  (cd "$ROOT" && RUSTUP_AUTO_INSTALL=0 "$1" --version 2>/dev/null) | awk '{print $2}'
}
if command -v cargo >/dev/null && [ "$(cargo_version cargo)" = "$VERSION" ]; then
  exit 0
fi

# ---- rustup: PATH's, else the private one, else bootstrap the private one ---------------------
OFFLINE=${DEVKIT_OFFLINE:-0}
STORE="${XDG_DATA_HOME:-$HOME/.local/share}/devkit/rust"
if command -v rustup >/dev/null; then
  RUSTUP=rustup
else
  export RUSTUP_HOME="$STORE/rustup" CARGO_HOME="$STORE/cargo"
  RUSTUP="$CARGO_HOME/bin/rustup"
  if [ ! -x "$RUSTUP" ]; then
    [ "$OFFLINE" = 1 ] && die "rust $VERSION from $DECL: no rustup on PATH, none cached at $STORE, and DEVKIT_OFFLINE=1"
    command -v curl >/dev/null || die "curl not found"
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/devkit-rustup.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT
    echo "rust_toolchain: bootstrapping rustup into $STORE" >&2
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$TMP/rustup-init.sh" "${DEVKIT_RUSTUP_INIT:-https://sh.rustup.rs}"
    mkdir -p "$STORE"
    # --default-toolchain none: the install below is the one path that installs toolchains.
    RUSTUP_INIT_SKIP_PATH_CHECK=yes sh "$TMP/rustup-init.sh" -y --no-modify-path \
      --profile minimal --default-toolchain none >&2 || die "rustup bootstrap into $STORE failed"
    [ -x "$RUSTUP" ] || die "rustup bootstrap finished but $RUSTUP is missing"
  fi
fi

# ---- toolchain --------------------------------------------------------------------------------
# Already installed with every declared component: no network. Otherwise install, which is
# idempotent and adds missing components to an existing toolchain.
installed() {
  "$RUSTUP" toolchain list 2>/dev/null | grep -q "^$VERSION-" || return 1
  local have c
  have=$("$RUSTUP" component list --installed --toolchain "$VERSION" 2>/dev/null) || return 1
  for c in ${COMPONENTS[@]+"${COMPONENTS[@]}"}; do
    grep -Eq "^$c(-|$)" <<<"$have" || return 1
  done
}
if ! installed; then
  [ "$OFFLINE" = 1 ] && die "rust $VERSION from $DECL is not installed in $RUSTUP and DEVKIT_OFFLINE=1"
  args=(toolchain install "$VERSION" --profile minimal --no-self-update)
  for c in ${COMPONENTS[@]+"${COMPONENTS[@]}"}; do args+=(--component "$c"); done
  echo "rust_toolchain: installing rust $VERSION from $DECL" >&2
  "$RUSTUP" "${args[@]}" >&2 || die "rustup toolchain install $VERSION failed"
fi

SYSROOT=$("$RUSTUP" run "$VERSION" rustc --print sysroot) || die "rustup run $VERSION rustc failed"
got=$(cargo_version "$SYSROOT/bin/cargo")
[ "$got" = "$VERSION" ] || die "cargo in $SYSROOT/bin reports '${got:-nothing}', expected $VERSION"
echo "$SYSROOT/bin"
