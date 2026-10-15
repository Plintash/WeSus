#!/usr/bin/env bash
# Download/unpack the pinned official Mac engine locally. Never launch or install
# the vendor client, and never include its files in the repository or release.
set -euo pipefail
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$BASE"
[[ "$(uname -s)" == Darwin ]] || { echo "This setup requires macOS." >&2; exit 1; }
VERSION=2.2.3_657
SHA256=8ef48bb21fe9d7b017b8a09fb9496b1b8f960ad960db27872226e08c09db264b
ROOT="$BASE/.deps/mac-engine"
ZIP="${1:-$ROOT/WeType_$VERSION.zip}"
mkdir -p "$ROOT"
if [[ ! -f "$ZIP" ]]; then
  curl -fL --retry 3 -o "$ZIP.part" "https://download.weread.qq.com/app/wxkb/mac/2.2.3/WeType_$VERSION.zip"
  [[ "$(shasum -a 256 "$ZIP.part" | cut -d' ' -f1)" == "$SHA256" ]] || {
    echo "Official package checksum mismatch." >&2; exit 1;
  }
  mv "$ZIP.part" "$ZIP"
fi
[[ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" == "$SHA256" ]] || {
  echo "Only the pinned official WeType $VERSION package is supported." >&2; exit 1;
}
if [[ "$(cat "$ROOT/.package-sha256" 2>/dev/null)" != "$SHA256" ||
      ! -f "$ROOT/WeType.app/Contents/MacOS/WeType" ]]; then
  STAGE="$(mktemp -d "$ROOT/extract.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  ditto -x -k "$ZIP" "$STAGE"
  [[ -f "$STAGE/WeType.app/Contents/MacOS/WeType" &&
     -f "$STAGE/WeType.app/Contents/Resources/imeData.bundle/index.json" ]] || {
    echo "Official package layout changed." >&2; exit 1;
  }
  rm -rf "$ROOT/WeType.app"
  mv "$STAGE/WeType.app" "$ROOT/WeType.app"
  echo "$SHA256" > "$ROOT/.package-sha256"
fi
mkdir -p build/macos
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -mmacosx-version-min=13.0 -framework Foundation \
  macos/Engine/NativeEngine.mm -o build/macos/WeTypeNativeEngine
echo "Native engine prepared. Test: python3 scripts/test_flypy.py --backend native"
