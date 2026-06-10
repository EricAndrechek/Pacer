# Storage visibility + DuckDB vs SQLite

> Status: **research queued, not started.** Two parts: (1) a small
> in-app feature surfacing how much disk the data uses, and (2) a
> research question — would DuckDB save meaningful at-rest space or query
> time vs SQLite (the SwiftData backing store), especially under a future
> Rust/Go core. Part 2 is curiosity-driven; don't let it block anything.

## Baseline measurements (this machine, 2026-06-10)

Real numbers to anchor the research — captured with `du` / `find`:

| What | Size | Notes |
|---|---|---|
| **Claude Code JSONL logs** (`~/.claude/projects`) | **1.1 GB** | 1,143 `*.jsonl` files; ~1.115 GB raw bytes. This is the *source* data Pacer parses — Pacer doesn't own it and shouldn't delete it, but it's the dominant footprint and users will want to see it. |
| **Pacer SwiftData store** (active) | **~97 MB** | `Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite` (+3 MB WAL, 32 KB shm). The team-prefixed container — the signed app's. |
| **Pacer SwiftData store** (other) | 17 MB | `Library/Group Containers/group.com.ericandrechek.pacer/pacer.sqlite` (+2 MB WAL). ⚠️ **Investigate** — a second container exists. Likely a dev/unsigned/`.standard`-fallback store from earlier builds. Confirm which one `PacerStore.appGroupIdentifier` actually opens; the visibility feature must report the live one, and we may have an orphaned ~17 MB store to clean up. |
| **Pacer logs** (`~/Library/Logs/Pacer`) | 28 MB | stderr redirect from the in-process service. Already rotatable. |

**Key ratio:** Pacer's *derived* store (~97 MB) is ~9% of the raw JSONL
(1.1 GB). The derived store is row-oriented SwiftData (`TokenSample` +
`RateLimitSample` + hourly/daily/project aggregates). The OAuth poller
alone adds ~2 `RateLimitSample` rows / 5 min ≈ 200k rows/year (see the
note in `RateLimitSample.swift`).

## Part 1 — in-app storage visibility (the feature)

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
