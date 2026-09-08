#!/usr/bin/env bash
#
# verify-menubar-tooltip.sh — the one check in this repo that touches the screen.
#
#   bin/verify-menubar-tooltip.sh [outdir]      (or: make verify-tooltip)
#
# READ bin/../AGENTS.md § "Never take over the machine" BEFORE RUNNING THIS.
#
# It takes the cursor for about four seconds. That is only acceptable with the
# machine owner's go-ahead, for this run, right now. An agent must never launch
# it on its own initiative, and must never run it twice without asking again.
#
# What it does, in order, with no branches that depend on what it finds:
#
#   1. Starts a SECOND Pacer process over an in-memory fixture. The Pacer you
#      are running is untouched — not quit, not relaunched, not read from.
#   2. That process adds its own status item, opens its own menu, and moves the
#      cursor onto a row whose position it computed from its own view
#      hierarchy. Nothing here guesses coordinates.
#   3. Waits out the system tooltip delay, takes a full-screen PNG, closes the
#      menu, puts the cursor back where it was, and exits.
#
# It cannot loop, cannot prompt, and cannot leave anything behind: the status
# item goes with the process, and the fixture was never on disk.
#
# What you are looking for in the PNG: a tooltip beside the highlighted row of
# the Pacer menu. Present = `.help` now works inside NSMenu. Absent = it does
# not, and the backlog entry stands.
set -euo pipefail

OUT="${1:-$(pwd)/screenshots/live}"
APP="/Applications/Pacer.app"
BIN="$APP/Contents/MacOS/Pacer"

[ -x "$BIN" ] || { echo "no installed Pacer at $BIN — run 'make install' first"; exit 1; }
mkdir -p "$OUT"
rm -f "$OUT/menubar-tooltip.png"

# Screen recording permission is per-binary and prompts the first time. Say so
# up front rather than letting a dialog appear mid-run and look like a hang.
echo "==> Taking the cursor for ~4 seconds. Do not type or move the mouse."
echo "    (If macOS asks for Screen Recording permission, this run will fail;"
echo "     grant it and we ask you before trying again.)"
echo

PACER_SCREENSHOT_MODE=1 \
PACER_TOOLTIP_SELFTEST=1 \
PACER_TOOLTIP_SELFTEST_DIR="$OUT" \
  "$BIN" 2>&1 | grep -E '^\[Pacer tooltip-selftest\]' || true

echo
if [ -f "$OUT/menubar-tooltip.png" ]; then
  echo "    ✓ $OUT/menubar-tooltip.png"
else
  echo "    ✗ nothing captured — see the lines above"
  exit 1
fi
