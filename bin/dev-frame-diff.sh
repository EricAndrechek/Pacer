#!/bin/zsh
# List what changed between consecutive frames of a pacer-window-recorder run.
#   bin/dev-frame-diff.sh <dir> [from-ms] [to-ms]
# One line per frame that differs from the previous: wall time (UTC, the log's
# clock), ms since the previous change, changed pixels, bounding box (window
# points) of the change. Pixels count if they moved by more than 6% luminance,
# which ignores compositor dithering but keeps a one-point text shift.
set -u
dir=$1; from=${2:-0}; to=${3:-99999999999999}
prev=""; prevt=0
for f in $(ls "$dir"/*.png | grep -E '/[0-9]{13}\.png$' | sort); do
    t=${${f:t}%.png}
    (( t < from || t > to )) && continue
    if [[ -n $prev ]]; then
        magick "$prev" "$f" -compose difference -composite -colorspace gray -threshold 6% "$dir/.diff.png"
        px=$(magick "$dir/.diff.png" -format '%[fx:round(mean*w*h)]' info:)
        if (( px > 0 )); then
            box=$(magick "$dir/.diff.png" -trim -format '%wx%h+%X+%Y' info: 2>/dev/null)
            printf "%s.%03dZ  +%5dms  px=%-7d box=%s\n" \
                "$(date -u -r $(( t / 1000 )) +%H:%M:%S)" $(( t % 1000 )) $(( t - prevt )) "$px" "$box"
            prevt=$t
        fi
    else
        prevt=$t
    fi
    prev=$f
done
rm -f "$dir/.diff.png"
