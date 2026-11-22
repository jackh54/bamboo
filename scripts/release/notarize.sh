#!/usr/bin/env bash
# Submits a .zip, .dmg or .pkg to Apple's notary service and waits for the
# verdict. Staple the ticket afterwards with `xcrun stapler staple`.
#
# Usage: scripts/release/notarize.sh <file>
# Env:   APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, APPLE_API_KEY_P8 (base64 of the .p8)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <file>" >&2
  exit 2
fi
file="$1"

key_file="$(mktemp)"
result="$(mktemp)"
trap 'rm -f "$key_file" "$result"' EXIT
printf '%s' "$APPLE_API_KEY_P8" | base64 --decode > "$key_file"

# Read the status ourselves rather than trusting notarytool's exit code for an
# Invalid verdict.
xcrun notarytool submit "$file" \
  --key "$key_file" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
  --wait --output-format plist > "$result"

status="$(plutil -extract status raw -o - "$result")"
if [[ "$status" != "Accepted" ]]; then
  id="$(plutil -extract id raw -o - "$result")"
  xcrun notarytool log "$id" \
    --key "$key_file" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" >&2
  echo "error: notarization of $file finished with status $status" >&2
  exit 1
fi
