#!/usr/bin/env bash
# Builds the Rust core and stages what the Xcode project links against:
#   target/bamboo-out/libbamboo_core.a   static library
#   target/bamboo-out/bamboo-mcp         stdio MCP bridge (copied into the app)
#   target/bamboo-out/include/           C headers + module.modulemap
#   app/Bamboo/Generated/*.swift         UniFFI Swift bindings
#
# Usage: scripts/build-core.sh [--universal]
#   --universal  build arm64 + x86_64 and lipo them (release builds; needs rustup targets)
# Env:   BAMBOO_RUST_PROFILE  cargo profile (default: release; CI uses dist)
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="15.0"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/target/bamboo-out"
generated="$root/app/Bamboo/Generated"
profile="${BAMBOO_RUST_PROFILE:-release}"
universal=false
[[ "${1:-}" == "--universal" ]] && universal=true

cd "$root"
mkdir -p "$out/include" "$generated"

if $universal; then
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --locked --profile "$profile" --target "$target" -p bamboo-core -p bamboo-mcp
  done
  lipo -create "target/aarch64-apple-darwin/$profile/libbamboo_core.a" \
               "target/x86_64-apple-darwin/$profile/libbamboo_core.a" \
       -output "$out/libbamboo_core.a"
  lipo -create "target/aarch64-apple-darwin/$profile/bamboo-mcp" \
               "target/x86_64-apple-darwin/$profile/bamboo-mcp" \
       -output "$out/bamboo-mcp"
  bindgen_lib="target/aarch64-apple-darwin/$profile/libbamboo_core.a"
else
  cargo build --profile "$profile" -p bamboo-core -p bamboo-mcp
  cp "target/$profile/libbamboo_core.a" "$out/libbamboo_core.a"
  cp "target/$profile/bamboo-mcp" "$out/bamboo-mcp"
  bindgen_lib="target/$profile/libbamboo_core.a"
fi

bindings="$(mktemp -d)"
trap 'rm -rf "$bindings"' EXIT
cargo run --quiet --profile "$profile" -p uniffi-bindgen -- \
  generate --library "$bindgen_lib" --language swift --out-dir "$bindings" >/dev/null

# Only touch files whose content changed, so Xcode doesn't recompile every build.
sync_file() {
  if ! cmp -s "$1" "$2"; then cp "$1" "$2"; fi
}
for f in "$bindings"/*.swift; do sync_file "$f" "$generated/$(basename "$f")"; done
for f in "$bindings"/*.h; do sync_file "$f" "$out/include/$(basename "$f")"; done
for f in "$bindings"/*.modulemap; do cat "$f"; echo; done > "$bindings/module.modulemap.combined"
sync_file "$bindings/module.modulemap.combined" "$out/include/module.modulemap"
