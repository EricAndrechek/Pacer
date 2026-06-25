# Performance tuning — where we landed and what's left

A fresh agent picking up perf work in Pacer should read this first, then
`AGENTS.md` → "Performance — invariants and patterns" for the timeless
rules. Live ops state (cycle stats, current bottlenecks) is in
`~/Library/Logs/Pacer/perf-loop-state.md`; that file is overwritten by
later overnight loops, so don't put durable knowledge there.

## TL;DR — current state

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
