#!/bin/zsh
# docs/screenshots/widgets.png — the real PacerWidgets extension, rendered by
# Notification Center, over fixture data. CI only: it rewrites Notification
# Center's widget list and opens the panel, which on a person's Mac would
# replace their widgets (AGENTS.md).
#
#   bin/nc-widget-shots.sh <Pacer.app> <capture-request-dir> <out-dir>
#
# Why Notification Center and not WidgetKit Simulator: the simulator renders
# only a widget's small family and has no scriptable way to ask for another;
# the README shows most widgets at medium. Notification Center renders any
# family with the system's own chrome, once its preferences say the widgets
# are there (bin/nc-widget-records.py).
set -u
[[ ${CI:-} == true ]] || { echo "[widgets] CI only — this replaces Notification Center's widgets"; exit 2; }
(( $# == 3 )) || { echo "usage: $0 <Pacer.app> <request-dir> <out-dir>"; exit 64; }
ROOT=${0:A:h:h}
SRC_APP=$1 REQ=$2 OUT=$3
APP=/Applications/Pacer.app
APPEX=$APP/Contents/PlugIns/PacerWidgets.appex
NC_PREFS=$HOME/Library/Containers/com.apple.notificationcenterui/Data/Library/Preferences/com.apple.notificationcenterui
WORK=$(mktemp -d)
DEBUG_DIR=
[[ ${PACER_WIDGETSIM_DEBUG:-} == 1 ]] && { DEBUG_DIR=$OUT/debug-widgets; mkdir -p "$DEBUG_DIR"; }

log() { print -r -- "[widgets] $*"; }
debug_shot() { [[ -n $DEBUG_DIR ]] && screencapture -x -t jpg "$DEBUG_DIR/$1.jpg" 2>&1 | sed 's/^/[widgets] screencapture: /'; }

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

# Installed where LaunchServices and chronod look for extensions, signed
# ad-hoc (an unsigned extension, without its App Group entitlement, is not
# loaded), nested first, no --deep.
rm -rf "$APP"
ditto "$SRC_APP" "$APP" 2>/dev/null || sudo ditto "$SRC_APP" "$APP" || { log "cannot install $APP"; exit 1; }
pluginkit -r "$SRC_APP/Contents/PlugIns/PacerWidgets.appex" 2>/dev/null
codesign --force -s - --entitlements "$ROOT/Widgets/PacerWidgets.entitlements" "$APPEX" 2>&1 | grep -v "replacing existing signature"
codesign --force -s - --entitlements "$ROOT/App/Pacer.entitlements" "$APP" 2>&1 | grep -v "replacing existing signature"
# chronod drops an extension LaunchServices has no containing app for.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
pluginkit -a "$APPEX"
log "registered: $(pluginkit -m -i com.ericandrechek.pacer.widgets 2>&1)"

request widget-appearance '{"kind":"appearance","dark":false}' || exit 1

# The README's widgets, in gallery order — the fixture build's stand-ins
# (`ReadmeShotWidget`), each in the family it is shown at.
specs=(
    ReadmeShot.TodayCostWidget:small
    ReadmeShot.PaceGaugesWidget:medium
    ReadmeShot.LiveSessionWidget:medium
    ReadmeShot.DailyChartWidget:medium
    ReadmeShot.TopProjectsWidget:medium
)
defaults export "$NC_PREFS" "$WORK/nc-in.plist" 2>&1 | sed 's/^/[widgets] export: /'
"$ROOT/bin/nc-widget-records.py" "$WORK/nc-in.plist" "$WORK/nc-out.plist" \
    com.ericandrechek.pacer com.ericandrechek.pacer.widgets $specs || exit 1
defaults import "$NC_PREFS" "$WORK/nc-out.plist" 2>&1 | sed 's/^/[widgets] import: /'
defaults export "$NC_PREFS" "$WORK/nc-check.plist"
log "instances now: $(python3 -c "import plistlib,sys;print(len(plistlib.load(open(sys.argv[1],'rb')).get('widgets',{}).get('instances',[])))" "$WORK/nc-check.plist")"
# DIAGNOSIS — is Notification Center running at all on a runner, and can it be started?
log "procs: $(ps -axo comm | grep -iE 'notificationcenter|chronod|widget|controlcenter' | sort -u | tr '\n' ' ')"
uid=$(id -u)
launchctl print "gui/$uid" 2>&1 | grep -iE 'notificationcenter|chrono' | head -10 | sed 's/^/[widgets] launchd: /'
# The runner image ships Notification Center disabled; a user may enable their
# own agents.
launchctl enable "gui/$uid/com.apple.notificationcenterui.agent" 2>&1 | sed 's/^/[widgets] enable: /'
launchctl bootstrap "gui/$uid" /System/Library/LaunchAgents/com.apple.notificationcenterui.agent.plist 2>&1 | sed 's/^/[widgets] bootstrap: /'
launchctl load -w /System/Library/LaunchAgents/com.apple.notificationcenterui.agent.plist 2>&1 | sed 's/^/[widgets] load: /'
sleep 2
pgrep -x NotificationCenter >/dev/null || open -g /System/Library/CoreServices/NotificationCenter.app 2>&1 | sed 's/^/[widgets] open-nc: /'
sleep 3
if ! pgrep -x NotificationCenter >/dev/null; then
    /System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter >"$WORK/nc.out" 2>&1 &
    sleep 4
    log "direct exec: $(pgrep -x NotificationCenter || echo 'not running'); $(head -c 600 "$WORK/nc.out")"
fi
log "NotificationCenter pid: $(pgrep -x NotificationCenter || echo none)"
for svc in com.apple.notificationcenterui.agent com.apple.chronod; do
    launchctl print "gui/$uid/$svc" 2>&1 | grep -E 'state|path|program|last exit|disabled' | head -6 | sed "s/^/[widgets] $svc: /"
    launchctl kickstart -k "gui/$uid/$svc" 2>&1 | sed "s/^/[widgets] kickstart $svc: /"
done
launchctl print-disabled "gui/$uid" 2>&1 | grep -iE 'notification|chrono' | sed 's/^/[widgets] disabled: /'
sleep 6
log "procs after kickstart: $(ps -axo comm | grep -iE 'notificationcenter|chronod|widget' | sort -u | tr '\n' ' ')"
/usr/bin/log show --last 2m --style compact --predicate 'process == "NotificationCenter" OR process == "chronod"' 2>/dev/null | grep -iE 'error|fail|pacer|ReadmeShot|widget' | head -40 | sed 's/^/[widgets] oslog: /'
debug_shot nc-before-open

# Open the panel: the menu bar clock.
osascript -e 'tell application "System Events" to tell process "ControlCenter"
        set out to ""
        repeat with m in menu bar items of menu bar 1
            set out to out & (name of m as text) & " / " & (description of m as text) & "; "
        end repeat
        return out
    end tell' 2>&1 | sed 's/^/[widgets] cc items: /'
osascript -e 'tell application "System Events" to tell process "ControlCenter"
        repeat with m in menu bar items of menu bar 1
            if (description of m as text) contains "Clock" or (name of m as text) contains "Clock" then
                click m
                return "clicked " & (description of m as text)
            end if
        end repeat
        return "no clock item"
    end tell' 2>&1 | sed 's/^/[widgets] open: /'
sleep 5
debug_shot nc-open
log "procs after click: $(ps -axo comm | grep -iE 'notificationcenter|chronod|widget' | sort -u | tr '\n' ' ')"
/usr/bin/log show --last 1m --style compact --predicate 'process == "NotificationCenter" OR process == "chronod"' 2>/dev/null | grep -iE 'error|fail|pacer|ReadmeShot' | head -40 | sed 's/^/[widgets] oslog2: /'
osascript -e 'set out to ""
    tell application "System Events" to tell process "NotificationCenter"
        repeat with w in windows
            set out to out & "WINDOW " & (name of w as text) & " @" & (position of w as text) & " " & (size of w as text) & linefeed
            try
                repeat with e in (entire contents of w)
                    try
                        set out to out & (role of e) & " | " & (description of e as text) & " | " & (position of e as text) & " | " & (size of e as text) & linefeed
                    end try
                end repeat
            end try
        end repeat
    end tell
    return out' 2>&1 | sed 's/^/[widgets] ax: /' | head -150
log "done (diagnosis)"
exit 1
