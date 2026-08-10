#!/usr/bin/env bash
#
# dev-verify-data.sh — check every rollup against the raw samples it derives
# from, on the REAL store. Read-only.
#
# This exists because it found a real bug. After the streaming-dedup repair
# (v0.4.2) the daily rollup matched its samples exactly while the hourly
# rollup read ~1% high — 34 `HourlyAggregate` rows whose samples had moved to
# a different hour and which nothing deleted, because the recomputer only
# removes buckets in its dirty set and a bucket with no samples is never
# dirtied. Nothing in the app noticed; the totals just quietly ran high.
#
# Two kinds of check, and the distinction matters:
#
#   KEYS    a rollup row whose bucket has no samples (stranded), or a sample
#           bucket with no rollup row (missing). Stranded rows inflate totals;
#           missing rows deflate them.
#   VALUES  a rollup row whose bucket exists but whose numbers disagree with
#           the samples in it. That's a recompute bug rather than a
#           bookkeeping one.
#
# Run it after anything that changes what a sample contains or how one is
# bucketed — a parser change, a dedup change, a migration, a version bump.
#
#   bin/dev-verify-data.sh        (or: make verify-data)
#
# Exits non-zero if anything is inconsistent, so it can gate a release.

set -euo pipefail

STORE="${HOME}/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite"
[ -f "$STORE" ] || { echo "no store at $STORE"; exit 1; }

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; X=$'\033[0m'
else B=; G=; R=; X=; fi
fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then printf '%s  ✓%s %s\n' "$G" "$X" "$1"
  else printf '%s  ✗%s %s — expected %s, got %s\n' "$R" "$X" "$1" "$2" "$3"; fail=1; fi
}

# Read a snapshot so a live scan mid-run can't produce a phantom mismatch:
# the app writes continuously, and two queries seconds apart legitimately
# disagree. (That bit me once — a 157k "shortfall" that was just drift.)
SNAP="$(mktemp -t pacer-verify).sqlite"
trap 'rm -f "$SNAP" "$SNAP"-wal "$SNAP"-shm' EXIT
sqlite3 "file:${STORE}?mode=ro" ".backup '$SNAP'" 2>/dev/null

q() { sqlite3 -noheader -list -batch -init /dev/null "$SNAP" "$1" 2>/dev/null; }

printf '%s==>%s Rollup keys — stranded rows (inflate) and missing rows (deflate)\n' "$B" "$X"

check "daily: no stranded rows" 0 "$(q "
  SELECT COUNT(*) FROM ZDAILYAGGREGATE a
  LEFT JOIN (SELECT DISTINCT ZDATE d, ZMODEL m FROM ZTOKENSAMPLE) s
    ON s.d=a.ZDATE AND s.m=a.ZMODEL WHERE s.d IS NULL")"

# Hour is DERIVED from sampledAt rather than stored the way date is, so a DST
# or timezone shift re-buckets samples and strands their old rows. This is the
# check that caught the 34.
check "hourly: no stranded rows" 0 "$(q "
  SELECT COUNT(*) FROM ZHOURLYAGGREGATE a
  LEFT JOIN (SELECT DISTINCT ZDATE d, ZMODEL m,
             CAST(strftime('%H', datetime(ZSAMPLEDAT+978307200,'unixepoch','localtime')) AS INTEGER) h
             FROM ZTOKENSAMPLE) s
    ON s.d=a.ZDATE AND s.m=a.ZMODEL AND s.h=a.ZHOUR WHERE s.d IS NULL")"

check "hourly: no missing rows" 0 "$(q "
  SELECT COUNT(*) FROM (SELECT DISTINCT ZDATE d, ZMODEL m,
    CAST(strftime('%H', datetime(ZSAMPLEDAT+978307200,'unixepoch','localtime')) AS INTEGER) h
    FROM ZTOKENSAMPLE) s
  LEFT JOIN ZHOURLYAGGREGATE a ON a.ZDATE=s.d AND a.ZMODEL=s.m AND a.ZHOUR=s.h
  WHERE a.ZDATE IS NULL")"

