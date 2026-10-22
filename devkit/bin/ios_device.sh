#!/usr/bin/env bash
# The physical-iPhone recipe, once (locus docs/ios.md, instalite scripts/pull-diagnostics.sh):
# build and install a Debug build, or copy the app's diagnostics off the phone. macOS only.
#
#   devkit/bin/ios_device.sh install    build IOS_SCHEME for the device, install it
#   devkit/bin/ios_device.sh pull       copy IOS_DIAG_SOURCE out of the app's container
#
# Env (a repo's Makefile sets these; nothing is per machine but IOS_DEVICE):
#   IOS_SCHEME          install: the xcodebuild scheme (required)
#   IOS_PROJECT         install: -project <it> (optional; xcodebuild finds a lone project)
#   IOS_CONFIGURATION   install: Debug
#   IOS_DERIVED_DATA    install: build/ios-device (its own -derivedDataPath, never ~/Library's)
#   IOS_BUILD_ARGS      install: extra xcodebuild words, e.g. -allowProvisioningUpdates
#   IOS_BUNDLE_ID       pull: the app's bundle id (required)
#   IOS_DIAG_GROUP      pull: an App Group id; the copy then reads the group container
#   IOS_DIAG_SOURCE     pull: the path inside the container, Library/Application Support/diagnostics
#   IOS_DIAG_OUT        pull: diagnostics/<yyyymmdd-hhmmss>
#   IOS_DEVICE          either: a device name, model ("iPhone 17 Pro"), CoreDevice UUID or
#                       UDID; else the one paired, reachable physical iPhone devicectl lists
#                       (two of them is exit 2, naming both with their models)
#
# Gotchas this owns, each paid for once: the phone has two ids and the tools refuse each
# other's (xcodebuild -destination takes the hardware UDID, devicectl the CoreDevice UUID), so
# both come from one `devicectl list devices` JSON; an old phone stays paired (tunnelState
# "unavailable" when it is away) and may share the new one's name, so the model tells them
# apart; the .app is the NEWEST under the derived
# data, never a glob's alphabetical first; a CoreDeviceError on install is transient and gets
# exactly one retry (a second one is real). "The developer disk image could not be mounted"
# means the phone is locked.
#
# Output: one `ios-device: …` line per step; xcodebuild's log goes to
# <derived data>/xcodebuild.log and only its last 40 lines print on failure. Exit 0 done,
# 1 a build, install or copy failed, 2 a bad call, a missing tool, no single device, or not macOS.
set -euo pipefail

say() { echo "ios-device: $*"; }
die() { echo "ios-device: $1" >&2; exit "${2:-1}"; }

case "${1:-}:$#" in
  install:1 | pull:1) ;;
  *) die "usage: ios_device.sh install|pull (env contract in the script header)" 2 ;;
esac
verb="$1"
[ "$(uname -s)" = Darwin ] || die "macOS only (xcodebuild and devicectl); this is $(uname -s)" 2
command -v xcrun >/dev/null 2>&1 \
  || die "xcrun not found: install Xcode, then xcode-select -s /Applications/Xcode.app" 2
command -v python3 >/dev/null 2>&1 || die "python3 not found (Xcode's command line tools ship it)" 2

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ios_device.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Sets DEVICE_UDID (xcodebuild) and DEVICE_COREDEVICE (devicectl) for IOS_DEVICE, or the one
# paired physical iOS device.
resolve_device() {
  xcrun devicectl list devices --json-output "$tmp/devices.json" >/dev/null 2>&1 \
    || die "xcrun devicectl list devices failed (Xcode 15+ is required)" 2
  # Not inside $(…): bash 3.2 mis-parses a quoted heredoc in a command substitution.
  local rc=0
  python3 -I - "$tmp/devices.json" "${IOS_DEVICE:-}" >"$tmp/ids" <<'PY' || rc=$?
import json
import sys

path, want = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    devices = json.load(f).get("result", {}).get("devices", [])
rows = []
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    props = d.get("deviceProperties", {})
    row = (d.get("identifier", ""), hw.get("udid", ""), props.get("name", ""),
           hw.get("marketingName", ""))
    if want:
        if want in row:
            rows.append(row)
    elif (hw.get("platform") == "iOS" and hw.get("reality") == "physical"
          and conn.get("pairingState") == "paired" and conn.get("tunnelState") != "unavailable"):
        rows.append(row)
if len(rows) != 1:
    found = "; ".join(f"{n}, {m} ({c})" for c, _, n, m in rows) or "none"
    sys.exit(f"want exactly one device{' matching ' + want if want else ' paired'}, found: {found}")
print(rows[0][0], rows[0][1])
PY
  [ "$rc" -eq 0 ] || die "set IOS_DEVICE to a name, model, CoreDevice UUID or UDID" 2
  local ids
  ids="$(cat "$tmp/ids")"
  DEVICE_COREDEVICE="${ids%% *}"
  DEVICE_UDID="${ids#* }"
  [ -n "$DEVICE_UDID" ] || die "devicectl reports no hardware UDID for $DEVICE_COREDEVICE" 2
}

