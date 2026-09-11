#!/usr/bin/env bash
#
# pace.sh — report Claude usage from Pacer's local API and gate heavy work
# against every rate-limit window, so hitting a limit costs a resumable pause
# rather than a lost run.
#
# Design: ONE poller, MANY cheap readers.
#   - An orchestrator runs `gate` once per fan-out wave (a fresh HTTP read),
#     which writes a shared state file.
#   - The subagents only ever run `status` — a plain file read, no HTTP — so a
#     hundred of them cost Pacer nothing.
#   - On a trip, `wait` blocks (background-friendly) until the window resets,
#     then exits so the launcher is re-invoked to resume.
#
# Subcommands:
#   accounts               every account: plan, live sessions, windows (HTTP)
#   sessions               where the live sessions are, with branches (HTTP)
#   report                 human table of every window (HTTP)
#   json                   machine JSON of the same (HTTP)
#   gate  --cap N          HTTP read + write state file; 0=go 10=paused
#                          2=api-off 4=misconfigured
#   status                 read state file only (no HTTP); 0=go 10=paused
#                          3=unknown or stale
#   wait  --cap N          block until the tripping window resets; 0=resume
#                          20=beyond --max-wait (checkpoint & stop) 2=api-off
#
# Flags: --cap N (default 85), --interval S (default 300, floor 300 — Pacer
#   only updates every ~5 min), --window SEL (default all; a label or identity
#   substring, e.g. 5h, 7d, fable), --account ID|all, --max-wait S (default
#   21600 = 6h), --max-age S (default 900; how old a state file may be before
#   `status` calls it stale), --retries N (default 3), --state FILE
#
# Env: PACER_API (default http://127.0.0.1:7223), PACE_TOKEN (bearer, optional),
#   PACE_SESSION_API (override just the session lookup's base URL),
#   PACE_ACCOUNT, PACE_STATE, PACE_RUN (names a per-run state file, so two
#   orchestrations on one machine do not overwrite each other's verdict)
#
# Dependencies: curl and awk. Deliberately not jq — macOS does not ship it, and
# a skill that shipped with an app cannot assume Homebrew.
#
set -uo pipefail

API_BASE="${PACER_API:-http://127.0.0.1:7223}"
API="${API_BASE%/}/metrics"
# One state file per orchestration. The shared default is what makes the
# many-readers design cheap, but two runs with different caps sharing it means
# last-writer-wins on a verdict the other one is about to obey — so a run that
# names itself gets its own.
STATE="${PACE_STATE:-$HOME/.claude/pace/state${PACE_RUN:+-$PACE_RUN}.json}"
ACCOUNT="${PACE_ACCOUNT:-}"
CAP=85
INTERVAL=300
WINDOW=all
MAXWAIT=21600
MAXAGE=900
MODEL="${PACE_MODEL:-}"
# Stands for "which model I am is not knowable here". Deliberately not the
# empty string: empty already means "every window binds", which is the
# opposite instruction. Only windows that name no model bind this.
AMBIGUOUS_MODEL="__ambiguous__"
ETA=0
INTERVAL_SET=0
# How many times to re-ask before believing "nothing is listening". Pacer
# restarts itself for updates, so one refused connection is not an answer.
RETRIES="${PACE_RETRIES:-3}"
AUTH=()
[ -n "${PACE_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${PACE_TOKEN}")

# Which login to ask about, resolved by Pacer rather than here.
#
# A session running beside another account has its own `CLAUDE_CONFIG_DIR` and
# knows nothing else about it; Pacer knows which login is signed into that
# directory, because it recorded the activation. Handing the path over is what
# stops a pinned session pacing against the *default* login's windows — a
# different account's entirely. `--data-urlencode` so a path with spaces in it
# survives the trip.
SCOPE=()
# Accounts present in the last response, before any narrowing.
ALL_ACCOUNTS=0
# What the parser keeps. Empty means "whichever login is active", which is only
# right when nothing more specific is known.
AWK_WANT="${PACE_ACCOUNT:-}"

# Field separator for the internal row format. **Not a tab**: bash treats
# runs of IFS *whitespace* as one delimiter, so a row whose model column is
# empty — every account-wide window — collapsed and shifted every later field
# left by one. A window's reset time was read as its percentage, and 5h
# reported "3501% used". \037 is the ASCII unit separator: not whitespace, so
# an empty field stays an empty field.
SEP=$'\037'

die() { echo "pace: $*" >&2; exit 1; }

# "90m" / "2h" / "5400" -> seconds. Anything unparseable is a typo worth
# stopping for, not a zero to silently ignore.
duration() {
  case "$1" in
    ''|0) echo 0;;
    *[0-9]s) echo "${1%s}";;
    *[0-9]m) echo $(( ${1%m} * 60 ));;
    *[0-9]h) echo $(( ${1%h} * 3600 ));;
    *[0-9]) echo "$1";;
    *) die "cannot read duration '$1' (try 90m, 2h, or plain seconds)";;
  esac
}
command -v curl >/dev/null || die "need curl"
command -v awk  >/dev/null || die "need awk"