check "project: no stranded rows" 0 "$(q "
  SELECT COUNT(*) FROM ZPROJECTDAILYAGGREGATE a
  LEFT JOIN (SELECT DISTINCT COALESCE(ZPROJECTPATH,'(unknown)') p, ZDATE d FROM ZTOKENSAMPLE) s
    ON s.p=a.ZPROJECTPATH AND s.d=a.ZDATE WHERE s.p IS NULL")"

check "session: no stranded rows" 0 "$(q "
  SELECT COUNT(*) FROM ZSESSIONINFO si
  LEFT JOIN (SELECT DISTINCT ZSESSIONID s FROM ZTOKENSAMPLE
             WHERE ZSESSIONID IS NOT NULL AND ZSESSIONID<>'') s ON s.s=si.ZSESSIONID
  WHERE s.s IS NULL")"

printf '\n%s==>%s Rollup values — numbers must equal the samples in the bucket\n' "$B" "$X"

check "daily: token totals match samples" "$(q "
  SELECT SUM(ZINPUTTOKENS)||'/'||SUM(ZOUTPUTTOKENS)||'/'||SUM(ZCACHEREADTOKENS) FROM ZTOKENSAMPLE")" "$(q "
  SELECT SUM(ZINPUTTOKENS)||'/'||SUM(ZOUTPUTTOKENS)||'/'||SUM(ZCACHEREADTOKENS) FROM ZDAILYAGGREGATE")"

check "hourly: token totals match samples" "$(q "
  SELECT SUM(ZINPUTTOKENS)||'/'||SUM(ZOUTPUTTOKENS)||'/'||SUM(ZCACHEREADTOKENS) FROM ZTOKENSAMPLE")" "$(q "
  SELECT SUM(ZINPUTTOKENS)||'/'||SUM(ZOUTPUTTOKENS)||'/'||SUM(ZCACHEREADTOKENS) FROM ZHOURLYAGGREGATE")"

check "project: per-bucket values match" 0 "$(q "
  WITH s AS (SELECT COALESCE(ZPROJECTPATH,'(unknown)') p, ZDATE d,
             SUM(ZINPUTTOKENS) i, SUM(ZOUTPUTTOKENS) o FROM ZTOKENSAMPLE GROUP BY p,d)
  SELECT COUNT(*) FROM s JOIN ZPROJECTDAILYAGGREGATE a
    ON a.ZPROJECTPATH=s.p AND a.ZDATE=s.d
  WHERE a.ZINPUTTOKENS<>s.i OR a.ZOUTPUTTOKENS<>s.o")"

check "session: per-session values match" 0 "$(q "
  WITH s AS (SELECT ZSESSIONID sid, SUM(ZINPUTTOKENS) i, SUM(ZOUTPUTTOKENS) o
             FROM ZTOKENSAMPLE WHERE ZSESSIONID IS NOT NULL AND ZSESSIONID<>'' GROUP BY sid)
  SELECT COUNT(*) FROM s JOIN ZSESSIONINFO si ON si.ZSESSIONID=s.sid
  WHERE si.ZCUMULATIVEINPUTTOKENS<>s.i OR si.ZCUMULATIVEOUTPUTTOKENS<>s.o")"

# Cost is the number users actually look at, and it's DERIVED (tokens x
# pricing, or Claude Code's own figure depending on cost mode) rather than
# summed from a stored column — so it can drift independently of the tokens
# above. Every rollup slices the same samples differently, so all four totals
# must agree with each other to the cent.
printf '\n%s==>%s Cost — every rollup slices the same spend\n' "$B" "$X"

