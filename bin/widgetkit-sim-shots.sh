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

# Light, whatever the scenes before left it in (menubar-dark switches the
# whole system to dark): the widgets are photographed on a light desktop.
request widget-appearance '{"kind":"appearance","dark":false}' || exit 1

# Register this copy, and only this one. Launching the app from the build
# directory for the other scenes registered the build's own (unsigned) appex
# under the same identifier, and the simulator loaded that one ("WidgetDocument.
# Error error 5"): so that copy is unregistered, and every shot below carries a
# higher build number than anything registered before it.
pluginkit -r "$SRC_APP/Contents/PlugIns/PacerWidgets.appex" 2>/dev/null

# One widget per launch. The simulator opens an extension on its first widget
# and has no scriptable way to choose another (its picker lists nothing on a
# runner), so the fixture build's first widget is `ReadmeShotWidget`, which
# becomes whichever kind `PacerFixtureKind` in the extension's Info.plist
# names. Set it, re-sign (the plist is sealed by the signature), re-register.
prepare() {   # kind, build-number
    /usr/libexec/PlistBuddy -c "Delete :PacerFixtureKind" "$APPEX/Contents/Info.plist" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Add :PacerFixtureKind string $1" "$APPEX/Contents/Info.plist"
    for plist in "$APPEX/Contents/Info.plist" "$APP/Contents/Info.plist"; do
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $2" "$plist"
    done
    codesign --force -s - --entitlements "$ROOT/Widgets/PacerWidgets.entitlements" "$APPEX" 2>&1 | grep -v "replacing existing signature"
    codesign --force -s - --entitlements "$ROOT/App/Pacer.entitlements" "$APP" 2>&1 | grep -v "replacing existing signature"
    pluginkit -a "$APPEX"
}

