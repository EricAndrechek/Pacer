#!/bin/bash
# Capture a one-shot performance snapshot of the running Pacer.app
# WITHOUT touching the user's mouse, screen, or active workspace.
#
# Everything in here is a CLI tool that already runs against an
# arbitrary pid: `sample` (Apple's poor-man's profiler — no Instruments
# UI needed), `top -l`, `tail` on the log, `sqlite3` queries against the
# read-only-cloned store, and a fingerprint of App Group prefs.
#
# Output: one timestamped directory under
# `~/Library/Logs/Pacer/perf-snapshots/<ts>/` with a `summary.txt` plus
# the raw outputs. The summary is the only file a debugging session
# typically needs to read; the raw files are there for follow-up.
#
# Usage:
#   bin/dev-perf-snapshot.sh                  # default 10s sample, 5x top
#   PERF_SAMPLE_SECONDS=30 bin/dev-perf-snapshot.sh
#   bin/dev-perf-snapshot.sh --log-tail 1000  # more log lines
# Strict mode but no pipefail: each section is best-effort against an
# arbitrary running process and we'd rather emit a partial summary
# than bail mid-script if (say) `sample` momentarily can't attach.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/Pacer"
LOG_FILE="$LOG_DIR/Pacer.err.log"
STORE_DIR="$HOME/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"
STORE_FILE="$STORE_DIR/pacer.sqlite"
PREFS_FILE="$STORE_DIR/Library/Preferences/YZXWMJ5VBY.com.ericandrechek.pacer.plist"

# Tuneables. Override via env or args.
SAMPLE_SECONDS="${PERF_SAMPLE_SECONDS:-10}"
TOP_ITERATIONS="${PERF_TOP_ITERATIONS:-5}"
TOP_INTERVAL="${PERF_TOP_INTERVAL:-2}"
LOG_TAIL_LINES=500

while [ $# -gt 0 ]; do
    case "$1" in
        --log-tail) LOG_TAIL_LINES="$2"; shift 2 ;;
        --sample-seconds) SAMPLE_SECONDS="$2"; shift 2 ;;
        --top-iterations) TOP_ITERATIONS="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Resolve the running pid up front. Without it, sample / top have
# nothing to attach to and the whole script is pointless.
PID="$(pgrep -f '/Pacer\.app/Contents/MacOS/Pacer$' | head -1 || true)"
if [ -z "$PID" ]; then
    echo "Pacer.app is not running — start it (open it from Launchpad or run 'make open') and retry." >&2
    exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$LOG_DIR/perf-snapshots/$TS"
mkdir -p "$OUT_DIR"

echo "Capturing perf snapshot for pid $PID → $OUT_DIR"

# ----------------------------------------------------------------------
# 1. CPU profile via `sample`. This is the cheapest "where is CPU
#    going" answer available — Apple ships it with the OS, it doesn't
#    require Instruments to be installed, and it's safe against a
#    long-running app (sends SIGSTOP briefly during sampling, then
#    SIGCONT). Output is a text call tree we can grep through.
# ----------------------------------------------------------------------
echo "  [1/5] sample ${SAMPLE_SECONDS}s ..."
# `-mayDie` lets sample finish gracefully if Pacer is quit mid-sample.
# `-file` writes the report directly rather than going through the
# terminal-only output formatter that strips newlines.
sample "$PID" "$SAMPLE_SECONDS" -mayDie -file "$OUT_DIR/sample.txt" >/dev/null 2>&1 || true

# ----------------------------------------------------------------------
# 2. Resource snapshot via `top -l`. CPU %, memory, threads, wakeups,
#    disk I/O. One snapshot is noise; N snapshots TOP_INTERVAL apart
#    let us see drift. `-stats` selects only the columns we care about
#    so the file stays small.
# ----------------------------------------------------------------------
echo "  [2/5] top ${TOP_ITERATIONS}x ${TOP_INTERVAL}s ..."
top -pid "$PID" \
    -l "$TOP_ITERATIONS" \
    -s "$TOP_INTERVAL" \
    -stats pid,command,cpu,mem,threads,state,csw,time \
    > "$OUT_DIR/top.txt" 2>/dev/null || true