daily_cost="$(q "SELECT ROUND(SUM(ZTOTALCOSTUSD),2) FROM ZDAILYAGGREGATE")"
check "hourly cost equals daily"  "$daily_cost" "$(q "SELECT ROUND(SUM(ZTOTALCOSTUSD),2) FROM ZHOURLYAGGREGATE")"
check "project cost equals daily" "$daily_cost" "$(q "SELECT ROUND(SUM(ZTOTALCOSTUSD),2) FROM ZPROJECTDAILYAGGREGATE")"
check "session cost equals daily" "$daily_cost" "$(q "SELECT ROUND(SUM(ZCUMULATIVECOSTUSD),2) FROM ZSESSIONINFO")"

# Two TokenSamples sharing a dedup key is the one thing the dedup guard exists
# to prevent — it means the same turn was counted twice, inflating tokens and
# cost for whatever day it lands on. Reported, never auto-repaired: raw samples
# are never deleted without a human deciding to (see the never-delete rule),
# and old residue like this can predate the fix that made it impossible.
printf '\n%s==>%s Duplicate turns\n' "$B" "$X"
dupes="$(q "SELECT COUNT(*) FROM (SELECT ZDEDUPKEY FROM ZTOKENSAMPLE
            WHERE ZDEDUPKEY IS NOT NULL GROUP BY ZDEDUPKEY HAVING COUNT(*) > 1)")"
if [ "${dupes:-0}" = 0 ]; then
  printf '%s  ✓%s no turn is stored twice\n' "$G" "$X"
else
  # Not a failure: known residue, and failing on it would make the whole check
  # useless as a gate until someone decides what to do about it.
  printf '  ! %s dedup key(s) appear on more than one row — double-counted turns\n' "$dupes"
  q "SELECT '      ' || ZDATE || '  ' || COUNT(*) || ' key(s)' FROM (
       SELECT ZDEDUPKEY k, ZDATE, COUNT(*) n FROM ZTOKENSAMPLE
       WHERE ZDEDUPKEY IS NOT NULL GROUP BY k HAVING n > 1)
     GROUP BY ZDATE ORDER BY ZDATE DESC LIMIT 5"
fi

# The raw archive is a SECOND copy of every billable turn, written by a
# different code path (DuckDB appender) than the store (SwiftData). Two copies
# that are never compared are just two chances to be wrong, so compare them.
#
# DuckDB takes an EXCLUSIVE per-process file lock, so this can only run while
# Pacer is closed. That's a real limitation of the design, not an oversight —
# it's why the app also verifies its own appends. Skipped loudly rather than
# silently, because a check that quietly does nothing is worse than no check.
printf '\n%s==>%s Raw archive vs store\n' "$B" "$X"
ARCHIVE="${HOME}/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/raw-archive.duckdb"
if [ ! -f "$ARCHIVE" ]; then
  printf '  - no archive yet (nothing has been written)\n'
elif ! command -v duckdb >/dev/null 2>&1; then
  printf '  - skipped: duckdb CLI not installed (brew install duckdb)\n'
elif ! d_rows="$(duckdb -noheader -list -readonly "$ARCHIVE" \
        "SELECT COUNT(*) FROM turn" 2>/dev/null)" || [ -z "$d_rows" ]; then
  # Locked, so read the verdict the app recorded instead. Pacer checks the
  # same thing hourly from inside, precisely because a check that requires
  # quitting the app is a check that never runs.
  verdict="$(q "SELECT ZVALUE FROM ZCLAUDECODEMETA WHERE ZKEY='archive_integrity'")"
  case "${verdict%%|*}" in
    ok)
      when="$(echo "$verdict" | cut -d'|' -f2)"
      rows="$(echo "$verdict" | cut -d'|' -f3)"
      age=$(( $(date +%s) - ${when:-0} ))
      checks="$(echo "$verdict" | tr '|' '\n' | sed -n 's/^checks=//p')"
      misses="$(echo "$verdict" | tr '|' '\n' | sed -n 's/^mismatches=//p')"
      # A stale verdict is a failure, not a detail. `ArchiveSync` disables
      # itself after an error, and a check that silently stopped running
      # looks exactly like a check that keeps passing.
      if [ "$age" -gt 10800 ]; then
        check "archive self-check is running" "within 3h" "$(( age / 3600 ))h ago"
      else
        printf '%s  ✓%s archive matched the store (%s turns, self-checked %sm ago)\n' \
          "$G" "$X" "$rows" "$(( age / 60 ))"
      fi
      printf '      %s check(s) all-time, %s mismatch(es)\n' "${checks:-?}" "${misses:-0}"
      # A soak is only evidence if a failure that self-corrected still shows.
      first="$(echo "$verdict" | tr '|' '\n' | sed -n 's/^first=//p')"
      [ -n "$first" ] && printf '%s      ! first divergence: %s%s\n' "$R" "$first" "$X"
      ;;
    mismatch)
      check "archive matches the store (app self-check)" "ok" "${verdict#mismatch|*|}"
      ;;
    *)
      printf '  - skipped: Pacer holds the archive lock and has not self-checked yet\n'
      ;;
  esac
