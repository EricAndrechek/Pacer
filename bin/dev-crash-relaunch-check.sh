#!/bin/bash
# The on-machine check for the crash relauncher (#412): the part unit tests
# cannot reach, namely Launch Services, launchd and a real Pacer.
#
# It QUITS AND KILLS THE RUNNING PACER, so it runs only with the machine
# owner's go-ahead, for that run (AGENTS.md, "Never take over the machine").
# Bare, it prints its plan and exits. APPROVED=1 runs it. About a minute.
# It reports verdicts read from the process table and the log, not pictures.
#
# Install the build under test first (`make install`).
set -uo pipefail

APP="/Applications/Pacer.app"
RELAUNCHER="${APP}/Contents/Helpers/PacerRelauncher"
LOG="$HOME/Library/Logs/Pacer/Pacer.err.log"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

plan() {
    cat <<EOF
Crash relauncher check (#412). With APPROVED=1 it will, in about a minute:

  0. Check that ${APP} has the relauncher, that one Pacer is running, and
     that a PacerRelauncher is watching it. If not, stop and change nothing.
  1. Quit:     quit Pacer the normal way (the AppleScript quit, as the
               Makefile does). Pass: Pacer and its relauncher both exit, and
               no Pacer comes back within 15 s. Then reopen it, in the
               background (open -g; it is not running, so this is a launch,
               not a reopen).
  2. Install:  run bin/dev-quit-app.sh, which make install runs. Pass: the
               relauncher is stopped, Pacer quits, nothing comes back within
               15 s. Then reopen it in the background.
  3. Kill:     SIGKILL the running Pacer, which is what a watchdog or memory
               kill is. Pass: a new Pacer appears 10-25 s later, the log has
               the relauncher's lines, the new Pacer has its own relauncher,
               and the frontmost app is the same before and after.

What you will see: the menu-bar item disappears and comes back three times;
if the dashboard is open it closes and reopens where it was, without taking
focus; the two quits may post the usual "Pacer paused" notification, which
the relaunch clears. Nothing is clicked or typed. SIGKILL rather than a crash signal: a SIGSEGV would also put macOS's
"quit unexpectedly" dialog on screen and send a made-up crash to Sentry. The
relauncher cannot tell them apart (both are an exit without "quit"). The
kill can lose the scan cycle in flight, which the next scan redoes, and the
next daily check-in from this Mac will count one relaunch.

Leaves Pacer running (relaunched by step 3) with one relaunch in its
history, which ages out in 30 minutes. If anything fails, Pacer is reopened
on the way out.

Run it with: APPROVED=1 $0
EOF
}

if [ "${APPROVED:-}" != "1" ]; then
    plan
    exit 0
fi

START="$(date -u +%Y-%m-%dT%H:%M:%S)"
FAILED=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }

# Lines written since the run started, across a rotation at launch.
new_log() { cat "${LOG}.1" "${LOG}" 2>/dev/null | awk -v s="$START" '$1 >= s'; }
pacer_pid() { pgrep -x Pacer | head -1; }
# The relauncher watching this pid: its first argument is the pid.
relauncher_for() {
    local pid
    for pid in $(pgrep -x PacerRelauncher); do
        if [ "$(ps -o args= -p "$pid" | awk '{print $2}')" = "$1" ]; then echo "$pid"; return; fi
    done
}
front_app() { lsappinfo info -only bundleID "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*bundleID="\(.*\)".*/\1/p'; }
wait_until() {   # seconds, command...
    local limit="$1"; shift
    local end=$(( $(date +%s) + limit ))
    while [ "$(date +%s)" -lt "$end" ]; do "$@" && return 0; sleep 0.25; done
    "$@"
}
gone() { ! kill -0 "$1" 2>/dev/null; }
pacer_running() { pgrep -xq Pacer; }
relauncher_running() { pgrep -xq PacerRelauncher; }
neither_running() { ! pacer_running && ! relauncher_running; }
armed() { local p; p="$(pacer_pid)"; [ -n "$p" ] && [ -n "$(relauncher_for "$p")" ]; }
reopen() {
    open -g -a "$APP"
    wait_until 30 armed || fail "reopened Pacer has no relauncher watching it"
}
trap 'pacer_running || open -g -a "$APP" 2>/dev/null || true' EXIT

# 0. Preconditions. Nothing has been touched yet.
[ -x "$RELAUNCHER" ] || { echo "STOP  ${RELAUNCHER} is missing: install the build under test first"; exit 2; }
[ "$(pgrep -x Pacer | wc -l | tr -d ' ')" = "1" ] || { echo "STOP  expected exactly one running Pacer"; exit 2; }
armed || { echo "STOP  no PacerRelauncher is watching the running Pacer"; exit 2; }
pass "precondition: Pacer $(pacer_pid) is watched by relauncher $(relauncher_for "$(pacer_pid)")"

# 1. A normal quit is never relaunched.
pid="$(pacer_pid)"
osascript -e 'quit app "Pacer"' >/dev/null 2>&1
if wait_until 15 neither_running; then
    sleep 15
    if pacer_running; then fail "quit: Pacer came back after a normal quit"
    else pass "quit: Pacer and its relauncher exited, nothing came back"; fi
else
    fail "quit: still running after 15 s (Pacer: $(pgrep -x Pacer | xargs), relauncher: $(pgrep -x PacerRelauncher | xargs))"
fi
pacer_running || reopen

# 2. make install's quit stops the relauncher first and nothing relaunches.
"${REPO_ROOT}/bin/dev-quit-app.sh" >/dev/null
if neither_running; then
    sleep 15
    if pacer_running; then fail "install: Pacer came back after bin/dev-quit-app.sh"
    else pass "install: relauncher stopped, Pacer quit, nothing came back"; fi
else
    fail "install: still running after bin/dev-quit-app.sh"
fi
pacer_running || reopen

# 3. A kill is relaunched, in the background, by the relauncher.
pid="$(pacer_pid)"
old_relauncher="$(relauncher_for "$pid")"
front_before="$(front_app)"
killed_at="$(date +%s)"
kill -KILL "$pid"
relaunched() { local p; p="$(pacer_pid)"; [ -n "$p" ] && [ "$p" != "$pid" ]; }
if wait_until 40 relaunched; then
    took=$(( $(date +%s) - killed_at ))
    if [ "$took" -ge 9 ] && [ "$took" -le 25 ]; then pass "kill: relaunched after ${took} s"
    else fail "kill: relaunched after ${took} s, expected 10-25"; fi
    wait_until 15 armed && pass "kill: the relaunched Pacer has its own relauncher" \
        || fail "kill: the relaunched Pacer has no relauncher"
    gone "$old_relauncher" && pass "kill: the old relauncher exited" || fail "kill: the old relauncher is still running"
    sleep 2
    lines="$(new_log)"
    for expected in \
        "[Relauncher] Pacer (pid ${pid}) exited without quitting; relaunching in 10 s" \
        "[Relauncher] relaunched Pacer" \
        "[CrashRelaunch] relaunched after Pacer exited without quitting (1 of 3 in 30 min)" \
        "[CrashRelaunch] armed"; do
        printf '%s\n' "$lines" | grep -qF -- "$expected" && pass "log: ${expected}" || fail "log: missing \"${expected}\""
    done
    front_after="$(front_app)"
    if [ "$front_before" = "$front_after" ] || [ "$front_before" = "com.ericandrechek.pacer" ]; then
        pass "kill: the frontmost app is still ${front_after}"
    else
        fail "kill: the frontmost app changed from ${front_before} to ${front_after}"
    fi
else
    fail "kill: no new Pacer within 40 s"
fi

echo
if [ "$FAILED" = "0" ]; then echo "All checks passed."; else echo "Some checks FAILED; the log since ${START}Z is in ${LOG}."; fi
exit "$FAILED"