do_install() {
  local config="${IOS_CONFIGURATION:-Debug}" dd="${IOS_DERIVED_DATA:-build/ios-device}" app
  local -a args=(-scheme "$IOS_SCHEME" -configuration "$config" -derivedDataPath "$dd")
  [ -z "${IOS_PROJECT:-}" ] || args+=(-project "$IOS_PROJECT")
  # IOS_BUILD_ARGS is a word list on purpose (flags only, never paths with spaces).
  # shellcheck disable=SC2206
  [ -z "${IOS_BUILD_ARGS:-}" ] || args+=($IOS_BUILD_ARGS)
  mkdir -p "$dd"
  say "build $IOS_SCHEME ($config) for $DEVICE_UDID; log: $dd/xcodebuild.log"
  if ! xcodebuild "${args[@]}" -destination "platform=iOS,id=$DEVICE_UDID" build \
      >"$dd/xcodebuild.log" 2>&1; then
    tail -n 40 "$dd/xcodebuild.log" >&2
    die "xcodebuild failed (last 40 lines above; a locked phone fails to mount its disk image)"
  fi
  # Newest, never a glob's first: a renamed scheme leaves the old .app beside the new one.
  # `|| true`: with no .app the unmatched glob fails ls, and pipefail + set -e would exit here
  # silently instead of reaching the diagnostic below.
  # shellcheck disable=SC2012  # ls -t is the portable newest-first; the names are ours
  app="$(ls -dt "$dd/Build/Products/$config-iphoneos/"*.app 2>/dev/null | head -n 1 || true)"
  [ -n "$app" ] || die "no .app under $dd/Build/Products/$config-iphoneos after the build"
  say "install $app on $DEVICE_COREDEVICE"
  local attempt=1
  while ! xcrun devicectl device install app --device "$DEVICE_COREDEVICE" "$app" \
      >"$tmp/install.log" 2>&1; do
    if [ "$attempt" -eq 1 ] && grep -q CoreDeviceError "$tmp/install.log"; then
      say "install hit a CoreDeviceError (transient tunnel); retrying once"
      attempt=2
      continue
    fi
    cat "$tmp/install.log" >&2
    die "devicectl install failed"
  done
  say "installed"
}

do_pull() {
  local domain=appDataContainer id="$IOS_BUNDLE_ID"
  if [ -n "${IOS_DIAG_GROUP:-}" ]; then domain=appGroupDataContainer; id="$IOS_DIAG_GROUP"; fi
  local src="${IOS_DIAG_SOURCE:-Library/Application Support/diagnostics}"
  local out="${IOS_DIAG_OUT:-diagnostics/$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$out"
  say "copy $domain $id:$src to $out"
  if ! xcrun devicectl device copy from --device "$DEVICE_COREDEVICE" --domain-type "$domain" \
      --domain-identifier "$id" --source "$src" --destination "$out" >"$tmp/copy.log" 2>&1; then
    cat "$tmp/copy.log" >&2
    die "devicectl copy failed (is $IOS_BUNDLE_ID installed, and has it written $src?)"
  fi
  say "pulled to $out"
  ls -1 "$out"
}

# A bad call fails before any device is touched.
case "$verb" in
  install) [ -n "${IOS_SCHEME:-}" ] || die "IOS_SCHEME is not set" 2 ;;
  pull) [ -n "${IOS_BUNDLE_ID:-}" ] || die "IOS_BUNDLE_ID is not set" 2 ;;
esac
resolve_device
case "$verb" in
  install) do_install ;;
  pull) do_pull ;;
esac