SUB="${1:-report}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --cap)      CAP="$2"; shift 2;;
    --interval) INTERVAL="$2"; INTERVAL_SET=1; shift 2;;
    --window)   WINDOW="$2"; shift 2;;
    --model)    MODEL="$2"; shift 2;;
    --eta)      ETA="$2"; shift 2;;
    --account)  ACCOUNT="$2"; shift 2;;
    --max-wait) MAXWAIT="$2"; shift 2;;
    --max-age)  MAXAGE="$2"; shift 2;;
    --retries)  RETRIES="$2"; shift 2;;
    --state)    STATE="$2"; shift 2;;
    -h|--help)  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown flag: $1";;
  esac
done
# 300 is the right default because Pacer's own readings only refresh every
# ~5 minutes (one token is polled no faster than that, which is what keeps it
# off Anthropic's throttle). The floor is far lower than the default on
# purpose, and is only a guard against a spin loop rather than a
# recommendation: an *account switch* is visible the instant Pacer notices it,
# so a process that is waiting has a reason to look more often than a reading
# changes, and the endpoint it looks at is on this machine.
[ "$INTERVAL" -lt 5 ] 2>/dev/null && INTERVAL=5
ETA=$(duration "$ETA") || exit 1   # `die` inside $() exits the subshell, not us


# --- reading Pacer ---------------------------------------------------------

