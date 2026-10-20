#!/opt/homebrew/bin/bash
# The supervising session's wake: run it in the background and it EXITS when
# there is something to act on, printing why. Exit is the wake; relaunch after.
#
#   watch.sh [HEARTBEAT_MIN] [room]     (default 90)
#
# `room` mode is for a hold the supervisor itself is caught in (it bills the
# same login): it wakes only when room is back (SWITCH, hold over), on ERROR or
# a dead controller, and on the heartbeat. A wake during the hold would fail on
# the limit and leave nothing to wake the supervisor once room returns.
#
# Wakes on: a controller decision line (SWITCH, EXTERNAL, HOLD, hold over,
# ERROR, WARN, start), the controller dying, a main session newly stopped by a
# usage limit (stuck.py, every 2 min, each stop reported once), or the
# heartbeat, and (outside room mode) a new `pacer feedback` report in
# ~/.claude/pace/feedback.jsonl. Quiet otherwise, because every wake re-reads
# the supervisor's whole context.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROTATE_HOME=${ROTATE_HOME:-$HOME/.local/state/pacer-account-rotation}
LOG=$ROTATE_HOME/state/rotate.log
SEEN=$ROTATE_HOME/state/stuck.seen
HB=$(( ${1:-90} * 60 ))
MODE=${2:-all}
PAT=' (SWITCH|EXTERNAL|HOLD|hold over|ERROR|WARN|start)'
[ "$MODE" = room ] && PAT=' (SWITCH|hold over|ERROR|start)'
touch "$SEEN"
FB=$HOME/.claude/pace/feedback.jsonl
# The inbox only exists once someone has reported something.
fb_count() { if [ -f "$FB" ]; then wc -l <"$FB" | tr -d ' '; else echo 0; fi; }
fb_lines=$(fb_count)
start=$(date +%s)
offset=$(wc -c <"$LOG" 2>/dev/null || echo 0)
# A hold in progress makes every wake but "room is back" a trap: the supervisor
# bills the same login, its turn fails at the limit, and nothing re-arms this
# watcher. So while the controller's last word is HOLD, behave as `room` mode
# whatever was asked (2026-10-20: the manual mode switch was the only guard).
holding() { awk '/ (HOLD|holding:) /{h=1} / (hold over|SWITCH|EXTERNAL)/{h=0} END{exit !h}' "$LOG" 2>/dev/null; }
n=0
while :; do
  now=$(date +%s)
  eff=$MODE; [ "$MODE" != room ] && holding && eff=room
  PAT=' (SWITCH|EXTERNAL|HOLD|hold over|ERROR|WARN|start)'
  [ "$eff" = room ] && PAT=' (SWITCH|hold over|ERROR|start)'
  new=$(tail -c +$(( offset + 1 )) "$LOG" 2>/dev/null)
  offset=$(wc -c <"$LOG" 2>/dev/null || echo 0)
  hits=$(printf '%s\n' "$new" | grep -E "$PAT" || true)
  if [ -n "$hits" ]; then echo "rotate:"; printf '%s\n' "$hits"; exit 0; fi
  if ! "$HERE/rotate.sh" status | head -1 | grep -q '^running'; then
    echo "controller NOT running"; "$HERE/rotate.sh" log 3; exit 0
  fi
  if [ "$eff" != room ] && [ $(( n % 2 )) = 0 ]; then
    fresh=$(python3 -I "$HERE/stuck.py" 6 2>/dev/null | while read -r line; do
      key=$(printf '%s' "$line" | awk '{print $1, $NF}')
      grep -qxF "$key" "$SEEN" || { echo "$key" >>"$SEEN"; echo "$line"; }
    done)
    if [ -n "$fresh" ]; then echo "stuck:"; printf '%s\n' "$fresh"; exit 0; fi
  fi
  if [ "$eff" != room ]; then
    cur=$(fb_count)
    if [ "$cur" -gt "$fb_lines" ]; then
      echo "feedback:"; tail -n $(( cur - fb_lines )) "$FB" | cut -c1-600; exit 0
    fi
    [ "$cur" -lt "$fb_lines" ] && fb_lines=$cur
  fi
  # No heartbeat wake while an automatic hold lasts; it restarts after.
  [ "$eff" = room ] && [ "$MODE" != room ] && start=$now
  if [ $(( now - start )) -ge "$HB" ]; then
    echo "heartbeat ($(( HB / 60 )) min)"; grep 'status:' "$LOG" | tail -1; exit 0
  fi
  n=$(( n + 1 ))
  sleep 60
done
