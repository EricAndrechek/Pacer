# Performance tuning — where we landed and what's left

A fresh agent picking up perf work in Pacer should read this first, then
`AGENTS.md` → "Performance — invariants and patterns" for the timeless
rules. Live ops state (cycle stats, current bottlenecks) is in
`~/Library/Logs/Pacer/perf-loop-state.md`; that file is overwritten by
later overnight loops, so don't put durable knowledge there.

## TL;DR — current state

- **Physical footprint ≈ 200 MB idle** (was 646 MB before 2026-08-04).
- **Startup `prep` ≈ 40 ms** on a 190k-row store (was 12.5 s). The dedup map
  is persisted beside the store (`DedupIndex`) instead of rebuilt by walking
  every row. See "Memory and startup (2026-08-04)".
- **Cold start ≈ 41 s** for a first launch over a 1,697-file history (was
  75 s).
- **p50 scan cycle ≈ 100 ms** (was 1500 ms at start of the 2026-05 work).
- **Idle CPU ≈ 0 %** with brief spikes during actual scan cycles (was
  105 % sustained).
- **Backstop full walks** during idle: ≤ 1 per 30 min (was 30+).
- **Remaining variance**: p90 ≈ 1100 ms on FSEvents-hinted insert cycles.
  Confirmed cause is MainActor-resume latency after `await scanner.scan`
  while the previous cycle's save is still propagating `@Query`
  refreshes. Fixing this needs the scan loop off MainActor — see
  "Open work" below.

## How to investigate

1. **Phase-timed log lines.** Every `[ScanCoordinator] scan: ...` line in
   `~/Library/Logs/Pacer/Pacer.err.log` ends with a bracketed phase
   tail:
   ```
   [autoA=N prep=N mig=N consume=N scan=N flush=N curs=N
    dailyR=N hourR=N projR=N sessR=N probe=N save=N notif=N]
   ```
   Read left-to-right through the cycle. `fast=N/M` shows how many
   dirty pairs took the daily recomputer's incremental fast path vs
   full recompute — large gaps signal pollution (recovery /
   cost-version bump / migration).
2. **`make perf-snapshot`.** One-shot CLI: 10 s `sample(1)` CPU
   profile, 5× `top` snapshots, last 500 log lines distilled into
   P50/P90/P99 + per-phase median, sqlite row counts. Output:
   `~/Library/Logs/Pacer/perf-snapshots/<ts>/summary.txt`. Skip the
   GUI; this answers "is something hot, and where" without it.
3. **Raw `sample(1)`** when phase data doesn't pinpoint:
   `sample $(pgrep -f '/Pacer\.app/Contents/MacOS/Pacer') 10 -file /tmp/p.txt`,
   then grep for `_layoutSubtreeIfNeeded`, `cacheDisplayInRect`,
   `_updateReplicants`, `_scalableMinSize` — those are the AppKit hot
   paths the SwiftUI animations hit when they're misconfigured.

## What got fixed (chronological)

Each commit is self-contained and documented in its own message. Listed
here so a fresh agent can grep `git log -p <hash>` for the diff and the
prose rationale together.

