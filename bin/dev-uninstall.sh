#!/bin/bash
# Stop the daemon and the GUI, then remove Pacer.app from /Applications.
# Preserves the SwiftData store at
# ~/Library/Group Containers/group.com.ericandrechek.pacer/ and logs
# at ~/Library/Logs/Pacer/ — neither is touched by this script. Use
# `make clean-data` for a full nuke.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_LABEL="com.ericandrechek.pacer.daemon.dev"
DEV_PLIST="$HOME/Library/LaunchAgents/${DEV_LABEL}.plist"
INSTALLED_APP="/Applications/Pacer.app"

echo "==> Pacer dev uninstall"

# Quit the GUI first so the bundle isn't held open by a running
# process when we rm -rf it. Discard the "was running" stdout — we
# don't re-open after an uninstall.
echo "==> Quitting any running Pacer.app GUI"
"${REPO_ROOT}/bin/dev-quit-app.sh" >/dev/null

echo "==> Stopping any running daemon"
"${REPO_ROOT}/bin/dev-stop-daemon.sh"

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
