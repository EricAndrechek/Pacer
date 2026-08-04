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
