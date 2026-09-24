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
# under the same identifier and version, and the simulator loaded that one
# ("WidgetDocument.Error error 5"): so a higher build number, and the build
# directory's copy unregistered.
for plist in "$APPEX/Contents/Info.plist" "$APP/Contents/Info.plist"; do
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 9999" "$plist"
done
pluginkit -r "$SRC_APP/Contents/PlugIns/PacerWidgets.appex" 2>/dev/null
codesign --force -s - --entitlements "$ROOT/Widgets/PacerWidgets.entitlements" "$APPEX" 2>&1 | grep -v "replacing existing signature"
codesign --force -s - --entitlements "$ROOT/App/Pacer.entitlements" "$APP" 2>&1 | grep -v "replacing existing signature"
pluginkit -a "$APPEX"

# Point the open document at one widget: File › Select Widget…, the widget by
# its display name, then the sheet's confirm button. Through Accessibility
# (osascript holds that grant on GitHub's runners), on the disposable runner
# only. Prints what it saw, for when the simulator's layout changes.
pick() {
    perl -e 'alarm 60; exec @ARGV' osascript - "$1" "${DEBUG_DIR:-/dev/null}" <<'OSA'
on textsOf(e)
    set out to {}
    tell application "System Events"
        try
            set end of out to (name of e as text)
        end try
        try
            set end of out to (value of e as text)
        end try
        try
            set end of out to (description of e as text)
        end try
    end tell
    return out
end textsOf

on pressFor(w, label)
    tell application "System Events"
        set els to entire contents of w
        repeat with e in els
            if my textsOf(e) contains label then
                set target to e
                repeat 6 times
                    try
                        if role of target is "AXRow" then
                            set selected of target to true
                            return "selected row for " & label
                        end if
                    end try
                    try
                        perform action "AXPress" of target
                        return "pressed " & (role of target) & " for " & label
                    end try
                    try
                        set target to value of attribute "AXParent" of target
                    on error
                        exit repeat
                    end try
                end repeat
            end if
        end repeat
    end tell
    return "NOT FOUND: " & label
end pressFor

on run argv
    set widgetName to item 1 of argv
    set debugDir to item 2 of argv
    tell application "System Events" to tell process "WidgetKit Simulator"
        set frontmost to true
        repeat 60 times
            if (count of windows) > 0 then exit repeat
            delay 0.25
        end repeat
        click menu item "Select Widget…" of menu 1 of menu bar item "File" of menu bar 1
        delay 2
        set w to window 1
        set kindOf to "window " & (name of w as text)
        if exists sheet 1 of window 1 then
            set w to sheet 1 of window 1
            set kindOf to "sheet"
        end if
        try
            set dump to (entire contents of w) as text
        on error
            set dump to ""
        end try
        if debugDir is not "/dev/null" then
            try
                do shell script "cat > " & quoted form of (debugDir & "/select-widget-ax.txt") & " <<'EOF'
" & dump & "
EOF"
            end try
        end if
        set log1 to my pressFor(w, widgetName)
        delay 0.5
        set log2 to "no confirm button"
        repeat with b in {"Open", "Select", "Choose", "Done", "OK"}
            try
                click button (b as text) of w
                set log2 to "clicked " & b
                exit repeat
            end try
        end repeat
        return kindOf & ": " & log1 & "; " & log2
    end tell
end run
OSA
}

# Everything the simulator shows in its front window, for the debug dump.
ax_dump() {
    perl -e 'alarm 40; exec @ARGV' osascript -e \
        'tell application "System Events" to tell process "WidgetKit Simulator" to get entire contents of front window' \
        > "$DEBUG_DIR/$1-ax.txt" 2>&1
    screencapture -x "$DEBUG_DIR/$1-screen.png" 2>/dev/null
}

# name, kind, display name — the gallery's order; the family is the one
# WidgetFixtures.readmeShots gives the kind.
shots=(
    today         TodayCostWidget    "Today"
    pace-gauges   PaceGaugesWidget   "Rate limits"
    live-session  LiveSessionWidget  "Current session"
    daily-chart   DailyChartWidget   "Daily cost"
    top-projects  TopProjectsWidget  "Top projects"
)
failed=0
for name kind display in $shots; do
    quit_simulator
    open -a "$SIM" "$APPEX" || { log "⚠️ $name: cannot open $SIM"; failed=1; continue; }
    # Opened on the extension, the simulator shows its first widget kind —
    # Today; every other one is chosen.
    [[ $name == today ]] || log "$name: $(pick "$display" 2>&1)"
    debug=
    [[ -n $DEBUG_DIR ]] && debug=",\"debug\":\"$DEBUG_DIR/$name-window.png\""
    if request "widget-$name" "{\"kind\":\"widgetsim\",\"png\":\"$WORK/$name.png\"$debug}"; then
        log "✓ $name ($kind)"
    else
        failed=1
        [[ -n $DEBUG_DIR ]] && ax_dump "$name-after"
    fi
done
quit_simulator
(( failed )) && { log "not composing widgets.png: a widget failed"; exit 1; }

request widget-gallery "{\"kind\":\"gallery\",\"png\":\"$OUT/widgets.png\",\"rows\":[[\"$WORK/today.png\",\"$WORK/pace-gauges.png\"],[\"$WORK/live-session.png\",\"$WORK/daily-chart.png\"],[\"$WORK/top-projects.png\"]]}" || exit 1
[[ -n $DEBUG_DIR ]] && cp "$WORK"/*.png "$DEBUG_DIR/"
rm -rf "$WORK"
log "✓ widgets.png"
