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

REQ=$(mktemp -d)
"$HELPER" "$REQ" ${HELPER_ARGS[@]} & HELPER_PID=$!
trap 'touch "$REQ/stop"; wait $HELPER_PID 2>/dev/null; rm -rf "$REQ"' EXIT
for _ in $(seq 1 300); do
    [[ -f $REQ/ready ]] && break
    kill -0 $HELPER_PID 2>/dev/null || { echo "ERROR: capture helper exited before it was ready"; exit 1; }
    sleep 0.1
done
[[ -f $REQ/ready ]] || { echo "ERROR: capture helper never became ready"; exit 1; }

PACER_SCREENSHOT_MODE=1 \
PACER_SCREENSHOT_DIR="$OUT" \
PACER_SCREENSHOT_CAPTURE_DIR="$REQ" \
PACER_SCREENSHOT_LOCAL_APPROVED=$LOCAL \
    "$APP"
status=$?
(( status == 0 )) || { echo "ERROR: screenshot run failed (exit $status) — see the lines above"; exit $status; }
echo "Wrote PNGs to $OUT"
