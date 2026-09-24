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
# How each widget is chosen. The simulator opens an extension on its first
# widget kind, in that kind's first family, and has no documented way to ask
# for another. So the extension is made to have exactly one of each: the build
# is compiled with PACER_WIDGET_FIXTURES (the workflow sets it), which makes
# every provider serve `WidgetFixtures` and every widget offer only the family
# the README shows; `PacerFixtureKind` in the extension's Info.plist then
# leaves only one kind with any family at all. The widget types, views,
# configuration and the system's rendering are the shipping ones.
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

# Installed where LaunchServices and pluginkit look for extensions; the build
# is unsigned, and an extension without a signature (and its App Group
# entitlement) is not loaded. Ad-hoc, nested first, no --deep.
rm -rf "$APP"
ditto "$SRC_APP" "$APP" 2>/dev/null || sudo ditto "$SRC_APP" "$APP" || { log "cannot install $APP"; exit 1; }
# A document per launch, never a restored one from the launch before.
defaults write com.apple.widgetkit.simulator ApplePersistenceIgnoreState -bool YES
defaults write com.apple.widgetkit.simulator NSQuitAlwaysKeepsWindows -bool NO

# name, kind — the gallery's order; the family is WidgetFixtures.readmeShots'.
shots=(
    today         TodayCostWidget
    pace-gauges   PaceGaugesWidget
    live-session  LiveSessionWidget
    daily-chart   DailyChartWidget
    top-projects  TopProjectsWidget
)
failed=0 version=100
for name kind in $shots; do
    quit_simulator
    version=$(( version + 1 ))
    for plist in "$APPEX/Contents/Info.plist" "$APP/Contents/Info.plist"; do
        # A fresh build number per kind: nothing may serve the previous kind's
        # descriptors from a cache keyed on the bundle version.
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$plist"
    done
    /usr/libexec/PlistBuddy -c "Delete :PacerFixtureKind" "$APPEX/Contents/Info.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :PacerFixtureKind string $kind" "$APPEX/Contents/Info.plist"
    codesign --force -s - --entitlements "$ROOT/Widgets/PacerWidgets.entitlements" "$APPEX" 2>&1 | grep -v "replacing existing signature"
    codesign --force -s - --entitlements "$ROOT/App/Pacer.entitlements" "$APP" 2>&1 | grep -v "replacing existing signature"
    pluginkit -a "$APPEX"
    open -a "$SIM" "$APPEX" || { log "⚠️ $name: cannot open $SIM"; failed=1; continue; }
    debug=
    [[ -n $DEBUG_DIR ]] && debug=",\"debug\":\"$DEBUG_DIR/$name-window.png\""
    if request "widget-$name" "{\"kind\":\"widgetsim\",\"png\":\"$WORK/$name.png\"$debug}"; then
        log "✓ $name ($kind)"
    else
        failed=1
    fi
    if [[ -n $DEBUG_DIR && $name == today ]]; then
        # What the simulator exposes, for whoever next needs to drive it.
        perl -e 'alarm 40; exec @ARGV' osascript -e \
            'tell application "System Events" to tell process "WidgetKit Simulator" to get entire contents of front window' \
            > "$DEBUG_DIR/ax-tree.txt" 2>&1
        defaults read com.apple.widgetkit.simulator > "$DEBUG_DIR/defaults.txt" 2>&1
    fi
done
quit_simulator
(( failed )) && { log "not composing widgets.png: a widget failed"; exit 1; }

request widget-gallery "{\"kind\":\"gallery\",\"png\":\"$OUT/widgets.png\",\"rows\":[[\"$WORK/today.png\",\"$WORK/pace-gauges.png\"],[\"$WORK/live-session.png\",\"$WORK/daily-chart.png\"],[\"$WORK/top-projects.png\"]]}" || exit 1
[[ -n $DEBUG_DIR ]] && cp "$WORK"/*.png "$DEBUG_DIR/"
rm -rf "$WORK"
log "✓ widgets.png"