shots=(
    pace-gauges   PaceGaugesWidget   "Rate limits"
    today         TodayCostWidget    "Today"
    live-session  LiveSessionWidget  "Current session"
    daily-chart   DailyChartWidget   "Daily cost"
    top-projects  TopProjectsWidget  "Top projects"
)
failed=0
build=9000
for name kind display in $shots; do
    quit_simulator
    build=$((build + 1))
    prepare "$kind" "$build"
    # The simulator remembers the last document's widget; a fresh start per
    # shot, so each opens on the stand-in as it is now. (Logged once, to see
    # what it keeps.)
    [[ $build == 9001 ]] || log "simulator state before $name: $(defaults read com.apple.widgetkit.simulator 2>&1 | tr '\n' ' ' | cut -c1-600)"
    defaults delete com.apple.widgetkit.simulator 2>/dev/null
    defaults write com.apple.widgetkit.simulator NSQuitAlwaysKeepsWindows -bool NO
    rm -rf ~/Library/Containers/com.apple.widgetkit.simulator/Data/Library/Saved\ Application\ State \
           ~/Library/Saved\ Application\ State/com.apple.widgetkit.simulator.savedState 2>/dev/null
    # chronod keeps an extension process alive between launches; a fresh one
    # is what reads the new Info.plist.
    pkill -f "PacerWidgets.appex/Contents/MacOS/PacerWidgets" 2>/dev/null
    sleep 1
    open -a "$SIM" "$APPEX" || { log "⚠️ $name: cannot open $SIM"; failed=1; continue; }
    debug=
    [[ -n $DEBUG_DIR ]] && debug=",\"debug\":\"$DEBUG_DIR/$name-window.png\""
    if [[ ${PACER_WIDGETSIM_DEBUG:-} == 1 && $name == pace-gauges ]]; then   # DIAGNOSIS — temporary
        sleep 3
        osascript -e 'tell application "System Events" to tell process "WidgetKit Simulator" to click menu item "Select Widget…" of menu 1 of menu bar item "File" of menu bar 1' 2>&1 | sed 's/^/[widgets] select: /'
        sleep 3
        osascript -e 'tell application "System Events" to tell process "WidgetKit Simulator"
                set theOutline to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window "Choose a Widget"
                repeat with r in rows of theOutline
                    try
                        if value of static text 1 of UI element 1 of r is "Pacer" then
                            select r
                            return "selected Pacer"
                        end if
                    end try
                end repeat
                return "Pacer row not found"
            end tell' 2>&1 | sed 's/^/[widgets] pick-app: /'
        sleep 3
        osascript -e 'tell application "System Events" to tell process "WidgetKit Simulator"
                set theList to outline 1 of scroll area 1 of group 2 of splitter group 1 of group 1 of window "Choose a Widget"
                repeat with r in rows of theList
                    try
                        if (value of static text 1 of UI element 1 of r) starts with "README screenshot" then
                            select r
                            exit repeat
                        end if
                    end try
                end repeat
                set bs to buttons of group 2 of splitter group 1 of group 1 of window "Choose a Widget"
                set out to "buttons: "
                repeat with b in bs
                    set out to out & (title of b as text) & "/" & (description of b as text) & "; "
                end repeat
                click item (count of bs) of bs
                return out & "clicked last"
            end tell' 2>&1 | sed 's/^/[widgets] choose: /'
        sleep 4
        screencapture -x /tmp/after-choose.png && mkdir -p "$OUT/debug-widgets" && cp /tmp/after-choose.png "$OUT/debug-widgets/after-choose.png"
        osascript -e 'set out to ""
            tell application "System Events" to tell process "WidgetKit Simulator"
                set targets to {}
                try
                    set targets to entire contents of window 1
                end try
                try
                    set targets to targets & (entire contents of sheet 1 of window 1)
                end try
                if (count of targets) is 0 then
                    try
                        set targets to targets & (entire contents of window 1)
                    end try
                end if
                repeat with e in targets
                    try
                        set out to out & (role of e) & " | " & (name of e as text) & " | " & (description of e as text) & " | " & (value of e as text) & linefeed
                    on error
                        try
                            set out to out & (role of e) & linefeed
                        end try
                    end try
                end repeat
                set out to out & "windows: " & (name of every window as text)
            end tell
            return out' 2>&1 | sed 's/^/[widgets] picker: /' | head -150
        screencapture -x /tmp/picker.png && mkdir -p "$OUT/debug-widgets" && cp /tmp/picker.png "$OUT/debug-widgets/picker.png"
        osascript -e 'tell application "System Events" to get name of every process whose background only is false' 2>&1 | sed 's/^/[widgets] processes: /'
        osascript -e 'tell application "System Events" to tell process "WidgetKit Simulator"
            try
                select (first row of outline 1 of scroll area 1 of splitter group 1 of group 1 of window 1 whose value of static text 1 is "Info")
            end try
            try
                click (first UI element of window 1 whose name is "Info")
            end try
        end tell' 2>&1 | sed 's/^/[widgets] ax-click: /'
        sleep 2
        osascript -e 'set out to ""
            tell application "System Events" to tell process "WidgetKit Simulator"
                repeat with e in (entire contents of window 1)
                    try
                        set out to out & (role of e) & " | " & (name of e as text) & " | " & (value of e as text) & " | " & (description of e as text) & linefeed
                    on error
                        try
                            set out to out & (role of e) & linefeed
                        end try
                    end try
                end repeat
            end tell
            return out' 2>&1 | sed 's/^/[widgets] ax: /' | head -120
    fi
    if request "widget-$name" "{\"kind\":\"widgetsim\",\"png\":\"$WORK/$name.png\"$debug}"; then
        log "✓ $name ($kind)"
    else
        failed=1
    fi
done
quit_simulator
(( failed )) && { log "not composing widgets.png: a widget failed"; exit 1; }

request widget-gallery "{\"kind\":\"gallery\",\"png\":\"$OUT/widgets.png\",\"rows\":[[\"$WORK/today.png\",\"$WORK/pace-gauges.png\"],[\"$WORK/live-session.png\",\"$WORK/daily-chart.png\"],[\"$WORK/top-projects.png\"]]}" || exit 1
[[ -n $DEBUG_DIR ]] && cp "$WORK"/*.png "$DEBUG_DIR/"
rm -rf "$WORK"
log "✓ widgets.png"
