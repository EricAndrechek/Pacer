#!/opt/homebrew/bin/bash
# Rotates this Mac's Claude Code login between the owner's cswap accounts so every
# session keeps running. See SKILL.md for the rules and why they are what they
# are.
#
#   rotate.sh start [why]  run the controller detached (survives the session that
#                          started it, including a Claude Code restart); logs why
#   rotate.sh stop         stop it
#   rotate.sh status       running? + the last status line + the active account
#   rotate.sh log [N]      the last N decision/status lines (default 20)
#   rotate.sh dry          one decision pass on live readings, printed; never switches
#   rotate.sh run          the loop itself, in the foreground (what start runs)
#
# Thresholds live in rotate.conf beside this script and are re-read every loop.
# Accounts are whatever `cswap list --json` reports, so adding a fifth login to
# cswap needs no edit here. ROTATE_CONF and ROTATE_STATE override the conf file
# and the state directory (tests.sh uses both).
#
# Needs bash 4+ (associative arrays): /opt/homebrew/bin/bash, not /bin/bash.
set -u
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
HERE=$(dirname "$SELF")
# State and config live outside the repo, so a branch switch, `git clean` or a
# removed worktree never touches a running controller's log, pid or settings.
ROTATE_HOME=${ROTATE_HOME:-$HOME/.local/state/pacer-account-rotation}
STATE_DIR=${ROTATE_STATE:-$ROTATE_HOME/state}
CONF=${ROTATE_CONF:-$ROTATE_HOME/rotate.conf}
mkdir -p "$STATE_DIR"
LOG=$STATE_DIR/rotate.log
PIDFILE=$STATE_DIR/rotate.pid
# The last switch (when, from which slot, that slot's 5h reset instant and use
# at the time, to which slot). Kept on disk so a stop/start does not forget
# the one-switch gap or the ping-pong guard.
LASTFILE=$STATE_DIR/last_switch

is_running() {
  local pid
  [ -f "$PIDFILE" ] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null)
  # Any copy of this script (rotate.sh, rotate.new.sh, state/rotate.v4.sh), so
  # a renamed copy can never start a second controller beside a running one.
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= | grep -qE 'rotate[^/ ]*\.sh run'
}

DRY=0
case "${1:-status}" in
  start)
    if is_running; then echo "already running (pid $(cat "$PIDFILE"))"; exit 0; fi
    # Its own process session, so neither a closed terminal nor the Claude Code
    # process that launched it takes it down. macOS has no setsid(1).
    nohup python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
      "$SELF" run "${2:-}" </dev/null >>"$STATE_DIR/rotate.out" 2>&1 &
    echo $! >"$PIDFILE"
    sleep 2
    if is_running; then echo "started (pid $(cat "$PIDFILE")); log: $LOG"; else echo "failed to start; see $STATE_DIR/rotate.out"; exit 1; fi
    exit 0;;
  stop)
    if is_running; then kill "$(cat "$PIDFILE")"; rm -f "$PIDFILE"; echo stopped; else echo "not running"; fi
    exit 0;;
  status)
    if is_running; then echo "running (pid $(cat "$PIDFILE"))"; else echo "NOT running"; fi
    grep -E 'status:|SWITCH|EXTERNAL|HOLD' "$LOG" 2>/dev/null | tail -2
    cswap status 2>/dev/null | head -1 | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email>/g'
    exit 0;;
  log)
    tail -n "${2:-20}" "$LOG" 2>/dev/null; exit 0;;
  dry) DRY=1;;
  run) ;;
  *) echo "usage: rotate.sh start [why]|stop|status|log [N]|dry|run" >&2; exit 2;;
esac
WHY=${2:-}

# ---- the controller ---------------------------------------------------------

