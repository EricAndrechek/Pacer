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

# 2. Build unsigned. project.yml sets CODE_SIGNING_ALLOWED=NO globally
#    so xcodebuild produces unsigned bundles (no provisioning profile
#    round-trip, no Apple Development cert). We sign manually below.
echo
echo "==> Building Pacer.app (Debug, unsigned)"
xcodebuild \
    -project Pacer.xcodeproj \
    -scheme Pacer \
    -configuration Debug \
    -destination 'platform=macOS' \
    build \
    | (grep -E '(error:|warning:|FAILED|SUCCEEDED)' || true)

if [ ! -d "${BUILD_OUTPUT}" ]; then
    echo "ERROR: build did not produce ${BUILD_OUTPUT}"
    exit 1
fi

# 2b. Manually sign every binary inside the .app with Developer ID
#     Application. This is what the eventual Sparkle release will use,
#     and matters during dev too: Apple Development-signed binaries
#     don't get a csreq blob written into TCC.db, so the macOS Sequoia
#     "Pacer would like to access data from other apps" prompt fires on
#     every launch. Developer ID writes a populated csreq and the grant
#     persists across launches. Signing inside-out (deepest first) is
#     required so each enclosing bundle's signature seals the inner ones.
SIGN_IDENTITY="Developer ID Application: Eric Andrechek (YZXWMJ5VBY)"
APP_ENTITLEMENTS="${REPO_ROOT}/App/Pacer.entitlements"
DAEMON_ENTITLEMENTS="${REPO_ROOT}/Daemon/PacerDaemon.entitlements"
WIDGETS_ENTITLEMENTS="${REPO_ROOT}/Widgets/PacerWidgets.entitlements"
echo
echo "==> Signing with ${SIGN_IDENTITY}"

sign() {
    # $1 = entitlements file (or empty), $2 = path, $3 = optional --identifier override
    #
    # `--timestamp` (Apple's secure timestamp server) is REQUIRED for
    # notarization — `--timestamp=none` would make `xcrun notarytool
    # submit` reject the bundle. Same for `--options runtime` (Hardened
    # Runtime), which is also a notarization gate.
    local entitlements="$1"
    local target="$2"
    local identifier="${3:-}"
    local args=(--force --options runtime --timestamp --sign "${SIGN_IDENTITY}")
    [ -n "${entitlements}" ] && args+=(--entitlements "${entitlements}")
    [ -n "${identifier}" ]  && args+=(--identifier "${identifier}")
    codesign "${args[@]}" "${target}"
}

# Debug-build dylibs (Pacer.debug.dylib, PacerWidgets.debug.dylib,
# __preview.dylib) are produced by Xcode in Debug config and must be
# signed by the SAME Team ID as the loading binary or dyld refuses to
# load them — ad-hoc / unsigned dylibs trip "different Team IDs" at
# launch. Sign these before the bundles that contain them.
while IFS= read -r dylib; do
    [ -e "${dylib}" ] && sign "" "${dylib}"
done < <(find "${BUILD_OUTPUT}" -name "*.dylib" -type f)

# PacerCore resource bundles ride along inside the app and the daemon
# directory; sign them so the parent seals don't break later.
for bundle in \
    "${BUILD_OUTPUT}/Contents/Library/LaunchServices/PacerCore_PacerCore.bundle" \
    "${BUILD_OUTPUT}/Contents/Resources/PacerCore_PacerCore.bundle" \
    "${BUILD_OUTPUT}/Contents/PlugIns/PacerWidgets.appex/Contents/Resources/PacerCore_PacerCore.bundle"; do
    [ -e "${bundle}" ] && sign "" "${bundle}"
done

# Embedded Mach-O binaries (daemon and widget extension binary) get
# their own entitlements; the app extension bundle gets re-sealed
# after its inner binary is signed. The daemon needs an explicit
# --identifier override because it's a tool target with no Info.plist
# CFBundleIdentifier — without this codesign falls back to the binary
# name "PacerDaemon", which TCC sees as a foreign third-party app
# accessing com.ericandrechek.pacer's data (AGENTS.md bug #5).
sign "${DAEMON_ENTITLEMENTS}" "${BUILD_OUTPUT}/Contents/Library/LaunchServices/PacerDaemon" "com.ericandrechek.pacer.daemon"
sign "${WIDGETS_ENTITLEMENTS}" "${BUILD_OUTPUT}/Contents/PlugIns/PacerWidgets.appex/Contents/MacOS/PacerWidgets"
sign "${WIDGETS_ENTITLEMENTS}" "${BUILD_OUTPUT}/Contents/PlugIns/PacerWidgets.appex"

