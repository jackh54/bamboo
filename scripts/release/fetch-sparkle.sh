#!/usr/bin/env bash
# Downloads Sparkle's release tarball and unpacks its command-line tools
# (generate_appcast, sign_update, generate_keys) into <dest-dir>/bin.
#
# Usage: scripts/release/fetch-sparkle.sh <dest-dir>
# Keep version and checksum in step with the Sparkle pin in app/project.yml.
# The checksum is the SHA-256 GitHub publishes for the release asset.
set -euo pipefail

version="2.10.1"
sha256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <dest-dir>" >&2
  exit 2
fi
dest="$1"

mkdir -p "$dest"
archive="$dest/Sparkle-$version.tar.xz"
curl --fail --silent --show-error --location --retry 3 --retry-all-errors --output "$archive" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
echo "$sha256  $archive" | shasum -a 256 --check --status
tar -xf "$archive" -C "$dest"
