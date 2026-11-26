#!/usr/bin/env bash
# update-e2e.sh — Pacer's update path end to end, on a disposable Mac (#470).
#
#   bin/update-e2e.sh                prints the plan and exits; runs nothing
#   bin/update-e2e.sh build <dir>    builds versions A (1) < B (2) < C (3) of the
#                                    test app and their signed archives; launches
#                                    nothing, so it is safe anywhere
#   bin/update-e2e.sh run <dir>      the scenarios. Refuses unless this is a
#                                    GitHub-hosted runner (or
#                                    PACER_UPDATE_E2E_DISPOSABLE_MAC=yes on a VM)
#
# The test app (UpdateE2E/) is Pacer's own update code, App/Update compiled
# verbatim, against the Sparkle Pacer ships. It replaces itself, which is why
# `run` never happens on a Mac someone uses (docs/releasing.md, "Testing the
# update path end to end"): a Sparkle client keeps its state in its host's defaults
# and touches LaunchServices.
#
# The archives are signed with an EdDSA key made in <dir> by
# bin/sparkle-eddsa.swift keygen. Never the release key.
#
# Scenarios (`run`):
#   1. newest once: A launches with B in the feed and defers it (no archive is
#      requested); C is added and replaces B as the pending update, still with no
#      download; at the install moment A downloads C, only C, and relaunches into
#      it, once.
#   2. download failure: C's archive answers 404. A stays on A, retries at its
#      spacing, never falls back to B; once the archive is back, it installs C.
#
# Everything is read from the app's own log (Pacer's [Update] lines and the test
# app's STATUS lines), the feed server's request log, and the installed
# bundle's Info.plist. Failures print all three. Exit 0 only if every check holds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME=PacerUpdateE2E
BUNDLE_ID=com.ericandrechek.pacer.update-e2e
PORT=8471
FEED_URL="http://127.0.0.1:${PORT}"
INSTALL_DIR="${HOME}/Applications"
APP="${INSTALL_DIR}/${APP_NAME}.app"
HANDLES="${HOME}/Library/Application Support/PacerUpdateE2E"
LOG="${HANDLES}/app.log"
# The test app's PacerPreferences suite: the App Group's name, which an
# unentitled app reads and writes as a plain user-domain plist.
PACER_SUITE=YZXWMJ5VBY.com.ericandrechek.pacer

plan() {
    sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "update-e2e: $*" >&2; exit 1; }
say() { echo "==> $*"; }

failures=0
check() {
    # check <description> <command...>: one assertion, reported either way.
    local what="$1"; shift
    if "$@"; then
        echo "  ok    ${what}"
    else
        echo "  FAIL  ${what}"
        failures=$((failures + 1))
    fi
}

abs() { mkdir -p "$1" && (cd "$1" && pwd); }

# ---- build -----------------------------------------------------------------

codesign_adhoc() { codesign --force --sign - "$1" 2>&1 | (grep -v 'replacing existing signature' || true); }

sign_app() {
    # Inside-out, as bin/dev-install.sh signs Pacer, ad hoc.
    local app="$1" sp="$1/Contents/Frameworks/Sparkle.framework" xpc name
    while IFS= read -r xpc; do
        name="$(basename "${xpc}" .xpc)"
        [ -e "${xpc}/Contents/MacOS/${name}" ] && codesign_adhoc "${xpc}/Contents/MacOS/${name}"
        codesign_adhoc "${xpc}"
    done < <(find "${sp}" -name "*.xpc" -type d)
    for helper in "${sp}/Versions/Current/Autoupdate" "${sp}/Versions/Current/Updater.app"; do
        [ -e "${helper}" ] && codesign_adhoc "${helper}"
    done
    codesign_adhoc "${sp}"
    [ -e "${app}/Contents/Resources/PacerCore_PacerCore.bundle" ] && \
        codesign_adhoc "${app}/Contents/Resources/PacerCore_PacerCore.bundle"
    codesign_adhoc "${app}"
    codesign --verify --deep --strict "${app}"
}