# Parse the Prometheus exposition into one TSV row per window:
#
#   account <TAB> identity <TAB> label <TAB> usedPercent <TAB> resetsInSeconds
#
# `/metrics` rather than `/v1/snapshot` because it is already line-oriented —
# parsing JSON without jq is the part that would be fragile, not this. The
# label is derived from the identity (`kind|model|surface`), which is what the
# server keys a window on; the two fixed blocks get the familiar 5h/7d names.
#
# On a multi-account install every account's windows are present, so rows are
# filtered to one login: --account if given, else the one flagged active by
# `pacer_account_info`, else the only account there is.
PARSE_AWK='
function tagval(line, key,   s, p, q) {
  p = index(line, key "=\"")
  if (p == 0) return ""
  s = substr(line, p + length(key) + 2)
  q = index(s, "\"")
  if (q == 0) return ""
  return substr(s, 1, q - 1)
}
function modelfor(id,   n, parts) {
  if (id == "five_hour" || id == "seven_day") return ""
  n = split(id, parts, "|")
  return (n >= 2 ? parts[2] : "")
}
function labelfor(id,   n, parts, m) {
  if (id == "five_hour") return "5h"
  if (id == "seven_day") return "7d"
  m = modelfor(id)
  if (m != "") return m
  n = split(id, parts, "|")
  if (n >= 3 && parts[3] != "") return parts[3]     # surface
  return parts[1]                                   # kind
}
function slot(line,   a, w, key) {
  a = tagval(line, "account"); w = tagval(line, "window")
  key = a SUBSEP w
  if (!(key in seen)) { seen[key] = 1; order[++n] = key; acct[key] = a; win[key] = w }
  accounts[a] = 1
  return key
}
/^pacer_account_info\{/ {
  if (tagval($0, "active") == "true") active = tagval($0, "account")
  next
}
/^pacer_rate_limit_used_ratio\{/          { pct[slot($0)]  = $NF * 100; next }
/^pacer_rate_limit_reset_seconds\{/       { secs[slot($0)] = $NF; next }
/^pacer_rate_limit_hit_eta_seconds\{/     { eta[slot($0)]  = $NF; next }
/^pacer_rate_limit_will_hit\{/            { hit[slot($0)]  = $NF; next }
/^pacer_rate_limit_burn_percent_per_hour\{/ { burn[slot($0)] = $NF; next }
/^pacer_rate_limit_recent_burn_percent_per_hour\{/ { recent[slot($0)] = $NF; next }
END {
  count = 0
  for (a in accounts) { count++; only = a }
  want = WANT
  if (want == "") want = (active != "" ? active : (count == 1 ? only : ""))
  if (want == "all") want = ""
  for (i = 1; i <= n; i++) {
    key = order[i]
    if (want != "" && acct[key] != want) continue
    if (!(key in pct)) continue                       # a window with no reading
    printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n",
           acct[key], SEP, win[key], SEP, labelfor(win[key]), SEP, modelfor(win[key]), SEP,
           pct[key], SEP,
           (key in secs ? secs[key] : "null"), SEP,
           (key in eta  ? eta[key]  : "null"), SEP,
           (key in burn ? burn[key] : "null"), SEP,
           (key in hit  ? hit[key]  : "0"), SEP,
           (key in recent ? recent[key] : "null")
  }
}'

# Ask Pacer what it knows about *this* session: the model it is running and the
# account its work is billed to.
#
# Claude Code exports `CLAUDE_CODE_SESSION_ID` into every command it runs, and
# that id names the transcript Pacer already parses — so the two facts a script
# cannot determine about itself are one local request away. A subagent gets its
# own id, so this answers for the subagent rather than its parent.
#
# Line-oriented extraction rather than a JSON parser: the response is six fields
# from an encoder we control, which prints one key per line. There is a test
# pinning that shape.
SESSION_MODEL=""
SESSION_MODELS=""
SESSION_ACCOUNT=""
session_looked_up=false
resolve_session() {
  $session_looked_up && return 0
  session_looked_up=true
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
  local body
  body=$(curl -s -m 5 ${AUTH[@]+"${AUTH[@]}"} \
         --get --data-urlencode "id=$CLAUDE_CODE_SESSION_ID" \
         "${PACE_SESSION_API:-${API_BASE%/}}/v1/session") || return 1
  case "$body" in *'"sessionId"'*) ;; *) return 1;; esac
  SESSION_MODEL=$(printf '%s\n' "$body" | awk -F'"' '/"model"/ { print $4; exit }')
  SESSION_ACCOUNT=$(printf '%s\n' "$body" | awk -F'"' '/"accountId"/ { print $4; exit }')
  # Every model this session is running, not just the newest turn's. A
  # subagent shares its parent's session id, so this is how we find out that
  # "the session's model" is not a single answer.
  SESSION_MODELS=$(printf '%s\n' "$body" \
    | tr ',' '\n' \
    | awk '/"models"/,/\]/' \
    | grep -o '"[^"]*"' \
    | grep -v '"models"' \
    | tr -d '"')
  [ -n "$SESSION_MODEL" ] || [ -n "$SESSION_ACCOUNT" ]
}

# Fills ROWS with the TSV above, and FETCH_REASON with why it could not.
#
#   off   — nothing answered. Pacer is opt-in; this is the ordinary case.
#   auth  — it answered 401/403. A token is set on the server and not here, or
#           it is wrong. This used to be indistinguishable from `off`, which
#           meant one typo in a token silently disabled every gate in a run.
#   http  — it answered something else unhappy.
#   empty — it answered, but reported no windows at all.
#
# One read is retried a couple of times first: Pacer installs its own silent
# updates and restarts, so a multi-hour `wait` is guaranteed to meet a moment
# where the server is not listening, and treating that as "no limits to worry
# about" is the worst possible reading of it.
fetch_rows() {
  local attempt=1 raw code body
  FETCH_REASON=off
  while [ "$attempt" -le "$RETRIES" ]; do
    # `${AUTH[@]+...}` so an empty array does not trip `set -u` on bash 3.2.
    if raw=$(curl -s -m 5 -w '\n%{http_code}' --get ${SCOPE[@]+"${SCOPE[@]}"} ${AUTH[@]+"${AUTH[@]}"} "$API"); then
      code=${raw##*$'\n'}
      body=${raw%$'\n'*}
      case "$code" in
        401|403) FETCH_REASON=auth; return 1;;
        000|200) ;;                       # 000 = a non-HTTP URL, e.g. file://
        *)       FETCH_REASON=http; HTTP_CODE=$code; return 1;;
      esac
      if [ -n "$body" ]; then
        # Counted before filtering: `ROWS` is already narrowed to one login, so
        # counting accounts in it would always say one and the caveat below
        # would never fire on the machines that need it.
        ALL_ACCOUNTS=$(printf '%s\n' "$body" | awk '/^pacer_account_info\{/ { n++ } END { print n+0 }')
        ROWS=$(printf '%s\n' "$body" | awk -v WANT="$AWK_WANT" -v SEP="$SEP" "$PARSE_AWK")
        if [ -n "$ROWS" ]; then FETCH_REASON=""; return 0; fi
        FETCH_REASON=empty
        return 1
      fi
    fi
    [ "$attempt" -lt "$RETRIES" ] && sleep "$attempt"
    attempt=$((attempt + 1))
  done
  return 1
}

# Rows the caller asked to watch. `--window` is a case-insensitive substring of
# either the label or the identity, so `5h`, `fable` and `weekly_scoped|Fable|`
# all select something sensible.
selected_rows() {
  printf '%s\n' "$ROWS" | awk -F"$SEP" -v SEL="$WINDOW" '
    BEGIN { sel = tolower(SEL) }
    sel == "" || sel == "all" { print; next }
    { if (index(tolower($3), sel) || index(tolower($2), sel)) print }'
}

# The rows that actually constrain *this* caller.
#
# A per-model cap binds only work using that model: a Fable weekly window at
# 95% has nothing to say to an Opus agent, and stopping it would be a pause
# nobody needed. Account-wide windows (an empty model component) bind
# everything, always. With no --model given every window binds, which is the
# safe reading of "the caller did not say".
# Whether one window's model constrains `--model`. The shell half of the same
# rule `binding_rows` applies, so the report's marker can never disagree with
# what the gate actually did.
model_binds() {
  awk -v MODEL="$1" -v WANT="$MODEL" -v AMBIG="$AMBIGUOUS_MODEL" '
    function norm(v) { v = tolower(v); gsub(/[^a-z0-9]/, "", v); return v }
    BEGIN {
      want = norm(WANT); m = norm(MODEL)
      # Identity unknown: only a window that binds every model binds us.
      if (WANT == AMBIG) exit (m == "") ? 0 : 1
      if (want == "" || want == "all" || m == "") exit 0
      exit (index(m, want) || index(want, m)) ? 0 : 1
    }'
}

binding_rows() {
  selected_rows | awk -F"$SEP" -v WANT="$MODEL" -v AMBIG="$AMBIGUOUS_MODEL" '
    function norm(v) { v = tolower(v); gsub(/[^a-z0-9]/, "", v); return v }
    BEGIN { want = norm(WANT); ambiguous = (WANT == AMBIG) }
    ambiguous { if ($4 == "") print; next }
    want == "" || want == "all" { print; next }
    $4 == "" { print; next }
    { m = norm($4)
      if (index(m, want) || index(want, m)) print }'
}

# A `--window` that matches nothing is a typo, not "no limits to worry about".
# Without this, `--window fabel` reports GO forever — the exact failure a pacing
# tool must not have.
require_selection() {
  case "$WINDOW" in ''|all) return 0;; esac
  [ -n "$(selected_rows)" ] && return 0
  echo "pace: --window '$WINDOW' matches no window. Available: $(printf '%s\n' "$ROWS" | awk -F"$SEP" '{ printf "%s%s", (NR>1 ? ", " : ""), $3 }')" >&2
  exit 1
}

human() {  # seconds -> "3d 9h" / "1h 12m" / "7m"
  local s="$1"; case "$s" in ''|null) echo "?"; return;; esac
  local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else                      printf '%dm' "$m"; fi
}

clock() {  # seconds-from-now -> local "Sun 5:00 PM"
  local s="$1"; case "$s" in ''|null) echo "?"; return;; esac
  date -r "$(( $(date +%s) + s ))" +'%a %-I:%M %p' 2>/dev/null || echo "?"
}

