#!/usr/bin/env bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$BASE"
mkdir -p build/macos
xcrun swiftc -swift-version 5 macos/Sources/Preferences.swift macos/Sources/Composition.swift macos/Tests/main.swift \
  -o build/macos/composition-test
build/macos/composition-test
xcrun swiftc -swift-version 5 -framework AppKit macos/Sources/Preferences.swift \
  macos/Sources/Composition.swift macos/Sources/CandidatePanel.swift macos/Tests/Keyboard/main.swift \
  -o build/macos/keyboard-test
build/macos/keyboard-test
xcrun swiftc -swift-version 5 -framework AppKit macos/Sources/Preferences.swift \
  macos/Sources/Composition.swift macos/Sources/CandidatePanel.swift macos/Tests/Rendering/main.swift \
  -o build/macos/rendering-test
build/macos/rendering-test
if [[ -x build/macos/WeTypeNativeEngine && -d .deps/mac-engine/WeType.app ]]; then
  xcrun swiftc -swift-version 5 macos/Sources/Preferences.swift macos/Sources/Composition.swift macos/Sources/ProcessEngine.swift \
    macos/Tests/Integration/main.swift -o build/macos/native-frontend-test
  build/macos/native-frontend-test "$BASE"
fi
