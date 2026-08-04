# DuckDB in Pacer — what's built, what it cost, and why

Pacer links a static DuckDB build. Today it does exactly one job: **parsing
every transcript at once on a full scan**. The larger idea it came from — a
columnar archive holding raw rows forever — is measured and designed but *not
built*; see "The archive, not yet built" at the end.

Read this before changing anything under `App/Archive/`, `bin/build-duckdb-xcframework.sh`,
or the bulk path in `ScanCoordinator`.

Every number here is measured on a frozen 1,697-file snapshot of a real
`~/.claude` (302,783 lines, 1.8 GB) or on the maintainer's real 189k-row
store. None of it is estimated.

## Why DuckDB is here at all

A first launch has to parse the user's whole history. Measured with the real
scanner over an empty store:

```
TOTAL 50.1 s — 1,692 files, 148,991 entries parsed, 53,994 inserted
  PARSE  (JSONL → entries)          34,763 ms   ← 70%
  rollups (daily/hourly/proj/sess)  11,673 ms
  INSERT (save phase)                    2 ms
```

A first launch is **parse-bound**, and DuckDB reads the same corpus in
seconds. That is the whole justification. It is not here because it is faster
at queries — at Pacer's scale (millions of rows, not billions) SQLite is
entirely adequate, and the live scan is untouched.

## What it is NOT allowed to do

**It never touches the incremental path.** `JSONLScanner` is FSEvents-hinted
and resumes from per-file byte offsets, so a live cycle reads only the bytes
that changed — 33–80 ms, ~0% idle CPU, which is what the whole 2026-05 perf
effort bought (`docs/perf-tuning.md`). DuckDB has no incremental cursor and
re-reads whole files; pointing it at a live cycle would hand all of that back.
`ScanCoordinator` calls it only when `isFullScan`.

**The widget extension never links it.** PacerCore declares
`BulkTranscriptImporter` and takes an implementation from the app;
`ArchiveImporter` (the DuckDB one) lives in the app target. Widgets link
PacerCore to render charts from rollups and have a tight memory budget — they
must not drag in an analytical engine. Anything that would make PacerCore
depend on DuckDB directly is a bug.

**It fails soft.** An importer that throws logs and falls back to the line
parser. The line parser can always do the job; a DuckDB problem should cost
time, not a launch.

## Vendoring: we build it, and that's deliberate

| option | what ships | size | packaging |
|---|---|---|---|
| official prebuilt | **dylib only**, arm64-thinned | 54.6 MB | embed in `Frameworks`, re-sign, rpath, library validation |
| official `duckdb-swift` | source amalgamation | — | compiles DuckDB on every clean CI run |
| **ours** (static XCFramework) | static, dead-stripped | **~39.5 MB of the binary** | linked in, no separate signing |

DuckDB's official macOS artifact (`libduckdb-osx-universal.zip`) contains only
a dylib, and a dylib can't be dead-stripped, so all 54.6 MB lands in the
bundle — bigger than our entire static-linked binary, plus embedding and
signing ceremony. `bin/build-duckdb-xcframework.sh` pins a version, builds
arm64 against the app's deployment target, merges the ~17 archives, and prints
an SPM checksum for pinning as a `.binaryTarget(url:checksum:)` if we ever
publish it.

The artifact is **gitignored**. Each version bump would otherwise add ~78 MB
to git history permanently. CI caches it keyed on
`Vendor/duckdb-version.txt` **and a hash of the build script** — see below for
why the script hash matters.

### Extensions: which, and why each is non-optional

- **core_functions** — `SUM` and friends live here, *not* in the engine. A
  build without it links, runs, ingests 187k rows, and then fails every
  aggregate at runtime with `Scalar Function with name "sum" is not in the
  catalog`. Homebrew's static lib bundles it, which is why the first spike
  passed and the first from-source build did not.
- **json** — `read_ndjson_objects` and every `json_extract*` live here, and
  DuckDB's core has no JSON parsing at all. Without it the importer throws
  `Table Function with name read_ndjson_objects is not in the catalog`.
