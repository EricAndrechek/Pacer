#!/bin/zsh
# Record Pacer's window through a scenario and line it up with the log.
#
#   make record SCENARIO=relaunch APPROVED=1   # reinstall + relaunch (make install)
#   make record SCENARIO=tabs APPROVED=1       # walk every tab, end where it started
#   make record SCENARIO=idle APPROVED=1       # just watch it sit (DUR=300 default)
#   make record SCENARIO=reopen APPROVED=1     # quit + reopen, no rebuild (REPEAT=5 default)
#
# THIS RECORDS THE SCREEN — AGENTS.md → "Never take over the machine". Only
# with the owner's go-ahead. Without APPROVED=1 it prints its plan and exits.
#
# What it records: only Pacer. bin/pacer-window-recorder.swift captures the
# rectangle the dashboard occupies, with every other application excluded, via
# ScreenCaptureKit — nothing is dimmed, nothing else is in a frame, and the
# area follows wherever the window actually is (no monitor layout is kept).
# What it drives: `make install` (relaunch), or Pacer's own tab switch via
# bin/pacer-select-tab.swift (tabs). No input events, no activation, no focus
# change — the owner can keep working in other apps throughout.
#
# Output: screenshots/recordings/<scenario>-<time>/ (gitignored) —
#   <epoch-ms>.png   every frame whose content changed (window points)
#   events.txt       window appeared/moved/gone, ms
#   marks.txt        what the script did, ms
#   log.txt          Pacer's log over the run (ms timestamps, same clock)
#   changes.txt      bin/dev-frame-diff.sh over the run
set -u
ROOT=${0:A:h:h}
SCENARIO=${SCENARIO:-relaunch}
case $SCENARIO in
    relaunch) DUR=${DUR:-75} ;;
    tabs)     DUR=${DUR:-30} ;;
    idle)     DUR=${DUR:-300} ;;
    reopen)   REPEAT=${REPEAT:-5}; DUR=${DUR:-$(( REPEAT * 12 + 6 ))} ;;
    *) echo "SCENARIO must be relaunch, tabs, idle or reopen" >&2; exit 64 ;;
esac
OUT=${OUT:-$ROOT/screenshots/recordings/$SCENARIO-$(date +%Y%m%d-%H%M%S)}
BIN=$ROOT/build
LOGDIR=~/Library/Logs/Pacer

echo "Plan: record Pacer's dashboard window only (all other apps excluded) for ${DUR}s,"
case $SCENARIO in
    relaunch) echo "      running \`make install\` once it is ready (quits + relaunches Pacer in the background)." ;;
    tabs)     echo "      asking Pacer to switch through every tab (2.5s each) and back to where it was." ;;
    idle)     echo "      doing nothing else — whatever changes on its own is what gets recorded." ;;
    reopen)   echo "      quitting Pacer (bin/dev-quit-app.sh, as make install does) and reopening it in the background, ${REPEAT}×." ;;
esac
echo "      Output: $OUT"
if [[ "${1:-}" != "--owner-approved" ]]; then
    echo
    echo "Not run. This records the screen; it needs the owner's go-ahead:"
    echo "  make record SCENARIO=$SCENARIO APPROVED=1"
    exit 2
fi

mkdir -p "$BIN"
for tool in pacer-window-recorder pacer-select-tab; do
    if [[ ! -x $BIN/$tool || $ROOT/bin/$tool.swift -nt $BIN/$tool ]]; then
        swiftc -O "$ROOT/bin/$tool.swift" -o "$BIN/$tool" 2>&1 | grep ' error:' && exit 1
    fi
done

mkdir -p "$OUT"
ms() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%03dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1000'; }
mark() { echo "$(ms) $1" | tee -a "$OUT/marks.txt"; }

"$BIN/pacer-window-recorder" "$OUT" "$DUR" > /dev/null & REC=$!
until grep -qE "ready|error" "$OUT/events.txt" 2>/dev/null; do sleep 0.1; done
if grep -q error "$OUT/events.txt"; then cat "$OUT/events.txt"; exit 1; fi
START=$(ms)
mark "recording ready"

case $SCENARIO in
relaunch)
    sleep 2
    mark "make install start"
    ( cd "$ROOT" && make install ) > "$OUT/install.log" 2>&1
    mark "make install end (exit $?)"
    ;;
tabs)
    original=$(grep -o 'title "[^"]*"' "$OUT/events.txt" | head -1 | cut -d'"' -f2 | tr 'A-Z' 'a-z')
    [[ -z $original ]] && original=dashboard
    for tab in dashboard history projects models settings dashboard history projects models $original; do
        sleep 2.5
        "$BIN/pacer-select-tab" "$tab"
        mark "tab → $tab"
    done
    ;;
idle) ;;
reopen)
    # The same quit and reopen `make install` does, minus the build: a clean
    # quit request, then `open -g` (background — no activation, no focus).
    for i in $(seq 1 $REPEAT); do
        sleep 2
        mark "quit $i"
        "$ROOT/bin/dev-quit-app.sh" > /dev/null 2>&1
        mark "reopen $i"
        open -g /Applications/Pacer.app
        sleep 8
    done
    ;;
esac
wait $REC
mark "recording end"

# Log lines by timestamp, across a rotation if `make install` caused one.
cat $LOGDIR/Pacer.err.log.1(N) $LOGDIR/Pacer.err.log 2>/dev/null \
    | awk -v s="$START" '/^20[0-9][0-9]-/ && substr($0,1,24) >= s' > "$OUT/log.txt"
"$ROOT/bin/dev-frame-diff.sh" "$OUT" > "$OUT/changes.txt"
echo
echo "$(wc -l < "$OUT/changes.txt" | tr -d ' ') visual change(s); window events:"
grep -E "appeared|moved|gone" "$OUT/events.txt" | cut -c12-
echo "$OUT"
