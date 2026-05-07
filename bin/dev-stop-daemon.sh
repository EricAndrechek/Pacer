#!/bin/bash
# Stop every running PacerDaemon: the launchctl-managed dev label, the
# bundled SMAppService label (in case it was registered via the Debug
# tab), AND any orphan/foreground PacerDaemon processes that bootout
# can't reach (e.g. one started directly via `make daemon-fg` or by an
# AI session that shelled out the binary).
#
# Idempotent — safe to run when nothing is loaded.
set -euo pipefail

DEV_LABEL="com.ericandrechek.pacer.daemon.dev"
SMAPP_LABEL="com.ericandrechek.pacer.daemon"

# pgrep -f matches the full command line. The $-anchored path catches
# both /Applications/Pacer.app/.../PacerDaemon AND any foreground
# daemon launched out of a Build/Products/Debug copy.
DAEMON_PATH_REGEX='/Pacer\.app/Contents/Library/LaunchServices/PacerDaemon$'

bootout_and_wait() {
    local label="$1"
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    # `bootout` returns before launchd has fully released the label, so
    # poll up to 10s. If we proceed too quickly the next bootstrap will
    # race and EIO.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! launchctl list "${label}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "    WARNING: ${label} still loaded after 10s, continuing anyway"
}

stop_orphan_daemons() {
    local pids
    pids="$(pgrep -f "${DAEMON_PATH_REGEX}" 2>/dev/null || true)"
    if [ -z "${pids}" ]; then
        return 0
    fi
    echo "    orphan PacerDaemon process(es): $(echo "${pids}" | tr '\n' ' ')"
    # shellcheck disable=SC2086 -- intentional word-split on PID list
    kill -TERM ${pids} 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        sleep 1
        if [ -z "$(pgrep -f "${DAEMON_PATH_REGEX}" 2>/dev/null || true)" ]; then
            return 0
        fi
    done
    echo "    orphan(s) still alive after SIGTERM; sending SIGKILL"
    pids="$(pgrep -f "${DAEMON_PATH_REGEX}" 2>/dev/null || true)"
    if [ -n "${pids}" ]; then
        # shellcheck disable=SC2086
        kill -KILL ${pids} 2>/dev/null || true
    fi
}

bootout_and_wait "${DEV_LABEL}"
bootout_and_wait "${SMAPP_LABEL}"
stop_orphan_daemons