pct_fmt() {  # 61.99999 -> 62 ; 4.5 -> 4.5
  awk -v v="$1" 'BEGIN { if (v == "" || v == "null") { print "?"; exit }
                         r = sprintf("%.1f", v); sub(/\.0$/, "", r); print r }'
}

# --- state file ------------------------------------------------------------

# Written by hand rather than with jq. Every value is a number or a string we
# generated ourselves, so there is nothing here that needs escaping.
write_state() {  # status window pct secs note
  mkdir -p "$(dirname "$STATE")" 2>/dev/null
  local tmp="${STATE}.tmp.$$"
  {
    printf '{\n'
    printf '  "status": "%s",\n' "$1"
    printf '  "tripWindow": "%s",\n' "$2"
    printf '  "model": "%s",\n' "$MODEL"
    printf '  "cap": %s,\n' "$CAP"
    printf '  "usedPercent": %s,\n' "${3:-null}"
    printf '  "resetsInSeconds": %s,\n' "${4:-null}"
    printf '  "note": "%s",\n' "$5"
    printf '  "updatedAt": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '}\n'
  } > "$tmp" && mv "$tmp" "$STATE"
}

# Seconds since the state file was written, from its own `updatedAt` (the file
# mtime would be wrong the moment anything copies it). Empty when it cannot be
# parsed, which skips the staleness check rather than failing on it.
state_age_seconds() {
  local stamp epoch
  stamp=$(awk -F'"' '/"updatedAt"/ { print $4; exit }' "$STATE" 2>/dev/null)
  [ -n "$stamp" ] || return 0
  epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" +%s 2>/dev/null) || return 0
  [ -n "$epoch" ] || return 0
  echo $(( $(date +%s) - epoch ))
}

# --- evaluation ------------------------------------------------------------