| # | Hash | Mechanism | Measured win |
|---|------|-----------|--------------|
| 1 | `a65b5ca` | `PhaseTimings` + `bin/dev-perf-snapshot.sh` | (tooling) |
| 2 | `f7f0fe5` | Daily/hourly/project recomputers: delta-apply fast path when (pair has pending samples) AND (not polluted) AND (existing row found). Tracked via `pendingPairSamples` / `pollutedDailyPairs` etc. in `SamplePersister`. | dailyR 419 ms→1 ms, hourR 411 ms→0 ms, projR 281 ms→0 ms |
| 3 | `0730115` | FSEvents-targeted scan (scanner gets a `hintedPaths` set, stats just those instead of walking ~900 files) + sync emit (entries buffered in lock-protected `InsertSink`, one MainActor flush at end instead of N hops) + `SampleCostCache` reads (recomputers stop awaiting `PricingTable.shared`) | scan phase 340 ms→2-5 ms on hinted cycles; consume= phase 143 ms→0 ms |
| 4 | `5b35aed` | Watcher `recordChangedPathsAndCoalesce` only fires `coalesceTrigger()` if a `.jsonl` path was in the FSEvent batch | breaks the @Query-refresh-storm feedback loop |
| 5 | `3eb927a` | Auto-aliaser throttled to 60 s + skipped when distinct-project-path set is unchanged | autoA 1200 ms spikes → ≤ 30 ms |
| 6 | `3d6e94b` | Removed `ActivityDot` `.repeatForever(autoreverses: true)` opacity+scale pulse | **CPU 105 %→25 %** |
| 7 | `92d6d32` | Removed `FreshnessPulse` `TimelineView(.animation(12fps))` halo from the toolbar | **CPU 25 %→15 %** |
| 8 | `e531904` | Session recomputer fast path (mirrors #2, with same-`topModel` guard for the per-model token leader) | sessR 290 ms→0 ms |
| 9 | `109bdb1` | Backstop skips its emit when an `.jsonl` FSEvent fired within `liveBackstopSeconds`; safety net forces a fire after 9 consecutive skips | drops full walks during active typing |
| 10 | `edc6916` | `flushPending` checks `changedPaths.isEmpty` before yielding — races between in-flight scans draining the set and pending coalesces were producing ~30 spurious `files=0 skipped=915` full walks per 12 min | removed that whole class of cycles |
| 11 | `8c85baa` | FSEvents coalesce window 0.5 s → 2.0 s | bundles a typical assistant turn's 3-8 writes into 1 scan+save |
| 12 | `6cf0cea` | `JSONLFileCursor` cached in memory (`cursorsCache`); `saveCursors` does per-path predicate fetch instead of full-table fetch | prep 100 ms→6 ms, curs 60 ms→0 ms |
| 13 | `22742bb` | `StatsCacheProbe` throttled to 60 s | probe 30-278 ms→0 ms between runs |
| 14 | `fddc31a` | `visibleBackstop` 60 s → 300 s | ~70 % of idle-window cycles eliminated |
| 15 | `ba2abe1` | One-shot stale-cursor prune at startup | 1072→931 cursors, perm reduction |

Plus a `bin/dev-install.sh` `PACER_DEV_SKIP_NOTARIZE=1` escape hatch
when the notarytool keychain profile is missing (the user's
`pacer-notarization` profile was lost mid-session; restore with
`xcrun notarytool store-credentials pacer-notarization …`).

## Anti-patterns this session uncovered

These all hid behind seemingly-benign SwiftUI/SwiftData APIs. The
mechanisms are subtle enough that grep won't catch them in review.

1. **`.repeatForever` animations in views hosted by `NSStatusItem`.**
   Each frame triggers SwiftUI body re-eval → NSHostingView signals
   change → NSStatusItem `_updateReplicants` → `cacheDisplayInRect`
   rasterizes the whole status item to a bitmap at 60 Hz. Use a static
   indicator + state changes via discrete `withAnimation` instead.
2. **`TimelineView(.animation)` inside `NSToolbarItem` subviews.**
   Even with a fixed external frame, each tick rebuilds the SwiftUI
   tree → NSHostingView size-change signal → `NSToolbarItem _scalableMinSize`
   → AutoLayout pass on the whole toolbar item chain. If you must
   animate in a toolbar item, drive it from a `CALayer` directly so
   it bypasses SwiftUI's per-frame re-eval.
   **Same cost, different trigger (2026-06-23):** a toolbar-hosted view
   bound to `@Query` (the `ToolbarFreshness` "● live / 3m ago" pill) pays
   the identical recursive `NSToolbarView` → `NSToolbarItemViewer` relayout
   on *every store save*, even when the displayed value is unchanged —
   `@Query` refreshes on each save and re-renders the hosted `NSView`.
   Remedy: funnel the render through a small `Equatable` snapshot struct
   and wrap the pill in `.equatable()` (`EquatableView`). The outer view
   still re-evaluates (cheap: fetchLimit-1 probes), but the AppKit relayout
   only fires when the snapshot actually changes. Measured: across 3 saves,
   pill re-renders 10→0, `NSToolbarItemViewer` relayouts ~14/90s→~5/150s.
3. **Per-cycle `FetchDescriptor<X>()` with no predicate.** Even with
   `propertiesToFetch` slimming, materializing a 1000-row table per
   cycle costs 70-150 ms under MainActor contention. Cache the dict
   in memory, write-through on updates.
4. **`await pricingTable.snapshot()` per recomputer.** Actor hop to an
   actor that's contended with MainActor is ~150 ms. Use the
   process-wide `SampleCostCache.current()` (Sendable snapshot,
   nonisolated) on the hot path.
5. **Yielding from a coalesce timer without checking the buffer.**
   Race: an in-flight scan drains paths between record and flush →
   yielded trigger arrives with an empty buffer → full walk over
   ~900 files for nothing. Guard with `guard !changedPaths.isEmpty`.
6. **Reading sanity-check probes per cycle.** `StatsCacheProbe`,
   auto-aliaser candidate walks, etc. don't need cycle-rate freshness;
   throttle to ≥60 s.
7. **60 s backstop walks during quiet idle.** macOS FSEvents is
   reliable enough that 5-min safety-net cadence is sufficient. The
   600 ms cost of a 900-file walk per minute, times 24/7, is exactly
   the kind of always-on CPU that puts a menu-bar app in the top-10.
8. **`LazyVStack` of heavy chart cards in a `ScrollView` (2026-06-25).**
   The lazy stack defers each card's body + `@Query` until it scrolls
   on-screen — good for the notification budget, but it realizes the
   card *mid-scroll*, so scrolling past a chart card builds its whole
   Swift Charts body right then. A `sample(1)` taken WHILE scrolling
   (the only way to catch this — an idle sample shows nothing) had the
   main thread 74→99 % idle yet still dropped frames: the cost was
   `ViewRendererHost`/`GraphHost` on the render thread, near-zero
   `CA::Transaction::commit`, i.e. SwiftUI re-rendering cards as they
   appeared, not compositing. Fix: eager `VStack` for pages with a
   small fixed card set (a `lazy: Bool` flag on `PageScaffold`;
   dashboard passes `lazy: false`). Re-incurs the `@Query` fanout, but
   measured ~98 % main-thread idle during active use after the #102/#104/
   #105 mitigations, so affordable. Lesson: **scroll jank with an idle
   main thread is render/realize cost — profile WHILE scrolling.**
9. **`await`ing an uncontended `@ModelActor` from `@MainActor` runs its
   work INLINE on main (2026-06-25).** Swift skips the executor hop for
   an idle actor and resumes the job on the caller's thread — so the
   forecast engine's `DiurnalBurnModel.fit` ran on the main thread
   (confirmed: no `swift_task_switch` frame between caller and fit; all
   133 fit frames in the Main-Thread block). `@ModelActor` is not
   enough; its default executor permits inline-on-main. Fix: wrap the
   engine call sites (`PaceChartCard.refreshProjections`,
   `AppBackgroundService.recomputeEngineIfDue`/`exportEngineSnapshot`)
   in `Task.detached { [engine] in await engine.… }.value` so the await
   genuinely hops off the main actor. (A dedicated `unownedExecutor` on
   the engine would fix every call site at once — deferred.)

## Memory and startup (2026-08-04)

Three fixes, and — more useful than the fixes — three hypotheses that were
wrong. Every one was plausible, and none survived measurement. **Profile
first here; this area punishes reasoning.**

### What was actually wrong

1. **The whole sample table was live in memory at idle.** 189,183
   `TokenSample` objects, plus ~890 bytes of SwiftData bookkeeping *each*
   (backing data, `_ModelMetadata`, a property-snapshot array, an
   observation registrar, a weak-ref slot) and 1.2M `CFString`s.
   `preloadFromStore` walks every row to build the dedup map — all plain
   values — but fetched through the persister's long-lived context, which
   registers every object permanently. Fetching through a **scratch
   `ModelContext`** frees them: footprint 646 MB → 199 MB, malloc'd nodes
   3.17M → 721k.
2. **Whole-table walks materialized everything at once.** `enumerate(batchSize:)`
   drains each chunk before pulling the next: startup `prep` 12.5 s → 9.0 s.
   Applied to all three walks — `preloadFromStore`, `markEverySampleDirty`
   (every cost-recompute bump), `canonicalizeProjectPaths` (every alias
   change).
3. **Per-item fetches on bulk paths** — see the invariant in AGENTS.md.

### The three wrong guesses

| guess | reality |
|---|---|
| hourly rollup is slow from `Calendar.component(.hour:)` | **13.3 ms** for all 54,046 rows; offset arithmetic saves 9 ms, for DST risk |
| idle memory is the dedup-key strings | it was the retained objects |
| idle memory is the `sampleByKey` map | removing it moved peak RSS 751 → 714 MB |

### How to measure this properly

`heap <pid>` gives a class-by-class breakdown and "Physical footprint",
which is what to quote — RSS lags because macOS doesn't return freed pages
promptly. Watch the count of `_ContiguousArrayStorage<Optional<Any>>` and
`_ModelMetadata`: those track live SwiftData objects one-for-one, so they
tell you instantly whether something is pinning a table.

`PACER_COLD_START_PROBE=1` (with `CLAUDE_CONFIG_DIR` pointed at a frozen
transcript copy) reports phase timings plus all six per-field token totals.
The startup log line `[SamplePersister] preload: N rows — walk Xms · gaps Yms`
splits the `prep` phase permanently.

### How the walk was eliminated

Both options from the original list got taken, in order:

1. **Lazy** — the walk moved out of `init` into `ensurePreloaded()`, called by
   `insert(_:)`. Launches with nothing to ingest stopped paying (`ms=274`
   total). The integrity sets it also seeds aren't insert-driven, so
   `ScanCoordinator` forces a walk once a day (`lastIntegrityWalkAt`).
2. **Persisted** — `DedupIndex` writes the map beside the store, 24 bytes per
   turn (4.4 MB here), loaded in milliseconds. That covered the remaining
   case, a launch that *does* ingest:

   ```
   before   prep 9,293 ms   walk 190,296 rows
   after    prep    42 ms   "dedup index: 190,067 entries + 0 newer"
   ```

The index caches the dedup guard, which is the most load-bearing correctness
rule here, so it is built to refuse itself: an exact `fetchCount` match or the
walk runs, and a 128-bit digest so a collision can't silently drop a turn.
Read `DedupIndex`'s header before changing any of it.

**It also caused a regression worth remembering.** Written on every cycle, it
re-emitted 4.4 MB to record one row — 90 ms per scan against a 33-80 ms
budget, pushing steady state to 178 ms. Throttled to 5 minutes with a forced
flush on shutdown; the watermark makes lagging safe. It surfaced as
"`curs=` got 90x slower" because the write lands inside that phase's timing
window. An optimisation that MOVES work rather than removing it lands
somewhere — check the hot path afterwards.

### Still open here

Nothing large. The hourly rollup emits 1,470 rows to daily's 184, which is
inherent to bucketing by hour, and `autoA` runs 37-57 ms on a live cycle.

## Open work (deferred from the autonomous loop)

**Queue #5 — ACHANGE / ATRANSACTION retention.** Core Data persistent
history tables. As of the end of the 2026-05 work: 380 K / 96 K rows,
growing ~810 / hour now (down from ~2 k / h pre-save-batching, but
unbounded long-term). `ModelConfiguration` doesn't expose the
persistent-history toggle directly. Approaches:
- Disable via `NSPersistentStoreDescription` options through a CoreData
  shim. SwiftData and CoreData coexist; the underlying coordinator can
  be configured. Risk: SwiftData `@Query` refresh may rely on history
  tracking internally.
- Periodic `NSPersistentHistoryChangeRequest.deleteHistory(before:)`
  from a maintenance pass. Same Core Data FFI requirement. Safer than
  disabling outright.

**Queue #6 — Move scan loop off MainActor. ✅ DONE (2026-06-20).** The
whole scan pipeline now runs on a custom serial global actor,
`@ScanActor` (`Coordination/ScanActor.swift`), instead of `@MainActor`:
`ScanCoordinator`, `SamplePersister`, all four per-pair recomputers,
`ProjectGitRootAutoAliaser`, and `StatsCacheProbe.probeAndStore`. The
main thread is now free during every cycle, so no scan cycle — however
slow — can stall scrolling. Measured: steady-state cycle dropped from
the ~300 ms–1.4 s MainActor-resume tail to ~21 ms wall-clock on the
background actor; the one-time ~7 s persister preload at launch also
moved off-main (it used to freeze the dashboard on open).

How it landed (vs. the original plan above):
- `ScanCoordinator`'s `ModelContext` was *already* a separate context
  from the views' `@Query` mainContext (it constructs
  `ModelContext(container)`), so cross-context propagation to `@Query`
  was already the live mechanism — the refactor only moved that
  context's executor to the background. `@Query` refresh topology is
  unchanged.
