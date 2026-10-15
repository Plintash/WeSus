#!/usr/bin/env bash
# Install our input method and keep the locally downloaded vendor engine separate.
set -euo pipefail
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$BASE"
[[ -f .deps/mac-engine/WeType.app/Contents/MacOS/WeType ]] || {
  echo "First run bash scripts/macos/prepare_native.sh." >&2; exit 1;
}
bash scripts/macos/build_app.sh
SUPPORT="$HOME/Library/Application Support/WeTypeIME"
DEST="$HOME/Library/Input Methods/WeTypeIME.app"
mkdir -p "$SUPPORT/Engine" "$(dirname "$DEST")"
# macOS protects already loaded, signed vendor bundles from in-place writes.
# The engine is pinned, so reuse an identical local copy rather than overwrite it.
VENDOR="$SUPPORT/Engine/WeType.app"
if [[ -f "$VENDOR/Contents/MacOS/WeType" ]]; then
  cmp -s .deps/mac-engine/WeType.app/Contents/MacOS/WeType "$VENDOR/Contents/MacOS/WeType" &&
    cmp -s .deps/mac-engine/WeType.app/Contents/Resources/imeData.bundle/index.json \
      "$VENDOR/Contents/Resources/imeData.bundle/index.json" || {
        echo "An incompatible native engine already exists at $VENDOR." >&2; exit 1;
      }
else
  ditto .deps/mac-engine/WeType.app "$VENDOR"
fi
# These are our own generated locations; preserve the previous app for recovery.
if [[ -d "$DEST" ]]; then
  ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")"
  [[ "$ID" == io.github.plintash.inputmethod.wetype || "$ID" == io.github.plintash.wetype-ime ]] || {
    echo "An unrelated app already exists at $DEST." >&2; exit 1;
  }
  mkdir -p "$SUPPORT/AppBackups"
  BACKUP="$SUPPORT/AppBackups/WeTypeIME.$(date +%Y%m%d%H%M%S).app"
  mv "$DEST" "$BACKUP"
fi
ditto build/macos/WeTypeIME.app "$DEST"
python3 - "$DEST" "$SUPPORT" <<'PY'
import plistlib, sys
from pathlib import Path
app, support = map(Path, sys.argv[1:])
with (app / 'Contents/Resources/EngineCommand.plist').open('wb') as f:
    plistlib.dump({'Executable': '$BUNDLE/Contents/MacOS/WeTypeNativeEngine',
                  'Arguments': [str(support / 'Engine/WeType.app'),
                                str(support / 'Dictionary'), 'flypy']}, f)
PY
codesign --force --sign - "$DEST"
xcrun swiftc macos/Tools/RegisterInputMethod.swift -o build/macos/register-input-method
build/macos/register-input-method "$DEST" || true
echo "Installed: $DEST"
echo "Add WeType 小鹤双拼 in System Settings → Keyboard → Input Sources."
echo "If it is not listed yet, log out and back in once."
