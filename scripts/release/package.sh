#!/usr/bin/env bash
# Builds the distributable DMG and the Sparkle update archive from Bamboo.app.
#
# Usage: scripts/release/package.sh <Bamboo.app> <version> <out-dir>
#   <out-dir>/Bamboo-<version>.dmg   drag-to-Applications disk image
#   <out-dir>/Bamboo-<version>.zip   archive Sparkle downloads and installs
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <Bamboo.app> <version> <out-dir>" >&2
  exit 2
fi
app="$1"
version="$2"
out="$3"

mkdir -p "$out"
rm -f "$out/Bamboo-$version.dmg" "$out/Bamboo-$version.zip"

ditto -c -k --keepParent "$app" "$out/Bamboo-$version.zip"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Bamboo.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Bamboo" -srcfolder "$staging" -fs HFS+ -format UDZO -ov \
  "$out/Bamboo-$version.dmg" >/dev/null
