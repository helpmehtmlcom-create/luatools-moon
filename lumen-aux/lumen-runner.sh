#!/usr/bin/env bash
# ============================================================================
#  lumen-runner.sh — Multi-architecture launcher for Lumen on DroidDeck
# ============================================================================
#  Supports both native execution and transparent FEX-Emu translation on
#  ARM64 Android devices (including Poco F9 Ultra / Snapdragon 8 Elite).
# ============================================================================

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="lumen.bin"
TARGET_BIN="$DIR/$BIN_NAME"

# Fallback if lumen.bin was not renamed
if [ ! -f "$TARGET_BIN" ] && [ -f "$DIR/lumen.x86_64" ]; then
    TARGET_BIN="$DIR/lumen.x86_64"
fi

export LUMEN_DIR="$DIR"
export LUMEN_BACKEND_DIR="${LUMEN_BACKEND_DIR:-$DIR/luatools/backend}"
export LUMEN_LUA_DIR="${LUMEN_LUA_DIR:-$DIR/lua}"

# Ensure log directory exists
LOG_FILE="${HOME:-/root}/.lumen.log"

arch="$(uname -m)"
case "$arch" in
    x86_64|amd64)
        if [ -x "$TARGET_BIN" ]; then
            exec "$TARGET_BIN" "$@"
        fi
        ;;
    aarch64|arm64)
        # 1. Prefer native arm64 binary if compiled or available
        if [ -x "$DIR/lumen.arm64" ]; then
            exec "$DIR/lumen.arm64" "$@"
        fi

        # 2. Prefer DroidDeck's integrated FEX-Emu runner
        if [ -x /usr/local/bin/droiddeck-fex ]; then
            exec /usr/local/bin/droiddeck-fex run --mode on -- "$TARGET_BIN" "$@"
        fi

        # 3. Check for standard fex-emu
        if command -v fex-emu >/dev/null 2>&1; then
            exec fex-emu "$TARGET_BIN" "$@"
        fi

        # 4. Check for FEX interpreter paths
        if [ -x /usr/bin/FEX ]; then
            exec /usr/bin/FEX "$TARGET_BIN" "$@"
        fi

        # 5. Fallback: direct execution (binfmt_misc might be configured)
        if [ -x "$TARGET_BIN" ]; then
            exec "$TARGET_BIN" "$@"
        fi
        ;;
    *)
        echo "lumen-runner: unsupported architecture: $arch" >&2
        if [ -x "$TARGET_BIN" ]; then
            exec "$TARGET_BIN" "$@"
        fi
        ;;
esac

echo "lumen-runner: failed to execute Lumen ($TARGET_BIN) on $arch" >&2
exit 127
