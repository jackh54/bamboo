#!/usr/bin/env bash
# Generates and EdDSA-signs appcast.xml for the update archive in <dir>.
# The private key is read from stdin so it never touches argv or the disk:
#   printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | scripts/release/appcast.sh ...
#   scripts/release/appcast.sh ... < /path/to/sparkle_ed_private_key
#
# Usage: scripts/release/appcast.sh <sparkle-bin-dir> <dir> <tag>
#   <dir> holds the one Bamboo-<version>.zip; appcast.xml is written next to it.
# Env:   BAMBOO_REPO  GitHub repository (default: jackh54/bamboo)
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <sparkle-bin-dir> <dir> <tag>" >&2
  exit 2
fi
sparkle_bin="$1"
dir="$2"
tag="$3"
repo="${BAMBOO_REPO:-jackh54/bamboo}"

# Only the newest release is listed, so no delta updates and no older items.
"$sparkle_bin/generate_appcast" --ed-key-file - \
  --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
  --full-release-notes-url "https://github.com/$repo/releases/tag/$tag" \
  --maximum-deltas 0 \
  "$dir"
