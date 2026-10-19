#!/usr/bin/env bash
# Run one command with a devkit-pinned release tool first on PATH (shellcheck for metrics/shell.py
# and bin/shellcheck.sh, bats for the infra-compose stack's test tier), the way cargo_tool.sh
# does for a cargo subcommand.
# Usage: devkit/bin/release_tool.sh <tool> -- <command> [args...]
#        devkit/bin/release_tool.sh <tool> --version    # the pinned version, nothing installed
#
# Why devkit holds the pin, not the repo: the tool is the same for every repo (one shellcheck
# for the fleet, as devkit's own CI pins 0.11.0), and a pin is only as good as its checksums,
# which live beside the version in PINS below. PATH's tool reporting the pinned version is used
# as-is; else the release archive is downloaded once per machine into
# $XDG_DATA_HOME/devkit/tools/<tool>-<version> (default ~/.local/share), verified against the
# sha256 below, and shared by every worktree and gate slot.
# Gotcha: two gate slots may install at once; each unpacks into its own temporary directory and
# only a slot that finds no store entry renames it into place, so a half-unpacked tool is never
# on PATH. DEVKIT_OFFLINE=1 refuses to download and fails loudly when the store is cold;
# DEVKIT_RELEASE_MIRROR replaces https://github.com (the tests serve archives from file://).
# Exit: the command's own status, or 2 when the tool cannot be provided (the reason on stderr)
# or the call is malformed.
set -euo pipefail

die() { echo "release_tool: $*" >&2; exit 2; }
usage() { die "usage: $0 <tool> -- <command> [args...] | $0 <tool> --version"; }
[ $# -ge 2 ] || usage
TOOL=$1
shift

case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) die "unsupported OS $(uname -s)" ;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=aarch64 ;; x86_64) ARCH=x86_64 ;; *) die "unsupported arch $(uname -m)" ;; esac
PLATFORM=$OS.$ARCH

# PINS: per tool, VERSION, the archive path under the mirror, its top directory (installed
# whole: bats's bin/bats finds its libexec/ beside it), the bin directory inside that, the
# command and the archive's sha256 for this platform (taken from the release on the day it was
# pinned; neither release publishes a checksum file). A new pin is a devkit PR with every
# platform's sum.
SHA='' BINDIR=''
case $TOOL in
  shellcheck)
    VERSION=0.11.0
    ARCHIVE=koalaman/shellcheck/releases/download/v$VERSION/shellcheck-v$VERSION.$PLATFORM.tar.xz
    TOP=shellcheck-v$VERSION BIN=shellcheck
    case $PLATFORM in
      darwin.aarch64) SHA=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79 ;;
      darwin.x86_64) SHA=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6 ;;
      linux.x86_64) SHA=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
      linux.aarch64) SHA=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
    esac ;;
  bats)
    # bats-core publishes no release asset; the tag's source archive is the release (bash only,
    # one archive for every platform).
    VERSION=1.14.0
    ARCHIVE=bats-core/bats-core/archive/refs/tags/v$VERSION.tar.gz
    TOP=bats-core-$VERSION BINDIR=bin BIN=bats
    SHA=bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177 ;;
  *) die "no pin for '$TOOL' (pinned: shellcheck, bats)" ;;
esac
[ -n "$SHA" ] || die "$TOOL $VERSION has no pinned archive for $PLATFORM"

if [ "$1" = --version ]; then
  [ $# -eq 1 ] || usage
  echo "$VERSION"
  exit 0
fi
[ "$1" = -- ] && [ $# -ge 2 ] || usage
shift

# reports <PATH>: true when that PATH's tool names VERSION in its --version output.
reports() {
  PATH=$1 command -v "$BIN" >/dev/null || return 1
  PATH=$1 "$BIN" --version 2>/dev/null | grep -Eqw "v?${VERSION//./\\.}"
}
reports "$PATH" && exec "$@"

STORE="${XDG_DATA_HOME:-$HOME/.local/share}/devkit/tools"
DEST="$STORE/$TOOL-$VERSION"
DEST_BIN="$DEST${BINDIR:+/$BINDIR}"
if ! reports "$DEST_BIN:$PATH"; then
  [ "${DEVKIT_OFFLINE:-0}" != 1 ] || die "$TOOL $VERSION is not installed in $DEST and DEVKIT_OFFLINE=1"
  command -v curl >/dev/null || die "curl is not on PATH; it downloads $TOOL $VERSION"
  if command -v sha256sum >/dev/null; then SHA256=sha256sum; else SHA256="shasum -a 256"; fi
  mkdir -p "$STORE"
  TMP=$(mktemp -d "$STORE/.$TOOL-$VERSION.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  URL="${DEVKIT_RELEASE_MIRROR:-https://github.com}/$ARCHIVE"
  echo "release_tool: installing $TOOL $VERSION into $DEST (once per machine)" >&2
  curl -fsSL --retry 3 -o "$TMP/archive" "$URL" || die "cannot download $URL"
  [ "$($SHA256 "$TMP/archive" | awk '{print $1}')" = "$SHA" ] || die "checksum mismatch for $URL (pinned $SHA)"
  tar -xf "$TMP/archive" -C "$TMP" "$TOP" || die "$URL holds no $TOP/"
  [ -x "$TMP/$TOP${BINDIR:+/$BINDIR}/$BIN" ] || die "$URL holds no $TOP${BINDIR:+/$BINDIR}/$BIN"
  [ -e "$DEST" ] || mv "$TMP/$TOP" "$DEST" || die "cannot move $TMP/$TOP to $DEST"
  rm -rf "$TMP"  # a lost race's copy: exec below skips the EXIT trap
  reports "$DEST_BIN:$PATH" || die "$DEST_BIN/$BIN does not report $VERSION"
fi
export PATH="$DEST_BIN:$PATH"
exec "$@"