API=${PACER_API:-http://127.0.0.1:7223}
# No fixed budget (owner, 2026-10-07): the active account is used up to its
# safe limit, the same one `pacer gate` pauses at by default: 100% minus how
# far usage can climb before a fresher reading (burn × (reading age + 5 min),
# at least 1 point). The switch happens EARLY points before it, so it lands
# before any session's gate trips.
#
# Room (owner, 2026-10-20): the old "real room" margin (10 below the target's
# switch point, and 10 below the active) dates from when a Claude session did
# the switching and a session on a spent login could not switch back. This
# controller is a bash script that needs no quota, so it can always switch
# back. What a switch still costs is one cache rewrite per busy session
# (≈3 points of a 5h window with ~6 busy, ≈0 idle).
#
# The room a target needs is burn-aware (2026-10-20, 22:03Z and 22:08Z): a
# bridge onto a few points released every waiting session at once and the
# target was full within minutes. A target needs BRIDGE_MIN_MINUTES of the
# active account's current burn below its own switch point, and never less
# than BRIDGE_MIN_PTS; the expiring rule's bar is the same with EXPIRE_MIN_PTS.
load_conf() {
  EARLY=2; WEEK_MAX=90; STAGGER=9000; MIN_SWITCH_GAP=300
  BRIDGE_MIN_PTS=6; BRIDGE_MIN_MINUTES=20; BURN_UNKNOWN=40
  EXPIRE_WINDOW=2700; EXPIRE_MIN_PTS=8; WEEK_ROOM_MIN=3
  EXCLUDE=""; RESERVE_SLOT=""; RESERVE_WEEK_MAX=97
  # A WEEK_MAX_<slot> deleted from the conf must stop applying, not linger
  # from an earlier read.
  unset "${!WEEK_MAX_@}"
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"
}
wkmax() { local v="WEEK_MAX_$1"; echo "${!v:-$WEEK_MAX}"; }
# Points of room needed: BRIDGE_MIN_MINUTES at burn $2 %/h, rounded up, at
# least $1.
bar() { local n=$(( ($2 * BRIDGE_MIN_MINUTES + 59) / 60 )); [ "$n" -lt "$1" ] && n=$1; echo "$n"; }
excluded() { case " $EXCLUDE " in *" $1 "*) return 0;; esac; return 1; }

ts() { date -u +%H:%M:%S; }
say() { if [ "$DRY" = 1 ]; then echo "$(ts) $*"; else echo "$(ts) $*" >>"$LOG"; fi; }

