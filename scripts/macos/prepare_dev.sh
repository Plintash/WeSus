#!/usr/bin/env bash
# Reproducible Android-engine reference backend on Apple Silicon.
# This is for development/testing; the finished macOS app must use a native engine.
set -euo pipefail
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$BASE"
MACHINE="${WETYPE_ORB_MACHINE:-wetype-dev}"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "This development setup requires an Apple Silicon Mac." >&2; exit 1;
}
for tool in orb python3 curl unzip shasum; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
if ! orb info "$MACHINE" >/dev/null 2>&1; then
  orb create -a arm64 ubuntu:24.04 "$MACHINE"
fi
orb -m "$MACHINE" -u root sh -c 'command -v patchelf >/dev/null || { apt-get update -qq && apt-get install -y --no-install-recommends patchelf; }'
mkdir -p .deps/tools .deps/releases
fetch() {
  local path="$1" algorithm="$2" checksum="$3" url="$4"
  if [[ -f "$path" && "$(shasum -a "$algorithm" "$path" | cut -d' ' -f1)" == "$checksum" ]]; then return; fi
  curl -fL --retry 3 -o "$path.part" "$url"
  [[ "$(shasum -a "$algorithm" "$path.part" | cut -d' ' -f1)" == "$checksum" ]] || {
    echo "Checksum mismatch: $path" >&2; exit 1;
  }
  mv "$path.part" "$path"
}
# Google's SDK repository metadata pins the Darwin ZIP for NDK 27.2.12479018.
fetch .deps/tools/android-ndk-r27c-darwin.zip 1 0217c10ffbec496bb9fbfbb3c6fc2477c6b77297 \
  https://dl.google.com/android/repository/android-ndk-r27c-darwin.zip
NDK="$BASE/.deps/tools/android-ndk-r27c"
[[ -x "$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang" ]] || unzip -q .deps/tools/android-ndk-r27c-darwin.zip -d .deps/tools
# This upstream artifact contains only the project's harness and AOSP runtime.
# It contains no proprietary WeType engine/dictionary files.
fetch .deps/releases/WeTypeIME-Engine-aarch64.AppImage 256 9fc09d47e72f4359c72ebff6649280683586e66b57bf40717d2d53914febec6b \
  https://github.com/yu1745/wetype-ime-linux/releases/download/v0.1.8/WeTypeIME-Engine-aarch64.AppImage
if [[ ! -f runtime/sysroot/.image-sha256 ]]; then
  chmod +x .deps/releases/WeTypeIME-Engine-aarch64.AppImage
  (cd .deps/releases && orb -m "$MACHINE" ./WeTypeIME-Engine-aarch64.AppImage --appimage-extract)
  mkdir -p runtime
  cp -R .deps/releases/squashfs-root/usr/lib/wetype-ime/arm64/sysroot runtime/sysroot
fi
WETYPE_APK_CACHE="$BASE/.deps/apk-cache" bash scripts/prepare_assets.sh "${@}"
bash scripts/10_patch_libs.sh
CC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang"
"$CC" --target=aarch64-linux-android28 -shared -fPIC -O2 -Wl,-soname,libandroid.so -o runtime/libandroid.so shim/libandroid.c
"$CC" --target=aarch64-linux-android28 -O0 -g -o harness/jinterop harness/jinterop.c -ldl
orb -m "$MACHINE" patchelf --set-interpreter "$BASE/runtime/sysroot/system/bin/linker64" "$BASE/harness/jinterop"
echo "Development engine prepared. Test: python3 scripts/test_flypy.py --backend orb --machine $MACHINE"
