#!/opt/homebrew/bin/bash
# Decision tests for rotate.sh: every scenario runs one `dry` pass against a
# FAKE cswap and checks the decision line (WOULD SWITCH → N [reason], HOLD …,
# no switch: …, or WARN …). Self-contained: the fake, the conf and the state
# dir live in a temp dir; Pacer is pointed at a dead port (switch point 93);
# the real cswap, rotate.conf and state/ are never read or touched.
#
#   tests.sh [path/to/rotate.sh]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROT=${1:-$HERE/rotate.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/rot-tests.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# The fake. FAKE_ACT=<active slot>
# FAKE_ACCTS="slot:u5:r5:u7:status[:r7[:lexp]] …"
#   u5, u7  percent, or "null" for no reading
#   r5      5h reset, minutes from now ("-" = no running window; negative = past)
#   r7      7d reset, minutes from now (default 6 days; "-" = none)
#   lexp    loginExpiresAt, minutes from now (default 30 days; "-" = none)
cat >"$T/bin/cswap" <<'FAKE'
#!/bin/bash
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.123456+00:00; }
case "$1" in
  status) echo "Status: Account-$FAKE_ACT (x@y [org])";;
  switch) echo "$2" >>"$FAKE_DIR/switched"; echo "Switched to Account-$2";;
  list)
    now=$(date -u +%s)
    printf '{"schemaVersion":1,"activeAccountNumber":%s,"accounts":[' "$FAKE_ACT"
    first=1
    for a in $FAKE_ACCTS; do
      IFS=: read -r s u5 r5 u7 st r7 lexp <<<"$a"
      r7=${r7:-8640}; lexp=${lexp:-43200}
      [ $first = 1 ] || printf ','; first=0
      act=false; [ "$s" = "$FAKE_ACT" ] && act=true
      if [ "$u5" = null ]; then fh=null
      elif [ "$r5" = - ]; then fh="{\"pct\":$u5}"
      else fh="{\"pct\":$u5,\"resetsAt\":\"$(iso $(( now + r5 * 60 )))\"}"; fi
      if [ "$u7" = null ]; then sd=null
      elif [ "$r7" = - ]; then sd="{\"pct\":$u7}"
      else sd="{\"pct\":$u7,\"resetsAt\":\"$(iso $(( now + r7 * 60 )))\"}"; fi
      le=null; [ "$lexp" != - ] && le="\"$(date -u -r $(( now + lexp * 60 )) +%Y-%m-%dT%H:%M:%SZ)\""
      printf '{"number":%s,"organizationUuid":"acc%sacc0000-aaaa","usageStatus":"%s","active":%s,"usage":{"fiveHour":%s,"sevenDay":%s},"usageAgeSeconds":60,"loginExpiresAt":%s}' \
        "$s" "$s" "$st" "$act" "$fh" "$sd" "$le"
    done
    echo ']}';;
  *) exit 1;;
esac
FAKE
chmod +x "$T/bin/cswap"