- The context is created lazily on first `@ScanActor` access (not in
  the now-`nonisolated` init) so it's born on the actor that uses it —
  `ModelContext` is thread-affine.
- `cursorsCache` and the other bare fields became `@ScanActor`-isolated
  actor state for free (no separate lock needed) since the whole class
  is on one serial executor.
- **Gotcha worth remembering:** `postScanCycleSummary` MUST run on
  `@MainActor` (its `queue: .main` observers, and any future no-queue
  observer, otherwise deliver on the scan thread). Posting it from the
  background actor measured `notif` phases up to ~16 s. It's now
  fire-and-forget onto main (`Task { @MainActor in … }`) so the cycle
  never blocks on main-thread availability for a refresh hint.

Remaining nit: the launch-time `prep` preload (~7 s: build the
dedup Set from every TokenSample + prune stale cursors) is one-time and
off-main, but could be chunked/yielded if it ever matters.

## The optimisation that made a cost wrong (2026-08-04)

The single most instructive bug of this whole effort, because it was
*caused* by a perf fix and hid behind an asymmetry.

**The optimisation.** Recomputers used to `await PricingTable.shared`
per cycle, costing ~150 ms per phase under MainActor contention. That
was replaced with `SampleCostCache.current()` — a process-wide snapshot,
sync, warmed once at launch. Correct reasoning, real win.

