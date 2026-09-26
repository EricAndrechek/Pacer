#!/bin/zsh
# Render the README screenshots. Window scenes are the app's real window,
# captured through the window server (#128); everything else is rendered from
# the views off-screen, as before. Synthetic data only — never the real store.
#
#   CI:     make screenshots            → docs/screenshots/  (committed via PR)
#   local:  make screenshots APPROVED=1 → screenshots/preview/ (gitignored)
#
# The README images come from CI (.github/workflows/screenshots.yml): its
# runner builds with the same SDK releases do, so the images show the chrome
# users actually get, and it can make the window key, so the traffic lights are
# in colour. A local run is a preview. It captures the screen — invisibly, the
# window sits beneath the desktop picture and is never activated — so, like
# `make record`, it needs the owner's go-ahead (AGENTS.md).
set -u
ROOT=${0:A:h:h}
APP="$ROOT/Build/Products/Debug/Pacer.app/Contents/MacOS/Pacer"
[[ -x $APP ]] || APP=$(ls -d "$ROOT"/Build/**/Products/Debug/Pacer.app(N) | head -1)/Contents/MacOS/Pacer
[[ -x $APP ]] || { echo "ERROR: no Debug build under Build/ — run make verify"; exit 1; }

if [[ ${CI:-} == true ]]; then
    OUT=$ROOT/docs/screenshots
    HELPER_ARGS=(--virtual-display)
    LOCAL=0
else
    OUT=$ROOT/screenshots/preview
    HELPER_ARGS=()
    LOCAL=1
    if [[ ${1:-} != --owner-approved ]]; then
        echo "Plan: render the README scenes over synthetic data into $OUT."
        echo "      Window scenes open the real Pacer window beneath the desktop picture —"
        echo "      invisible, never focused — and are captured with ScreenCaptureKit."
        echo "      The committed README images come from CI: gh workflow run screenshots.yml"
        echo
        echo "Not run. This captures the screen; it needs the owner's go-ahead:"
        echo "  make screenshots APPROVED=1"
        exit 2
    fi
fi

TOOLS=$ROOT/Build/tools
HELPER=$TOOLS/pacer-screenshot-capture
mkdir -p "$TOOLS" "$OUT"
if [[ ! -x $HELPER || $ROOT/bin/pacer-screenshot-capture.swift -nt $HELPER ]]; then
    swiftc -O -import-objc-header "$ROOT/bin/screenshot-virtual-display.h" \
        "$ROOT/bin/pacer-screenshot-capture.swift" -o "$HELPER" || exit 1
fi

# One instant and time zone for every run, so a PR with no UI change produces
# no screenshot commit (#154). Both come from ScreenshotClock, the only copy;
# bin/fixed-clock.c pins the app's wall clock to the instant, TZ the zone.
CLOCK_SRC=$ROOT/PacerCore/Sources/PacerCore/Util/PacerClock.swift
FIXED_NOW=$(sed -n 's/.*fixedNowUnix: TimeInterval = \([0-9_]*\).*/\1/p' "$CLOCK_SRC" | tr -d _)
FIXED_TZ=$(sed -n 's/.*timeZoneID = "\(.*\)".*/\1/p' "$CLOCK_SRC")
[[ -n $FIXED_NOW && -n $FIXED_TZ ]] || { echo "ERROR: could not read ScreenshotClock from $CLOCK_SRC"; exit 1; }
CLOCK_LIB=$TOOLS/libfixedclock.dylib
if [[ ! -f $CLOCK_LIB || $ROOT/bin/fixed-clock.c -nt $CLOCK_LIB ]]; then
    clang -dynamiclib -O2 -framework CoreFoundation \
        -o "$CLOCK_LIB" "$ROOT/bin/fixed-clock.c" || exit 1
fi

REQ=$(mktemp -d)
"$HELPER" "$REQ" ${HELPER_ARGS[@]} & HELPER_PID=$!
trap 'touch "$REQ/stop"; wait $HELPER_PID 2>/dev/null; rm -rf "$REQ"' EXIT
for _ in $(seq 1 300); do
    [[ -f $REQ/ready ]] && break
    kill -0 $HELPER_PID 2>/dev/null || { echo "ERROR: capture helper exited before it was ready"; exit 1; }
    sleep 0.1
done
[[ -f $REQ/ready ]] || { echo "ERROR: capture helper never became ready"; exit 1; }

DYLD_INSERT_LIBRARIES="$CLOCK_LIB" \
PACER_FIXED_NOW="$FIXED_NOW" \
TZ="$FIXED_TZ" \
PACER_SCREENSHOT_MODE=1 \
PACER_SCREENSHOT_DIR="$OUT" \
PACER_SCREENSHOT_CAPTURE_DIR="$REQ" \
PACER_SCREENSHOT_LOCAL_APPROVED=$LOCAL \
    "$APP"
rc=$?
(( rc == 0 )) || { echo "ERROR: screenshot run failed (exit $rc) — see the lines above"; exit $rc; }

# widgets.png: the real widget extension, rendered by WidgetKit Simulator over
# fixture data (the build must have PACER_WIDGET_FIXTURES — the workflow sets
# it). The simulator opens a visible window, so a local preview skips it.
if (( LOCAL )); then
    echo "[widgets] skipping widgets.png — WidgetKit Simulator opens a visible window; captured in CI only"
else
    "$ROOT/bin/widgetkit-sim-shots.sh" "${APP:h:h:h}" "$REQ" "$OUT" \
        || { echo "ERROR: widget screenshots failed — see the lines above"; exit 1; }
fi
echo "Wrote PNGs to $OUT"
