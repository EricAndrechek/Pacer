#!/bin/bash
# Print a one-screen summary of the dev install state — useful both
# when something feels off and as the first thing AI checks before
# diving into specific issues.
set -euo pipefail

DEV_LABEL="com.ericandrechek.pacer.daemon.dev"
SMAPP_LABEL="com.ericandrechek.pacer.daemon"
INSTALLED_APP="/Applications/Pacer.app"
LOG_DIR="$HOME/Library/Logs/Pacer"
STORE_DIR="$HOME/Library/Group Containers/group.com.ericandrechek.pacer"
DAEMON_BIN="${INSTALLED_APP}/Contents/Library/LaunchServices/PacerDaemon"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32mok\033[0m  %s\n" "$1"; }
warn() { printf "  \033[33m??\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31m!!\033[0m  %s\n" "$1"; }

bold "Pacer dev install status"

# Installed app
if [ -d "${INSTALLED_APP}" ]; then
    mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "${INSTALLED_APP}" 2>/dev/null || echo "?")
    ok "${INSTALLED_APP} exists (modified ${mtime})"
    if [ -x "${DAEMON_BIN}" ]; then
        ok "PacerDaemon binary embedded"
    else
        fail "PacerDaemon NOT embedded at ${DAEMON_BIN}"
    fi
else
    fail "${INSTALLED_APP} not installed (run: make install)"
fi

# Daemon launchd state
echo
bold "LaunchAgent state"
for label in "${DEV_LABEL}" "${SMAPP_LABEL}"; do
    if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
        pid=$(launchctl print "gui/$(id -u)/${label}" 2>/dev/null | awk '/pid =/ {print $3; exit}')
        if [ -n "${pid}" ] && [ "${pid}" != "0" ]; then
            ok "${label} loaded (pid ${pid})"
        else
            warn "${label} loaded but not running"
        fi
    else
        # Fine for the SMAppService one — only report missing for dev label.
        if [ "${label}" = "${DEV_LABEL}" ]; then
            warn "${label} not loaded (run: make install)"
        fi
    fi
done

# Logs
echo
bold "Logs"
if [ -d "${LOG_DIR}" ]; then
    for f in PacerDaemon.err.log PacerDaemon.out.log; do
        if [ -f "${LOG_DIR}/${f}" ]; then
            size=$(wc -c <"${LOG_DIR}/${f}" | tr -d ' ')
            mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${LOG_DIR}/${f}" 2>/dev/null || echo "?")
            ok "${LOG_DIR}/${f} (${size} bytes, modified ${mtime})"
        else
            warn "${LOG_DIR}/${f} not yet created"
        fi
    done
else
    warn "${LOG_DIR} does not exist (daemon hasn't started)"
fi

# SwiftData store
echo
bold "SwiftData store"
if [ -d "${STORE_DIR}" ]; then
    ok "App Group container exists at ${STORE_DIR}"
    if [ -f "${STORE_DIR}/pacer.sqlite" ]; then
        size=$(wc -c <"${STORE_DIR}/pacer.sqlite" | tr -d ' ')
        ok "pacer.sqlite (${size} bytes)"
    else
        warn "pacer.sqlite not yet created (open the app once)"
    fi
else
    warn "App Group container missing — Pacer.app hasn't run yet"
fi

# Recent log lines (most useful for AI debugging)
echo
bold "Recent daemon log (last 10 lines)"
if [ -f "${LOG_DIR}/PacerDaemon.err.log" ]; then
    tail -n 10 "${LOG_DIR}/PacerDaemon.err.log" | sed 's/^/  /'
else
    echo "  (no log yet)"
fi
