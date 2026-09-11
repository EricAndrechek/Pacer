#!/usr/bin/env bash
#
# pace-guard.sh — run `claude` only once Pacer says a usage window has
# headroom. A thin wrapper over `pace.sh wait`: the long waiting happens out
# here in the shell, because a single Claude session cannot sleep for hours.
#
# Usage:  pace-guard.sh [claude args...]
#         pace-guard.sh -p "keep working on the migration"
#
# Env: PACE_THRESHOLD (default 85), plus PACER_API / PACE_TOKEN / PACE_STATE
#      / PACE_ACCOUNT. PACE_WINDOW narrows which windows count.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP="${PACE_THRESHOLD:-85}"
ARGS=(wait --cap "$CAP")
[ -n "${PACE_WINDOW:-}" ] && ARGS+=(--window "$PACE_WINDOW")

"$HERE/pace.sh" "${ARGS[@]}"; code=$?
case "$code" in
  0|2) exec claude "$@" ;;   # headroom restored, or API off (cannot gate) → go
  20)  echo "pace-guard: the blocker resets further out than --max-wait — not launching."
       echo "            Resume later; run: $0 $*" ; exit 20 ;;
  *)   echo "pace-guard: pace.sh wait exited $code — not launching." ; exit "$code" ;;
esac
