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
#   changes-*.txt            every frame that differs from the last: video time,
#                            changed pixels, and the bounding box of the change
#   frames-*/                every frame (half scale) + times.txt; sheet-*.png
#                            is a contact sheet of the changed ones
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

# Every frame, diffed against the one before it. ffmpeg's scene score was tried
# first and missed exactly what matters here — a 3pt card shift or a scrollbar
# flash scores far below any threshold that also ignores encoder noise — and
# with `-fps_mode vfr` it silently dropped frames that shared a timestamp.
# Recordings are at the display's backing scale (2× on Retina); frames are
# written at half width, which is still ≥ 1pt per pixel.
for clip in home default; do
    [[ -f "$OUT/$clip.mov" ]] || continue
    mkdir -p "$OUT/frames-$clip"
    ffmpeg -hide_banner -loglevel info -i "$OUT/$clip.mov" \
        -vf "showinfo,scale=iw/2:-1" -fps_mode passthrough "$OUT/frames-$clip/%05d.png" 2>&1 \
        | grep -o 'pts_time:[0-9.]*' | cut -d: -f2 > "$OUT/frames-$clip/times.txt"
    : > "$OUT/changes-$clip.txt"
    changed=()
    i=0; prev=""
    for f in "$OUT/frames-$clip"/*.png; do
        i=$((i + 1))
        if [[ -n "$prev" ]]; then
            magick "$prev" "$f" -compose difference -composite -colorspace gray \
                -threshold 6% "$OUT/.diff.png"
            px=$(magick "$OUT/.diff.png" -format '%[fx:round(mean*w*h)]' info:)
            if (( px > 0 )); then
                box=$(magick "$OUT/.diff.png" -trim -format '%wx%h+%X+%Y' info: 2>/dev/null)
                printf "%s  %9.3fs  changed_px=%-7d box=%s\n" "${f:t}" \
                    "$(sed -n "${i}p" "$OUT/frames-$clip/times.txt")" "$px" "$box" \
                    >> "$OUT/changes-$clip.txt"
                changed+=("$f")
            fi
        fi
        prev=$f
    done
    if (( ${#changed} > 0 )); then
        # An explicit font: ImageMagick has no default on macOS and -label fails.
        magick montage -font /System/Library/Fonts/Supplemental/Arial.ttf -label '%f' \
            "${changed[@]:0:64}" -tile 8x -geometry 400x+4+4 "$OUT/sheet-$clip.png"
    fi
    rm -f "$OUT/.diff.png"
    echo "$clip: ${#changed} changed frame(s) of $i → $OUT/changes-$clip.txt"
done
echo "$OUT"