# Sets TRIP/TPCT/TSECS to the watched window that is at or over the cap and
# resets soonest — the one worth waiting out. Empty TRIP means headroom.
evaluate() {
  local line
  # Two ways to trip, and the second is the one that reads the future: a
  # window at 40% climbing fast enough to hit the cap inside the horizon is a
  # worse place to launch a wave from than one sitting still at 80%. Whichever
  # binding window resets soonest wins, since that is the one worth waiting out.
  line=$(binding_rows | awk -F"$SEP" -v SEP="$SEP" -v cap="$CAP" -v horizon="$ETA" '
    {
      pct = $5; secs = $6; eta = $7; hit = $9
      why = ""
      if (pct != "null" && pct + 0 >= cap + 0) why = "cap"
      else if (horizon + 0 > 0 && hit + 0 == 1 && eta != "null" && eta + 0 <= horizon + 0) why = "eta"
      if (why == "") next
      s = (secs == "null" ? 9999999 : secs + 0)
      if (best == "" || s < bests) { best = $3 SEP pct SEP secs SEP why SEP eta; bests = s }
    }
    END { if (best != "") print best }')
  TRIP=""; TPCT=""; TSECS=""; TWHY=""; TETA=""
  [ -n "$line" ] && IFS="$SEP" read -r TRIP TPCT TSECS TWHY TETA <<<"$line"
}

# Whose numbers these are, said out loud when it had to be inferred.
#
# On a machine with one account there is nothing to get wrong. With several,
# falling back to "whichever login is active" is a guess, and a gate that
# reports a percentage without saying whose it is invites exactly the mistake
# this is here to prevent.
# What `--model auto` decided. Says it out loud on the lines a caller reads,
# because this was computed and never printed: a subagent gated against its
# orchestrator's model for as long as that was true and nothing said so.
auto_note() {
  [ -n "$AUTO_NOTE" ] || return 0
  printf ' [%s]' "$AUTO_NOTE"
}

scope_caveat() {
  [ -n "$AWK_WANT" ] && [ "$AWK_WANT" != all ] && return 0
  [ "${ALL_ACCOUNTS:-0}" -le 1 ] 2>/dev/null && return 0
  printf ' (%s accounts signed in and this session could not be identified — these are the active login'"'"'s numbers, which may not be the ones billing you; pass --account, or run where CLAUDE_CODE_SESSION_ID is set)' "$ALL_ACCOUNTS"
}

# Why the gate tripped, in words.
trip_reason() {
  if [ "${TWHY:-cap}" = eta ]; then
    echo "${TRIP} at $(pct_fmt "$TPCT")% is projected to fill in $(human "$TETA") (horizon $(human "$ETA"))"
  else
    echo "${TRIP} at $(pct_fmt "$TPCT")% >= cap ${CAP}%"
  fi
}

# One-line summary of every watched window, for a human note.
summary() {
  binding_rows | awk -F"$SEP" '{ printf "%s%s %s%%", (NR>1 ? ", " : ""), $3, sprintf("%.0f", $5) }'
}

# --- subcommands -----------------------------------------------------------

# Says what actually went wrong, and how loudly. `off` is ordinary; `auth` and
# `http` are misconfigurations that a run must not mistake for "no limits".
api_off_note() {
  case "${FETCH_REASON:-off}" in
    auth) echo "pace: Pacer requires a token and this one was rejected. Set PACE_TOKEN to the token in Pacer → Settings → Integrations. NOT gating — fix this or the run is unpaced." >&2;;
    http) echo "pace: Pacer answered HTTP ${HTTP_CODE:-?} at $API. NOT gating." >&2;;
    empty) echo "pace: Pacer answered but reported no rate-limit windows yet — it may not have polled since launch. Proceeding ungated.";;
    *)    echo "Pacer API unreachable at $API — it is opt-in and likely just off (Pacer → Settings → Integrations). Proceed normally.";;
  esac
}

# 4 for a misconfiguration (a token that does not work is a bug to fix, not a
# state to tolerate), 2 for the ordinary "Pacer is not running".
off_exit_code() {
  case "${FETCH_REASON:-off}" in auth|http) echo 4;; *) echo 2;; esac
}

cmd_report() {
  fetch_rows || { api_off_note; exit "$(off_exit_code)"; }
  require_selection
  [ -n "$AUTO_NOTE" ] && printf 'pace:%s\n' "$(auto_note)"
  local multi
  multi=$(printf '%s\n' "$ROWS" | awk -F"$SEP" '{ a[$1] = 1 } END { print length(a) }')
  selected_rows | while IFS="$SEP" read -r acct id label model pct secs eta burn hit recent; do
    local prefix="" rate="" full="" mine=""
    [ "$multi" -gt 1 ] && prefix="$(printf '%-8s ' "${acct:0:8}")"
    # The measured half-hour rate answers "right now"; the engine's smoothed
    # slope is shown beside it when they disagree enough to matter, which is
    # what tells a burst from a steady climb.
    if [ "$recent" != null ]; then
      rate="$(printf ' · %+.0f%%/h now' "$recent")"
      if [ "$burn" != null ] \
         && [ "$(awk -v a="$recent" -v b="$burn" 'BEGIN { print (a - b > 5 || b - a > 5) ? 1 : 0 }')" = 1 ]; then
        rate="$rate$(printf ' (%+.0f avg)' "$burn")"
      fi
    elif [ "$burn" != null ]; then
      rate="$(printf ' · %+.0f%%/h' "$burn")"
    fi
    [ "$hit" = 1 ] && [ "$eta" != null ] && full=" · full in $(human "$eta")"
    # Only worth saying when the caller named a model: otherwise everything
    # binds and the note is noise on every line.
    if [ -n "$MODEL" ] && [ "$MODEL" != all ] && [ -n "$model" ] && ! model_binds "$model"; then
      mine="  — binds $model only"
    fi
    printf '%s%-10s %4s%% used%s%s · resets in %-7s (%s)%s\n' \
      "$prefix" "$label" "$(pct_fmt "$pct")" "$rate" "$full" \
      "$(human "$secs")" "$(clock "$secs")" "$mine"
  done
}

