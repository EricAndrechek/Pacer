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
# How many times to re-ask before believing "nothing is listening". Pacer
# restarts itself for updates, so one refused connection is not an answer.
RETRIES="${PACE_RETRIES:-3}"
AUTH=()
[ -n "${PACE_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${PACE_TOKEN}")

die() { echo "pace: $*" >&2; exit 1; }
command -v curl >/dev/null || die "need curl"
command -v awk  >/dev/null || die "need awk"

SUB="${1:-report}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --cap)      CAP="$2"; shift 2;;
    --interval) INTERVAL="$2"; shift 2;;
    --window)   WINDOW="$2"; shift 2;;
    --account)  ACCOUNT="$2"; shift 2;;
    --max-wait) MAXWAIT="$2"; shift 2;;
    --max-age)  MAXAGE="$2"; shift 2;;
    --retries)  RETRIES="$2"; shift 2;;
    --state)    STATE="$2"; shift 2;;
    -h|--help)  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown flag: $1";;
  esac
done
[ "$INTERVAL" -lt 300 ] 2>/dev/null && INTERVAL=300   # Pacer only updates every ~5 min

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
function labelfor(id,   n, parts) {
  if (id == "five_hour") return "5h"
  if (id == "seven_day") return "7d"
  n = split(id, parts, "|")
  if (n >= 2 && parts[2] != "") return parts[2]     # model
  if (n >= 3 && parts[3] != "") return parts[3]     # surface
  return parts[1]                                   # kind
}
/^pacer_account_info\{/ {
  if (tagval($0, "active") == "true") active = tagval($0, "account")
}
/^pacer_rate_limit_used_ratio\{/ {
  a = tagval($0, "account"); w = tagval($0, "window")
  key = a SUBSEP w
  if (!(key in seen)) { seen[key] = 1; order[++n] = key; acct[key] = a; win[key] = w }
  pct[key] = $NF * 100
  accounts[a] = 1
  next
}
/^pacer_rate_limit_reset_seconds\{/ {
  a = tagval($0, "account"); w = tagval($0, "window")
  key = a SUBSEP w
  if (!(key in seen)) { seen[key] = 1; order[++n] = key; acct[key] = a; win[key] = w }
  secs[key] = $NF
  next
}
END {
  count = 0
  for (a in accounts) { count++; only = a }
  want = WANT
  if (want == "") want = (active != "" ? active : (count == 1 ? only : ""))
  if (want == "all") want = ""
  for (i = 1; i <= n; i++) {
    key = order[i]
    if (want != "" && acct[key] != want) continue
    printf "%s\t%s\t%s\t%s\t%s\n", acct[key], win[key], labelfor(win[key]),
           (key in pct ? pct[key] : "null"), (key in secs ? secs[key] : "null")
  }
}'

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
    if raw=$(curl -s -m 5 -w '\n%{http_code}' ${AUTH[@]+"${AUTH[@]}"} "$API"); then
      code=${raw##*$'\n'}
      body=${raw%$'\n'*}
      case "$code" in
        401|403) FETCH_REASON=auth; return 1;;
        000|200) ;;                       # 000 = a non-HTTP URL, e.g. file://
        *)       FETCH_REASON=http; HTTP_CODE=$code; return 1;;
      esac
      if [ -n "$body" ]; then
        ROWS=$(printf '%s\n' "$body" | awk -v WANT="$ACCOUNT" "$PARSE_AWK")
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
  printf '%s\n' "$ROWS" | awk -F'\t' -v SEL="$WINDOW" '
    BEGIN { sel = tolower(SEL) }
    sel == "" || sel == "all" { print; next }
    { if (index(tolower($3), sel) || index(tolower($2), sel)) print }'
}

# A `--window` that matches nothing is a typo, not "no limits to worry about".
# Without this, `--window fabel` reports GO forever — the exact failure a pacing
# tool must not have.
require_selection() {
  case "$WINDOW" in ''|all) return 0;; esac
  [ -n "$(selected_rows)" ] && return 0
  echo "pace: --window '$WINDOW' matches no window. Available: $(printf '%s\n' "$ROWS" | awk -F'\t' '{ printf "%s%s", (NR>1 ? ", " : ""), $3 }')" >&2
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
  line=$(selected_rows | awk -F'\t' -v cap="$CAP" '
    $4 != "null" && $4 + 0 >= cap + 0 {
      s = ($5 == "null" ? 9999999 : $5 + 0)
      if (best == "" || s < bests) { best = $3 "\t" $4 "\t" $5; bests = s }
    }
    END { if (best != "") print best }')
  TRIP=""; TPCT=""; TSECS=""
  [ -n "$line" ] && IFS=$'\t' read -r TRIP TPCT TSECS <<<"$line"
}

