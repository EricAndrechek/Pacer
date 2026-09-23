#!/bin/zsh
# Record Pacer's own window area on screen while it is reinstalled and
# relaunched, then line the video up against the log.
#
#   make record-relaunch APPROVED=1
#
# THIS RECORDS THE SCREEN. AGENTS.md → "Never take over the machine": it may
# only run with the owner's explicit go-ahead *for that run* — an agent
# describes the run, the owner says go, the agent runs it once. Without
# --owner-approved it prints what it would do and exits.
#
# What it touches, and nothing else:
#   - records two rectangles, never whole displays: the dashboard's saved home
#     frame, and the frame SwiftUI first creates the window at (read from the
#     last "[Placement]" log lines, so they follow whatever monitors exist);
#   - runs `make install` (or $RELAUNCH_CMD), which quits and reopens Pacer the
#     way every install does — in the background, without taking focus.
# No input events, no window moves, no activation, no audio, no cursor.
#
# Output (under $OUT, default screenshots/recordings/<timestamp>, gitignored):
#   home.mov / default.mov   the recordings
#   marks.txt                wall-clock marks from this script (ms)
#   log.txt                  Pacer log lines from the recorded span (ms)
#   changes-*.txt            every instant the picture changed (video seconds)
#   frames-*/                a frame at each change, plus sheet-*.png contact sheets
#
# Aligning: video t=0 is roughly "recording start" in marks.txt, but
# screencapture's own startup adds a few hundred ms. Anchor instead on the
# frame where the window disappears ↔ "[Lifecycle] terminating", and the frame
# where it reappears ↔ "[Placement] dashboard is id=main".
set -u
ROOT=${0:A:h:h}
LOG=~/Library/Logs/Pacer/Pacer.err.log
DUR=${DUR:-75}
OUT=${OUT:-$ROOT/screenshots/recordings/$(date +%Y%m%d-%H%M%S)}
RELAUNCH_CMD=${RELAUNCH_CMD:-make install}

# "X,Y W×H" in AppKit coordinates (origin bottom-left of the main display) →
# "x,y,w,h" in the top-left coordinates screencapture -R takes.
MAIN_H=$(swift -e 'import CoreGraphics; print(Int(CGDisplayBounds(CGMainDisplayID()).height))' 2>/dev/null)
to_cg() {
    local x y w h
    read x y w h <<< "$(echo "$1" | sed -E 's/[,×]/ /g')"
    echo "$x,$(( MAIN_H - y - h )),$w,$h"
}
HOME_FRAME=$(grep -E '\[Placement\] (parked at|adopt: .* → )' "$LOG" | tail -1 \
    | sed -E 's/.*(parked at|→) //' | awk '{print $1, $2}')
DEFAULT_FRAME=$(grep '\[Placement\] dashboard is id=main' "$LOG" | tail -1 \
    | sed -E 's/.*frame=//' | awk '{print $1, $2}')
if [[ -z "$MAIN_H" || -z "$HOME_FRAME" ]]; then
    echo "Could not resolve the main display or the dashboard's home frame from $LOG." >&2
    exit 1
fi
HOME_R=$(to_cg "$HOME_FRAME")
DEFAULT_R=${DEFAULT_FRAME:+$(to_cg "$DEFAULT_FRAME")}
[[ "$DEFAULT_R" == "$HOME_R" ]] && DEFAULT_R=""

cat <<EOF
Plan (${DUR}s):
  record home rect     $HOME_R   (AppKit $HOME_FRAME)
  record default rect  ${DEFAULT_R:-(same as home — skipped)}   (AppKit ${DEFAULT_FRAME:-?})
  after 4s run         $RELAUNCH_CMD
  output               $OUT
EOF
if [[ "${1:-}" != "--owner-approved" ]]; then
    echo
    echo "Not run. This records the screen; it needs the owner's go-ahead for this run:"
    echo "  make record-relaunch APPROVED=1"
    exit 2
fi
for tool in ffmpeg magick; do
    command -v $tool >/dev/null || { echo "needs $tool (brew install $tool)" >&2; exit 1; }
done

mkdir -p "$OUT"
ms() { perl -MTime::HiRes=time -MPOSIX=strftime -e '$t=time; printf "%s.%03dZ\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime($t)), ($t-int($t))*1000'; }
mark() { echo "$(ms) $1" | tee -a "$OUT/marks.txt"; }

LOG_START=$(wc -l < "$LOG")
mark "recording start (${DUR}s)"
pids=()
screencapture -x -V "$DUR" -R"$HOME_R" "$OUT/home.mov" & pids+=$!
if [[ -n "$DEFAULT_R" ]]; then
    screencapture -x -V "$DUR" -R"$DEFAULT_R" "$OUT/default.mov" & pids+=$!
fi
sleep 4
mark "relaunch start: $RELAUNCH_CMD"
( cd "$ROOT" && eval "$RELAUNCH_CMD" ) > "$OUT/relaunch.log" 2>&1
mark "relaunch end (exit $?)"
wait $pids
mark "recording end"
# The log may have rotated during the install; if so, take the new file whole.
if (( $(wc -l < "$LOG") >= LOG_START )); then
    tail -n +$(( LOG_START + 1 )) "$LOG" > "$OUT/log.txt"
else
    cp "$LOG" "$OUT/log.txt"
fi

for clip in home default; do
    [[ -f "$OUT/$clip.mov" ]] || continue
    mkdir -p "$OUT/frames-$clip"
    # Scene score > 0.001 catches a few-point card shift in a large rect; each
    # kept frame is written and its video time logged by showinfo.
    ffmpeg -hide_banner -loglevel info -i "$OUT/$clip.mov" \
        -vf "select='gt(scene,0.001)+eq(n,0)',showinfo,scale=540:-1" -fps_mode vfr \
        "$OUT/frames-$clip/%04d.png" 2>&1 \
        | grep -o 'pts_time:[0-9.]*' | cut -d: -f2 \
        | awk '{printf "%04d %8.3fs\n", NR, $1}' > "$OUT/changes-$clip.txt"
    n=$(wc -l < "$OUT/changes-$clip.txt" | tr -d ' ')
    if (( n > 0 )); then
        # An explicit font: ImageMagick has no default on macOS and -label fails.
        magick montage -font /System/Library/Fonts/Supplemental/Arial.ttf -label '%f' \
            "$OUT/frames-$clip"/*.png -tile 8x -geometry +4+4 "$OUT/sheet-$clip.png"
    fi
    echo "$clip: $n visual change(s) → $OUT/changes-$clip.txt"
done
echo "$OUT"
