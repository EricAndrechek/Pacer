#!/bin/bash
# Stop the daemon and remove Pacer.app from /Applications. Preserves
# the SwiftData store at ~/Library/Group Containers/group.com.ericandrechek.pacer/
# and logs at ~/Library/Logs/Pacer/ — neither is touched by this
# script. Use `make clean-data` for a full nuke.
set -euo pipefail

DEV_LABEL="com.ericandrechek.pacer.daemon.dev"
SMAPP_LABEL="com.ericandrechek.pacer.daemon"
DEV_PLIST="$HOME/Library/LaunchAgents/${DEV_LABEL}.plist"
INSTALLED_APP="/Applications/Pacer.app"

echo "==> Pacer dev uninstall"

echo "==> Stopping any running daemon"
launchctl bootout "gui/$(id -u)/${DEV_LABEL}" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/${SMAPP_LABEL}" 2>/dev/null || true

if [ -f "${DEV_PLIST}" ]; then
    echo "==> Removing dev LaunchAgent plist"
    rm "${DEV_PLIST}"
fi

if [ -d "${INSTALLED_APP}" ]; then
    echo "==> Removing ${INSTALLED_APP}"
    rm -rf "${INSTALLED_APP}"
fi

echo
echo "Uninstall complete."
echo "SwiftData store and logs preserved. Use 'make clean-data' to wipe those too."