# What am I working with: how many accounts, on what plan, with how many
# sessions already drawing on each, and where each window stands.
#
# Everything here comes out of `/metrics`, which already carries the account
# directory (`pacer_account_info`) and the session counts — so this is the same
# single request the gate makes, not a second source of truth.
cmd_accounts() {
  local body
  body=$(curl -s -m 5 ${AUTH[@]+"${AUTH[@]}"} "$API") || { api_off_note; exit "$(off_exit_code)"; }
  [ -n "$body" ] || { api_off_note; exit "$(off_exit_code)"; }
  printf '%s\n' "$body" | awk -v SEP="$SEP" '
    function tagval(line, key,   s, p, q) {
      p = index(line, key "=\"")
      if (p == 0) return ""
      s = substr(line, p + length(key) + 2)
      q = index(s, "\"")
      return q ? substr(s, 1, q - 1) : ""
    }
    function labelfor(id,   n, parts) {
      if (id == "five_hour") return "5h"
      if (id == "seven_day") return "7d"
      n = split(id, parts, "|")
      if (n >= 2 && parts[2] != "") return parts[2]
      return parts[1]
    }
    /^pacer_account_info\{/ {
      a = tagval($0, "account")
      if (!(a in seen)) { seen[a] = 1; order[++n] = a }
      name[a] = tagval($0, "name"); plan[a] = tagval($0, "plan")
      tier[a] = tagval($0, "tier")
      act[a] = tagval($0, "active"); next
    }
    /^pacer_account_active_sessions\{/ { live[tagval($0, "account")] = $NF; next }
    /^pacer_rate_limit_used_ratio\{/ {
      a = tagval($0, "account"); w = tagval($0, "window")
      if (!(a in seen)) { seen[a] = 1; order[++n] = a }
      wins[a] = wins[a] (wins[a] == "" ? "" : "  ") sprintf("%s %d%%", labelfor(w), $NF * 100 + 0.5)
      next
    }
    END {
      if (n == 0) { print "pace: Pacer reports no accounts yet."; exit }
      printf "%d account%s\n", n, (n == 1 ? "" : "s")
      for (i = 1; i <= n; i++) {
        a = order[i]
        printf "\n  %-10s %s%s\n", substr(a, 1, 8),
               (plan[a] == "" ? "plan unknown" : plan[a]),
               (act[a] == "true" ? " · active login" : "")
        printf "    %s session%s drawing on it now\n",
               (a in live ? live[a] : "0"), ((a in live && live[a] + 0 == 1) ? "" : "s")
        if (wins[a] != "") printf "    %s\n", wins[a]
      }
      print "\nA window is account-wide: every session above draws on the same percentage."
    }'
}

# Where the other sessions are. Paths come from Pacer; the branch is read here,
# at the moment you ask, because a branch changes without producing a turn for
# Pacer to notice and a stored one would be wrong more often than right.
cmd_sessions() {
  local body
  body=$(curl -s -m 5 ${AUTH[@]+"${AUTH[@]}"} \
         --get ${SCOPE[@]+"${SCOPE[@]}"} "${API_BASE%/}/v1/sessions") \
    || { api_off_note; exit "$(off_exit_code)"; }
  case "$body" in *'"sessions"'*) ;; *) api_off_note; exit "$(off_exit_code)";; esac

  local rows
  rows=$(printf '%s\n' "$body" | awk -v SEP="$SEP" '
    function val(line,   p, rest, q) {
      p = index(line, "\" : \"")
      if (p == 0) return ""
      rest = substr(line, p + 5)
      q = index(rest, "\"")
      return q ? substr(rest, 1, q - 1) : ""
    }
    /^ *\{/ { acct = ""; model = ""; path = ""; proj = ""; repo = ""; when = ""; state = ""; next }
    /"accountId" *:/  { acct  = val($0); next }
    /"model" *:/      { model = val($0); next }
    /"projectPath" *:/{ path  = val($0); next }
    /"project" *:/    { proj  = val($0); next }
    /"repository" *:/ { repo  = val($0); next }
    /"lastActiveAt" *:/ { when = val($0); next }
    /"activity" *:/   { state = val($0); next }
    /^ *\}/ {
      if (proj != "" || path != "")
        printf "%s%s%s%s%s%s%s%s%s%s%s\n", state, SEP, substr(acct, 1, 8), SEP,
               proj, SEP, (model == "" ? "?" : model), SEP, path, SEP, repo
    }')
  [ -n "$rows" ] || { echo "No sessions in the last hour."; return 0; }

  printf '%s\n' "$rows" | while IFS="$SEP" read -r state acct proj model path repo; do
    local branch=""
    if [ -n "$path" ] && [ -d "$path" ]; then
      branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
      [ -n "$branch" ] && branch=" ($branch)"
    fi
    local where="$proj$branch"
    # Truncate rather than let a long branch name shove every later column
    # out of line — the full path is on the same row anyway.
    [ "${#where}" -gt 34 ] && where="${where:0:33}…"
    printf '%-7s %-9s %-34s %-18s %s%s\n' "$state" "$acct" "$where" "$model" "$path" \
      "$([ -n "$repo" ] && printf '  ← %s' "$repo")"
  done
}

cmd_json() {
  fetch_rows || {
    printf '{"ok": false, "reason": "%s"}\n' "${FETCH_REASON:-off}"
    exit "$(off_exit_code)"
  }
  require_selection
  printf '{\n  "ok": true,\n  "at": "%s",\n  "windows": [\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  selected_rows | awk -F"$SEP" -v WANT="$MODEL" '
    function norm(v) { v = tolower(v); gsub(/[^a-z0-9]/, "", v); return v }
    function binds(model,   m) {
      if (want == "" || want == "all" || model == "") return 1
      m = norm(model)
      return (index(m, want) || index(want, m)) ? 1 : 0
    }
    BEGIN { want = norm(WANT) }
    { printf "%s    {\"account\": \"%s\", \"identity\": \"%s\", \"label\": \"%s\", \"model\": \"%s\", \"usedPercent\": %s, \"resetsInSeconds\": %s, \"willHitLimit\": %s, \"hitEtaSeconds\": %s, \"burnPercentPerHour\": %s, \"recentBurnPercentPerHour\": %s, \"binds\": %s}",
             (NR > 1 ? ",\n" : ""), $1, $2, $3, $4, $5, $6,
             ($9 + 0 == 1 ? "true" : "false"), $7, $8, $10,
             (binds($4) ? "true" : "false") }
    END { if (NR > 0) printf "\n" }'
  printf '  ]\n}\n'
}

cmd_gate() {
  if ! fetch_rows; then
    write_state unknown "" "" "" "not gating (${FETCH_REASON:-off})"
    api_off_note
    [ "${FETCH_REASON:-off}" = off ] && echo "pace: API off — proceeding ungated."
    exit "$(off_exit_code)"
  fi
  require_selection
  evaluate
  if [ -z "$TRIP" ]; then
    write_state go "" "" "" "$(summary) (cap ${CAP}%)"
    echo "pace: GO — $(summary) (cap ${CAP}%).$(auto_note)$(scope_caveat)"
    exit 0
  fi
  write_state paused "$TRIP" "$TPCT" "$TSECS" \
    "$(trip_reason); resets in $(human "$TSECS")"
  echo "pace: PAUSE — $(trip_reason), resets in $(human "$TSECS") ($(clock "$TSECS")).$(auto_note)"
  exit 10
}

cmd_status() {
  [ -f "$STATE" ] || { echo "pace: no state file ($STATE) — run 'gate' first."; exit 3; }
  local st note age
  # A verdict has a shelf life. An orchestrator that crashed an hour ago leaves
  # its last word on disk, and every reader after that is obeying a snapshot of
  # a window that has since moved — in either direction.
  age=$(state_age_seconds)
  if [ -n "$age" ] && [ "$age" -gt "$MAXAGE" ]; then
    echo "stale: last gated $((age / 60))m ago (max ${MAXAGE}s) — treat as unknown and re-gate."
    exit 3
  fi
  # A verdict is only about the model it was gated for. An Opus wave must not
  # inherit a pause a Fable cap caused, and the state file is the only thing a
  # subagent reads — so the mismatch has to be caught here.
  local gatedModel
  gatedModel=$(awk -F'"' '/"model"/ { print $4; exit }' "$STATE" 2>/dev/null)
  if [ -n "$MODEL" ] && [ "$MODEL" != all ] && [ "$gatedModel" != "$MODEL" ]; then
    echo "unknown: last gate was for '${gatedModel:-every model}', not '$MODEL' — re-gate."
    exit 3
  fi
  st=$(awk -F'"' '/"status"/ { print $4; exit }' "$STATE" 2>/dev/null)
  case "$st" in
    go)     echo "go"; exit 0;;
    paused) note=$(awk -F'"' '/"note"/ { print $4; exit }' "$STATE" 2>/dev/null)
            echo "paused: ${note}"; exit 10;;
    *)      echo "unknown"; exit 3;;
  esac
}