# One-line summary of every watched window, for a human note.
summary() {
  selected_rows | awk -F'\t' '{ printf "%s%s %s%%", (NR>1 ? ", " : ""), $3, sprintf("%.0f", $4) }'
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
  local multi
  multi=$(printf '%s\n' "$ROWS" | awk -F'\t' '{ a[$1] = 1 } END { print length(a) }')
  selected_rows | while IFS=$'\t' read -r acct id label pct secs; do
    local prefix=""
    [ "$multi" -gt 1 ] && prefix="$(printf '%-8s ' "${acct:0:8}")"
    printf '%s%-10s %4s%% used · resets in %-7s (%s)\n' \
      "$prefix" "$label" "$(pct_fmt "$pct")" "$(human "$secs")" "$(clock "$secs")"
  done
}

cmd_json() {
  fetch_rows || {
    printf '{"ok": false, "reason": "%s"}\n' "${FETCH_REASON:-off}"
    exit "$(off_exit_code)"
  }
  require_selection
  printf '{\n  "ok": true,\n  "at": "%s",\n  "windows": [\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  selected_rows | awk -F'\t' '
    { printf "%s    {\"account\": \"%s\", \"identity\": \"%s\", \"label\": \"%s\", \"usedPercent\": %s, \"resetsInSeconds\": %s}",
             (NR > 1 ? ",\n" : ""), $1, $2, $3, $4, $5 }
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
    echo "pace: GO — $(summary) (cap ${CAP}%)."
    exit 0
  fi
  write_state paused "$TRIP" "$TPCT" "$TSECS" \
    "${TRIP} at $(pct_fmt "$TPCT")% >= cap ${CAP}%; resets in $(human "$TSECS")"
  echo "pace: PAUSE — ${TRIP} at $(pct_fmt "$TPCT")% (cap ${CAP}%), resets in $(human "$TSECS") ($(clock "$TSECS"))."
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
  st=$(awk -F'"' '/"status"/ { print $4; exit }' "$STATE" 2>/dev/null)
  case "$st" in
    go)     echo "go"; exit 0;;
    paused) note=$(awk -F'"' '/"note"/ { print $4; exit }' "$STATE" 2>/dev/null)
            echo "paused: ${note}"; exit 10;;
    *)      echo "unknown"; exit 3;;
  esac
}

cmd_wait() {
  local waiting=false everRead=false fails=0
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
    require_selection
    evaluate
    if [ -z "$TRIP" ]; then
      write_state go "" "" "" "headroom restored ($(summary))"
      $waiting && echo "pace: reset — headroom restored ($(summary)). Resume."
      exit 0
    fi
    if [ "${TSECS:-0}" != null ] && [ "${TSECS:-0}" -gt "$MAXWAIT" ] 2>/dev/null; then
      write_state paused "$TRIP" "$TPCT" "$TSECS" \
        "manual: ${TRIP} resets in $(human "$TSECS") (> max-wait $(human "$MAXWAIT")) — checkpoint & stop"
      echo "pace: ${TRIP} at $(pct_fmt "$TPCT")% resets in $(human "$TSECS") — beyond max-wait. Checkpoint and stop; resume after $(clock "$TSECS")."
      exit 20
    fi
    write_state paused "$TRIP" "$TPCT" "$TSECS" "waiting for ${TRIP} reset (~$(human "$TSECS"))"
    $waiting || echo "pace: ${TRIP} at $(pct_fmt "$TPCT")% — waiting ~$(human "$TSECS") for reset ($(clock "$TSECS"))…"
    waiting=true
    sleep "$INTERVAL"
  done
}

case "$SUB" in
  report) cmd_report;;
  json)   cmd_json;;
  gate)   cmd_gate;;
  status) cmd_status;;
  wait)   cmd_wait;;
  *) die "unknown subcommand '$SUB' (report|json|gate|status|wait)";;
esac
