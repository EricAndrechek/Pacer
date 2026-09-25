#!/bin/zsh
# docs/screenshots/widgets.png — the real PacerWidgets extension, rendered by
# Apple's WidgetKit Simulator, over fixture data. CI only: the simulator opens
# a real, visible window, so this never runs on a person's Mac (AGENTS.md).
#
#   bin/widgetkit-sim-shots.sh <Pacer.app> <capture-request-dir> <out-dir>
#
# Called by bin/dev-screenshots.sh while its capture helper is running (the
# helper owns the 2× virtual display, and photographs for us).
#
# Which widget, at which size: the simulator reads the same environment Xcode
# sets when you run a widget extension's scheme — `_XCWidgetKind`,
# `_XCWidgetFamily` (small / medium / large), `_XCWidgetDefaultView` — and
# `open --env` sets it for us. The build is compiled with
# PACER_WIDGET_FIXTURES (the workflow sets it), so the extension holds only the
# README's widgets, each the real widget view over `WidgetFixtures`
# (`ReadmeShotWidget`).
set -u
[[ ${CI:-} == true ]] || { echo "[widgets] CI only — WidgetKit Simulator opens a visible window"; exit 2; }
(( $# == 3 )) || { echo "usage: $0 <Pacer.app> <request-dir> <out-dir>"; exit 64; }
ROOT=${0:A:h:h}
SRC_APP=$1 REQ=$2 OUT=$3
APP=/Applications/Pacer.app
APPEX=$APP/Contents/PlugIns/PacerWidgets.appex
SIM="WidgetKit Simulator"
WORK=$(mktemp -d)
DEBUG_DIR=
[[ ${PACER_WIDGETSIM_DEBUG:-} == 1 ]] && { DEBUG_DIR=$OUT/debug-widgets; mkdir -p "$DEBUG_DIR"; }

log() { print -r -- "[widgets] $*"; }

# Hand the capture helper one request and wait for it to be handled.
request() {
    local name=$1 json=$2
    rm -f "$REQ/$name.failed"
    print -r -- "$json" > "$REQ/$name.json.tmp" && mv "$REQ/$name.json.tmp" "$REQ/$name.request"
    for _ in $(seq 1 1200); do
        [[ -e $REQ/$name.request ]] || break
        sleep 0.1
    done
    [[ -e $REQ/$name.request ]] && { log "⚠️ $name: capture helper never answered"; return 1; }
    [[ -e $REQ/$name.failed ]] && { log "⚠️ $name: $(<"$REQ/$name.failed")"; return 1; }
    return 0
}

quit_simulator() {
    pkill -x "$SIM" 2>/dev/null
    pkill -x PacerWidgets 2>/dev/null
    for _ in $(seq 1 50); do pgrep -x "$SIM" >/dev/null || break; sleep 0.1; done
}

# Installed where LaunchServices and pluginkit look for extensions.
rm -rf "$APP"
ditto "$SRC_APP" "$APP" 2>/dev/null || sudo ditto "$SRC_APP" "$APP" || { log "cannot install $APP"; exit 1; }
# A document per launch, never a restored one from the launch before.
defaults write com.apple.widgetkit.simulator ApplePersistenceIgnoreState -bool YES
defaults write com.apple.widgetkit.simulator NSQuitAlwaysKeepsWindows -bool NO

# Light, whatever the scenes before left it in (menubar-dark switches the
# whole system to dark): the widgets are photographed on a light desktop.
request widget-appearance '{"kind":"appearance","dark":false}' || exit 1

# Register this copy, and only this one. Launching the app from the build
# directory for the other scenes registered the build's own (unsigned) appex
# under the same identifier, and the simulator loaded that one ("WidgetDocument.
# Error error 5"), so that copy is unregistered.
pluginkit -r "$SRC_APP/Contents/PlugIns/PacerWidgets.appex" 2>/dev/null

# Before each launch: a build number above anything registered before, signed,
# registered. chronod only re-reads an extension's widgets for a new version
# (the build directory's copy was seen, then purged, at the same one), and an
# extension without a signature (and its App Group entitlement) is not
# loaded. Ad-hoc, nested first, no --deep. Not `lsregister -f`: the extension
# was registered, then removed within a second, and the simulator found none.
build=9000
prepare() {
    build=$((build + 1))
    for plist in "$APPEX/Contents/Info.plist" "$APP/Contents/Info.plist"; do
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
    done
    codesign --force -s - --entitlements "$ROOT/Widgets/PacerWidgets.entitlements" "$APPEX" 2>&1 | grep -v "replacing existing signature"
    codesign --force -s - --entitlements "$ROOT/App/Pacer.entitlements" "$APP" 2>&1 | grep -v "replacing existing signature"
    pluginkit -a "$APPEX"
    sleep 1
}

shots=(
    today         TodayCostWidget    small
    pace-gauges   PaceGaugesWidget   medium
    live-session  LiveSessionWidget  medium
    daily-chart   DailyChartWidget   medium
    top-projects  TopProjectsWidget  medium
)
# DIAGNOSIS — temporary: which of (the bundle, the environment) breaks loading.
if [[ -n $DEBUG_DIR ]]; then
    for variant in none kind both; do
        quit_simulator
        defaults delete com.apple.widgetkit.simulator 2>/dev/null
        defaults write com.apple.widgetkit.simulator ApplePersistenceIgnoreState -bool YES
        envs=()
        [[ $variant != none ]] && envs+=(--env _XCWidgetKind=ReadmeShot.TodayCostWidget)
        [[ $variant == both ]] && envs+=(--env _XCWidgetFamily=small)
        prepare
        open -n $envs -a "$SIM" "$APPEX"
        request "diag-$variant" "{\"kind\":\"widgetsim\",\"png\":\"$WORK/diag-$variant.png\",\"debug\":\"$DEBUG_DIR/diag-$variant-window.png\"}" \
            && log "diag $variant: loaded" || log "diag $variant: failed"
    done
    ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i pacer | sed 's/^/[widgets] crash: /'
    for f in ~/Library/Logs/DiagnosticReports/PacerWidgets*(N); do python3 -c "
import json,sys
t=open(sys.argv[1]).read(); body=json.loads(t[t.index(chr(10))+1:])
imgs=body.get('usedImages',[])
for fr in body['threads'][body.get('faultingThread',0)]['frames'][:25]:
    im=imgs[fr['imageIndex']] if fr['imageIndex']<len(imgs) else {}
    print(im.get('name','?'), fr.get('symbol',''), fr.get('imageOffset'))
print('asi:', body.get('asi'))" "$f" 2>&1 | sed 's/^/[widgets] crashlog: /'; done
    /usr/bin/log show --last 5m --style compact --predicate 'process == "PacerWidgets" OR (process == "WidgetKit Simulator" AND NOT eventMessage CONTAINS "file:///System") OR (process == "chronod" AND eventMessage CONTAINS[c] "pacer")' 2>/dev/null \
        | grep -vE 'MobileGestalt|XPCErrors|stateCapture' | grep -iE 'fail|error|descriptor|pacer|kind|family|crash|exception' | head -60 | sed 's/^/[widgets] diaglog: /'
fi

failed=0
for name kind family in $shots; do
    quit_simulator
    # A fresh document per shot, never the last one restored.
    defaults delete com.apple.widgetkit.simulator 2>/dev/null
    defaults write com.apple.widgetkit.simulator ApplePersistenceIgnoreState -bool YES
    defaults write com.apple.widgetkit.simulator NSQuitAlwaysKeepsWindows -bool NO
    prepare
    open -n --env "_XCWidgetKind=ReadmeShot.$kind" --env "_XCWidgetFamily=$family" \
         --env _XCWidgetDefaultView=timeline -a "$SIM" "$APPEX" \
        || { log "⚠️ $name: cannot open $SIM"; failed=1; continue; }
    debug=
    [[ -n $DEBUG_DIR ]] && debug=",\"debug\":\"$DEBUG_DIR/$name-window.png\""
    if request "widget-$name" "{\"kind\":\"widgetsim\",\"png\":\"$WORK/$name.png\"$debug}"; then
        log "✓ $name ($kind, $family)"
    else
        failed=1
        [[ -n $DEBUG_DIR ]] && /usr/bin/log show --last 1m --style compact \
            --predicate 'process == "WidgetKit Simulator" OR (process == "chronod" AND eventMessage CONTAINS "pacer")' 2>/dev/null \
            | grep -iE 'fail|error|descriptor|pacer' | head -25 | sed "s/^/[widgets] $name log: /"   # DIAGNOSIS — temporary
    fi
done
quit_simulator
(( failed )) && { log "not composing widgets.png: a widget failed"; exit 1; }

request widget-gallery "{\"kind\":\"gallery\",\"png\":\"$OUT/widgets.png\",\"rows\":[[\"$WORK/today.png\",\"$WORK/pace-gauges.png\"],[\"$WORK/live-session.png\",\"$WORK/daily-chart.png\"],[\"$WORK/top-projects.png\"]]}" || exit 1
[[ -n $DEBUG_DIR ]] && cp "$WORK"/*.png "$DEBUG_DIR/"
rm -rf "$WORK"
log "✓ widgets.png"