- **parquet** — the export escape hatch. DuckDB takes an **exclusive
  per-process file lock**: while Pacer holds a database open, no other process
  can open it, *not even read-only*. `COPY TO` parquet is how a user gets data
  out without quitting the app. Costs ~14 MB.

Changing this set changes the artifact without changing the DuckDB version,
which is exactly why the CI cache key hashes the build script. Keying on the
version alone silently restores a stale framework that fails at runtime.

## Cost

Release configuration, measured both ways:

| | binary | bundle | gzipped (≈DMG) |
|---|---|---|---|
| without DuckDB | 15.1 MB | 28 MB | 4.1 MB |
| with | 40.9 MB | 54 MB | 11.1 MB |

So ~+26 MB of binary and ~2.7× the auto-update download. A standalone probe
suggested +19.2 MB, but it only referenced a sliver of the API so dead-strip
dropped far more than real use does — adding `-Wl,-dead_strip` to the app link
recovers only 2.2 MB. Don't re-derive this from a toy binary; measure the real
target.

## Correctness: the differential gate

Two ingest paths that disagree would give users different numbers depending on
how their data arrived. **Any change to the importer must be checked against
the line parser over the same corpus, comparing all six token totals** — not
just row count. A matching count proves the filter and dedup agree; only
per-field sums prove the mapping does.

```
                 rows     input       output      cacheRead        total
Swift          54,046  18,227,526  76,144,456  14,283,467,300  14,741,420,680
DuckDB         54,046  18,227,526  76,144,456  14,283,467,300  14,741,420,680
```

Harnesses (env-gated, headless, read-only):

- `PACER_COLD_START_SPIKE=1` — real scanner, empty in-memory store, phase
  timings and per-field totals.
- `PACER_IMPORT_SPIKE=1` — DuckDB parse → the ordinary persister, same totals
  for comparison.

Point either at a frozen corpus with `CLAUDE_CONFIG_DIR` so results are
reproducible while your live transcripts keep growing.