**The hole.** The cache's default value is empty, and an empty pricing
snapshot doesn't mean "unknown" to `CostCalculator` — it means **$0**.
The app warms it in an un-awaited `Task` at launch, which the first scan
cycle routinely beats. Any bucket recomputed in that window is written
with zero cost, and *a rollup cannot tell a real $0 from an unpriced
one*, so nothing ever recomputes it. The zero is permanent.

**Why it survived.** Only two of the four recomputers switched to the
cache for their from-scratch path; daily and hourly still read
`PricingTable` directly. So daily stayed right while project and session
went to zero, and no single number looked wrong on its own. Had all four
read the cache, they'd have agreed with each other and been silently
wrong together — undetectable by any cross-rollup check.

**How it was found.** Not by the app. `make verify-data` reported hourly
cost $0.70 under daily. Solving a price vector across the day's buckets
localised it to one frozen bucket; forcing a rebuild of the open buckets
then exposed the real bug as a **$663** project shortfall — the whole
`claude-fable-5` share of one day.

Three lessons, in order of how much they cost:

1. **Moving a value behind a cache moves its failure mode with it.**
   The hop was the cost; the *guarantee* that pricing was loaded before
   use was the thing quietly dropped.
2. **"Missing" must not render as a legal value.** $0 is a plausible
   cost. If unknown and zero are the same bits, nothing downstream can
   ever repair it.
