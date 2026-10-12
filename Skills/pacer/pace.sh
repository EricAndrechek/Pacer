#!/usr/bin/env bash
#
# pace.sh — run `pacer pace`, the pacing commands of the `pacer` command line
# inside Pacer.app (#194). Every flag, exit code, state file and line of
# output is the command line's; `pace.sh --help` prints them all.
#
# The command line is found, in order:
#   1. $PACER_CLI, when set (and then only there);
#   2. `pacer` beside this script, which Pacer links when it installs the skill
#      and re-points at every launch;
#   3. /Applications/Pacer.app/Contents/Helpers/pacer.
#
# Without one there is nothing to read, so this exits 2 — "no data source" —
# which every caller already treats as "proceed ungated".
set -u
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${PACER_CLI:-}" ]; then
  candidates=("$PACER_CLI")
else
  candidates=("$dir/pacer" "/Applications/Pacer.app/Contents/Helpers/pacer")
fi
for cli in "${candidates[@]}"; do
  [ -x "$cli" ] && exec "$cli" pace "$@"
done

echo "pace: Pacer's command line was not found (looked in: ${candidates[*]})." >&2
echo "pace: open Pacer once, or reinstall the skill from Pacer → Settings → Integrations. Proceeding ungated." >&2
exit 2
