#!/usr/bin/env bash
# Signs Bamboo.app inside-out. No --deep: Sparkle's Downloader service needs
# --preserve-metadata=entitlements and the other helpers must not get it
# (https://sparkle-project.org/documentation/sandboxing/).
#
# Usage: scripts/release/sign-app.sh <Bamboo.app> <identity>
#   <identity>  "Developer ID Application: ..." (hardened runtime + secure
#               timestamp, ready for notarization) or "-" for ad-hoc.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <Bamboo.app> <identity>" >&2
  exit 2
fi
app="$1"
identity="$2"

root="$(cd "$(dirname "$0")/../.." && pwd)"
entitlements="$root/app/Bamboo/Resources/Bamboo.entitlements"
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"

options=(--options runtime --timestamp)
if [[ "$identity" == "-" ]]; then
  # With the hardened runtime, library validation refuses to load an ad-hoc
  # signed Sparkle.framework (no shared Team ID) and the app dies in dyld.
  options=(--timestamp=none)
fi

sign() {
  codesign --force --sign "$identity" "${options[@]}" "$@"
}

sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app/Contents/MacOS/bamboo-mcp"
sign --entitlements "$entitlements" "$app"

codesign --verify --deep --strict --verbose=2 "$app"