declare -A U5=() R5=() U7=() R7=() RESET_AT=() RESET7_AT=() B5=() A5=() ID=() STAT=() AGE=() LEXP=()
declare -A CU5=() CR5=() CU7=() CR7=()
SLOTS=(); CACT=""
read_metrics() {
  local body
  body=$(curl -s -m 8 "$API/metrics") || return 1
  [ -n "$body" ] || return 1
  U5=(); R5=(); U7=(); B5=(); A5=()
  while read -r kind acct win val; do
    case "$kind:$win" in
      used:five_hour)  U5[$acct]=$val;;
      reset:five_hour) R5[$acct]=$val;;
      used:seven_day)  U7[$acct]=$val;;
      recent:five_hour) B5[$acct]=$val;;
      model:five_hour) [ -n "${B5[$acct]:-}" ] || B5[$acct]=$val;;
      age:five_hour)   A5[$acct]=$val;;
    esac
  done < <(printf '%s\n' "$body" | awk -F'"' '
    /^pacer_rate_limit_used_ratio\{account="[^"]+",window="(five_hour|seven_day)"\}/ {
      split($0, v, " "); printf "used %s %s %d\n", substr($2,1,8), $4, v[2]*100 + 0.5 }
    /^pacer_rate_limit_reset_seconds\{account="[^"]+",window="five_hour"\}/ {
      split($0, v, " "); printf "reset %s %s %d\n", substr($2,1,8), $4, v[2] }
    /^pacer_rate_limit_recent_burn_percent_per_hour\{account="[^"]+",window="five_hour"\}/ {
      split($0, v, " "); printf "recent %s %s %d\n", substr($2,1,8), $4, v[2] }
    /^pacer_rate_limit_burn_percent_per_hour\{account="[^"]+",window="five_hour"\}/ {
      split($0, v, " "); printf "model %s %s %d\n", substr($2,1,8), $4, v[2] }
    /^pacer_rate_limit_sample_age_seconds\{account="[^"]+",window="five_hour"\}/ {
      split($0, v, " "); printf "age %s %s %d\n", substr($2,1,8), $4, v[2] }')
}
# Every account's 5h/7d from cswap's own cache, kept fresh by its menu bar app.
# The primary source: under memory pressure Pacer's API stopped answering at all
# (2026-10-07, Pacer #191), and `cswap list` answers in a quarter of a second.
# A missing figure stays missing ("-"): it must never read as 0% and room.
read_cswap() {
  local out slot id st u5 r5 u7 r7 age act lexp
  out=$(cswap list --json 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  SLOTS=(); CU5=(); CR5=(); CU7=(); CR7=(); CACT=""
  while IFS=$'\t' read -r slot id st u5 r5 u7 r7 age act lexp; do
    [ -n "$slot" ] || continue
    SLOTS+=("$slot"); ID[$slot]=$id; STAT[$id]=$st; AGE[$id]=$age
    [ "$u5" != "-" ] && CU5[$id]=$u5
    [ "$r5" != "-" ] && CR5[$id]=$r5
    [ "$u7" != "-" ] && CU7[$id]=$u7
    [ "$r7" != "-" ] && CR7[$id]=$r7
    [ "$act" = 1 ] && CACT=$slot
    LEXP[$slot]=$lexp
  done < <(printf '%s' "$out" | jq -r --argjson now "$(date +%s)" '
    def secs: if . == null or . == "" then "-"
      else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 - $now | floor | tostring) end;
    def pct: if . == null then "-" else (round | tostring) end;
    .accounts[] | [ (.number | tostring), .organizationUuid[0:8], (.usageStatus // "?"),
      (.usage.fiveHour.pct | pct), (.usage.fiveHour.resetsAt | secs),
      (.usage.sevenDay.pct | pct), (.usage.sevenDay.resetsAt | secs),
      ((.usageAgeSeconds // 0) | floor | tostring), (if .active then "1" else "0" end),
      (.loginExpiresAt | secs) ] | @tsv' 2>/dev/null)
  [ ${#SLOTS[@]} -gt 0 ]
}

# Effective use: 0 once its reset has passed, since the stored reading
# describes the window that ended. cswap's cache still said "93%, resets in 0m"
# a minute after a reset. Unknown prints "-".
eff5() { local r=${R5[$1]:-}; if [ -n "$r" ] && [ "$r" -le 0 ]; then echo 0; else echo "${U5[$1]:--}"; fi; }
eff7() { local r=${R7[$1]:-}; if [ -n "$r" ] && [ "$r" -le 0 ]; then echo 0; else echo "${U7[$1]:--}"; fi; }
# Seconds until a RUNNING window resets; "-" when no window is running (idle,
# or its reset has passed) or the reset is unknown.
left5() { local r=${R5[$1]:-}; if [ -n "$r" ] && [ "$r" -gt 0 ]; then echo "$r"; else echo -; fi; }
left7() { local r=${R7[$1]:-}; if [ -n "$r" ] && [ "$r" -gt 0 ]; then echo "$r"; else echo -; fi; }
# pace's safe limit for one account's 5h window. Unknown burn (Pacer not
# answering): 95, since this decides switches rather than gates.
safe5() {
  local b=${B5[$1]:-} age=${A5[$1]:-300}
  [ -n "$b" ] || { echo 95; return; }
  awk -v b="$b" -v age="$age" 'BEGIN { if (b < 0) b = 0; m = b * (age + 300) / 3600
    if (m < 1) m = 1; m = (m == int(m)) ? m : int(m) + 1; print 100 - m }'
}
switch_at() { echo $(( $(safe5 "$1") - EARLY )); }
active_slot() { cswap status 2>/dev/null | awk 'NR == 1 { if (match($0, /Account-[0-9]+/)) print substr($0, RSTART + 8, RLENGTH - 8) }'; }
fmt_left() {
  local s=$1; [ "$s" = - ] && { echo -; return; }
  if [ "$s" -ge 86400 ]; then printf '%dd%02dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  else printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 )); fi
}
# "resets 0h26m" for a running window, "idle" for none.
win_desc() {
  local l; l=$(left5 "$1")
  if [ "$l" != - ]; then echo "resets $(fmt_left "$l")"
  elif [ "$(eff5 "$1")" = 0 ]; then echo idle
  else echo "reset unknown"; fi
}

# "Expiring first" (owner, 2026-10-20): when several accounts could take the
# login, spend the room that will be lost soonest. A running 5h window's room
# expires at its reset; an idle account's does not expire (using it starts a
# fresh 5 h window), so it ranks as now + 5 h. Ties go to the sooner 7d reset,
# then to the most 5h room. Lower key = better; the parts are fixed-width so
# one integer compares all three.
rank_key() {  # id room
  local l5 l7; l5=$(left5 "$1"); l7=$(left7 "$1")
  [ "$l5" = - ] && l5=18000; [ "$l5" -gt 18000 ] && l5=18000
  [ "$l7" = - ] && l7=604800; [ "$l7" -gt 604800 ] && l7=604800
  echo $(( l5 * 100000000000 + l7 * 10000 + 1000 - $2 ))
}
# The stagger rule's idle pick: soonest 7d reset, then lowest 7d, then room.
idle_key() {  # id room
  local l7 w; l7=$(left7 "$1"); w=$(eff7 "$1")
  [ "$l7" = - ] && l7=604800; [ "$l7" -gt 604800 ] && l7=604800
  echo $(( l7 * 10000000 + w * 10000 + 1000 - $2 ))
}

# Ping-pong guard: never go back to the slot we just left within
# MIN_SWITCH_GAP, unless its 5h window has reset since (fresh room is a reason
# to go back; anything else is churn).
left_slot=""; left_at=0; left_reset=-; left_u5=-
if [ -f "$LASTFILE" ]; then read -r left_at left_slot left_reset left_u5 _ <"$LASTFILE" 2>/dev/null || true; fi
[[ $left_at =~ ^[0-9]+$ ]] || { left_at=0; left_slot=""; }
[[ $left_reset =~ ^[0-9]+$ ]] || left_reset=-
[[ $left_u5 =~ ^[0-9]+$ ]] || left_u5=-
just_left() {  # slot
  local v
  [ -n "$left_slot" ] && [ "$1" = "$left_slot" ] || return 1
  [ $(( now - left_at )) -lt "$MIN_SWITCH_GAP" ] || return 1
  [ "$left_reset" != - ] && [ "$now" -ge "$left_reset" ] && return 1
  v=$(eff5 "${ID[$1]}")
  [ "$v" != - ] && [ "$left_u5" != - ] && [ "$v" -lt "$left_u5" ] && return 1
  return 0
}
# Record leaving slot $1 for $2, in memory and on disk.
note_left() {
  local fid=${ID[$1]:-} t; t=$(date +%s)
  left_slot=$1; left_at=$t; left_reset=-; left_u5=-
  if [ -n "$fid" ]; then
    [ "$(left5 "$fid")" != - ] && [ -n "${RESET_AT[$fid]:-}" ] && left_reset=${RESET_AT[$fid]}
    left_u5=$(eff5 "$fid")
  fi
  [ "$DRY" = 1 ] || printf '%s %s %s %s %s\n' "$left_at" "$left_slot" "$left_reset" "$left_u5" "$2" >"$LASTFILE"
}

last_switch=$left_at; last_set=""
switch_to() {
  local slot=$1 why=$2 out
  if [ "$DRY" = 1 ]; then say "WOULD SWITCH → $slot (${ID[$slot]}) [$why]"; return; fi
  out=$(cswap switch "$slot" 2>&1 | tail -1 | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email>/g')
  sleep 3
  if [ "$(active_slot)" = "$slot" ]; then
    say "SWITCH → $slot (${ID[$slot]}) [$why] $out"
    note_left "$act" "$slot"
    last_switch=$(date +%s); last_set=$slot
  else
    say "ERROR switch to $slot failed [$why]: $out"
  fi
}

load_conf
if [ "$DRY" = 0 ]; then
  echo $$ >"$PIDFILE"
  say "start${WHY:+ ($WHY)}: switch at the safe limit - ${EARLY}; a target needs ${BRIDGE_MIN_MINUTES} min of the active burn (at least ${BRIDGE_MIN_PTS} points) below its own switch point; expiring room first (EXPIRE_WINDOW=${EXPIRE_WINDOW}s, at least ${EXPIRE_MIN_PTS} points); WEEK_MAX=$WEEK_MAX STAGGER=${STAGGER}s, accounts from cswap, exclude [${EXCLUDE}], reserve [${RESERVE_SLOT:-none}]"
fi
# A missing reading for the active account is normal for a loop or two after a
# switch (cswap reads the new login); only a gap of GAP_WARN_SECS is worth a WARN.
GAP_WARN_SECS=300; missing_since=0
# gap_warn_due NOW: track the first-missing time; true once it has lasted long enough.
gap_warn_due() {
  [ "$missing_since" = 0 ] && missing_since=$1
  [ "$DRY" = 1 ] || [ $(( $1 - missing_since )) -ge "$GAP_WARN_SECS" ]
}
last_status=0; hold_since=0; hold_said=0; hold_burn=0; rsv_err=0
declare -A PREV_STAT=() LEXP_SAID=() BAD_SINCE=() BAD_SAID=()
while :; do
  load_conf
  now=$(date +%s)
  # Readings: cswap first; Pacer may only raise a figure, and only when both
  # describe the same window (resets within 15 min of each other). If neither
  # answers, the reset instants from the last good read still let a reset count.
  pacer_ok=0; read_metrics && pacer_ok=1
  if read_cswap; then
    declare -A P5=() PR5=() P7=()
    if [ $pacer_ok = 1 ]; then
      for k in "${!U5[@]}"; do P5[$k]=${U5[$k]}; done
      for k in "${!R5[@]}"; do PR5[$k]=${R5[$k]}; done
      for k in "${!U7[@]}"; do P7[$k]=${U7[$k]}; done
    fi
    U5=(); R5=(); U7=(); R7=()
    for k in "${!CU5[@]}"; do U5[$k]=${CU5[$k]}; done
    for k in "${!CR5[@]}"; do R5[$k]=${CR5[$k]}; done
    for k in "${!CU7[@]}"; do U7[$k]=${CU7[$k]}; done
    for k in "${!CR7[@]}"; do R7[$k]=${CR7[$k]}; done
    for k in "${!P5[@]}"; do
      pr=${PR5[$k]:-}; cr=${R5[$k]:-}
      if [ -n "$pr" ] && [ -n "$cr" ] && [ "$pr" -gt 0 ] && [ "$cr" -gt 0 ] \
         && [ $(( pr > cr ? pr - cr : cr - pr )) -le 900 ] && [ "${P5[$k]}" -gt "${U5[$k]:-0}" ]; then
        U5[$k]=${P5[$k]}
      fi
      [ -n "${U7[$k]:-}" ] && [ "${P7[$k]:-0}" -gt "${U7[$k]}" ] && U7[$k]=${P7[$k]}
    done
    for k in "${!R5[@]}"; do RESET_AT[$k]=$(( now + R5[$k] )); done
    for k in "${!R7[@]}"; do RESET7_AT[$k]=$(( now + R7[$k] )); done
  elif [ ${#RESET_AT[@]} -gt 0 ] && [ ${#SLOTS[@]} -gt 0 ]; then
    # cswap silent: keep its last figures, let cached resets count.
    for k in "${!RESET_AT[@]}"; do R5[$k]=$(( RESET_AT[$k] - now )); done
    for k in "${!RESET7_AT[@]}"; do R7[$k]=$(( RESET7_AT[$k] - now )); done
    [ $(( now % 600 )) -lt 60 ] && say "WARN no fresh cswap readings; using cached figures and reset times"
  else
    say "WARN no readings and nothing cached; holding"; [ "$DRY" = 1 ] && exit 1; sleep 60; continue
  fi
  act=$(active_slot)
  [ -n "$act" ] || act=$CACT
  [ -n "$act" ] && [ -n "${ID[$act]:-}" ] || { say "WARN active account unreadable; holding"; [ "$DRY" = 1 ] && exit 1; sleep 60; continue; }
  actid=${ID[$act]}
  # A login cswap can no longer refresh drops out of rotation silently (it is
  # never a target). Say so once, loudly, because only the owner can fix it.
  for s in "${SLOTS[@]}"; do
    st=${STAT[${ID[$s]}]:-?}
    # Only a dead login needs the owner. cswap's other non-ok states clear on their
    # own: token_expired on the active slot is a deferred refresh it retries
    # (Claude Code renews the live token itself), keychain_unavailable is a
    # lock, unavailable is a failed fetch. 2026-10-19 06:16Z: slot 3 read
    # token_expired for under a minute and the first version of this check
    # told the owner to re-log. Those get a WARN only if they last 15 min.
    if [ "$st" = ok ]; then
      [ -n "${BAD_SAID[$s]:-}" ] && say "recovered: slot $s (${ID[$s]}) is ok again"
      BAD_SINCE[$s]=""; BAD_SAID[$s]=""
    else
      [ -n "${BAD_SINCE[$s]:-}" ] || BAD_SINCE[$s]=$now
      case "$st" in
        relogin_required|no_credentials)
          if [ "${BAD_SAID[$s]:-}" != ERROR ]; then
            say "ERROR slot $s (${ID[$s]}) is $st: out of rotation until the owner logs in with Claude Code as that account, then runs \`cswap add\`"
            BAD_SAID[$s]=ERROR
          fi;;
        *)
          if [ -z "${BAD_SAID[$s]:-}" ] && [ $(( now - BAD_SINCE[$s] )) -ge 900 ]; then
            say "WARN slot $s (${ID[$s]}) has been $st for $(( (now - BAD_SINCE[$s]) / 60 ))m (cswap normally clears this itself)"
            BAD_SAID[$s]=WARN
          fi;;
      esac
    fi
    PREV_STAT[$s]=$st
    # A login has a fixed lifetime (Claude Code's refreshTokenExpiresAt); only a
    # fresh /login renews it. Warn 3 days and 1 day ahead so the owner re-logs at a
    # time that suits him, not when a 2 a.m. switch finds the slot dead
    # (account 3, 2026-10-19: lapsed 15:50Z, found dead at 21:43Z).
    le=${LEXP[$s]:-}
    if [ -n "$le" ] && [ "$le" != - ] && [ "$st" = ok ]; then
      lvl=""; [ "$le" -le 259200 ] && lvl=WARN; [ "$le" -le 86400 ] && lvl=ERROR
      if [ -n "$lvl" ] && [ "${LEXP_SAID[$s]:-}" != "$lvl" ]; then
        say "$lvl login for slot $s (${ID[$s]}) expires in $(fmt_left "$le"): the owner needs to /login as that account, then \`cswap add\` (and switch back if it isn't the one in use)"
        LEXP_SAID[$s]=$lvl
      fi
    fi
  done
  # A switch made by someone else (the owner by hand, cswap's own auto mode) is
  # adopted, not fought: log it and give it the same grace as our own,
  # including the ping-pong guard on the slot it left.
  if [ -n "$last_set" ] && [ "$act" != "$last_set" ]; then
    say "EXTERNAL: active $last_set → $act (adopted)"
    note_left "$last_set" "$act"
    last_switch=$now
  fi
  last_set=$act

  # The burn every target is measured against: the active account's recent
  # 5h burn from Pacer, since every session follows the login. BURN_OVERRIDE
  # (dry mode only) is for tests. During a hold the sessions are paused, so the
  # recent burn falls toward 0 while the demand waiting behind the hold does
  # not: the burn from when the hold began stays the floor until it ends, or
  # the bar would sink to BRIDGE_MIN_PTS and bridge onto a sliver again.
  burn=${B5[$actid]:-}; burn_src=pacer
  [ -n "$burn" ] || { burn=$BURN_UNKNOWN; burn_src=assumed; }
  if [ "$DRY" = 1 ] && [ -n "${BURN_OVERRIDE:-}" ]; then burn=${BURN_OVERRIDE%%.*}; burn_src=override; fi
  if [ "$hold_said" = 1 ] && [ "$hold_burn" -gt "$burn" ]; then burn=$hold_burn; burn_src="since the hold began"; fi
  need=$(bar "$BRIDGE_MIN_PTS" "$burn"); xneed=$(bar "$EXPIRE_MIN_PTS" "$burn")

  if [ "$DRY" = 1 ] || [ $(( now - last_status )) -ge 600 ]; then
    line="status: on $act"
    for s in "${SLOTS[@]}"; do
      sid=${ID[$s]}
      line+=" | $s: 5h $(eff5 "$sid")% (sw $(switch_at "$sid")) left $(fmt_left "$(left5 "$sid")") 7d $(eff7 "$sid")% left $(fmt_left "$(left7 "$sid")") [${STAT[$sid]} $(( ${AGE[$sid]:-0} / 60 ))m]"
    done
    line+=" | burn ${burn}%/h ($burn_src): a target needs ${need} points, expiring ${xneed}"
    say "$line"
    last_status=$now
  fi

  mine=$(eff5 "$actid"); mywk=$(eff7 "$actid"); myleft=$(left5 "$actid"); at=$(switch_at "$actid")
  if [ "$mine" = - ] || [ "$mywk" = - ]; then
    gap_warn_due "$now" && say "WARN no reading for the active account $act; holding"; [ "$DRY" = 1 ] && exit 1; sleep 60; continue
  fi
  missing_since=0
  # The active's own room is about to be lost at its reset: spending it beats
  # moving away (blocks the expiring and stagger rules, not the limit ones).
  myexp=0
  [ "$myleft" != - ] && [ "$myleft" -le "$EXPIRE_WINDOW" ] && [ $(( at - mine )) -ge "$xneed" ] && myexp=1
  if [ "$DRY" = 1 ] || [ $(( now - last_switch )) -ge "$MIN_SWITCH_GAP" ]; then
    # Every target choice goes through one filter (EXCLUDE, status ok, both
    # readings present, 7d below its ceiling, `need` points of 5h room, not
    # the slot just left) and one ranking (rank_key).
    best=""; bestkey=""; idle=""; idlekey=""; exp=""; expkey=""; others=""
    for s in "${SLOTS[@]}"; do
      [ "$s" = "$act" ] && continue
      sid=${ID[$s]}; v=$(eff5 "$sid"); w=$(eff7 "$sid"); l5=$(left5 "$sid")
      room=-; [ "$v" != - ] && room=$(( $(switch_at "$sid") - v ))
      why=""
      if excluded "$s"; then why=excluded
      elif [ "${STAT[$sid]:-?}" != ok ]; then why=${STAT[$sid]:-?}
      # A missing figure is never 0% and room.
      elif [ "$v" = - ] || [ "$w" = - ]; then why="no reading"
      elif [ "$w" -ge "$(wkmax "$s")" ]; then why="7d cap $(wkmax "$s")%, 7d resets in $(fmt_left "$(left7 "$sid")")"
      # A point or two of weekly room is minutes of work, then a second switch
      # off it (2026-10-21 10:40Z: stagger chose an account at 7d 89% of 90).
      elif [ "$w" -gt $(( $(wkmax "$s") - WEEK_ROOM_MIN )) ]; then why="7d within ${WEEK_ROOM_MIN} of its cap"
      elif [ "$room" -lt "$need" ]; then why="room < $need"
      elif just_left "$s"; then why="just left"
      fi
      others+="$s: ${v}% room ${room}, $(win_desc "$sid"), 7d ${w}%${why:+ [$why]} | "
      [ -n "$why" ] && continue
      k=$(rank_key "$sid" "$room")
      if [ -z "$best" ] || [ "$k" -lt "$bestkey" ]; then best=$s; bestkey=$k; bestv=$v; bestroom=$room; fi
      if [ "$v" = 0 ] && [ "$l5" = - ]; then
        k2=$(idle_key "$sid" "$room")
        if [ -z "$idle" ] || [ "$k2" -lt "$idlekey" ]; then idle=$s; idlekey=$k2; fi
      fi
      # Use it or lose it: a running window resetting soon, with room worth a
      # switch, resetting before the active's own.
      if [ "$l5" != - ] && [ "$l5" -le "$EXPIRE_WINDOW" ] && [ "$room" -ge "$xneed" ] \
         && [ $(( burn * l5 )) -ge $(( EXPIRE_MIN_PTS * 3600 )) ] \
         && { [ "$myleft" = - ] || [ "$l5" -lt "$myleft" ]; }; then
        if [ -z "$exp" ] || [ "$k" -lt "$expkey" ]; then exp=$s; expkey=$k; expv=$v; exproom=$room; expleft=$l5; fi
      fi
    done
    others=${others% | }
    # The reserve: only when the active account is at its 5h limit and no
    # normal account has room. Never chosen by the stagger or expiring rules.
    rsv=""
    if [ -n "$RESERVE_SLOT" ] && [ -n "${ID[$RESERVE_SLOT]:-}" ] && [ -z "$best" ] && [ "$RESERVE_SLOT" != "$act" ]; then
      rsid=${ID[$RESERVE_SLOT]}; rv=$(eff5 "$rsid"); rw=$(eff7 "$rsid")
      if [ "$rv" != - ] && [ "$rw" != - ] && [ "${STAT[$rsid]}" = ok ] \
         && [ $(( $(switch_at "$rsid") - rv )) -ge "$need" ] && [ "$rw" -lt "$RESERVE_WEEK_MAX" ] \
         && ! just_left "$RESERVE_SLOT"; then
        rsv=$RESERVE_SLOT
      fi
    fi
    # On the reserve past its cap with nowhere to go: the owner decides, loudly, once.
    if [ -n "$RESERVE_SLOT" ] && [ "$act" = "$RESERVE_SLOT" ] && [ "$mywk" -ge "$RESERVE_WEEK_MAX" ] && [ -z "$best" ]; then
      [ "$rsv_err" = 0 ] && say "ERROR reserve $act at 7d ${mywk}% (cap ${RESERVE_WEEK_MAX}%) and nowhere with room — the owner's call"
      rsv_err=1
    else
      rsv_err=0
    fi
    # Don't pick a target the stagger rule would leave at once. A running window
    # with more than EXPIRE_WINDOW but at most STAGGER left, while an idle
    # account qualifies, means two switches (and two cache rewrites in every busy
    # session) for one move (2026-10-21: 10:45Z to it, 10:51Z off it). Inside
    # EXPIRE_WINDOW the stagger rule yields to its expiring room, so keep it.
    pick=$best; pickv=${bestv:-}; pickroom=${bestroom:-}
    if [ -n "$best" ] && [ -n "$idle" ] && [ "$idle" != "$best" ]; then
      bl=$(left5 "${ID[$best]}")
      if [ "$bl" != - ] && [ "$bl" -gt "$EXPIRE_WINDOW" ] && [ "$bl" -le "$STAGGER" ]; then
        pick=$idle; pickv=$(eff5 "${ID[$idle]}"); pickroom=$(( $(switch_at "${ID[$idle]}") - pickv ))
      fi
    fi
    held=0
    # Limit: no "GAP below the active" test any more. Any target with room
    # for BRIDGE_MIN_MINUTES of burn beats pausing every session; a nearly full
    # one bridges, and this rule (or stagger) brings the login back later.
    if [ "$mine" -ge "$at" ] && [ -n "$best" ]; then
      kind=limit; [ "$pickroom" -lt 20 ] && kind=bridge
      switch_to "$pick" "$kind: $act at ${mine}% (switch point ${at}%, 7d ${mywk}%, 5h resets in $(fmt_left "$myleft")), $pick at ${pickv}% (room ${pickroom} ≥ ${need} for ${BRIDGE_MIN_MINUTES} min at ${burn}%/h, $(win_desc "${ID[$pick]}"))"
    elif [ "$mine" -ge "$at" ] && [ -n "$rsv" ]; then
      switch_to "$rsv" "reserve: $act at ${mine}% and nothing else has room; $rsv at $(eff5 "${ID[$rsv]}")% (7d $(eff7 "${ID[$rsv]}")% of ${RESERVE_WEEK_MAX})"
    # The 7-day gets its own test: sharing the 5h rule's "GAP points lower"
    # blocked it whenever the active 5h was low, so a 7d could run out unseen.
    elif [ "$mywk" -ge "$(wkmax "$act")" ] && [ -n "$best" ]; then
      switch_to "$pick" "7-day: $act at ${mywk}% on its 7d, $pick at ${pickv}% (room ${pickroom}, $(win_desc "${ID[$pick]}"))"
    elif [ -n "$exp" ] && [ "$myexp" = 0 ]; then
      switch_to "$exp" "expiring: $exp has ${exproom} points of room (at ${expv}%) that reset in $(fmt_left "$expleft"); $act at ${mine}% resets in $(fmt_left "$myleft")"
    elif [ -n "$idle" ] && [ "$myleft" != - ] && [ "$myleft" -le "$STAGGER" ] && [ "$myexp" = 0 ]; then
      switch_to "$idle" "stagger: $idle is idle (7d $(eff7 "${ID[$idle]}")%, 7d resets in $(fmt_left "$(left7 "${ID[$idle]}")")), $act has $(( myleft / 60 ))m left"
    elif [ -z "$best" ] && { [ "$mine" -ge $(( at - 3 )) ] || [ "$mywk" -ge "$(wkmax "$act")" ]; }; then
      held=1
      # One HOLD per episode (the watcher relays it), then a quiet reminder
      # every 30 min so a long hold is still visible in the log.
      if [ "$hold_said" = 0 ]; then
        say "HOLD $act at ${mine}% (switch point ${at}%, 7d ${mywk}%, 5h resets in $(fmt_left "$myleft")); nowhere with ${need}+ points of room (${BRIDGE_MIN_MINUTES} min at ${burn}%/h, $burn_src) ($others)"
        hold_said=1; hold_since=$now; hold_burn=$burn
      elif [ $(( now - hold_since )) -ge 1800 ]; then
        say "holding: $act at ${mine}%, 7d ${mywk}%, resets in $(fmt_left "$myleft") ($others)"
        hold_since=$now
      fi
    elif [ "$DRY" = 1 ]; then
      note=""
      [ "$myexp" = 1 ] && note="; $act's own $(( at - mine )) points of room are lost at its reset first, so it stays"
      say "no switch: $act at ${mine}% < switch point ${at}% (5h resets in $(fmt_left "$myleft"), 7d ${mywk}%), best target ${best:-none}${best:+ at ${bestv}% (room ${bestroom}, $(win_desc "${ID[$best]}"))}$note"
    fi
    if [ "$held" = 0 ] && [ "$hold_said" = 1 ]; then say "hold over: on $(active_slot)"; hold_said=0; hold_burn=0; fi
  fi
  [ "$DRY" = 1 ] && exit 0
  sleep 60
done
