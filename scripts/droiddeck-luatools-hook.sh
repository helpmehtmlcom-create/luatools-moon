#!/usr/bin/env bash
# ============================================================================
#  droiddeck-luatools-hook.sh — DroidDeck Session Supervisor for LuaTools/Lumen
# ============================================================================
#  Automatically starts and supervises Lumen whenever Steam runs inside
#  DroidDeck on Poco F9 Ultra / Android.
#
#  Usage:
#    droiddeck-luatools-hook.sh start    # Starts the background supervisor
#    droiddeck-luatools-hook.sh run      # Runs foreground supervisor loop
#    droiddeck-luatools-hook.sh stop     # Stops Lumen and the supervisor
#    droiddeck-luatools-hook.sh status   # Reports current status
# ============================================================================

set -uo pipefail

STEAM_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/Steam"
LUMEN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/Lumen"
LUMEN_BIN="$LUMEN_DIR/lumen"
PID_DIR="${XDG_RUNTIME_DIR:-/tmp}/droiddeck-luatools"
SUPERVISOR_PID_FILE="$PID_DIR/supervisor.pid"
LUMEN_PID_FILE="$PID_DIR/lumen.pid"

mkdir -p "$PID_DIR" 2>/dev/null || true

log() {
    printf '[%s] [DroidDeck-LuaTools] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

is_steam_running() {
    pgrep -f '(steamrtarm64/steam|steamwebhelper|/steam )' >/dev/null 2>&1
}

is_lumen_running() {
    pgrep -f "$LUMEN_DIR/lumen" >/dev/null 2>&1
}

ensure_cef_debugging() {
    # Ensure CEF remote debugging sentinel exists for DroidDeck
    mkdir -p "$STEAM_ROOT" "$HOME/.steam/steam" 2>/dev/null || true
    touch "$STEAM_ROOT/.cef-enable-remote-debugging" 2>/dev/null || true
    touch "$HOME/.steam/steam/.cef-enable-remote-debugging" 2>/dev/null || true
    touch "$HOME/.steam/debian-installation/.cef-enable-remote-debugging" 2>/dev/null || true
}

start_lumen_instance() {
    if is_lumen_running; then
        return 0
    fi

    if [ ! -x "$LUMEN_BIN" ]; then
        log "Warning: Lumen executable not found at $LUMEN_BIN"
        return 1
    fi

    ensure_cef_debugging

    export LUMEN_DIR="$LUMEN_DIR"
    export LUMEN_BACKEND_DIR="$LUMEN_DIR/luatools/backend"
    export LUMEN_LUA_DIR="$LUMEN_DIR/lua"

    log "Starting Lumen sidecar for Steam in DroidDeck..."
    (
        env -u LD_AUDIT -u LD_PRELOAD -u LD_LIBRARY_PATH \
            LUMEN_DIR="$LUMEN_DIR" \
            LUMEN_BACKEND_DIR="$LUMEN_DIR/luatools/backend" \
            LUMEN_LUA_DIR="$LUMEN_DIR/lua" \
            setsid "$LUMEN_BIN" >> "${HOME:-/root}/.lumen.log" 2>&1 < /dev/null
    ) &
    local l_pid=$!
    echo "$l_pid" > "$LUMEN_PID_FILE" 2>/dev/null || true
    log "Lumen launched (pid: $l_pid)"
}

stop_lumen_instance() {
    log "Stopping Lumen sidecar..."
    pkill -f "$LUMEN_DIR/lumen" 2>/dev/null || true
    rm -f "$LUMEN_PID_FILE" 2>/dev/null || true
}

supervisor_loop() {
    ensure_cef_debugging
    echo "$$" > "$SUPERVISOR_PID_FILE"

    log "Supervisor started (PID: $$). Monitoring Steam sessions..."

    local steam_was_running=0
    while :; do
        if is_steam_running; then
            if [ "$steam_was_running" -eq 0 ]; then
                log "Steam detected running in DroidDeck. Initializing LuaTools..."
                steam_was_running=1
                # Short delay to give Steam CEF time to bind its remote debugging port
                sleep 2
                start_lumen_instance
            else
                if ! is_lumen_running; then
                    log "Lumen exited while Steam is still running. Restarting..."
                    start_lumen_instance
                fi
            fi
        else
            if [ "$steam_was_running" -eq 1 ]; then
                log "Steam has stopped. Stopping Lumen sidecar..."
                steam_was_running=0
                stop_lumen_instance
            fi
        fi
        sleep 3
    done
}

case "${1:-run}" in
    start)
        if [ -f "$SUPERVISOR_PID_FILE" ] && kill -0 "$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null)" 2>/dev/null; then
            log "Supervisor is already running (PID: $(cat "$SUPERVISOR_PID_FILE"))."
            exit 0
        fi
        log "Starting background supervisor..."
        ( "$0" run >> "${HOME:-/root}/.lumen.log" 2>&1 ) &
        log "Supervisor started in background."
        ;;
    run)
        trap 'stop_lumen_instance; rm -f "$SUPERVISOR_PID_FILE"; exit 0' TERM INT HUP
        supervisor_loop
        ;;
    stop)
        if [ -f "$SUPERVISOR_PID_FILE" ]; then
            spid="$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null)"
            if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
                kill "$spid" 2>/dev/null || true
            fi
            rm -f "$SUPERVISOR_PID_FILE"
        fi
        stop_lumen_instance
        log "Stopped."
        ;;
    status)
        echo "=== DroidDeck LuaTools Status ==="
        echo -n "Steam Running: "
        if is_steam_running; then echo "YES"; else echo "NO"; fi

        echo -n "Lumen Running: "
        if is_lumen_running; then echo "YES"; else echo "NO"; fi

        echo -n "Supervisor Running: "
        if [ -f "$SUPERVISOR_PID_FILE" ] && kill -0 "$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null)" 2>/dev/null; then
            echo "YES (PID: $(cat "$SUPERVISOR_PID_FILE"))"
        else
            echo "NO"
        fi
        echo "Lumen Binary: $LUMEN_BIN"
        echo "Log File: ${HOME:-/root}/.lumen.log"
        ;;
    *)
        echo "Usage: $0 {start|run|stop|status}"
        exit 1
        ;;
esac
