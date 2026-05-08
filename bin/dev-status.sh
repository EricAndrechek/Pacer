#!/bin/bash
# Print a one-screen summary of the dev install state — useful both
# when something feels off and as the first thing AI checks before
# diving into specific issues.
set -euo pipefail

INSTALLED_APP="/Applications/Pacer.app"
LOG_DIR="$HOME/Library/Logs/Pacer"
STORE_DIR="$HOME/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"
LEGACY_STORE_DIR="$HOME/Library/Group Containers/group.com.ericandrechek.pacer"

# Legacy daemon labels — only checked so we can warn if migration
# from the old daemon-based architecture didn't complete cleanly.
LEGACY_DEV_LABEL="com.ericandrechek.pacer.daemon.dev"
LEGACY_SMAPP_LABEL="com.ericandrechek.pacer.daemon"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32mok\033[0m  %s\n" "$1"; }
warn() { printf "  \033[33m??\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31m!!\033[0m  %s\n" "$1"; }

bold "Pacer dev install status"

# Installed app
if [ -d "${INSTALLED_APP}" ]; then
    mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "${INSTALLED_APP}" 2>/dev/null || echo "?")
    ok "${INSTALLED_APP} exists (modified ${mtime})"
else
    fail "${INSTALLED_APP} not installed (run: make install)"
fi

# Running app process
echo
bold "App process"
if pid=$(pgrep -f '/Pacer\.app/Contents/MacOS/Pacer$' 2>/dev/null) && [ -n "${pid}" ]; then
    ok "Pacer.app running (pid $(echo "${pid}" | tr '\n' ' '))"
else
    warn "Pacer.app not running — open it (or 'make open') to start collection"
fi

# Migration: warn loudly if a legacy daemon registration is still
# around. Old installs left these and they'd race the new in-process
# collection. `make install` cleans them up automatically; this is
# just a guard against partial states.
echo
bold "Migration check (legacy daemon should NOT be present)"
legacy_found=0
for label in "${LEGACY_DEV_LABEL}" "${LEGACY_SMAPP_LABEL}"; do
    if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
        fail "${label} is still registered — run 'make reinstall' to clean up"
        legacy_found=1
    fi
done
if [ ${legacy_found} -eq 0 ]; then
    ok "no legacy daemon registrations"
fi

# Logs
echo
bold "Logs"
if [ -d "${LOG_DIR}" ]; then
    for f in Pacer.err.log; do
        if [ -f "${LOG_DIR}/${f}" ]; then
            size=$(wc -c <"${LOG_DIR}/${f}" | tr -d ' ')
            mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${LOG_DIR}/${f}" 2>/dev/null || echo "?")
            ok "${LOG_DIR}/${f} (${size} bytes, modified ${mtime})"
        else
            warn "${LOG_DIR}/${f} not yet created"
        fi
    done
else
    warn "${LOG_DIR} does not exist (app hasn't started)"
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

# Legacy container (pre-Sequoia rename, 2026-05-07). Migration runs
# automatically on first launch with the new container; this is just
# a heads-up if the old one is still around so the user can clean it.
if [ -d "${LEGACY_STORE_DIR}" ]; then
    if [ -f "${LEGACY_STORE_DIR}/pacer.sqlite" ]; then
        warn "Legacy container still present at ${LEGACY_STORE_DIR}"
        warn "  (Pacer migrated to TeamID-prefixed container; safe to remove old via 'make clean-data')"
    fi
fi

# Recent log lines (most useful for AI debugging)
echo
bold "Recent app log (last 10 lines)"
if [ -f "${LOG_DIR}/Pacer.err.log" ]; then
    tail -n 10 "${LOG_DIR}/Pacer.err.log" | sed 's/^/  /'
else
    echo "  (no log yet)"
fi