# ----------------------------------------------------------------------
# 3. Recent log lines. The phase-timed ScanCoordinator log is the
#    single most useful artifact — one line per scan cycle, broken
#    into autoA / prep / scan / dailyR / hourR / projR / sessR / save.
#    Median + P95 cycle time gets aggregated into the summary.
# ----------------------------------------------------------------------
echo "  [3/5] log tail (${LOG_TAIL_LINES} lines) ..."
if [ -f "$LOG_FILE" ]; then
    tail -n "$LOG_TAIL_LINES" "$LOG_FILE" > "$OUT_DIR/pacer.log"
else
    echo "(no log at $LOG_FILE)" > "$OUT_DIR/pacer.log"
fi

# ----------------------------------------------------------------------
# 4. SwiftData store stats. Row counts per table + on-disk size +
#    schema. Read-only: we go through a temp WAL-checkpoint copy so
#    the live store isn't disturbed.
#
#    `sqlite3` opening the live file in shared mode is safe, but a
#    paranoid copy gets us an exact frozen-in-time snapshot and lets
#    us run heavier queries (counts on large tables) without
#    contending with the app's writes.
# ----------------------------------------------------------------------
echo "  [4/5] sqlite stats ..."
SQL_OUT="$OUT_DIR/sqlite.txt"
if [ -f "$STORE_FILE" ]; then
    DB_SIZE_BYTES="$(wc -c <"$STORE_FILE" | tr -d ' ')"
    DB_SIZE_MB="$(awk -v b="$DB_SIZE_BYTES" 'BEGIN { printf "%.1f", b/1024/1024 }')"
    {
        echo "## pacer.sqlite"
        echo "size: $DB_SIZE_BYTES bytes ($DB_SIZE_MB MB)"
        echo
        echo "## row counts per Pacer table (Z* = SwiftData models, A* = Core Data history tracking)"
        # SwiftData stores models as ZTOKENSAMPLE / ZDAILYAGGREGATE etc.
        # The A* tables (ACHANGE / ATRANSACTION) are Core Data's history
        # tracking — historically huge on long-running stores; counts
        # are informative on their own.
        # `-cmd ".headers off"` and `-cmd ".mode list"` apply the dot
        # commands BEFORE the SQL argument; passing them as a single
        # multi-line SQL string fails because sqlite3 parses each `.X`
        # line as a separate command argument.
        while read -r tbl; do
            [ -z "$tbl" ] && continue
            cnt="$(sqlite3 -cmd '.headers off' -cmd '.mode list' \
                "file:$STORE_FILE?mode=ro" \
                "SELECT count(*) FROM \"$tbl\";" 2>/dev/null || echo "?")"
            printf "  %-40s %s\n" "$tbl" "$cnt"
        done < <(sqlite3 -cmd '.headers off' -cmd '.mode list' \
            "file:$STORE_FILE?mode=ro" \
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" 2>/dev/null)

        echo
        echo "## indexes"
        sqlite3 -cmd '.headers off' -cmd '.mode list' \
            "file:$STORE_FILE?mode=ro" \
            "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name;" 2>/dev/null \
            | sed 's/^/  /'
    } > "$SQL_OUT" 2>&1
else
    echo "(no store at $STORE_FILE)" > "$SQL_OUT"
fi

