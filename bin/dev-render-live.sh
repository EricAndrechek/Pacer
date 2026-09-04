#!/usr/bin/env bash
#
# dev-render-live.sh — render Pacer's real cards, against the real store, to
# PNGs. For looking at the app without asking a human to look at it.
#
#   bin/dev-render-live.sh [scopes] [outdir]      (or: make render-live)
#
# `scopes` is `auto` (all-accounts plus every account, the default), or a
# comma-separated list of `all` and account ids. Output defaults to
# ./screenshots/live.
#
# Why this is a script and not a one-liner
# ---------------------------------------
# It runs a SECOND PROCESS OF THE SAME BUNDLE beside the app the user is
# working in, and getting that wrong is disruptive in a way that is not
# obvious until someone is staring at it:
#
#   - The render process must be `.prohibited`, not `.accessory`. With
#     `.accessory`, macOS still treats it as an activatable instance of Pacer —
#     launching it pulled the real window onto the active Space and left it out
#     of place when the render exited. `LiveRenderMode` sets this; the note is
#     here because the symptom shows up at the command line.
#   - The real app is re-opened on the way out, whatever happens — success,
#     failure, or Ctrl-C. That is the `trap`, and it is the whole reason to
#     have a script.
#
# It opens the store READ-ONLY and sets the view scope ephemerally, so it
# cannot write the user's data or leave their dashboard on a different account.
set -euo pipefail

SCOPES="${1:-auto}"
OUT="${2:-$(pwd)/screenshots/live}"
APP="/Applications/Pacer.app"
BIN="$APP/Contents/MacOS/Pacer"

[ -x "$BIN" ] || { echo "no installed Pacer at $BIN — run 'make install' first"; exit 1; }

# Re-open the user's Pacer no matter how this exits. `-g` so it comes back
# without stealing focus.
restore() { open -g -a Pacer 2>/dev/null || true; }
trap restore EXIT INT TERM

mkdir -p "$OUT"

# The render opens the store read-only, and SwiftData needs a *write* to apply
# a schema migration — so the first render after a model change fails until the
# app has launched once and migrated. Make sure it has.
open -g -a Pacer 2>/dev/null || true

echo "==> Rendering scopes [$SCOPES] to $OUT"
PACER_SCREENSHOT_MODE=1 \
PACER_RENDER_LIVE="$SCOPES" \
PACER_SCREENSHOT_DIR="$OUT" \
  "$BIN" 2>&1 | grep -E '^\[Pacer (render|live-render)\]' || true

echo
ls -1 "$OUT"/*.png 2>/dev/null | sed 's|^|    |' || echo "    (nothing rendered)"
