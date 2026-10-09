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

log_err() { printf 'lumen-runner: %s
' "$*" | tee -a "$LOG_FILE" >&2 2>/dev/null || printf 'lumen-runner: %s
' "$*" >&2; }

# True when $1 is an x86_64 ELF (e_machine 0x3e at offset 18).
is_x86_64_elf() {
    [ "$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' 
')" = "3e00" ]
}

# FEX needs a rootfs; point it at DroidDeck's when the user did not set one.
setup_fex_env() {
    if [ -z "${FEX_ROOTFS:-}" ]; then
        for r in "$HOME/.fex-emu/RootFS" "$HOME/.local/share/fex-emu/RootFS"                  /usr/share/fex-emu/RootFS /opt/droiddeck/rootfs; do
            if [ -d "$r" ]; then export FEX_ROOTFS="$r"; break; fi
        done
    fi
}

case "$arch" in
    x86_64|amd64)
        if [ -x "$TARGET_BIN" ]; then
            exec "$TARGET_BIN" "$@"
        fi
        ;;
    aarch64|arm64)
        # 1. Native arm64 build wins when present.
        for native in "$DIR/lumen.arm64" "$DIR/lumen.aarch64"; do
            [ -x "$native" ] && exec "$native" "$@"
        done

        if [ ! -f "$TARGET_BIN" ]; then
            log_err "Lumen binary not found at $TARGET_BIN"
            exit 127
        fi
        if ! is_x86_64_elf "$TARGET_BIN"; then
            # Not x86_64 -> must already be arm64; run directly.
            [ -x "$TARGET_BIN" ] && exec "$TARGET_BIN" "$@"
        fi

        setup_fex_env
        # 2. DroidDeck's integrated FEX runner.
        if [ -x /usr/local/bin/droiddeck-fex ]; then
            exec /usr/local/bin/droiddeck-fex run --mode on -- "$TARGET_BIN" "$@"
        fi
        # 3. Stock FEX front-ends.
        for fex in FEXInterpreter FEXLoader fex-emu; do
            if command -v "$fex" >/dev/null 2>&1; then
                exec "$fex" "$TARGET_BIN" "$@"
            fi
        done
        [ -x /usr/bin/FEX ] && exec /usr/bin/FEX "$TARGET_BIN" "$@"
        # 4. box64 as a last-resort translator.
        if command -v box64 >/dev/null 2>&1; then
            exec box64 "$TARGET_BIN" "$@"
        fi
        # 5. binfmt_misc may already route x86_64 ELFs.
        if [ -x "$TARGET_BIN" ]; then
            exec "$TARGET_BIN" "$@"
        fi
        ;;
    *)
        log_err "unsupported architecture: $arch"
        if [ -x "$TARGET_BIN" ]; then
            exec "$TARGET_BIN" "$@"
        fi
        ;;
esac

log_err "failed to execute Lumen ($TARGET_BIN) on $arch; install FEX-Emu (droiddeck-fex), box64, or a native lumen.arm64"
exit 127