3. **A partial migration is worse than either end state.** Two paths
   reading two pricing sources is what made this *detectable*, and is
   also what made it possible. The detectability was luck.

Fixed by awaiting pricing before any recompute, plus rebuilding still-open
buckets on a 10-minute throttle so drift can't freeze at the hour
boundary. `costRecomputeVersion` 5 → 6 clears zeros already written.

## Known correctness items

- `sessionRecomputerRollsUpPerSession` test fails on `main` (asserts
  `b.totalTokens == 3` but gets 2). Pre-dates this session's work.
  Likely a `cacheReadTokens` accounting mismatch in `SessionInfo.totalTokens`
  vs the test's expectation. Not blocking — every CI run already had it
  failing before this session.
- TERNARY-IN SwiftData crash spotted once in stderr early in the
  session (`projectPath IN {~50 paths}`) was investigated and traced
  to a **pre-existing** regression test that confirms the crash is
  prevented in current code via per-source iteration in
  `SamplePersister.canonicalizeAffectedSamples`. The crash I observed
  was from an older build still running before my install caught up.

## When to revisit

If `make perf-snapshot` ever shows p50 cycle > 200 ms or p90 > 2000 ms
or `Pacer` consistently > 30 % CPU in `top`, walk the phase tail in
`Pacer.err.log` — the dominant phase will name itself.

If a new SwiftUI view is added that binds to a hot model (TokenSample,
DailyAggregate, RateLimitSample), check it against AGENTS.md
"Performance — invariants and patterns" before reviewing other things.
The `@Query` refresh fanout is now Pacer's biggest remaining
sensitivity surface.