build() {
    local out; out="$(abs "$1")"
    command -v xcodegen >/dev/null || die "xcodegen is needed (brew install xcodegen)"
    rm -rf "${out}/v1" "${out}/v2" "${out}/v3" "${out}/archives"
    mkdir -p "${out}/archives"
    if [ ! -f "${out}/test.key" ]; then
        swift "${REPO_ROOT}/bin/sparkle-eddsa.swift" keygen "${out}/test.key" >/dev/null
    fi
    local pub; pub="$(swift "${REPO_ROOT}/bin/sparkle-eddsa.swift" pubkey "${out}/test.key")"
    say "test EdDSA public key ${pub} (generated here; not the release key)"
    (cd "${REPO_ROOT}" && xcodegen generate --spec UpdateE2E/project.yml --quiet)
    local n product built
    for n in 1 2 3; do
        say "building version ${n} (0.0.${n})"
        xcodebuild -project "${REPO_ROOT}/UpdateE2E/${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" \
            -configuration Release -destination 'platform=macOS' -derivedDataPath "${out}/dd" \
            MARKETING_VERSION="0.0.${n}" CURRENT_PROJECT_VERSION="${n}" \
            E2E_PUBLIC_KEY="${pub}" E2E_FEED_URL="${FEED_URL}/appcast.xml" \
            build 2>&1 | (grep -E '(error:|warning: .*(App/Update|UpdateE2E)|BUILD SUCCEEDED|BUILD FAILED)' || true)
        # Where Xcode puts products under -derivedDataPath moves between
        # versions, and a project-relative build location wins over it on some
        # setups (AGENTS.md, "Build-path drift"): find it by its suffix.
        local roots=() root
        for root in "${out}/dd" "${REPO_ROOT}/UpdateE2E/Build"; do [ -d "${root}" ] && roots+=("${root}"); done
        product="$(find "${roots[@]}" -type d -path "*/Products/Release/${APP_NAME}.app" -prune 2>/dev/null | head -1 || true)"
        [ -n "${product}" ] || die "no ${APP_NAME}.app product for version ${n}"
        mkdir -p "${out}/v${n}"
        ditto "${product}" "${out}/v${n}/${APP_NAME}.app"
        built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${out}/v${n}/${APP_NAME}.app/Contents/Info.plist")"
        [ "${built}" = "${n}" ] || die "version ${n} came out as build ${built}"
        [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${out}/v${n}/${APP_NAME}.app/Contents/Info.plist")" = "${pub}" ] \
            || die "version ${n} does not carry the test key"
        sign_app "${out}/v${n}/${APP_NAME}.app"
        if [ "${n}" != 1 ]; then
            local zip="${out}/archives/${APP_NAME}-${n}.zip"
            ditto -c -k --sequesterRsrc --keepParent "${out}/v${n}/${APP_NAME}.app" "${zip}"
            local sig len
            sig="$(swift "${REPO_ROOT}/bin/sparkle-eddsa.swift" sign "${out}/test.key" "${zip}")"
            len="$(stat -f %z "${zip}")"
            [ "$(swift "${REPO_ROOT}/bin/sparkle-eddsa.swift" verify "${pub}" "${sig}" "${zip}")" = OK ] \
                || die "signature of ${zip} does not verify"
            printf '%s %s\n' "${sig}" "${len}" > "${zip}.meta"
        fi
    done
    say "built A, B, C in ${out}"
}

# ---- run -------------------------------------------------------------------

