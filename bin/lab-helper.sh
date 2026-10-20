#!/usr/bin/env bash
# Start, stop or check the prediction-lab helper (research/lab/helper): a
# loopback HTTP server that serves research forecasters to a dev build of
# Pacer. Reads the live store read-only. See research/lab/helper/README.md.
#
#   bin/lab-helper.sh start|stop|restart|status
#
# PACER_LAB_PORT (default 7231) picks the port; PACER_LAB_STORE another store.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_DIR="$REPO_ROOT/research/lab/helper"
LOG_DIR="$HOME/Library/Logs/Pacer"
PORT="${PACER_LAB_PORT:-7231}"
# One log and pid file per port, so a second helper on another port (a smoke
# test, say) never mistakes the overnight one for itself.
SUFFIX="$([ "$PORT" = 7231 ] && echo "" || echo "-$PORT")"
LOG="$LOG_DIR/lab-helper$SUFFIX.log"
PIDFILE="$LOG_DIR/lab-helper$SUFFIX.pid"

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

healthy() { curl -fsS --max-time 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; }

start() {
    if running; then
        echo "lab helper already running (pid $(cat "$PIDFILE")) on http://127.0.0.1:$PORT"
        return 0
    fi
    if healthy; then
        echo "something already answers on 127.0.0.1:$PORT; not starting a second helper" >&2
        return 1
    fi
    mkdir -p "$LOG_DIR"
    (cd "$HELPER_DIR" && nohup uv run server.py --port "$PORT" --pidfile "$PIDFILE" >>"$LOG" 2>&1 &)
    for _ in $(seq 1 50); do
        if healthy; then
            echo "lab helper up on http://127.0.0.1:$PORT (pid $(cat "$PIDFILE" 2>/dev/null || echo '?')), log $LOG"
            return 0
        fi
        sleep 0.2
    done
    echo "lab helper did not come up; last lines of $LOG:" >&2
    tail -20 "$LOG" >&2
    return 1
}

stop() {
    if ! running; then
        echo "lab helper not running"
        rm -f "$PIDFILE"
        return 0
    fi
    local pid
    pid="$(cat "$PIDFILE")"
    kill "$pid"
    for _ in $(seq 1 25); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid"; fi
    rm -f "$PIDFILE"
    echo "lab helper stopped (pid $pid)"
}

status() {
    if running && healthy; then
        echo "lab helper running (pid $(cat "$PIDFILE")) on http://127.0.0.1:$PORT"
        curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz"
        echo
    elif running; then
        echo "lab helper process $(cat "$PIDFILE") is up but not answering on $PORT; see $LOG"
        return 1
    else
        echo "lab helper not running"
        return 1
    fi
}

case "${1:-start}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    *) echo "usage: $0 start|stop|restart|status" >&2; exit 2 ;;
esac
