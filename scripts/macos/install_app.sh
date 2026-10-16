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
# Raw .app backups can be rediscovered with the same bundle ID and old icons.
# Migrate our existing backups too, retaining a restorable ZIP for each one.
python3 scripts/macos/archive_app.py "$SUPPORT/AppBackups" "$DEST"
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
build/macos/register-input-method "$DEST"
# Read in a fresh process so the registrar's own TIS objects cannot mask a
# stale system registration. Fail installation instead of reporting success.
build/macos/register-input-method "$DEST" --verify
# The switcher and caret indicator keep their own images in memory even when
# TIS already reports the new resource URLs. Refresh the current user's UI.
if [[ "${WETYPE_REFRESH_INPUT_UI:-1}" == 1 ]]; then
  python3 scripts/macos/refresh_input_ui.py
fi
echo "Installed: $DEST"
echo "Add 巨疑输入法 in System Settings → Keyboard → Input Sources."
echo "If it is not listed yet, log out and back in once."
