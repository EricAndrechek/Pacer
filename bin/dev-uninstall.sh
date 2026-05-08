#!/bin/bash
# Quit the GUI and remove Pacer.app from /Applications. Also bootouts
# any leftover legacy daemon LaunchAgent (from before the single-binary
# refactor). Preserves the SwiftData store at
# ~/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/
# (and the pre-Sequoia container ~/Library/Group Containers/group.com.ericandrechek.pacer/
# if still present from a pre-rename install) and logs at
# ~/Library/Logs/Pacer/ — none of these are touched by this script.
# Use `make clean-data` for a full nuke including both containers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEGACY_DEV_LABEL="com.ericandrechek.pacer.daemon.dev"
LEGACY_SMAPP_LABEL="com.ericandrechek.pacer.daemon"
LEGACY_DEV_PLIST="$HOME/Library/LaunchAgents/${LEGACY_DEV_LABEL}.plist"
INSTALLED_APP="/Applications/Pacer.app"

echo "==> Pacer dev uninstall"

# Quit the GUI first so the bundle isn't held open by a running
# process when we rm -rf it. Discard the "was running" stdout — we
# don't re-open after an uninstall.
echo "==> Quitting any running Pacer.app GUI"
"${REPO_ROOT}/bin/dev-quit-app.sh" >/dev/null

# Migration cleanup: bootout legacy daemon labels and remove the dev
# plist if any of them still exist. No-ops on a fresh single-binary
# install.
echo "==> Cleaning up legacy daemon registration (if present)"
for label in "${LEGACY_DEV_LABEL}" "${LEGACY_SMAPP_LABEL}"; do
    if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        echo "    bootout: ${label}"
    fi
done

if [ -f "${LEGACY_DEV_PLIST}" ]; then
    echo "    removed: ${LEGACY_DEV_PLIST}"
    rm "${LEGACY_DEV_PLIST}"
fi

if [ -d "${INSTALLED_APP}" ]; then
    echo "==> Removing ${INSTALLED_APP}"
    rm -rf "${INSTALLED_APP}"
fi

echo
echo "Uninstall complete."
echo "SwiftData store and logs preserved. Use 'make clean-data' to wipe those too."