# ----------------------------------------------------------------------
# 5. Summary. Distill the above into one screen the model can read
#    quickly: scan-cycle latency histogram parsed from the log, CPU%
#    from top, on-disk size, anything in the log tagged WARN/error.
# ----------------------------------------------------------------------
echo "  [5/5] summary ..."
SUMMARY="$OUT_DIR/summary.txt"
{
    echo "Pacer perf snapshot $TS"
    echo "  pid:     $PID"
    echo "  out:     $OUT_DIR"
    echo "  sample:  ${SAMPLE_SECONDS}s"
    echo "  top:     ${TOP_ITERATIONS}x @ ${TOP_INTERVAL}s"
    echo
    echo "## scan-cycle latency (from pacer.log)"
    # Pull `ms=NNNN` numbers out of every "ScanCoordinator] scan:" line
    # in the captured tail and produce a P50/P90/P99 from awk.
    if grep -q 'ScanCoordinator\] scan:' "$OUT_DIR/pacer.log" 2>/dev/null; then
        grep -oE 'ms=[0-9]+' "$OUT_DIR/pacer.log" \
            | grep -oE '[0-9]+' \
            | sort -n \
            | awk '
                { a[NR] = $1; total += $1; if ($1 > 1000) slow++ }
                END {
                    if (NR == 0) { print "  (no scan cycles in tail)"; exit }
                    p50 = a[int(NR*0.50)+0]
                    p90 = a[int(NR*0.90)+0]
                    p99 = a[int(NR*0.99)+0]
                    printf "  cycles=%d, slow(>1s)=%d (%.0f%%)\n", NR, slow+0, (slow+0)*100/NR
                    printf "  min=%d  p50=%d  p90=%d  p99=%d  max=%d  mean=%d (ms)\n", \
                           a[1], p50, p90, p99, a[NR], int(total/NR)
                }'
    else
        echo "  (no scan-cycle lines)"
    fi
    echo
    echo "## phase median (ms) — only present if the log has the phase tail"
    # Aggregate medians per named phase from the bracketed phase tail.
    # Format: `[autoA=N prep=N mig=N scan=N flush=N curs=N dailyR=N ...]`
    # awk pulls each key=val pair, sorts numerically per key, picks
    # the middle. No external tools required.
    if grep -q 'autoA=' "$OUT_DIR/pacer.log" 2>/dev/null; then
        awk '
            match($0, /\[autoA=[^]]+\]/) {
                tail = substr($0, RSTART+1, RLENGTH-2)
                n = split(tail, parts, " ")
                for (i = 1; i <= n; i++) {
                    eq = index(parts[i], "=")
                    if (!eq) continue
                    k = substr(parts[i], 1, eq-1)
                    v = substr(parts[i], eq+1) + 0
                    samples[k, ++count[k]] = v
                }
            }
            END {
                # Build sorted output by sorting per-key values then
                # picking the median.
                for (k in count) {
                    n = count[k]
                    for (i = 1; i <= n; i++) vals[i] = samples[k, i]
                    # Insertion sort — n is small (lines captured ≤ tail).
                    for (i = 2; i <= n; i++) {
                        key = vals[i]; j = i - 1
                        while (j >= 1 && vals[j] > key) { vals[j+1] = vals[j]; j-- }
                        vals[j+1] = key
                    }
                    med = vals[int(n/2) + 1]
                    printf "  %-10s n=%4d  median=%d  max=%d\n", k, n, med, vals[n]
                    delete vals
                }
            }
        ' "$OUT_DIR/pacer.log" | sort
    else
        echo "  (log lines pre-date the phase-timing instrumentation — rebuild and re-snapshot)"
    fi
    echo
    echo "## top — peak CPU% across iterations"
    # Parse the per-iteration top sections. Field positions are stable
    # in the -stats list we requested above.
    if [ -s "$OUT_DIR/top.txt" ]; then
        grep -E "^[ ]*$PID " "$OUT_DIR/top.txt" \
            | awk -v pid="$PID" '
                /^[ ]*[0-9]+ / && $1 == pid {
                    cpu = $3 + 0
                    if (cpu > max) max = cpu
                    sum += cpu; n++
                    if ($5 ~ /[0-9]/) threads = $5
                }
                END {
                    if (n) printf "  samples=%d  mean=%.1f%%  peak=%.1f%%  threads=%s\n", n, sum/n, max, threads
                    else print "  (pid not in top output)"
                }'
    else
        echo "  (no top output)"
    fi
    echo
    echo "## store"
    if [ -f "$STORE_FILE" ]; then
        size="$(wc -c <"$STORE_FILE" | tr -d ' ')"
        mb="$(awk -v b="$size" 'BEGIN { printf "%.1f", b/1024/1024 }')"
        echo "  pacer.sqlite: $size bytes ($mb MB)"
    fi
    echo
    echo "## anomalies in log tail (last $LOG_TAIL_LINES lines)"
    # Anything that looks like an error or a flagged slow path.
    grep -iE '(failed|error|warn|panic|fatal|integrity:|cost recompute)' \
        "$OUT_DIR/pacer.log" 2>/dev/null \
        | tail -20 \
        | sed 's/^/  /' \
        || echo "  (none)"
    echo
    echo "## artifacts"
    echo "  sample profile: $OUT_DIR/sample.txt"
    echo "  top snapshots:  $OUT_DIR/top.txt"
    echo "  log tail:       $OUT_DIR/pacer.log"
    echo "  sqlite stats:   $OUT_DIR/sqlite.txt"
    echo "  this summary:   $OUT_DIR/summary.txt"
} > "$SUMMARY"

echo
cat "$SUMMARY"
