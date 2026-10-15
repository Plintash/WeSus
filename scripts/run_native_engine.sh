#!/usr/bin/env bash
# Linux development backend. stdout is exclusively the harness protocol.
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 ]] || {
  echo "This development backend requires ARM64 Linux (for example OrbStack)." >&2
  exit 1
}
export WETYPE_DOUBLE_PINYIN="${1:-${WETYPE_DOUBLE_PINYIN:-full}}"
export WETYPE_WORK_DIR="${2:-${WETYPE_WORK_DIR:-$HOME/.local/share/wetype-ime/dict}}"
export WETYPE_DICT_DIR="${WETYPE_DICT_DIR:-$BASE/.deps/wechat-ime/assets/config/beta}"
export LD_LIBRARY_PATH="$BASE/runtime:$BASE/runtime/sysroot/system/lib64"
[[ -x "$BASE/harness/jinterop" && -f "$BASE/runtime/libwxhld_jni.so" &&
   -f "$WETYPE_DICT_DIR/index.json" ]] || {
  echo "Development engine is not prepared. Run scripts/macos/prepare_dev.sh." >&2
  exit 1
}
mkdir -p "$WETYPE_WORK_DIR/userdict/v5" "$WETYPE_WORK_DIR/userdict/user_hot_word"
ulimit -c 0
cd "$BASE"
exec "$BASE/harness/jinterop" "$BASE/runtime/libwxhld_jni.so" --daemon
