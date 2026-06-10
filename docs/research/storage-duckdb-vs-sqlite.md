# Storage visibility + DuckDB vs SQLite

> Status: **Part 1 (in-app storage visibility) shipped** — a "Storage"
> card in Settings → Data, backed by `StorageInspector` in PacerCore.
> **Part 2 (DuckDB vs SQLite) benchmarked — verdict: not worth adopting
> now.** ~8.5× smaller at rest but loses on the point-lookups Pacer's UI
> leans on and ties on analytics at current scale. The bigger, no-new-
> dependency win is reclaiming the ~30 MB of unused Core Data history.

## Baseline measurements (this machine, 2026-06-10)

Real numbers to anchor the research — captured with `du` / `find`:

| What | Size | Notes |
|---|---|---|
| **Claude Code JSONL logs** (`~/.claude/projects`) | **1.1 GB** | 1,143 `*.jsonl` files; ~1.115 GB raw bytes. This is the *source* data Pacer parses — Pacer doesn't own it and shouldn't delete it, but it's the dominant footprint and users will want to see it. |
| **Pacer SwiftData store** (active) | **~97 MB** | `Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite` (+3 MB WAL, 32 KB shm). The team-prefixed container — the signed app's. |
| **Pacer SwiftData store** (legacy) | 17 MB | `Library/Group Containers/group.com.ericandrechek.pacer/pacer.sqlite` (+2 MB WAL). The pre-rename `group.`-prefixed container documented in `PacerStore.swift` (`legacyAppGroupIdentifier`) — `bin/dev-install.sh` migrates *from* it. Not the live store; the in-app Storage card reports the live TeamID-prefixed one via `PacerStore.storeURL()`. Safe to delete once you've confirmed your data is in the live container (it is). |
| **Pacer logs** (`~/Library/Logs/Pacer`) | 28 MB | stderr redirect from the in-process service. Already rotatable. |

**Key ratio:** Pacer's *derived* store (~97 MB) is ~9% of the raw JSONL
(1.1 GB). The derived store is row-oriented SwiftData (`TokenSample` +
`RateLimitSample` + hourly/daily/project aggregates). The OAuth poller
alone adds ~2 `RateLimitSample` rows / 5 min ≈ 200k rows/year (see the
note in `RateLimitSample.swift`).

## Part 1 — in-app storage visibility (the feature) ✅ shipped

**Shipped:** a "Storage" card in Settings → Data showing Pacer database
(sqlite + WAL + shm), Pacer logs, and Claude Code logs (bytes + file
count). Backed by `PacerCore/.../Stats/StorageInspector.swift` (pure,
allocated-size measurement, unit-tested) + a `pacerBytes` formatter;
measured off-main on appear. Row counts (below) were left out of v1 —
add later if "what's in here" proves useful. Original plan, for the
record:

Surface, somewhere unobtrusive (Settings → Data, or the existing
Help/"Show Database in Finder" area):

- **Pacer's own footprint**: live store + WAL + shm + logs, via
  `PacerStore.storeURL()` and the logs dir. Cheap: `FileManager`
  `resourceValues(forKeys: [.fileSizeKey])` (or `.totalFileAllocatedSize`).
- **Claude Code's JSONL footprint**: sum of `*.jsonl` under the resolved
  Claude projects dir (`ClaudePathResolver`). Optionally per-project, to
  reuse in the Projects tab.
- Row counts per model (`TokenSample`, `RateLimitSample`, aggregates) for
  a "what's in here" breakdown.

Watch-outs: must stay off the main thread (1 GB tree walk), cache the
result, and never touch/delete Claude's data. Reuse the compact/exact
formatter pattern (`pacerBytes`? — add one) per `docs/ux-backlog.md`.

## Part 2 — DuckDB vs SQLite (the research question)

### First findings — where the 94 MB actually goes (2026-06-10, sqlite side)

Before touching DuckDB, broke the live store down with `dbstat` +
`COUNT(*)`. This reframed the whole question. Total **94.2 MB / 22,995
pages**:

| Segment | Size | Notes |
|---|---|---|
| `ZTOKENSAMPLE` (data) | **32.7 MB** | 104,300 rows — the actual usage samples. |
| Indexes on TokenSample | **~25 MB** | dedupKey 7.7 + projectPath 6.5 + sessionId 5.2 + datemodel 3.9 + sampledAt 1.8. ~76% of the data size, in indexes. |
| **Core Data history** (`ACHANGE` + `ATRANSACTION` + their indexes) | **~30 MB** | `ACHANGE` 13.5, `ACHANGE_ZTRANSACTIONID_INDEX` 7.3, `ATRANSACTION` 4.0 + ~6.7 of transaction indexes. |
| `ZRATELIMITSAMPLE` + aggregates | small | 13,732 rate-limit rows; 759 hourly / 98 daily / 153 project-daily aggregate rows. |

**The headline: ~⅓ of the store (~30 MB) is SwiftData/Core Data
persistent-history change-tracking, not user data.** That's a concrete,
*no-new-dependency* win that outranks anything DuckDB would buy:

1. **Prune persistent history.** Core Data's `NSPersistentHistoryToken`
   transaction log (`ATRANSACTION`/`ACHANGE`) accrues because SwiftData
   turns history tracking **on by default** for a SQLite store (the
   container uses a plain `ModelConfiguration(url:)` — no opt-out).
   **Confirmed: nothing in the codebase reads it** — a grep for any
   `PersistentHistory` / `historyToken` API is empty, and widgets refresh
   off the explicit `pacerScanCycleDidComplete` notification, not history
   tokens. So it's pure dead weight that grows with every write. Fix: a
   periodic `ModelContext.deleteHistory(before: now − N days)` maintenance
   pass (SwiftData macOS 15 API) to cap it; optionally a one-time VACUUM
   to actually shrink the file on disk (frees pages otherwise just get
   reused). Delete only *old* history so SwiftData's own cross-context
   `@Query` catch-up isn't disturbed. This is the first thing to chase.