cmd_wait() {
  local waiting=false everRead=false fails=0 startedOn="" nowOn=""
  # A waiting process has a reason to look more often than a reading changes:
  # under sequential accounts, switching logins restores headroom immediately
  # and Pacer sees it as soon as it notices the switch. Waiting out a *reset*
  # is still bounded by the ~5-minute poll either way.
  [ "$INTERVAL_SET" = 0 ] && INTERVAL=60
  while :; do
    if ! fetch_rows; then
      # A blip is not a reset. Pacer ships silent auto-updates and restarts
      # itself, so a wait long enough to matter *will* meet a minute where
      # nothing answers — and "the server went away" arriving at 95% used must
      # not read as "go ahead". Once a read has succeeded, keep waiting through
      # failures for `staleAfter`; only a wait that could never reach Pacer at
      # all gives up immediately.
      if $everRead && [ "${FETCH_REASON:-off}" != auth ]; then
        fails=$((fails + 1))
        if [ $((fails * INTERVAL)) -lt "$MAXAGE" ]; then
          [ "$fails" = 1 ] && echo "pace: Pacer stopped answering (${FETCH_REASON:-off}) — holding the pause, not resuming."
          sleep "$INTERVAL"
          continue
        fi
      fi
      write_state unknown "" "" "" "Pacer unreadable while waiting (${FETCH_REASON:-off})"
      api_off_note
      [ "${FETCH_REASON:-off}" = off ] && echo "pace: cannot gate; proceeding ungated."
      exit "$(off_exit_code)"
    fi
    everRead=true
    fails=0
    nowOn=$(printf '%s\n' "$ROWS" | awk -F"$SEP" 'NR == 1 { print $1; exit }')
    [ -z "$startedOn" ] && startedOn="$nowOn"
    require_selection
    evaluate
    if [ -z "$TRIP" ]; then
      # Why the headroom came back matters to whoever reads this: a reset is
      # the window rolling over, a switch is a different login's window
      # entirely — and under sequential accounts the second is the common one.
      if [ -n "$startedOn" ] && [ "$nowOn" != "$startedOn" ]; then
        write_state go "" "" "" "account switched — headroom on ${nowOn:0:8} ($(summary))"
        echo "pace: account switched (${startedOn:0:8} → ${nowOn:0:8}) — headroom on the new login ($(summary)). Resume."
      else
        write_state go "" "" "" "headroom restored ($(summary))"
        $waiting && echo "pace: reset — headroom restored ($(summary)). Resume."
      fi
      exit 0
    fi
    if [ "${TSECS:-0}" != null ] && [ "${TSECS:-0}" -gt "$MAXWAIT" ] 2>/dev/null; then
      write_state paused "$TRIP" "$TPCT" "$TSECS" \
        "manual: ${TRIP} resets in $(human "$TSECS") (> max-wait $(human "$MAXWAIT")) — checkpoint & stop"
      echo "pace: $(trip_reason) and resets in $(human "$TSECS") — beyond max-wait. Checkpoint and stop; resume after $(clock "$TSECS")."
      exit 20
    fi
    write_state paused "$TRIP" "$TPCT" "$TSECS" "waiting for ${TRIP} reset (~$(human "$TSECS"))"
    $waiting || echo "pace: $(trip_reason) — waiting ~$(human "$TSECS") for reset ($(clock "$TSECS"))…"
    waiting=true
    sleep "$INTERVAL"
  done
}

