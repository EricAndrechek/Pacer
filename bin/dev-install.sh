#!/bin/bash
# Build, sign, notarize, and install Pacer for daily-driver dev use.
#
# Single-binary architecture: the old separate `PacerDaemon` LaunchAgent
# was retired; data collection now runs inside the app process. This
# script builds + signs + notarizes the .app, replaces /Applications/
# Pacer.app, and (idempotently) cleans up any leftover legacy daemon
# launchctl registration from prior installs. Re-opens Pacer.app at the
# end if it was running before the install.
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
# Resolved after the build — the product dir under -derivedDataPath
# varies by Xcode version (newer emits <ddp>/Products/Debug, CI/older
# emits <ddp>/Build/Products/Debug). See the resolver below.
BUILD_OUTPUT=""

# Legacy daemon labels — retired in favor of in-process collection,
# but old installs may still have these registered. We bootout and
# remove any leftover plist on every install so the migration is
# automatic.
LEGACY_DEV_LABEL="com.ericandrechek.pacer.daemon.dev"
LEGACY_SMAPP_LABEL="com.ericandrechek.pacer.daemon"
LEGACY_DEV_PLIST="$HOME/Library/LaunchAgents/${LEGACY_DEV_LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/Pacer"

RESTORE_APP=0
if [ "${1:-}" = "--restore-app" ]; then
    RESTORE_APP=1
fi

echo "==> Pacer dev install"
echo "    repo:   ${REPO_ROOT}"
echo "    target: ${INSTALLED_APP}"
echo "    logs:   ${LOG_DIR}"

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
#
#    CFBundleVersion (CURRENT_PROJECT_VERSION) is stamped with the build
#    time as a unix timestamp, exactly like the release workflow does.
#    Sparkle orders updates by CFBundleVersion (its sparkle:version), so
#    the in-repo default of "1" sits *below* every published release's
#    timestamp — which made Sparkle offer to "update" a freshly-built
#    dev app back to the public DMG (silently replacing your local
#    build). Stamping the build time makes a fresh local build always
#    >= the latest release, so a manual "Check for Updates…" correctly
#    reports up to date. (Debug builds also suppress *automatic* checks
#    entirely — see PacerUpdater.swift — so this covers the manual path.)
#    The override applies to both the app and the widget extension, which
#    macOS requires to share a version.
DEV_BUILD_VERSION="$(date -u +%s)"
echo
echo "==> Building Pacer.app (Debug, unsigned, build ${DEV_BUILD_VERSION})"
xcodebuild \
    -project Pacer.xcodeproj \
    -scheme Pacer \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${REPO_ROOT}/Build" \
    CURRENT_PROJECT_VERSION="${DEV_BUILD_VERSION}" \
    build \
    | (grep -E '(error:|warning:|FAILED|SUCCEEDED)' || true)

