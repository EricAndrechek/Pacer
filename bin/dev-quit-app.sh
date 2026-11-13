#!/bin/bash
# Quit the running Pacer.app GUI (if any) so the install script can
# safely replace the bundle. Tries AppleScript quit first (so SwiftUI
# termination handlers run cleanly), falls back to SIGKILL after a
# bounded wait. Also terminates the WidgetKit extension and the crash
# relauncher (see below).
#
# Stdout: "1" if the app was running and has been stopped; "0" if it
# was not running. The install script captures this to decide whether
# to re-open after the upgrade. Status messages go to stderr so they
# don't pollute that single-line stdout contract.
set -euo pipefail

# $-anchored so only the actual GUI binary matches, not e.g. a
# `tail -F .../Pacer.log` shell line that happened to mention the path.
APP_PATH_REGEX='/Pacer\.app/Contents/MacOS/Pacer$'

# The widget extension (PacerWidgets.appex) is a SEPARATE process owned
# by WidgetKit's chronod, NOT a child of the host GUI — quitting the app
# above does not touch it. On a bundle swap macOS leaves the old appex
# running its now-replaced binary; chronod keeps serving that orphaned
# process's frozen timeline, so placed widgets show stale data until the
# user reboots or hand-kills it. (Diagnosed 2026-06-23: after a reinstall
# the pace widgets sat on days-old rate-limit data because the appex
# process predated the new bundle and the host's reloadTimelines requests
# never revived it.) Killing it here forces chronod to relaunch it from
# the fresh bundle on the next render — harmless, since the extension is
# stateless and reads only the shared store. This is what makes
# dev-install.sh's "OLD app/widget processes are guaranteed quit"
# invariant actually hold. Always runs, even when the host GUI is not:
# the appex can outlive the app.
WIDGET_PATH_REGEX='/PacerWidgets\.appex/Contents/MacOS/PacerWidgets$'
if pgrep -f "${WIDGET_PATH_REGEX}" >/dev/null 2>&1; then
    echo "    Terminating PacerWidgets extension (forces relaunch from new bundle)" >&2
    pkill -TERM -f "${WIDGET_PATH_REGEX}" 2>/dev/null || true
    sleep 1
    # Belt-and-suspenders: a wedged extension that ignored SIGTERM would
    # otherwise survive into the new bundle. SIGKILL is safe here.
    pkill -KILL -f "${WIDGET_PATH_REGEX}" 2>/dev/null || true
fi

# The crash relauncher (#412) goes first, before the app is asked to quit.
# Pacer tells it "quit" as it starts to terminate, so a clean quit never
# relaunches; but if the AppleScript quit below times out, the SIGKILL that
# follows looks exactly like a crash, and the relauncher would start the old
# app back up while the install is replacing the bundle. With it gone there
# is nothing to race: the install's own `open -g` starts the new build, which
# starts a new relauncher. Matched by exact process name, so only Pacer's.
# Always runs, even when the app is not: a relauncher can be in its back-off
# wait after a crash, about to relaunch.
stopped_relauncher=0
if pgrep -x PacerRelauncher >/dev/null 2>&1; then
    stopped_relauncher=1
    echo "    Stopping the crash relauncher (so nothing relaunches mid-install)" >&2
    pkill -TERM -x PacerRelauncher 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x PacerRelauncher >/dev/null 2>&1 || break
        sleep 0.2
    done
    pkill -KILL -x PacerRelauncher 2>/dev/null || true
fi

if ! pgrep -f "${APP_PATH_REGEX}" >/dev/null 2>&1; then
    # Not running, but a relauncher was waiting to bring it back after a
    # crash. We just cancelled that relaunch, so say "was running": the
    # install then reopens the new build instead of leaving Pacer closed.
    echo "${stopped_relauncher}"
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