**This gate has already paid for itself.** Chasing a 0.005% gap between the two
paths surfaced [the streaming-dedup bug](#the-bug-the-gate-found) — a 63%
under-count that had been shipping for months.

## The bug the gate found

Claude Code appends the same assistant message to the transcript several times
while it streams. Copies share `${messageId}:${requestId}`, `input` and
`cache_read` are identical, and only the last carries the real `output_tokens`
plus a non-null `stop_reason`:

```
18:31:20.543  output=1    stop_reason=null
18:31:22.947  output=1    stop_reason=null
18:31:23.564  output=289  stop_reason="tool_use"
```

Dedup was first-wins — correct for *replayed* duplicates (which is what
ccusage's rule addresses, and where we got it), wrong for *streamed* ones. On
the frozen corpus that discarded **29,533,409 output tokens, 63% of the output
recorded**, ~$443 at Opus output rates. ccusage very likely shares it.

Precedence is now `ParsedUsageEntry.supersedes`: prefer the finished message,
else the larger output. Comparing on output alone is provably sufficient here —
across 54,046 keys, **no** key had a finished copy whose output wasn't also the
maximum — and 6.3% of keys never get a finished copy at all (interrupted
messages), so "largest wins" resolves those too rather than dropping them.

`currentScanVersion` bumped to `"3"` repairs existing stores: the bump wipes
cursors, every transcript is re-read, and the persister now *upgrades* a stored
row instead of skipping it. Rows whose transcripts Claude Code has since
rotated away keep their old values — we never delete a sample we can't
re-derive.

## Two performance lessons, both learned the hard way

Both were found by running against a **real 189k-row store**, and neither was
visible in a synthetic cold start.

**One fetch per item is pathological on bulk paths.** Two places did an indexed
lookup per item — optimal for the handful an incremental cycle touches, ruinous
for the thousands a full scan does:

- the dedup upgrade path fetched by `dedupKey` per upgraded row: 98% CPU and
  **>2 GB resident** before it finished. A fresh store has *nothing* to
  upgrade, so no synthetic test could have caught it.
- `saveCursors` fetched by path per cursor: 1,701 round-trips to avoid reading
  a 1,701-row table — **33.7 s of a 70 s scan**.

Both now switch strategy above a threshold. When you add a bulk path, ask what
it does at 100× the item count.

**Don't re-read the same table per worker.** All four rollup workers fetched
the entire sample table into their own `ModelContext`. They can't share
SwiftData objects (context-bound, separate actors), so they share
`SampleSnapshot` — a `Sendable` value projection built at most once per cycle
by `SampleSnapshotCache`, lazily, so incremental cycles never materialize it.

## Where cold start stands

```
                 before    after
parse            39.5 s     4.3 s
project rollup    3,240 ms   116 ms
session rollup    3,219 ms   101 ms
cursor save      33,673 ms  batched
TOTAL             74.8 s    15.8 s
```

Remaining hot spot is the **hourly rollup** (~11.6 s on the real store). It is
*compute*, not fetch — it reuses the shared snapshot. Suspected cause is 54k
`Calendar.component(.hour:)` calls for its `(date, hour, model)` grouping, but
that is **unverified**. The obvious alternative is timezone-offset arithmetic,
which risks misfiling usage across DST transitions; measure before touching it.

## The archive, not yet built

The original goal was an immutable columnar archive of raw rows, kept forever
(Pacer never deletes raw data — that's what makes retrospective model
evaluation and re-deriving past mistakes possible). Measured, designed, and
**not implemented**:

- **8× storage.** Same rows, nothing dropped: SQLite 99.7 MB (55.5 data +
  44.2 indexes) vs DuckDB 13.0 MB. Projected to 5 years at the maintainer's
  rate (2.78M rows): **1,460 MB vs 180 MB**. The cause is structural — 75% of a
  row is strings, nearly all low-cardinality repeats (`projectPath` 60 distinct
  values, `model` 8) that columnar dictionary-encodes for free.
- **Don't archive raw transcript text.** Verbatim lines cost 1,819 MB from a
  1.8 GB corpus — no compression win, because long unique JSON strings defeat
  the string encodings. Re-serialized via `to_json` it's worse, 2,500 MB. The
  8× is a property of *typed columns*. And the transcripts already live in
  `~/.claude`; re-read them rather than duplicating them.
- **The seam.** Raw `TokenSample` is read by the scan/dedup write path, the
  rollup recomputers, one modal, two `fetchLimit=1` probes, and the alias
  migration. The engine already runs off rollups. So nothing interactive needs
  the full archive — SwiftData could keep rollups plus a hot window, with the
  archive holding everything. The hot window would be a *cache, not the
  record*, so trimming it is not deleting data.
- **A consequence worth wanting.** A columnar archive can't do cheap `UPDATE`s,
  which forces canonicalization (the alias rewrite in `SamplePersister`) and
  re-pricing (`costRecomputeVersion`) to become read-time views instead of
  table rewrites. That's better than mutating truth in place, which is what we
  do today.
- **Dedup must not depend on a hot-window length.** Measured across 1,697
  transcripts: 12% of keys are replayed across files, reach-back p50 0.05 d,
  p99 6.07 d, max 7.15 d. A 30-day window covers 100% — but `--resume` can
  target an arbitrarily old session, so build the dedup set from the archive's
  dedup column at startup instead of betting on a window. Store 64-bit hashes,
  not 57-character strings: `seenDedupKeys` is ~20 MB today and would be
  ~300 MB at five years.

## chDB / ClickHouse: evaluated, rejected

macOS arm64 `libchdb` is **82.6 MB compressed** (176 MB static) against a
28 MB app — roughly an order of magnitude worse than DuckDB for no measurable
gain at this scale. MergeTree's background merge threads also fight the ~0%
idle CPU. ClickHouse would be the right call only if Pacer ever grows a
server-side component.
