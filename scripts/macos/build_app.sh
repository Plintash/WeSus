#!/usr/bin/env bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$BASE"
APP="$BASE/build/macos/WeTypeIME.app"
mkdir -p "$BASE/build/macos"
STAGING="$(mktemp -d "$BASE/build/macos/app-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/WeTypeIME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework InputMethodKit macos/Sources/*.swift \
  -o "$APP/Contents/MacOS/WeTypeIME"
cp macos/Info.plist "$APP/Contents/Info.plist"
ICON_OUTPUT="$STAGING/wesus-artwork"
xcrun swift macos/Tools/GenerateInputSourceIcon.swift "$ICON_OUTPUT"
cp "$ICON_OUTPUT/WeSusMenuTemplate.pdf" "$APP/Contents/Resources/"
iconutil --convert icns "$ICON_OUTPUT/WeSus.iconset" --output "$APP/Contents/Resources/WeSus.icns"
cp -R macos/Resources/. "$APP/Contents/Resources/"
if [[ "${WETYPE_APP_BACKEND:-native}" == native ]]; then
  xcrun clang++ -std=c++17 -O2 -Wall -Wextra -mmacosx-version-min=13.0 -framework Foundation \
    macos/Engine/NativeEngine.mm -o "$APP/Contents/MacOS/WeTypeNativeEngine"
fi
python3 - "$BASE" "$APP" <<'PY'
import os, plistlib, shutil, sys
import hashlib
from pathlib import Path
base, app = map(Path, sys.argv[1:])
# A new artwork path prevents clients from reusing an image cached by URL.
resources = app / 'Contents/Resources'
# Include the generator to cover menu-only changes without using PDF metadata
# (which contains a generation timestamp and changes on every build).
revision = hashlib.sha256((base / 'macos/Tools/GenerateInputSourceIcon.swift').read_bytes()
                          + (resources / 'WeSus.icns').read_bytes()).hexdigest()[:12]
icons = {name: f'{Path(name).stem}-{revision}{Path(name).suffix}'
         for name in ['WeSus.icns', 'WeSusMenuTemplate.pdf']}
for old, new in icons.items():
    (resources / old).rename(resources / new)
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
def update_icons(value):
    if isinstance(value, dict):
        return {key: update_icons(item) for key, item in value.items()}
    if isinstance(value, list):
        return [update_icons(item) for item in value]
    return icons.get(value, value) if isinstance(value, str) else value
info_path.write_bytes(plistlib.dumps(update_icons(info)))
work = Path.home() / 'Library/Application Support/WeTypeIME/Dictionary'
if os.environ.get('WETYPE_APP_BACKEND', 'native') == 'orb':
    executable = shutil.which('orb')
    if not executable:
        raise SystemExit('OrbStack not found')
    arguments = ['-m', os.environ.get('WETYPE_ORB_MACHINE', 'wetype-dev'),
                 'bash', str(base / 'scripts/run_native_engine.sh'), 'flypy', str(work)]
else:
    executable = '$BUNDLE/Contents/MacOS/WeTypeNativeEngine'
    arguments = [str(base / '.deps/mac-engine/WeType.app'), str(work), 'flypy']
with (app / 'Contents/Resources/EngineCommand.plist').open('wb') as f:
    plistlib.dump({'Executable': executable, 'Arguments': arguments}, f)
PY
codesign --force --sign - "$APP"
rm -rf "$BASE/build/macos/WeTypeIME.app"
mv "$APP" "$BASE/build/macos/WeTypeIME.app"
APP="$BASE/build/macos/WeTypeIME.app"
echo "$APP"
