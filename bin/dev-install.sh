#!/bin/bash
# Build, sign, install, and register Pacer for daily-driver dev use.
#
# Idempotent: safe to run on a fresh checkout (first install) AND on a
# repo with an older Pacer.app already at /Applications (upgrade). On
# upgrade, it stops the running daemon, replaces the bundle, and
# re-registers — the LaunchAgent path stays the same so re-registering
# is what picks up the new binary signature.
#
# Designed to be runnable by AI without user interaction. Surfaces all
# state-changing operations as visible commands so the transcript is
# debuggable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pacer.app"
INSTALL_DIR="/Applications"
INSTALLED_APP="${INSTALL_DIR}/${APP_NAME}"
BUILD_OUTPUT="${REPO_ROOT}/Build/Products/Debug/${APP_NAME}"

# Two LaunchAgent labels to clean up: the dev one we own, plus the
# bundled SMAppService one in case the user previously clicked Register
# in the Debug tab. We don't want two daemons racing the SwiftData
# container.
DEV_LABEL="com.ericandrechek.pacer.daemon.dev"
SMAPP_LABEL="com.ericandrechek.pacer.daemon"
DEV_PLIST="$HOME/Library/LaunchAgents/${DEV_LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/Pacer"

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

# 3. Stop any running daemon. We bootout both possible labels to handle
#    the case where the user has the bundled plist registered via
#    SMAppService AND the dev plist registered via launchctl. `|| true`
#    swallows "service not loaded" exit codes.
#
#    `launchctl bootout` returns before the daemon's signal handler has
#    finished cleanup. If we hit `bootstrap` before launchd has fully
#    torn down the previous registration we get EIO. So we poll
#    `launchctl list` until the label disappears (bounded ~10s).
echo
echo "==> Stopping any running daemon"

bootout_and_wait() {
    local label="$1"
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! launchctl list "${label}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "    WARNING: ${label} still loaded after 10s, continuing anyway"
    return 0
}

bootout_and_wait "${DEV_LABEL}"
bootout_and_wait "${SMAPP_LABEL}"

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

echo
echo "Done. Open the dashboard with: make open"
echo "Tail logs with:                make logs"
echo "Status check:                  make status"