require_disposable() {
    if [ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; then
        return
    fi
    [ "${PACER_UPDATE_E2E_DISPOSABLE_MAC:-}" = yes ] && return
    die "run replaces an app, writes its defaults and LaunchServices records, and kills its processes: only on a GitHub-hosted runner, or a VM with PACER_UPDATE_E2E_DISPOSABLE_MAC=yes"
}

write_feed() {
    # write_feed <out> <build>...: an appcast offering those builds.
    local out="$1"; shift
    python3 -I - "${out}" "${FEED_URL}" "${APP_NAME}" "$@" <<'PY'
import os, sys
from email.utils import formatdate
out, base, name, *builds = sys.argv[1:]
items = []
for n in sorted(builds, key=int, reverse=True):
    meta = os.path.join(out, "archives", f"{name}-{n}.zip.meta")
    sig, length = open(meta).read().split()
    items.append(f"""    <item>
      <title>{name} 0.0.{n}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{n}</sparkle:version>
      <sparkle:shortVersionString>0.0.{n}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="{base}/{name}-{n}.zip" length="{length}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
    </item>""")
feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>{name}</title>
{chr(10).join(items)}
  </channel>
</rss>
"""
path = os.path.join(out, "feed", "appcast.xml")
tmp = path + ".tmp"
open(tmp, "w").write(feed)
os.replace(tmp, path)
PY
}

server_pid=""
start_server() {
    local out="$1"
    stop_server
    : > "${out}/server.log"
    python3 -I -u -m http.server "${PORT}" --bind 127.0.0.1 --directory "${out}/feed" \
        >>"${out}/server.log" 2>&1 &
    server_pid=$!
    local _
    for _ in $(seq 1 50); do
        curl -fsS -o /dev/null "${FEED_URL}/appcast.xml" 2>/dev/null && return
        sleep 0.2
    done
    die "the feed server did not come up"
}
stop_server() {
    if [ -n "${server_pid}" ]; then
        kill "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    server_pid=""
}

evidence() {
    # What the scenario rests on, printed passing or not: Pacer's [Update]
    # lines, the test app's launches and STATUS changes, and every archive
    # request the server answered.
    local out="$1"
    echo "  -- app log ([Update], launches, STATUS)"
    grep -E '\[(Update|E2E)\]' "${LOG}" 2>/dev/null | sed 's/^/     /' || true
    echo "  -- archive requests"
    grep -E 'GET /[^ ]+\.zip' "${out}/server.log" 2>/dev/null | sed 's/^/     /' || true
}

app_pids() { pgrep -x "${APP_NAME}" || true; }

stop_app() {
    local pid
    for pid in $(app_pids); do kill "${pid}" 2>/dev/null || true; done
    local _
    for _ in $(seq 1 50); do
        [ -z "$(app_pids)" ] && break
        sleep 0.2
    done
    for pid in $(app_pids); do kill -9 "${pid}" 2>/dev/null || true; done
    # Sparkle's installer and progress agent are launchd jobs named after the
    # host; a finished install leaves none, a failed scenario might.
    launchctl list 2>/dev/null | awk -v id="${BUNDLE_ID}" 'index($3, id) == 1 { print $3 }' \
        | while read -r label; do launchctl remove "${label}" 2>/dev/null || true; done
}

reset() {
    local out="$1"
    stop_app
    rm -rf "${APP}" "${HANDLES}" "${HOME}/Library/Caches/${BUNDLE_ID}"
    mkdir -p "${INSTALL_DIR}" "${HANDLES}" "${out}/feed"
    rm -f "${out}/feed/"*
    defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
    defaults delete "${PACER_SUITE}" >/dev/null 2>&1 || true
    ditto "${out}/v1/${APP_NAME}.app" "${APP}"
    : > "${LOG}"
}

publish() {
    # publish <out> <build>...: put those archives on the server.
    local out="$1"; shift
    local n
    for n in "$@"; do cp "${out}/archives/${APP_NAME}-${n}.zip" "${out}/feed/"; done
}

launch() {
    open -g "${APP}" 2>/dev/null || {
        echo "  (open failed; starting the executable directly)"
        "${APP}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 &
    }
}

wait_for() {
    # wait_for <seconds> <description> <extended regex on the app log>
    local seconds="$1" what="$2" pattern="$3" _
    for _ in $(seq 1 $((seconds * 2))); do
        if grep -Eq -- "${pattern}" "${LOG}" 2>/dev/null; then
            echo "  ok    ${what}"
            return 0
        fi
        sleep 0.5
    done
    echo "  FAIL  ${what} (no line matching /${pattern}/ within ${seconds} s)"
    failures=$((failures + 1))
    return 1
}

requests() {
    # requests <out> <path> <status>: how many times the server answered that.
    grep -Ec "\"GET /$2 HTTP/[0-9.]+\" $3 " "$1/server.log" 2>/dev/null || true
}
eq() { [ "$1" = "$2" ]; }
ge() { [ "$1" -ge "$2" ]; }
log_count() { grep -Ec -- "$1" "${LOG}" 2>/dev/null || true; }
installed_build() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP}/Contents/Info.plist" 2>/dev/null || echo none; }

dump() {
    local out="$1"
    echo "---- app log (${LOG})"
    cat "${LOG}" 2>/dev/null || true
    echo "---- feed server log"
    cat "${out}/server.log" 2>/dev/null || true
    echo "---- appcast"
    cat "${out}/feed/appcast.xml" 2>/dev/null || true
    echo "---- Sparkle (unified log, last 15 min)"
    log show --last 15m --style compact \
        --predicate "process == \"${APP_NAME}\" OR process == \"Autoupdate\" OR process == \"Updater\"" 2>/dev/null \
        | tail -200 || true
    echo "---- processes"
    pgrep -fl "${APP_NAME}|Autoupdate|Updater" || true
}

scenario_newest_once() {
    local out="$1"
    say "scenario 1: A defers B, then C; installs C once at the install moment"
    reset "${out}"
    publish "${out}" 2 3
    write_feed "${out}" 2
    start_server "${out}"
    launch
    wait_for 60 "A (build 1) launched" 'launched build=1 ' || return
    wait_for 120 "A found B and deferred it" 'STATUS phase=available offered=0\.0\.2 .*outcome=available@0\.0\.2' || return
    check "B's archive was never requested" eq "$(grep -c '\.zip' "${out}/server.log" || true)" 0
    check "the deferral is no error and no download" eq "$(log_count '\[Update\] (downloading|installing) ')" 0

    write_feed "${out}" 2 3
    touch "${HANDLES}/check-now"
    wait_for 60 "a later check sees C and C replaces B as pending" \
        'STATUS phase=available offered=0\.0\.3 .*outcome=available@0\.0\.3' || return
    check "still nothing downloaded" eq "$(grep -c '\.zip' "${out}/server.log" || true)" 0

    touch "${HANDLES}/install-now"
    wait_for 60 "the install moment arms" '\[Update\] arming for 0\.0\.3 \(policy\)' || return
    wait_for 240 "A installed C and relaunched into it" 'launched build=3 ' || return
    rm -f "${HANDLES}/install-now"
    # Long enough for a second install to show if there were one.
    sleep 20
    check "C's archive downloaded exactly once" eq "$(requests "${out}" "${APP_NAME}-3.zip" 200)" 1
    check "B's archive never requested" eq "$(grep -c "GET /${APP_NAME}-2.zip" "${out}/server.log" || true)" 0
    check "one install: Pacer's install line once" eq "$(log_count '\[Update\] installing 0\.0\.3 ')" 1
    check "two launches in all, A then C, never B" eq "$(log_count 'launched build=')" 2
    check "never launched as B" eq "$(log_count 'launched build=2 ')" 0
    check "the installed bundle is C" eq "$(installed_build)" 3
    check "one copy running" eq "$(app_pids | wc -l | tr -d ' ')" 1
    # The pending update was deferred on build 1: C starts clean, and counts
    # the armed install that brought it here.
    wait_for 30 "C starts with nothing pending and counts update.arm.installed" \
        'STATUS phase=idle .*update\.arm\.installed=1' || true
    evidence "${out}"
    stop_app
    stop_server
}

scenario_download_404() {
    local out="$1"
    say "scenario 2: C's archive 404s; A stays on A and retries; then installs C"
    reset "${out}"
    publish "${out}" 2
    write_feed "${out}" 2 3
    start_server "${out}"
    launch
    wait_for 60 "A (build 1) launched" 'launched build=1 ' || return
    wait_for 120 "A found C and deferred it" 'STATUS phase=available offered=0\.0\.3 ' || return
    touch "${HANDLES}/install-now"
    # armSpacing is 10 s in the test app: two attempts inside half a minute.
    wait_for 120 "two arm attempts ended in a failed download" \
        'STATUS .*update\.arm\.download_failed=2' || return
    check "A is still A" eq "$(installed_build)" 1
    check "A never relaunched" eq "$(log_count 'launched build=')" 1
    check "A is still running" eq "$(app_pids | wc -l | tr -d ' ')" 1
    check "C's archive was asked for again after the 404" ge "$(requests "${out}" "${APP_NAME}-3.zip" 404)" 2
    check "never fell back to B" eq "$(grep -c "GET /${APP_NAME}-2.zip" "${out}/server.log" || true)" 0
    check "the failures leave C pending" ge "$(log_count 'STATUS phase=available offered=0\.0\.3 ')" 1

    publish "${out}" 3
    wait_for 240 "with the archive back, the next attempt installs C" 'launched build=3 ' || return
    rm -f "${HANDLES}/install-now"
    sleep 20
    check "C's archive downloaded exactly once" eq "$(requests "${out}" "${APP_NAME}-3.zip" 200)" 1
    check "two launches in all" eq "$(log_count 'launched build=')" 2
    check "the installed bundle is C" eq "$(installed_build)" 3
    evidence "${out}"
    stop_app
    stop_server
}

run() {
    require_disposable
    local out; out="$(abs "$1")"
    [ -d "${out}/v1/${APP_NAME}.app" ] && [ -f "${out}/archives/${APP_NAME}-3.zip" ] \
        || die "nothing built in ${out}: run 'bin/update-e2e.sh build ${out}' first"
    trap 'stop_app; stop_server' EXIT
    sw_vers | sed 's/^/  /'
    scenario_newest_once "${out}" || true
    [ "${failures}" -eq 0 ] || { dump "${out}"; }
    local before="${failures}"
    scenario_download_404 "${out}" || true
    [ "${failures}" -eq "${before}" ] || { dump "${out}"; }
    if [ "${failures}" -eq 0 ]; then
        say "update e2e: every check held"
    else
        die "update e2e: ${failures} check(s) failed"
    fi
}

case "${1:-}" in
    build) [ $# -eq 2 ] || die "usage: bin/update-e2e.sh build <dir>"; build "$2" ;;
    run) [ $# -eq 2 ] || die "usage: bin/update-e2e.sh run <dir>"; run "$2" ;;
    "") plan ;;
    *) die "unknown command '$1' (build, run, or nothing for the plan)" ;;
esac