n=0; pass=0; fail=0
NOW=$(date +%s)
# t NAME DECISION_REGEX ACTIVE ACCOUNTS [CONF] [LAST_SWITCH_RECORD] [OUTPUT_REGEX]
# Prefix BURN=<%/h> to inject the active burn (BURN_OVERRIDE); without it,
# Pacer is unreachable and the burn is the assumed 40 %/h (bar 14 points).
# API=<url> points the script at a Pacer stand-in instead.
t() {
  local name=$1 want=$2 act=$3 accts=$4 conf=${5:-} last=${6:-} also=${7:-}
  local d out line ok=1
  n=$(( n + 1 )); d=$T/c$n; mkdir -p "$d/state"
  printf '%s\n' "$conf" >"$d/conf"
  [ -n "$last" ] && printf '%s\n' "$last" >"$d/state/last_switch"
  out=$(PATH="$T/bin:$PATH" FAKE_DIR=$T FAKE_ACT=$act FAKE_ACCTS=$accts \
        ROTATE_CONF=$d/conf ROTATE_STATE=$d/state PACER_API=${API:-http://127.0.0.1:1} \
        BURN_OVERRIDE=${BURN:-} "$ROT" dry 2>&1)
  line=$(printf '%s\n' "$out" | grep -E '^[0-9:]{8} (WOULD SWITCH|HOLD|no switch:|WARN)' | tail -1)
  printf '%s\n' "$line" | grep -qE -- "$want" || ok=0
  if [ -n "$also" ]; then printf '%s\n' "$out" | grep -qE -- "$also" || ok=0; fi
  if [ $ok = 1 ]; then
    pass=$(( pass + 1 )); printf 'PASS  %-42s %s\n' "$name" "$(printf '%s' "$line" | cut -c10-170)"
  else
    fail=$(( fail + 1 )); printf 'FAIL  %-42s want /%s/%s\n' "$name" "$want" "${also:+ and /$also/}"
    printf '%s\n' "$out" | sed 's/^/        | /'
  fi
}

for f in "$ROT" "$0"; do
  if /opt/homebrew/bin/bash -n "$f"; then pass=$(( pass + 1 )); printf 'PASS  %-42s\n' "bash -n $(basename "$f")"
  else fail=$(( fail + 1 )); printf 'FAIL  %-42s\n' "bash -n $(basename "$f")"; fi
done

# Tonight's other two accounts: 5h room, spent weeks.
SPENT="2:0:-:99:ok 4:0:-:100:ok"

# --- the scenarios the owner asked for -------------------------------------------
BURN=45 t "1 tonight at 45%/h: HOLD (room 8 < 15)" '^[0-9:]{8} HOLD 1 at 94%.*15\+ points of room \(20 min at 45%/h, override\).*3: 85% room 8, resets (2h59m|3h00m), 7d 77% \[room < 15\]' \
  1 "1:94:26:63:ok 3:85:180:77:ok $SPENT"
BURN=45 t "1b 3 at 70 (room 23 >= 15): switch" 'WOULD SWITCH → 3 .*\[limit: 1 at 94%.*3 at 70% \(room 23 ≥ 15 for 20 min at 45%/h' \
  1 "1:94:26:63:ok 3:70:180:77:ok $SPENT"
BURN=12 t "1c low burn, floor 6 pts: bridge to 3 at 85" 'WOULD SWITCH → 3 .*\[bridge: 1 at 94%.*\(room 8 ≥ 6 ' \
  1 "1:94:26:63:ok 3:85:180:77:ok $SPENT"
BURN=45 t "2 tonight, 3 at 89 (room 4): HOLD" '^[0-9:]{8} HOLD 1 at 94%.*3: 89% room 4, resets (2h59m|3h00m), 7d 77% \[room < 15\]' \
  1 "1:94:26:63:ok 3:89:180:77:ok $SPENT"
t "U1 burn unknown = 40%/h: room 13 < 14 HOLD" '^[0-9:]{8} HOLD 1 .*\(20 min at 40%/h, assumed\).*\[room < 14\]' \
  1 "1:94:26:63:ok 3:80:180:77:ok $SPENT"
t "U2 burn unknown: room 14 bridges" 'WOULD SWITCH → 3 .*\[bridge:.*\(room 14 ≥ 14 for 20 min at 40%/h' \
  1 "1:94:26:63:ok 3:79:180:77:ok $SPENT"
t "3 1 has reset, 3 at 95: back to 1" 'WOULD SWITCH → 1 .*\[limit: 3 at 95%.*1 at 0% \(room 93 ≥ 14 .*, idle\)' \
  3 "1:94:-5:63:ok 3:95:150:80:ok $SPENT"
t "4 expiring: 1 at 70 resets 25m" 'WOULD SWITCH → 1 .*\[expiring: 1 has 23 points' \
  3 "1:70:25:40:ok 3:30:240:77:ok $SPENT"
t "5 expiring, 1 at 88 (room 5): no" '^[0-9:]{8} no switch: 3 at 30%' \
  3 "1:88:25:40:ok 3:30:240:77:ok $SPENT"
BURN=2 t "5e expiring, 42 pts in 44m at 2%/h: unspendable, no" '^[0-9:]{8} no switch: 3 at 30%.*best target 1 at 51%' \
  3 "1:51:44:40:ok 3:30:240:77:ok $SPENT"
BURN=30 t "5f expiring, 42 pts in 44m at 30%/h: go" 'WOULD SWITCH → 1 .*\[expiring: 1 has 42 points' \
  3 "1:51:44:40:ok 3:30:240:77:ok $SPENT"
BURN=12 t "5b expiring floor: room 7 < 8 pts: no" '^[0-9:]{8} no switch: 3 at 30%.*best target 1 at 86% \(room 7' \
  3 "1:86:25:40:ok 3:30:240:77:ok $SPENT"
BURN=60 t "5c expiring burn bar: room 18 < 20: no" '^[0-9:]{8} no switch: 3 at 30%.*best target none' \
  3 "1:75:25:40:ok 3:30:240:77:ok $SPENT"
BURN=60 t "5d expiring burn bar: room 23 >= 20: go" 'WOULD SWITCH → 1 .*\[expiring: 1 has 23 points' \
  3 "1:70:25:40:ok 3:30:240:77:ok $SPENT"
t "6 active expires first: no" "^[0-9:]{8} no switch: 3 at 30%.*3's own 63 points" \
  3 "1:70:30:40:ok 3:30:20:77:ok $SPENT"
t "6b own room expiring blocks stagger" "^[0-9:]{8} no switch: 3 at 30%.*3's own 63 points" \
  3 "1:94:-5:99:ok 2:0:-:10:ok 3:30:20:77:ok 4:0:-:100:ok"
t "6c own room small: stagger runs" 'WOULD SWITCH → 2 .*\[stagger: 2 is idle' \
  3 "1:94:-5:99:ok 2:0:-:10:ok 3:88:20:77:ok 4:0:-:100:ok"
t "7 ranking: 3 (resets 30m) over idle 2" 'WOULD SWITCH → 3 .*\[limit: 1 at 95%.*3 at 60% \(room 33 ≥ 14 .*, resets 0h' \
  1 "1:95:26:63:ok 2:0:-:10:ok 3:60:30:50:ok 4:0:-:100:ok"
t "7b ranking is not slot order" 'WOULD SWITCH → 2 .*\[limit:.*2 at 60%' \
  1 "1:95:26:63:ok 2:60:30:50:ok 3:0:-:10:ok 4:0:-:100:ok"
t "7c tie on 5h reset: sooner 7d reset" 'WOULD SWITCH → 3 ' \
  1 "1:95:26:63:ok 2:50:60:20:ok:3000 3:50:60:20:ok:600 4:0:-:100:ok"
t "7d tie on both resets: most room" 'WOULD SWITCH → 2 ' \
  1 "1:95:26:63:ok 2:40:60:20:ok:600 3:50:60:20:ok:600 4:0:-:100:ok"
t "8 stagger: idle 3 (7d resets 6h) over 2" 'WOULD SWITCH → 3 .*\[stagger: 3 is idle \(7d 50%, 7d resets in (5h59m|6h00m)\), 1 has (99|100)m left' \
  1 "1:40:100:30:ok 2:0:-:20:ok:2880 3:0:-:50:ok:360 4:0:-:100:ok"
t "9 weekly cap blocks 3 at 0/92" '^[0-9:]{8} HOLD 1 at 95%.*3: 0% room 93, idle, 7d 92% \[7d cap 90%' \
  1 "1:95:26:63:ok 3:0:-:92:ok $SPENT"

# --- the old behaviour, kept --------------------------------------------------
t "10a missing 5h reading is not room" '^[0-9:]{8} HOLD 1 .*2: -% room -, reset unknown, 7d 10% \[no reading\]' \
  1 "1:95:26:63:ok 2:null:-:10:ok 3:0:-:99:ok 4:0:-:100:ok"
t "10a' missing 7d reading is not room" '^[0-9:]{8} HOLD 1 .*2: 0% room 93, idle, 7d -% \[no reading\]' \
  1 "1:95:26:63:ok 2:0:-:null:ok 3:0:-:99:ok 4:0:-:100:ok"
t "10b relogin_required is not a target" '^[0-9:]{8} HOLD 1 .*\[relogin_required\]' \
  1 "1:95:26:63:ok 2:0:-:10:relogin_required 3:0:-:99:ok 4:0:-:100:ok" "" "" \
  'ERROR slot 2 \(acc2acc0\) is relogin_required'
t "10c EXCLUDE" '^[0-9:]{8} HOLD 1 .*2: 0% room 93, idle, 7d 10% \[excluded\]' \
  1 "1:95:26:63:ok 2:0:-:10:ok 3:0:-:99:ok 4:0:-:100:ok" 'EXCLUDE="2"'
t "10d WEEK_MAX_2=50 blocks 2 at 7d 60" '^[0-9:]{8} HOLD 1 .*\[7d cap 50%' \
  1 "1:95:26:63:ok 2:0:-:60:ok 3:0:-:99:ok 4:0:-:100:ok" 'WEEK_MAX_2=50'
t "10d' WEEK_MAX_2=70 admits it" 'WOULD SWITCH → 2 .*\[limit:' \
  1 "1:95:26:63:ok 2:0:-:60:ok 3:0:-:99:ok 4:0:-:100:ok" 'WEEK_MAX_2=70'
t "10d'' WEEK_MAX_1=60 moves the active" 'WOULD SWITCH → 2 .*\[7-day: 1 at 63%' \
  1 "1:30:200:63:ok 2:0:-:10:ok 3:0:-:99:ok 4:0:-:100:ok" 'WEEK_MAX_1=60'
t "10e reserve when nothing else has room" 'WOULD SWITCH → 3 .*\[reserve: 1 at 95%' \
  1 "1:95:26:63:ok 3:0:-:92:ok $SPENT" 'RESERVE_SLOT=3'
t "10f reserve past its cap: ERROR + HOLD" '^[0-9:]{8} HOLD 3 at 95%' \
  3 "1:94:26:63:ok 3:95:100:97:ok $SPENT" 'RESERVE_SLOT=3' "" \
  'ERROR reserve 3 at 7d 97% \(cap 97%\)'
t "10g 7-day rule" 'WOULD SWITCH → 2 .*\[7-day: 1 at 91% on its 7d' \
  1 "1:30:200:91:ok 2:50:120:10:ok 3:0:-:99:ok 4:0:-:100:ok"
t "10h a passed 7d reset counts as 0%" 'WOULD SWITCH → 2 .*\[limit:' \
  1 "1:95:26:63:ok 2:0:-:99:ok:-5 3:0:-:99:ok 4:0:-:100:ok"
t "10i no active reading: WARN, hold" '^[0-9:]{8} WARN no reading for the active account 1' \
  1 "1:null:-:63:ok 2:0:-:10:ok"
t "10j login expiry ERROR (1 day) and WARN (3)" '^[0-9:]{8} no switch:' \
  1 "1:50:200:30:ok 2:0:-:99:ok:8640:600 4:0:-:100:ok:8640:2880" "" "" \
  'ERROR login for slot 2 .*expires in (9h59m|10h00m)'
t "10j' (the WARN line)" '^[0-9:]{8} no switch:' \
  1 "1:50:200:30:ok 2:0:-:99:ok:8640:600 4:0:-:100:ok:8640:2880" "" "" \
  'WARN login for slot 4 .*expires in (1d23h|2d00h)'
t "10k near the limit, no target: early HOLD" '^[0-9:]{8} HOLD 1 at 91% \(switch point 93%' \
  1 "1:91:26:63:ok 3:89:180:77:ok $SPENT"
t "10l nothing to do: no switch" '^[0-9:]{8} no switch: 1 at 50% < switch point 93%.*best target 3 at 20%' \
  1 "1:50:200:30:ok 3:20:250:40:ok $SPENT"

# --- the post-switch reading gap: WARN only after GAP_WARN_SECS (unit check of the helper;
# a dry pass holds no state, so the loop itself cannot be driven twice)
gw=$(bash -c 'DRY=0; '"$(sed -n '/^GAP_WARN_SECS=/p;/^gap_warn_due()/,/^}/p' "$ROT")"'
  r=""; gap_warn_due 1000 && r+=A; gap_warn_due 1200 && r+=B; gap_warn_due 1300 && r+=C
  missing_since=0; gap_warn_due 2000 && r+=D; echo "[$r]"')
if [ "$gw" = "[C]" ]; then pass=$(( pass + 1 )); printf 'PASS  %-42s\n' "G1 WARN only after 300 s missing"
else fail=$(( fail + 1 )); printf 'FAIL  %-42s got %s\n' "G1 WARN only after 300 s missing" "$gw"; fi

# --- ping-pong guard (state from the last switch) ----------------------------
PP="1:95:26:63:ok 3:50:120:50:ok $SPENT"
t "P1 just left 3 (60 s ago, no reset): HOLD" '^[0-9:]{8} HOLD 1 .*3: 50% room 43, resets (1h59m|2h00m), 7d 50% \[just left\]' \
  1 "$PP" "" "$(( NOW - 60 )) 3 $(( NOW + 7200 )) 50 1"
t "P2 left 3 400 s ago: allowed" 'WOULD SWITCH → 3 .*\[limit:' \
  1 "$PP" "" "$(( NOW - 400 )) 3 $(( NOW + 7200 )) 50 1"
t "P3 3's window reset since we left: allowed" 'WOULD SWITCH → 3 .*\[limit:' \
  1 "1:95:26:63:ok 3:0:-:50:ok $SPENT" "" "$(( NOW - 120 )) 3 $(( NOW - 30 )) 90 1"
t "P4 3's use dropped (no reset known): allowed" 'WOULD SWITCH → 3 .*\[limit:' \
  1 "1:95:26:63:ok 3:0:-:50:ok $SPENT" "" "$(( NOW - 60 )) 3 - 90 1"
t "P5 guard also covers the reserve" '^[0-9:]{8} HOLD 1 .*\[7d cap 90%' \
  1 "1:95:26:63:ok 3:0:-:92:ok $SPENT" 'RESERVE_SLOT=3' "$(( NOW - 60 )) 3 - 0 1"

# --- the burn as read from Pacer's /metrics (a file served on a local port) ---
# Account 1 burns 45 %/h, reading 0 s old: its safe limit is 96, switch point
# 94; the others have no burn (95, switch point 93); the bar is 15 points.
mkdir -p "$T/www"
cat >"$T/www/metrics" <<'EOF'
pacer_rate_limit_recent_burn_percent_per_hour{account="acc1acc0-0000",window="five_hour"} 45.2
pacer_rate_limit_sample_age_seconds{account="acc1acc0-0000",window="five_hour"} 0
EOF
port=$(( 20000 + RANDOM % 20000 ))
python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
srv=$!
trap 'kill "$srv" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/metrics" && break; sleep 0.1; done
API=http://127.0.0.1:$port t "M1 Pacer burn 45: room 13 < 15 HOLD" '^[0-9:]{8} HOLD 1 at 94% \(switch point 94%.*\(20 min at 45%/h, pacer\).*\[room < 15\]' \
  1 "1:94:26:63:ok 3:80:180:77:ok $SPENT" "" "" 'burn 45%/h \(pacer\): a target needs 15 points'
API=http://127.0.0.1:$port t "M2 Pacer burn 45: room 15 bridges" 'WOULD SWITCH → 3 .*\[bridge:.*\(room 15 ≥ 15 for 20 min at 45%/h' \
  1 "1:94:26:63:ok 3:78:180:77:ok $SPENT"
kill "$srv" 2>/dev/null

if [ -e "$T/switched" ]; then
  fail=$(( fail + 1 )); echo "FAIL  dry mode called cswap switch: $(tr '\n' ' ' <"$T/switched")"
else
  pass=$(( pass + 1 )); printf 'PASS  %-42s\n' "dry mode never called cswap switch"
fi
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
