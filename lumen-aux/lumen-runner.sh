#!/usr/bin/env bash
# ============================================================================
#  lumen-runner.sh — Multi-architecture launcher for Lumen on DroidDeck
# ============================================================================
#  Supports both native execution and transparent FEX-Emu translation on
#  ARM64 Android devices (including Poco F9 Ultra / Snapdragon 8 Elite).
#
#  DroidDeck runs x86_64 programs inside SteamLinuxRuntime_sniper (Debian 11,
#  glibc 2.31), but lumen.bin needs glibc >= 2.34. install.sh therefore unpacks
#  a newer glibc into $DIR/glibc/lib; when it exists, lumen.bin is started
#  through that ld.so so it never touches the runtime's older libc.
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

LOG_FILE="${HOME:-/root}/.lumen.log"
arch="$(uname -m)"

log_err() {
    printf 'lumen-runner: %s\n' "$*" >&2
    printf 'lumen-runner: %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# True when $1 is an x86_64 ELF (e_machine 0x3e at offset 18).
is_x86_64_elf() {
    [ "$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')" = "3e00" ]
}

# FEX needs a rootfs; point it at one when the user did not set FEX_ROOTFS.
setup_fex_env() {
    local r
    if [ -z "${FEX_ROOTFS:-}" ]; then
        for r in "$HOME/.fex-emu/RootFS" "$HOME/.local/share/fex-emu/RootFS" \
                 /usr/share/fex-emu/RootFS /opt/droiddeck/rootfs; do
            if [ -d "$r" ]; then export FEX_ROOTFS="$r"; break; fi
        done
    fi
}

# Command prefix that launches an x86_64 program, as an array in LAUNCH.
# Returns 1 when no translator is installed.
pick_translator() {
    local fex
    LAUNCH=()
    if [ -x /usr/local/bin/droiddeck-fex ]; then
        LAUNCH=(/usr/local/bin/droiddeck-fex run --mode on --)
        return 0
    fi
    for fex in FEXInterpreter FEXLoader fex-emu; do
        if command -v "$fex" >/dev/null 2>&1; then LAUNCH=("$fex"); return 0; fi
    done
    if [ -x /usr/bin/FEX ]; then LAUNCH=(/usr/bin/FEX); return 0; fi
    if command -v box64 >/dev/null 2>&1; then LAUNCH=(box64); return 0; fi
    return 1
}

run_translated() {
    local glibc_lib="$DIR/glibc/lib" ld
    ld="$glibc_lib/ld-linux-x86-64.so.2"
    setup_fex_env
    if [ -x "$ld" ] || [ -f "$ld" ]; then
        # --library-path overrides LD_LIBRARY_PATH, so the runtime's glibc 2.31
        # is never searched for libc/libm.
        exec "${LAUNCH[@]}" "$ld" --library-path "$glibc_lib" "$TARGET_BIN" "$@"
    fi
    exec "${LAUNCH[@]}" "$TARGET_BIN" "$@"
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
            # Not x86_64, so it is already arm64: run it directly.
            [ -x "$TARGET_BIN" ] && exec "$TARGET_BIN" "$@"
        fi

        # 2. Translate x86_64 -> arm64 (DroidDeck FEX, stock FEX or box64).
        if pick_translator; then
            run_translated "$@"
        fi
        # 3. binfmt_misc may already route x86_64 ELFs.
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