# `--model auto` (or PACE_MODEL=auto) means "whatever this session is running".
# It also settles which account to ask about, since the same lookup reports the
# attribution Pacer recorded for these turns — more direct than resolving a
# config directory, which only describes the profile.
AUTO_NOTE=""

# Resolve *this session's* account whenever we can, and never mind what
# `--model` says.
#
# These were one step, and coupling them was a real failure: an orchestrator
# that passed `--model opus` got no session lookup, so the parser fell back to
# "whichever login is active" — the idle account — and reported GO at 0% of a
# 5-hour window while the account this session actually runs on sat at 65% with
# five sessions drawing on it. Work was dispatched on that reading.
#
# Which account you are is not a function of which model you run. The lookup is
# one local request and it settles the account; the model half of its answer is
# only used when `--model auto` asked for it.
if [ -z "$ACCOUNT" ] || [ "$ACCOUNT" = all ]; then
  resolve_session || true
fi

if [ "$MODEL" = auto ]; then
  model_count=$(printf '%s\n' "$SESSION_MODELS" | grep -c . || true)
  if [ "${model_count:-0}" -gt 1 ]; then
    # More than one model on recent turns means this session is a parent and
    # its subagents at once, and *nothing available here says which one is
    # asking* — the session id is shared and no environment variable names a
    # per-agent model.
    #
    # The old code answered with the newest turn's model anyway. That is how a
    # Sonnet builder came to gate on its Fable orchestrator's window: a cap
    # that does not bind it, reported as if it did.
    #
    # So bind what certainly applies and nothing else. Account-wide windows
    # (5h, 7d) bind every model including ours; a per-model cap might be
    # somebody else's, and being paused by another model's cap is the same
    # wrong answer in the other direction.
    MODEL="$AMBIGUOUS_MODEL"
    AUTO_NOTE="model ambiguous ($(printf '%s\n' "$SESSION_MODELS" | paste -sd, - )) — account-wide windows only; pass --model to gate on yours"
  elif [ -n "$SESSION_MODEL" ]; then
    MODEL="$SESSION_MODEL"
    AUTO_NOTE="model $MODEL (detected)"
  else
    MODEL=""
    AUTO_NOTE="model unknown — every window binds"
  fi
fi

# Which login to ask about, and — separately — which login to keep when the
# answer arrives. They have to agree.
#
# They did not, and it took an account switch to show it: the request named
# this session's account while the parser fell back to whichever login was
# *active*, so after a switch every row was filtered out and the skill reported
# "no rate-limit windows yet" while staring at a full set of them. The rule is
# now that whenever the id is known it is used for both, and the client-side
# "whichever is active" fallback applies only when nothing else has said.
if [ -n "$ACCOUNT" ] && [ "$ACCOUNT" != all ]; then
  SCOPE=(--data-urlencode "account=$ACCOUNT")
  AWK_WANT="$ACCOUNT"
elif [ -n "$SESSION_ACCOUNT" ]; then
  SCOPE=(--data-urlencode "account=$SESSION_ACCOUNT")
  AWK_WANT="$SESSION_ACCOUNT"
elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  # Only Pacer can turn a config directory into an id, so here — and only
  # here — the response is taken as already narrowed.
  SCOPE=(--data-urlencode "config_dir=$CLAUDE_CONFIG_DIR")
  AWK_WANT=all
fi

case "$SUB" in
  accounts) cmd_accounts;;
  sessions) cmd_sessions;;
  report) cmd_report;;
  json)   cmd_json;;
  gate)   cmd_gate;;
  status) cmd_status;;
  wait)   cmd_wait;;
  *) die "unknown subcommand '$SUB' (report|json|accounts|sessions|gate|status|wait)";;
esac
