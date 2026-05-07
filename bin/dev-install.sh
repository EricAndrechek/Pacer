#!/bin/bash
# Build, sign, install, and register Pacer for daily-driver dev use.
#
# Idempotent: safe to run on a fresh checkout (first install) AND on a
# repo with an older Pacer.app already at /Applications (upgrade). On
# upgrade we:
#   1. Quit any running Pacer.app GUI (so the in-memory binary releases
#      the bundle — replacing /Applications/Pacer.app while it's
#      running leaves the user staring at the old code).
#   2. Stop every PacerDaemon — both launchctl-managed and any orphan
#      foreground processes — so they release the SwiftData store.
#   3. Replace the bundle and re-register the LaunchAgent.
#   4. Re-open Pacer.app if it was running before the install, so the
#      user lands back exactly where they were on the new binary.
#
# Designed to be runnable by AI without user interaction. Surfaces all
# state-changing operations as visible commands so the transcript is
# debuggable.
#
# Flags:
#   --restore-app   Force re-opening Pacer.app at the end even if no
#                   GUI was running when the script started. Used by
#                   `make reinstall` to preserve the user's running
#                   app across the uninstall→install boundary.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pacer.app"
INSTALL_DIR="/Applications"
INSTALLED_APP="${INSTALL_DIR}/${APP_NAME}"
BUILD_OUTPUT="${REPO_ROOT}/Build/Products/Debug/${APP_NAME}"

DEV_LABEL="com.ericandrechek.pacer.daemon.dev"
DEV_PLIST="$HOME/Library/LaunchAgents/${DEV_LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/Pacer"

RESTORE_APP=0
if [ "${1:-}" = "--restore-app" ]; then
    RESTORE_APP=1
fi

echo "==> Pacer dev install"
echo "    repo:      ${REPO_ROOT}"
echo "    target:    ${INSTALLED_APP}"
echo "    dev plist: ${DEV_PLIST}"
echo "    logs:      ${LOG_DIR}"

# 1. Regenerate the Xcode project from project.yml so any source
#    additions (new files in App/Views/, new PacerCore modules) get
#    picked up. Skipped if no project.yml change since the last
#    generate — xcodegen handles that internally.
echo
echo "==> Regenerating Pacer.xcodeproj"
cd "${REPO_ROOT}"
xcodegen generate

# 2. Sign + build. Uses the team in project.yml (YZXWMJ5VBY); xcodebuild
#    auto-selects an Apple Development cert from that team. -allowProvisioningUpdates
#    lets it fetch any missing profiles without an Xcode UI session.
echo
echo "==> Building Pacer.app (Debug, signed)"
xcodebuild \
    -project Pacer.xcodeproj \
    -scheme Pacer \
    -configuration Debug \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    build \
    | (grep -E '(error:|warning:|FAILED|SUCCEEDED)' || true)

if [ ! -d "${BUILD_OUTPUT}" ]; then
    echo "ERROR: build did not produce ${BUILD_OUTPUT}"
    exit 1
fi

# 3a. Quit Pacer.app if running, capturing whether it was so we can
#     re-open at the end. Doing this BEFORE the daemon stop matters
#     for two reasons: (a) the GUI holds the SwiftData container open
#     too, and (b) AppleScript quit cleanup is faster on a healthy
#     daemon than on a missing one.
echo
echo "==> Quitting any running Pacer.app GUI"
APP_WAS_RUNNING="$("${REPO_ROOT}/bin/dev-quit-app.sh")"

# 3b. Stop every PacerDaemon — launchctl-managed AND orphan foreground
#     processes (e.g. one started via `make daemon-fg` or directly by
#     a previous AI session). Two daemons racing the SwiftData store
#     causes the SX-zombie failure mode documented in AGENTS.md.
echo
echo "==> Stopping any running daemon"
"${REPO_ROOT}/bin/dev-stop-daemon.sh"

# 4. Replace the installed app. `rm -rf` is safe here because /Applications
#    is user-owned on macOS for non-system apps, and this script
#    explicitly targets the Pacer.app inside it.
echo
echo "==> Installing to ${INSTALLED_APP}"
rm -rf "${INSTALLED_APP}"
cp -R "${BUILD_OUTPUT}" "${INSTALL_DIR}/"

# 5. Ensure log directory exists so launchd can open the files.
echo
echo "==> Preparing log directory at ${LOG_DIR}"
mkdir -p "${LOG_DIR}"

# 6. Generate and install the dev LaunchAgent plist. We always
#    overwrite — the plist content is deterministic from the script,
#    and there's no useful customization a user would do here.
echo
echo "==> Writing dev LaunchAgent plist"
mkdir -p "$HOME/Library/LaunchAgents"
"${REPO_ROOT}/bin/dev-launchagent-plist.sh" > "${DEV_PLIST}"

# 7. Register and start. `bootstrap` loads the plist and (because
#    RunAtLoad=true) immediately starts the daemon. Retry once on EIO:
#    even with the bootout-and-wait, launchd occasionally needs an
#    extra moment to release the label.
echo
echo "==> Registering daemon with launchd"
if ! launchctl bootstrap "gui/$(id -u)" "${DEV_PLIST}"; then
    echo "    bootstrap failed; waiting 2s and retrying once"
    sleep 2
    launchctl bootstrap "gui/$(id -u)" "${DEV_PLIST}"
fi

echo
echo "==> Verifying"
sleep 1
if launchctl print "gui/$(id -u)/${DEV_LABEL}" >/dev/null 2>&1; then
    pid=$(launchctl print "gui/$(id -u)/${DEV_LABEL}" | awk '/pid =/ {print $3; exit}')
    echo "    daemon PID: ${pid:-not running yet}"
else
    echo "    WARNING: launchctl print did not find the service"
fi

if [ "${APP_WAS_RUNNING}" = "1" ] || [ "${RESTORE_APP}" = "1" ]; then
    echo
    echo "==> Re-opening Pacer.app (was running before install)"
    open "${INSTALLED_APP}"
fi

echo
echo "Done. Open the dashboard with: make open"
echo "Tail logs with:                make logs"
echo "Status check:                  make status"