2. **Audit the 5 TokenSample indexes (~25 MB).** Each maps to a hot
   predicate (see `RateLimitSample.swift`/`TokenSample.swift` index
   docs), but at ~25 MB for ~33 MB of data it's worth confirming all
   five still earn their keep, especially `dedupKey` (7.7 MB).

These two together could roughly halve the store with zero columnar
rewrite — and they're worth doing regardless of the DuckDB question.

### DuckDB benchmark results (2026-06-10)

Ran it for real: loaded the live `ZTOKENSAMPLE` (104,349 rows) into a
native DuckDB table via the `sqlite` extension and compared.

**At-rest size — DuckDB wins big (~8.5×):**

| | Size |
|---|---|
| SQLite `ZTOKENSAMPLE`: data 33 MB + indexes 25 MB | **~58 MB** |
| DuckDB native table | **6.8 MB** |

Driver: the data is tiny-cardinality — **6 distinct models, 27 projects,
412 sessions** across 104k rows — so columnar dictionary encoding stores
each repeated string (model / projectPath / sessionId) once instead of
per-row, and needs no 25 MB of B-tree indexes.

**Query time — a tie, or a loss, at this scale:**

| Query | SQLite | DuckDB |
|---|---|---|
| Analytical rollup (per date×model, full scan) | <1 ms | <1 ms |
| Point lookup "latest 50 samples" (Pacer's hot path) | ~1 ms (indexed) | ~4–12 ms (full scan, no index) |

At 104k rows both are instant on the rollup — DuckDB's vectorized-scan
edge only matters in the millions. And on the latest-N point lookups
Pacer's UI does constantly, SQLite's index *beats* DuckDB.

**Verdict:** DuckDB is a real ~8× *storage* win but a *mixed* query
story — it would slow the hot path and only ties on analytics at today's
scale. Not worth swapping the backing store (and SwiftData makes it
impractical without the Rust/Go core anyway). Reconsider only as a future
*analytics sidecar* if history grows into the millions of rows. The
~30 MB Core Data history reclaim (above) returns more, with no new
dependency and no hot-path risk — do that instead.

### Frame it honestly

SQLite (via SwiftData) is doing fine today: ~97 MB, and perf was already
tuned hard (`docs/perf-tuning.md`, p50 1500ms→103ms) with indexes on the
hot `RateLimitSample` / aggregate predicates. So this is **not** a
"we have a problem" investigation — it's "is there a better fit if/when
we move to a Rust/Go core, and would columnar storage shrink the
at-rest size or speed up the analytical scans (heatmaps, 6-month
history, per-model rollups)?"

### What to actually measure

1. **At-rest size.** Load the same `TokenSample`/aggregate data into a
   DuckDB file and compare on-disk size. DuckDB is columnar with
   per-column compression (dictionary/RLE/FSST) — for highly repetitive
   columns (model name, project path, date strings, source) it should
   compress *dramatically* better than SQLite's row pages. Hypothesis:
   the 97 MB store could be a small fraction of that in DuckDB. **Verify.**
2. **Query time.** Benchmark the genuinely analytical reads — the
   6-month heatmap, monthly rollups, per-model/-project aggregation over
   the full history — SQLite-with-indexes vs DuckDB. DuckDB wins big on
   full-scan aggregation; SQLite wins on tiny indexed point lookups
   (the "latest N samples" hot path). Pacer does both, so the answer is
   probably "mixed," which matters for the recommendation.
3. **Write path.** Pacer writes small batches frequently (scan cycles,
   5-min poll). DuckDB is optimized for bulk/append, not many tiny
   transactions — measure whether the frequent-small-write pattern is a
   problem or whether an append-only + periodic-compaction design fits.

### Open questions to resolve before any adoption

- **Swift/embedding story.** SwiftData is native; DuckDB would be a C/C++
  library via a C API (no first-class Swift binding — confirm current
  state). Under a **Rust/Go core** (the TODO that makes this interesting)
  the binding story is much better: `duckdb-rs` / Go `go-duckdb` are
  mature. So this question is really coupled to the
  multi-platform-core TODO — evaluate them together, not in isolation.
- **Migration / dual-write.** SwiftData owns the schema + the reactive
  `@Query` UI today. A DuckDB move means either (a) DuckDB as an
  *analytics sidecar* (SwiftData stays the system of record, DuckDB is a
  derived read-optimized copy for heavy scans) or (b) a full backing-store
  swap (large, ties into the Rust/Go core). (a) is the low-risk
  experiment; (b) is the strategic bet.
- **Does the win clear the bar?** At 97 MB, even a 10× at-rest reduction
  saves ~87 MB — nice but not user-visible-painful. The query-time win on
  history/heatmap views is the more likely real payoff. Decide what
  result would actually justify the dependency.

### Suggested first step (cheap, decisive)

Export the current `TokenSample` + aggregates to Parquet/CSV, load into a
standalone DuckDB file, and just **measure size + run the heatmap/rollup
queries both ways**. One afternoon, real numbers, no app changes. That
result (plus the Rust/Go-core timing) decides whether this is worth more
than a curiosity.

## Related

- `docs/perf-tuning.md` — why SQLite is already fast enough today.
- The "multi-platform Rust/Go core" TODO — the context that makes DuckDB
  actually attractive; evaluate jointly.
- `memory/project_overnight_perf_loop.md`.
