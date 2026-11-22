#!/usr/bin/env bash
# Archives the Release app and copies Bamboo.app to <out-dir>. The core must
# already be built (scripts/build-core.sh) and the project generated (xcodegen).
# The archive is ad-hoc signed; scripts/release/sign-app.sh signs the result.
#
# Usage: scripts/release/build-app.sh <marketing-version> <build-number> <out-dir>
# Env:   BAMBOO_ARCHS  architectures to build (default: "arm64 x86_64"; use
#                      "arm64" with a core built without --universal)
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <marketing-version> <build-number> <out-dir>" >&2
  exit 2
fi
version="$1"
build="$2"
out="$3"

root="$(cd "$(dirname "$0")/../.." && pwd)"
archive="$root/build/Bamboo.xcarchive"

rm -rf "$archive" "$out/Bamboo.app"
mkdir -p "$out"

xcodebuild archive \
  -project "$root/app/Bamboo.xcodeproj" \
  -scheme Bamboo \
  -configuration Release \
  -archivePath "$archive" \
  -destination "generic/platform=macOS" \
  ARCHS="${BAMBOO_ARCHS:-arm64 x86_64}" \
  ONLY_ACTIVE_ARCH=NO \
  BAMBOO_SKIP_CORE_BUILD=1 \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_IDENTITY=- \
  -quiet

ditto "$archive/Products/Applications/Bamboo.app" "$out/Bamboo.app"
