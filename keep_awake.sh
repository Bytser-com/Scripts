#!/usr/bin/env bash
set -euo pipefail
umask 077

# Use a secure, user-private directory (0700) instead of world-writable /tmp
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ ! -d "$RUNTIME_DIR" ] || [ ! -w "$RUNTIME_DIR" ] || [ ! -O "$RUNTIME_DIR" ]; then
    RUNTIME_DIR="${HOME:-/tmp}/.cache/keep_awake-$(id -u)"
    mkdir -p -m 700 "$RUNTIME_DIR"
fi
PID_FILE="$RUNTIME_DIR/keep_awake.pid"

notify_user() {
    local message="$1"
    echo "$message"
    if command -v notify-send >/dev/null 2>&1 && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
        notify-send "Keep Awake" "$message" 2>/dev/null || true
    fi
}

is_inhibitor_running() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    # Verify the PID actually belongs to our inhibitor process (prevents killing recycled PIDs)
    local comm
    comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    case "$comm" in
        systemd-inhibit|gnome-session-*|sleep) return 0 ;;
        *) return 1 ;;
    esac
}

if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_inhibitor_running "$OLD_PID"; then
        kill "$OLD_PID" 2>/dev/null || true
        wait "$OLD_PID" 2>/dev/null || true
        rm -f "$PID_FILE"
        notify_user "Sleep inhibition disabled. System can sleep now."
        exit 0
    fi
    rm -f "$PID_FILE"
fi

# Build the most complete inhibitor command available for the current environment:
# - gnome-session-inhibit prevents GNOME desktop idle/screen-blank/suspend
# - systemd-inhibit prevents system-level idle/suspend across all DEs and headless Debian/Ubuntu
PAYLOAD=(sleep infinity)
if command -v gnome-session-inhibit >/dev/null 2>&1 && \
   gnome-session-inhibit --inhibit idle:suspend true >/dev/null 2>&1; then
    PAYLOAD=(gnome-session-inhibit --inhibit idle:suspend --inhibit-only)
fi

INHIBIT_CMD=()
if command -v systemd-inhibit >/dev/null 2>&1; then
    if systemd-inhibit --what=idle:sleep --who="Keep Awake" --why="User requested keep awake" true >/dev/null 2>&1; then
        INHIBIT_CMD=(systemd-inhibit --what=idle:sleep --who="Keep Awake" --why="User requested keep awake" "${PAYLOAD[@]}")
    elif systemd-inhibit --what=idle --who="Keep Awake" --why="User requested keep awake" true >/dev/null 2>&1; then
        INHIBIT_CMD=(systemd-inhibit --what=idle --who="Keep Awake" --why="User requested keep awake" "${PAYLOAD[@]}")
    fi
fi

if [ "${#INHIBIT_CMD[@]}" -eq 0 ]; then
    if [ "${PAYLOAD[0]}" = "gnome-session-inhibit" ]; then
        INHIBIT_CMD=("${PAYLOAD[@]}")
    else
        echo "Error: Could not acquire a sleep inhibitor lock (if running over headless SSH, try running with sudo)." >&2
        exit 1
    fi
fi

"${INHIBIT_CMD[@]}" >/dev/null 2>&1 &
NEW_PID=$!

# Verify the background inhibitor actually stayed alive
sleep 0.2
if ! is_inhibitor_running "$NEW_PID"; then
    rm -f "$PID_FILE"
    echo "Error: Inhibitor process exited unexpectedly." >&2
    exit 1
fi

echo "$NEW_PID" > "$PID_FILE"
notify_user "Sleep inhibition enabled. System will stay awake."