# Outer app bundle last, so its signature covers everything inside.
sign "${APP_ENTITLEMENTS}" "${BUILD_OUTPUT}"

# Verify the whole bundle is consistent before installing.
codesign --verify --deep --strict --verbose=2 "${BUILD_OUTPUT}" 2>&1 \
    | grep -v "^$" | head -5
echo "    signed."

# 2c. Notarize. Apple's notary service issues a ticket the system
#     stapler then attaches to the bundle; with the ticket present,
#     macOS Sequoia treats Allow clicks on the App Management TCC
#     prompt as persistent grants instead of session-scoped ones,
#     which is the whole point of running this step on every dev
#     install (AGENTS.md bug #6). Without a stapled ticket the
#     "would like to access data from other apps" prompt fires on
#     every launch even with Developer ID signing.
#
#     The credential profile `pacer-notarization` is set up once via
#     `xcrun notarytool store-credentials pacer-notarization \
#         --key ~/path/to/AuthKey_*.p8 --key-id <KEY_ID> --issuer <ISSUER>`.
#     If it's missing this script tells the user how to create it
#     and bails — we don't fall through to an unnotarized install,
#     because that produces the every-launch-prompt regression we're
#     trying to fix.
NOTARY_PROFILE="pacer-notarization"
NOTARY_ZIP="$(mktemp -d)/Pacer.zip"

echo
echo "==> Notarizing with Apple (profile: ${NOTARY_PROFILE})"

if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
    echo "ERROR: notarytool credential profile '${NOTARY_PROFILE}' not found."
    echo "Set it up once with:"
    echo "  xcrun notarytool store-credentials ${NOTARY_PROFILE} \\"
    echo "      --key /path/to/AuthKey_<KEY_ID>.p8 \\"
    echo "      --key-id <KEY_ID> --issuer <ISSUER_UUID>"
    echo "Get the .p8 + Key ID + Issuer ID from App Store Connect →"
    echo "Users and Access → Integrations → Team Keys."
    exit 1
fi

# notarytool wants a flat archive, not a directory tree. ditto with
# --keepParent preserves the .app bundle as the top-level entry,
# which is what the notary service expects to find.
ditto -c -k --keepParent "${BUILD_OUTPUT}" "${NOTARY_ZIP}"

# `--wait` blocks until the submission reaches a terminal status
# (Accepted / Invalid / Rejected). Typical wall time is 10-60s for
# small apps; Apple sometimes runs slow (minutes), but failing fast
# on a hung submission isn't useful since the dev loop is blocked
# either way. If you need to bail out, Ctrl-C and re-run.
NOTARY_OUTPUT="$(xcrun notarytool submit "${NOTARY_ZIP}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait 2>&1)"
NOTARY_EXIT=$?

echo "${NOTARY_OUTPUT}" | grep -E '(id:|status:|message:)' | head -10
rm -f "${NOTARY_ZIP}"

if [ ${NOTARY_EXIT} -ne 0 ] || ! echo "${NOTARY_OUTPUT}" | grep -q 'status: Accepted'; then
    SUBMISSION_ID="$(echo "${NOTARY_OUTPUT}" | awk '/^  id:/ {print $2; exit}')"
    echo "ERROR: notarization did not succeed."
    if [ -n "${SUBMISSION_ID}" ]; then
        echo "Fetch the rejection log with:"
        echo "  xcrun notarytool log ${SUBMISSION_ID} --keychain-profile ${NOTARY_PROFILE}"
    fi
    exit 1
fi

# Staple the issued ticket onto the .app so launchd / Gatekeeper /
# TCC don't have to phone home to verify notarization on every
# launch. `xcrun stapler staple` mutates the bundle in place;
# `validate` confirms the ticket is correctly attached.
xcrun stapler staple "${BUILD_OUTPUT}" 2>&1 | tail -3
xcrun stapler validate "${BUILD_OUTPUT}" 2>&1 | tail -1

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