else
  # Check the guarantee the archive actually makes, which is eventual, not
  # instantaneous: turns arriving out of order are picked up by a reconcile
  # pass every 30 minutes, so anything newer than that is legitimately absent.
  # The cutoff is therefore 2 hours ago — well past one reconcile interval —
  # and it is applied to BOTH sides.
  #
  # Two ways this was wrong before, both of which looked like data loss:
  # filtering only the store side (so rows sharing the boundary second landed
  # on different sides of the comparison), and comparing right up to the
  # archive's newest row (so normal sync lag read as a permanent shortfall).
  cutoff="$(( $(date +%s) - 7200 ))"
  # SwiftData stores dates as seconds since 2001-01-01.
  ref="$(( cutoff - 978307200 ))"
  a_where="WHERE sampled_at <= make_timestamp(${cutoff}000000)"
  check "archive row count matches the store" \
    "$(q "SELECT COUNT(*) FROM ZTOKENSAMPLE WHERE ZSAMPLEDAT <= ${ref}")" \
    "$(duckdb -noheader -list -readonly "$ARCHIVE" \
       "SELECT COUNT(*) FROM turn ${a_where}" 2>/dev/null)"
  for pair in "input_tokens:ZINPUTTOKENS" "output_tokens:ZOUTPUTTOKENS" \
              "cache_read:ZCACHEREADTOKENS" "cache_creation_5m:ZCACHECREATION5MTOKENS" \
              "cache_creation_1h:ZCACHECREATION1HTOKENS"; do
    dcol="${pair%%:*}"; scol="${pair##*:}"
    check "archive ${dcol} matches the store" \
      "$(q "SELECT COALESCE(SUM(${scol}),0) FROM ZTOKENSAMPLE WHERE ZSAMPLEDAT <= ${ref}")" \
      "$(duckdb -noheader -list -readonly "$ARCHIVE" \
         "SELECT CAST(COALESCE(SUM(${dcol}),0) AS BIGINT) FROM turn ${a_where}" 2>/dev/null)"
  done
fi

printf '\n%s==>%s Store\n' "$B" "$X"
printf '    %s rows · %s daily · %s hourly · %s project · %s sessions\n' \
  "$(q 'SELECT COUNT(*) FROM ZTOKENSAMPLE')" \
  "$(q 'SELECT COUNT(*) FROM ZDAILYAGGREGATE')" \
  "$(q 'SELECT COUNT(*) FROM ZHOURLYAGGREGATE')" \
  "$(q 'SELECT COUNT(*) FROM ZPROJECTDAILYAGGREGATE')" \
  "$(q 'SELECT COUNT(*) FROM ZSESSIONINFO')"

echo
if [ "$fail" = 0 ]; then printf '%s  ✓ every rollup agrees with its samples%s\n' "$G" "$X"
else printf '%s  ✗ inconsistencies above — see docs/perf-tuning.md "stranded"%s\n' "$R" "$X"; fi
exit "$fail"
