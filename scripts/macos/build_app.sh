#!/usr/bin/env bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$BASE"
APP="$BASE/build/macos/WeTypeIME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework InputMethodKit macos/Sources/*.swift \
  -o "$APP/Contents/MacOS/WeTypeIME"
cp macos/Info.plist "$APP/Contents/Info.plist"
xcrun swift macos/Tools/GenerateInputSourceIcon.swift assets/wetype-ime.png \
  "$APP/Contents/Resources/InputSourceIcon.tiff"
cp -R macos/Resources/. "$APP/Contents/Resources/"
if [[ "${WETYPE_APP_BACKEND:-native}" == native ]]; then
  xcrun clang++ -std=c++17 -O2 -Wall -Wextra -mmacosx-version-min=13.0 -framework Foundation \
    macos/Engine/NativeEngine.mm -o "$APP/Contents/MacOS/WeTypeNativeEngine"
fi
python3 - "$BASE" "$APP" <<'PY'
import os, plistlib, shutil, sys
from pathlib import Path
base, app = map(Path, sys.argv[1:])
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
echo "$APP"
