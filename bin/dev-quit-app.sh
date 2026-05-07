#!/bin/bash
# Quit the running Pacer.app GUI (if any) so the install script can
# safely replace the bundle. Tries AppleScript quit first (so SwiftUI
# termination handlers run cleanly), falls back to SIGKILL after a
# bounded wait.
#
# Stdout: "1" if the app was running and has been stopped; "0" if it
# was not running. The install script captures this to decide whether
# to re-open after the upgrade. Status messages go to stderr so they
# don't pollute that single-line stdout contract.
set -euo pipefail

# $-anchored so only the actual GUI binary matches, not e.g. a
# `tail -F .../Pacer.log` shell line that happened to mention the path.
APP_PATH_REGEX='/Pacer\.app/Contents/MacOS/Pacer$'

if ! pgrep -f "${APP_PATH_REGEX}" >/dev/null 2>&1; then
    echo 0
    exit 0
fi

echo "    Quitting Pacer.app" >&2

# AppleScript `with timeout` keeps osascript from hanging forever if
# the app's main thread is stuck — without it, a wedged Pacer would
# block the whole install. 5s is enough for any healthy quit cycle.
osascript \
    -e 'with timeout of 5 seconds' \
    -e 'tell application "Pacer" to quit' \
    -e 'end timeout' >/dev/null 2>&1 || true

# Even on a successful quit, the process can take a moment to drop off
# the process table. Two seconds is a generous allowance.
for _ in 1 2; do
    sleep 1
    if ! pgrep -f "${APP_PATH_REGEX}" >/dev/null 2>&1; then
        echo 1
        exit 0
    fi
done

echo "    GUI did not exit after AppleScript quit; sending SIGKILL" >&2
pkill -KILL -f "${APP_PATH_REGEX}" 2>/dev/null || true
sleep 1
echo 1