# Locate the built bundle by its stable suffix. Both Xcode product-dir
# layouts end in Products/Debug/Pacer.app, so resolving by suffix is
# version-proof — a hardcoded path breaks whenever the maintainer's and
# CI's toolchains disagree on the <derivedDataPath>/[Build/]Products nesting.
BUILD_OUTPUT="$(find "${REPO_ROOT}/Build" -type d -name "${APP_NAME}" -path "*/Products/Debug/*" | head -1)"
if [ -z "${BUILD_OUTPUT}" ] || [ ! -d "${BUILD_OUTPUT}" ]; then
    echo "ERROR: build did not produce ${APP_NAME} under ${REPO_ROOT}/Build"
    find "${REPO_ROOT}/Build" -name "${APP_NAME}" -type d 2>/dev/null | head -5
    exit 1
fi
echo "    built: ${BUILD_OUTPUT}"

# 2b. Manually sign every binary inside the .app with Developer ID
#     Application. This is what the eventual Sparkle release will use,
#     and matters during dev too: Apple Development-signed binaries
#     don't get a csreq blob written into TCC.db. Developer ID writes a
#     populated csreq and the grant persists across launches. Signing
#     inside-out (deepest first) is required so each enclosing bundle's
#     signature seals the inner ones.
SIGN_IDENTITY="Developer ID Application: Eric Andrechek (YZXWMJ5VBY)"
APP_ENTITLEMENTS="${REPO_ROOT}/App/Pacer.entitlements"
WIDGETS_ENTITLEMENTS="${REPO_ROOT}/Widgets/PacerWidgets.entitlements"
echo
echo "==> Signing with ${SIGN_IDENTITY}"

sign() {
    # $1 = entitlements file (or empty), $2 = path
    #
    # `--timestamp` (Apple's secure timestamp server) is REQUIRED for
    # notarization. Same for `--options runtime` (Hardened Runtime).
    local entitlements="$1"
    local target="$2"
    local args=(--force --options runtime --timestamp --sign "${SIGN_IDENTITY}")
    [ -n "${entitlements}" ] && args+=(--entitlements "${entitlements}")
    codesign "${args[@]}" "${target}"
}

# Debug-build dylibs (Pacer.debug.dylib, PacerWidgets.debug.dylib,
# __preview.dylib) are produced by Xcode in Debug config and must be
# signed by the SAME Team ID as the loading binary or dyld refuses to
# load them. Sign these before the bundles that contain them.
while IFS= read -r dylib; do
    [ -e "${dylib}" ] && sign "" "${dylib}"
done < <(find "${BUILD_OUTPUT}" -name "*.dylib" -type f)

# Sparkle.framework ships with embedded XPC services + helper
# executables (Autoupdate, Updater.app, Downloader.xpc, Installer.xpc).
# All of them have to be signed by the same Team ID as the host app
# or Sparkle's update flow will refuse to launch them. Sign deepest-
# first so each enclosing seal covers the inner signatures. The Sparkle
# README is explicit about this ordering; --deep is *not* the right
# answer (it overwrites existing internal signatures, and Apple's docs
# now flag it as deprecated).
SPARKLE_FW="${BUILD_OUTPUT}/Contents/Frameworks/Sparkle.framework"
if [ -d "${SPARKLE_FW}" ]; then
    # XPC services (Downloader, Installer): bundle binary then bundle.
    while IFS= read -r xpc; do
        xpc_name="$(basename "${xpc}" .xpc)"
        [ -e "${xpc}/Contents/MacOS/${xpc_name}" ] && \
            sign "" "${xpc}/Contents/MacOS/${xpc_name}"
        sign "" "${xpc}"
    done < <(find "${SPARKLE_FW}" -name "*.xpc" -type d)

    # The Autoupdate helper executable + the Updater.app helper bundle
    # inside the framework's Versions/B/.
    for helper in \
        "${SPARKLE_FW}/Versions/Current/Autoupdate" \
        "${SPARKLE_FW}/Versions/Current/Updater.app"; do
        [ -e "${helper}" ] && sign "" "${helper}"
    done

    # Finally the framework itself. Sign by Versions/Current path so
    # the version-resolved symlink chain stays valid.
    sign "" "${SPARKLE_FW}"
fi

# PacerCore resource bundles ride along inside the app and the widget
# extension; sign them so the parent seals don't break later.
for bundle in \
    "${BUILD_OUTPUT}/Contents/Resources/PacerCore_PacerCore.bundle" \
    "${BUILD_OUTPUT}/Contents/PlugIns/PacerWidgets.appex/Contents/Resources/PacerCore_PacerCore.bundle"; do
    [ -e "${bundle}" ] && sign "" "${bundle}"
done

# Widget extension binary, then the .appex itself.
sign "${WIDGETS_ENTITLEMENTS}" "${BUILD_OUTPUT}/Contents/PlugIns/PacerWidgets.appex/Contents/MacOS/PacerWidgets"
sign "${WIDGETS_ENTITLEMENTS}" "${BUILD_OUTPUT}/Contents/PlugIns/PacerWidgets.appex"

# Outer app bundle last, so its signature covers everything inside.
sign "${APP_ENTITLEMENTS}" "${BUILD_OUTPUT}"

# Verify the whole bundle is consistent before installing.
codesign --verify --deep --strict --verbose=2 "${BUILD_OUTPUT}" 2>&1 \
    | grep -v "^$" | head -5
echo "    signed."

# 2c. Notarize. Apple's notary service issues a ticket the system
#     stapler then attaches to the bundle. Without notarization the
#     "would like to access data from other apps" prompt fires on
#     every launch even with Developer ID signing.
#
# `PACER_DEV_SKIP_NOTARIZE=1` skips this whole step. Use only for
# rapid local-only perf iteration — the resulting bundle works on
# this machine for the running user (Developer ID + Gatekeeper grant
# is enough) but will trip TCC's "App Management" prompt on every
# launch and won't open on other machines. The NEXT non-skip install
# re-notarizes and clears the prompt.
NOTARY_PROFILE="pacer-notarization"
NOTARY_ZIP="$(mktemp -d)/Pacer.zip"

if [ "${PACER_DEV_SKIP_NOTARIZE:-0}" = "1" ]; then
    echo
    echo "==> Skipping notarization (PACER_DEV_SKIP_NOTARIZE=1)"
    echo "    note: TCC App-Management prompt may fire on launch"
else

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
    echo
    echo "For rapid local-only iteration without notarization:"
    echo "  PACER_DEV_SKIP_NOTARIZE=1 make install"
    exit 1
fi

ditto -c -k --keepParent "${BUILD_OUTPUT}" "${NOTARY_ZIP}"

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

xcrun stapler staple "${BUILD_OUTPUT}" 2>&1 | tail -3
xcrun stapler validate "${BUILD_OUTPUT}" 2>&1 | tail -1
fi  # PACER_DEV_SKIP_NOTARIZE

# 3a. Quit Pacer.app if running, capturing whether it was so we can
#     re-open at the end.
echo
echo "==> Quitting any running Pacer.app GUI"
APP_WAS_RUNNING="$("${REPO_ROOT}/bin/dev-quit-app.sh")"

# 3a'. Migrate SwiftData store + UserDefaults plist from the legacy
#      `group.com.ericandrechek.pacer` container to the new TeamID-
#      prefixed `YZXWMJ5VBY.com.ericandrechek.pacer` container.
#
#      Why we do this in shell at this point in the install:
#        - The OLD app/widget processes are guaranteed quit (step 3a).
#        - The NEW app bundle isn't yet copied to /Applications, so its
#          widget extension cannot launch and pre-create an empty new
#          container that would then race a shell `cp`.
#        - Idempotent: skipped if the new container already has data, so
#          re-running `make install` after a successful migration is a
#          no-op.
#
#      The legacy `group.X` prefix triggers the macOS Sequoia App
#      Management TCC prompt on every launch; the new TeamID-prefixed
#      identifier does not. See docs/research/tcc-app-management.md.
LEGACY_CONTAINER="$HOME/Library/Group Containers/group.com.ericandrechek.pacer"
NEW_CONTAINER="$HOME/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"

if [ -f "${LEGACY_CONTAINER}/pacer.sqlite" ] && [ ! -f "${NEW_CONTAINER}/pacer.sqlite" ]; then
    echo
    echo "==> Migrating SwiftData store from legacy container"
    mkdir -p "${NEW_CONTAINER}"
    # Copy the live SQLite plus the WAL/SHM sidecars so SwiftData picks
    # up uncheckpointed writes too. Use cp -p to preserve mtimes — the
    # daemon's `JSONLFileCursor` uses sample timestamps, not file mtimes,
    # so this is cosmetic, but keeps audit logs sensible.
    cp -p "${LEGACY_CONTAINER}/pacer.sqlite" "${NEW_CONTAINER}/"
    [ -f "${LEGACY_CONTAINER}/pacer.sqlite-wal" ] && \
        cp -p "${LEGACY_CONTAINER}/pacer.sqlite-wal" "${NEW_CONTAINER}/"
    [ -f "${LEGACY_CONTAINER}/pacer.sqlite-shm" ] && \
        cp -p "${LEGACY_CONTAINER}/pacer.sqlite-shm" "${NEW_CONTAINER}/"
    size=$(wc -c <"${NEW_CONTAINER}/pacer.sqlite" | tr -d ' ')
    echo "    copied pacer.sqlite (${size} bytes)"
fi

# UserDefaults plist for an App Group lives at
#   <container>/Library/Preferences/<group-id>.plist
# Filename mirrors the suite identifier, so we copy *and* rename. The
# new app's UserDefaults(suiteName: PacerStore.appGroupIdentifier) reads
# this on first launch.
LEGACY_PREFS="${LEGACY_CONTAINER}/Library/Preferences/group.com.ericandrechek.pacer.plist"
NEW_PREFS="${NEW_CONTAINER}/Library/Preferences/YZXWMJ5VBY.com.ericandrechek.pacer.plist"
if [ -f "${LEGACY_PREFS}" ] && [ ! -f "${NEW_PREFS}" ]; then
    echo "==> Migrating UserDefaults plist"
    mkdir -p "$(dirname "${NEW_PREFS}")"
    cp -p "${LEGACY_PREFS}" "${NEW_PREFS}"
    echo "    copied $(basename "${LEGACY_PREFS}") -> $(basename "${NEW_PREFS}")"
fi

# 3b. Migrate away from any leftover legacy daemon. Old installs had
#     a `com.ericandrechek.pacer.daemon.dev` LaunchAgent that's no
#     longer part of this architecture; bootout the label and remove
#     the plist so we don't have a zombie daemon racing the new
#     in-process collection.
echo
echo "==> Cleaning up legacy daemon registration (if present)"
bootout_label() {
    local label="$1"
    if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        echo "    bootout: ${label}"
    fi
}
bootout_label "${LEGACY_DEV_LABEL}"
bootout_label "${LEGACY_SMAPP_LABEL}"

if [ -f "${LEGACY_DEV_PLIST}" ]; then
    rm -f "${LEGACY_DEV_PLIST}"
    echo "    removed: ${LEGACY_DEV_PLIST}"
fi

# Kill any orphan daemon process that bootout couldn't reach (e.g. one
# launched directly via the old `make daemon-fg` flow before this
# refactor).
DAEMON_PATH_REGEX='/Pacer\.app/Contents/Library/LaunchServices/PacerDaemon$'
if pids="$(pgrep -f "${DAEMON_PATH_REGEX}" 2>/dev/null)" && [ -n "${pids}" ]; then
    # shellcheck disable=SC2086 -- intentional word-split on PID list
    kill -TERM ${pids} 2>/dev/null || true
    sleep 2
    if pids="$(pgrep -f "${DAEMON_PATH_REGEX}" 2>/dev/null)" && [ -n "${pids}" ]; then
        # shellcheck disable=SC2086
        kill -KILL ${pids} 2>/dev/null || true
    fi
    echo "    killed orphan daemon process(es)"
fi

# 4. Replace the installed app. /Applications is user-owned on macOS
#    for non-system apps, and this script explicitly targets just the
#    Pacer.app inside it.
echo
echo "==> Installing to ${INSTALLED_APP}"
rm -rf "${INSTALLED_APP}"
cp -R "${BUILD_OUTPUT}" "${INSTALL_DIR}/"

# 5. Ensure log directory exists. The app process writes its own
#    timestamped log lines into PacerDaemon.err.log here (the file
#    name is kept for backwards compat with `make logs`).
echo
echo "==> Preparing log directory at ${LOG_DIR}"
mkdir -p "${LOG_DIR}"

if [ "${APP_WAS_RUNNING}" = "1" ] || [ "${RESTORE_APP}" = "1" ]; then
    echo
    echo "==> Re-opening Pacer.app (was running before install)"
    open "${INSTALLED_APP}"
fi

echo
echo "Done. Open the dashboard with: make open"
echo "Tail logs with:                make logs"
echo "Status check:                  make status"
