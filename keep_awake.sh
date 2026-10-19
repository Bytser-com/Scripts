#!/usr/bin/env bash

PID_FILE="/tmp/keep_awake.pid"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    # Process is running -> kill it to allow sleep again
    kill "$(cat "$PID_FILE")"
    rm -f "$PID_FILE"
    echo "Sleep inhibition disabled. Ubuntu can sleep now."
    notify-send "Keep Awake" "Sleep inhibition disabled" 2>/dev/null
else
    # Process is not running -> launch in background and store PID
    gnome-session-inhibit --inhibit idle:suspend --inhibit-only >/dev/null &
    echo $! > "$PID_FILE"
    echo "Sleep inhibition enabled. System will stay awake."
    notify-send "Keep Awake" "Sleep inhibition enabled" 2>/dev/null
fi
