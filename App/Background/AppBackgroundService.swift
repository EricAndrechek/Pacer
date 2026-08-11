import Foundation
import SwiftData
import PacerCore
import PacerUI

/// In-process background data collector. Runs `ScanCoordinator`
/// (FSEvents-driven JSONL scan + OAuth polling + SwiftData
/// persistence) inside the app process.
///
/// Why this lives in `App/` and not `PacerCore/`: it's the
/// orchestration glue that wires `ScanCoordinator` into the AppKit
/// lifecycle. `PacerCore` stays host-agnostic so tests can drive it
/// without AppKit.
///
/// Idempotent — `start()` after a successful start is a no-op.
/// Termination goes through `stop()` from `applicationShouldTerminate`
/// so the watcher and OAuth poller wind down cleanly before the
/// process exits.
@MainActor
final class AppBackgroundService {

    private let container: ModelContainer
    private var coordinator: ScanCoordinator?
    private var coordinatorTask: Task<Void, Error>?
    /// NotificationCenter observer for `.pacerRequestImmediateScan`.
    /// UI surfaces (e.g. the bulk-merge sheet) post this when they
    /// commit changes the user expects to see reflected immediately;
    /// we relay to `ScanCoordinator.runOnce()` so the user doesn't
    /// have to wait up to a backstop interval for the next cycle.
    private var immediateScanObserver: NSObjectProtocol?
    /// Observer for `.pacerScanCycleDidComplete`. When a cycle reports
    /// fresh rate-limit rows, we run `GlobalRateLimitReset.detect` over
    /// the recent OAuth history and dispatch an early-reset banner if it
    /// fires. Lives here — in the process-lived background service —
    /// rather than in `NotificationsHost` (which only exists while the
    /// dashboard window is open) so this notification works headless:
    /// the whole point is to tell the user limits reset early while they
    /// weren't looking.
    private var globalResetObserver: NSObjectProtocol?
    /// The on-device usage-intelligence engine. Owns its own `ModelContext`,
    /// rebuilds the per-user feature representation and refits its models on
    /// each scan tick, and answers the typed `EngineQuestion` → `Estimate`
    /// contract views call. Created in `init` (not `start`) so it's non-nil by
    /// the time the SwiftUI scene captures it for the environment, and warmed
    /// headless so a view that opens later gets an already-fitted engine. It
    /// shares the one container the rest of the process uses.
    let engine: UsageIntelligenceEngine
    /// Observer for `.pacerScanCycleDidComplete` that drives `engine.recompute`.
    private var engineRecomputeObserver: NSObjectProtocol?
    /// Coalesce engine recomputes — the JSONL scan path posts `samplesChanged`
    /// many times a minute, and refitting is cheap but not free, so we refit at
    /// most this often. The next scan after the interval picks up everything
    /// missed in between (the engine reads the whole store, not a delta).
    /// Floor between refits when RATE-LIMIT data changed — the input the
    /// forecast is actually about.
    ///
    /// Set against what the refit COSTS, not against how often the data moves:
    /// ~4.5 s of heavy statistical work, so a 60 s floor is still a 7% duty
    /// cycle forever. Adaptive OAuth polling lands new rate-limit rows far more
    /// often than the five minutes originally assumed, so the floor has to do
    /// the limiting. The forecast is hourly-granularity — a fit up to five
    /// minutes old says the same thing as a fresh one.
    private static let engineRecomputeMinInterval: TimeInterval = 300

    /// Floor between refits driven only by new TOKEN samples.
    ///
    /// A refit costs ~4.5 s of heavy statistical work — diurnal fit, regime
    /// profiles, conformal calibrators, self-eval — and token samples arrive
    /// continuously while Claude Code is in use. At the old 20 s floor that is
    /// a **23% duty cycle, forever**, to recompute answers that change on the
    /// scale of hours. The forecast is hourly-granularity; refitting it three
    /// times a minute produced the same numbers at the cost of a core.
    private static let engineRecomputeIdleInterval: TimeInterval = 600
    private var engineRefitCount = 0
    private var engineRefitTotalMs = 0
    private var lastEngineRecomputeAt: Date?
    /// Consecutive engine refits that projected a pre-reset cap hit, per
    /// window — the burn warning's debounce counter.
    private var burnHitStreak: [String: Int] = [:]
    /// Bridges `pacerScanCycleDidComplete` notifications to per-kind
    /// `WidgetCenter.reloadTimelines` calls so the WidgetKit extension
    /// — which can't observe SwiftData — refreshes when new data
    /// lands. Without this, Notification Center widgets only refresh
    /// on their own internal timeline policy, gated by WidgetKit's
    /// budget, which can leave them tens of minutes stale.
    private let widgetRefreshCoordinator = WidgetRefreshCoordinator()
    /// Background task that periodically refreshes the LiteLLM pricing
    /// snapshot. Independent of the scan loop because its cadence (24h)
    /// is two orders of magnitude longer than scan cycles (5–60s) and
    /// entangling them would make the scan path responsible for
    /// network/CDN fallibility.
    private var pricingRefreshTask: Task<Void, Never>?
    /// Gentle backstop that trims unused SwiftData persistent history so
    /// the `ATRANSACTION`/`ACHANGE` log can't grow unbounded over years.
    /// Deliberately infrequent (weekly) with a generous 30-day retention
    /// — the data is small, so this is housekeeping, not management.
    private var historyPruneTask: Task<Void, Never>?
    /// Opt-in local HTTP server (JSON snapshot + Prometheus + SSE) for
    /// third-party integrations. Created here, owned for the process lifetime;
    /// `applyAPIServerConfig()` starts/stops it per the user's preference.
    private let httpServer = PacerHTTPServer()
    /// Observer for `.pacerAPIServerSettingsChanged` — re-applies the server
    /// config when the Settings UI toggles it or edits port/host/token.
    private var apiSettingsObserver: NSObjectProtocol?

    init(container: ModelContainer) {
        self.container = container
        self.engine = UsageIntelligenceEngine(modelContainer: container)
    }

    func start() {
        guard coordinator == nil else { return }

        let costMode = PacerPreferences.costMode()
        Log.write("AppBackground", "starting; cost mode: \(costMode)")

        // No Keychain prompt on first poll: `KeychainOAuth` shells to
        // `/usr/bin/security` (an Apple-signed binary already trusted
        // by `apple-tool:` partition membership), so reads complete
        // silently from the very first launch. See the type doc in
        // `KeychainOAuth.swift` for the partition-list rationale.
        // Persist the resolved token in Pacer's own keychain item so we read
        // Claude's stores only ~once per token lifetime and keep working if
        // the user logs out of Claude Code / removes Desktop. Tests and
        // Settings probes use the default in-memory store (no real keychain).
        let oauthClient = OAuthClient(
            heldStore: KeychainCredentialStore(),
            desktopKeyStore: KeychainDesktopKeyStore()
        )
        let scanCoordinator = ScanCoordinator(
            container: container,
            configuration: ScanCoordinator.Configuration(
                costMode: costMode,
                // DuckDB-backed bulk parse, used on FULL scans only — a first
                // launch, or a `currentScanVersion` bump re-deriving history.
                // Injected rather than imported by PacerCore so the widget
                // extension never links the engine. Incremental cycles are
                // untouched. See `BulkTranscriptImporter`.
                bulkImporter: ArchiveImporter()),
            oauthClient: oauthClient,
            oauthPoolStore: KeychainTokenPoolStore()
        )
        coordinator = scanCoordinator

        // ScanCoordinator.runForever blocks; run it in a child task
        // so the AppKit run loop stays responsive. Errors are logged
        // and the coordinator is cleared so a future start() can
        // retry.
        coordinatorTask = Task { [weak self] in
            do {
                try await scanCoordinator.runForever()
                Log.write("AppBackground", "scan loop exited")
            } catch {
                Log.write("AppBackground", "scan loop failed: \(error)")
                await MainActor.run { self?.coordinator = nil }
                throw error
            }
        }

        installImmediateScanObserver()
        installGlobalResetObserver()
        installArchiveObserver()
        startEngine()
        widgetRefreshCoordinator.start()
        startPricingRefreshTask()
        startHistoryPruneTask()
        installAPISettingsObserver()
        applyAPIServerConfig()
    }

    func stop() async {
        guard coordinator != nil else { return }
        Log.write("AppBackground", "stopping")
        if let coord = coordinator {
            await coord.stop()
        }
        coordinatorTask?.cancel()
        coordinatorTask = nil
        coordinator = nil
        if let observer = immediateScanObserver {
            NotificationCenter.default.removeObserver(observer)
            immediateScanObserver = nil
        }
        if let observer = globalResetObserver {
            NotificationCenter.default.removeObserver(observer)
            globalResetObserver = nil
        }
        if let observer = engineRecomputeObserver {
            NotificationCenter.default.removeObserver(observer)
            engineRecomputeObserver = nil
        }
        lastEngineRecomputeAt = nil
        widgetRefreshCoordinator.stop()
        pricingRefreshTask?.cancel()
        pricingRefreshTask = nil
        historyPruneTask?.cancel()
        historyPruneTask = nil
        httpServer.stop()
        if let observer = apiSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
            apiSettingsObserver = nil
        }
    }

    // MARK: - Local API server

    /// Start or stop the HTTP server to match the current preference. Called on
    /// launch and whenever `.pacerAPIServerSettingsChanged` fires. The server
    /// itself is idempotent — `start` tears down any prior listener first.
    private func applyAPIServerConfig() {
        let cfg = PacerPreferences.apiServerConfig()
        guard cfg.enabled, let port = UInt16(exactly: cfg.port) else {
            httpServer.stop()
            return
        }
        httpServer.start(config: .init(host: cfg.bindHost, port: port, token: cfg.token))
    }

    private func installAPISettingsObserver() {
        apiSettingsObserver = NotificationCenter.default.addObserver(
            forName: .pacerAPIServerSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyAPIServerConfig() }
        }
    }

    // MARK: - Pricing refresh

    /// 24h cadence for the pricing JSON refresh. LiteLLM ships updates
    /// frequently but each one only affects costs of *future* samples
    /// — historical aggregates keep the cost that was current when they
    /// were computed. Faster cadence isn't worth the bandwidth.
    private static let pricingRefreshInterval: TimeInterval = 24 * 3600
    /// How long to wait after a refresh attempt that didn't produce a
    /// usable snapshot (network down, decode failure, empty result).
    /// One hour matches typical CDN outage recovery windows.
    private static let pricingRetryInterval: TimeInterval = 3600

    private func startPricingRefreshTask() {
        guard pricingRefreshTask == nil else { return }
        pricingRefreshTask = Task {
            // Re-check the cache age before every attempt — a previous
            // run of this task might have refreshed before launch and
            // a fresh launch shouldn't immediately re-fetch.
            while !Task.isCancelled {
                let age = PricingTable.cacheAge()
                let stale: Bool
                switch age {
                case .none: stale = true
                case .some(let a): stale = a >= Self.pricingRefreshInterval
                }

                var refreshed = false
                if stale {
                    let count = await PricingTable.shared.modelCount()
                    refreshed = await PricingTable.shared.refresh()
                    if refreshed {
                        await SampleCostCache.reload()
                        let after = await PricingTable.shared.modelCount()
                        Log.write(
                            "AppBackground",
                            "pricing refresh ok: \(count) → \(after) model(s)"
                        )
                        // Notify any view bound to the pricing snapshot
                        // (model breakdowns, per-model today) so it
                        // re-renders with the new prices for samples
                        // landing after this point. Existing aggregate
                        // rows keep the cost that was current when they
                        // were recomputed. Hop to main because most
                        // observers register on `.main` and posting off-
                        // main would deliver on the poster's queue.
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .pacerPricingDidRefresh,
                                object: nil
                            )
                        }
                    }
                }

                // Compute next-sleep based on whichever path we took:
                // - successful refresh → full 24h until the next cache
                //   age check would flag stale
                // - skipped (cache still fresh) → sleep the remaining
                //   time until 24h
                // - failed refresh → retry after 1h
                let delay: TimeInterval
                if stale && !refreshed {
                    delay = Self.pricingRetryInterval
                } else {
                    let nextAge = PricingTable.cacheAge() ?? 0
                    delay = max(60, Self.pricingRefreshInterval - nextAge)
                }
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - History prune

    /// Weekly cadence. With a 30-day retention window, pruning weekly
    /// means the log never holds more than ~37 days of history — plenty
    /// of headroom, and idle enough to read as housekeeping.
    private static let historyPruneInterval: TimeInterval = 7 * 24 * 3600

    /// Prune unused persistent history at launch, then weekly. Runs on
    /// the main actor (`StoreMaintenance.pruneHistory` is `@MainActor`);
    /// `deleteHistory` is a cheap metadata operation, so doing it inline
    /// on the first tick during launch is fine.
    private func startHistoryPruneTask() {
        guard historyPruneTask == nil else { return }
        let container = self.container
        historyPruneTask = Task { @MainActor in
            while !Task.isCancelled {
                StoreMaintenance.pruneHistory(container: container)
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.historyPruneInterval * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Immediate-scan trigger

    /// Observe `.pacerRequestImmediateScan` and run the alias-only
    /// fast-path migration. The notification is posted by UI
    /// actions (bulk-merge sheet, quick-merge dialog) where the
    /// user expects the change to land NOW but doesn't need a
    /// fresh JSONL parse — that costs seconds on a busy DB and
    /// would block the main thread.
    ///
    /// Multiple concurrent posts are safe: the fingerprint check
    /// inside `runAliasMigrationOnly` no-ops when nothing changed
    /// between posts.
    private func installImmediateScanObserver() {
        immediateScanObserver = NotificationCenter.default.addObserver(
            forName: .pacerRequestImmediateScan,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let coordinator = self.coordinator else { return }
                do {
                    Log.write("AppBackground", "alias migration requested")
                    _ = try await coordinator.runAliasMigrationOnly()
                } catch {
                    Log.write("AppBackground", "alias migration failed: \(error)")
                }
            }
        }
    }

    // MARK: - Global rate-limit reset detection

    /// How far back to fetch samples when checking for an early reset on
    /// a given window. We look across the *whole current cycle* (one
    /// window-duration + 1h slack) rather than a fixed short window: an
    /// early reset leaves the anchor unchanged, so the pre-reset high we
    /// compare against necessarily sits within one window-duration of
    /// now — and a reset that happened while the Mac was asleep/closed
    /// must still find that high on next launch. Bounded to the
    /// authoritative OAuth source (~12 rows/hour), so even the 7-day
    /// window is ~2k rows scanned once per ~5-min poll — trivial.
    private func globalResetLookback(forWindow window: String) -> TimeInterval {
        (PaceMath.windowDuration(for: window) ?? (72 * 3600)) + 3600
    }

    /// Observe scan-cycle completions and, when one carries fresh
    /// rate-limit rows, check whether Anthropic just reset limits early.
    /// Gated on `rateLimitsChanged` so the chatty JSONL scan path (which
    /// posts `samplesChanged` many times a minute) never triggers it.
    /// Mirrors new turns into the raw archive. Created lazily on the first
    /// cycle that reports samples, so an install with nothing to archive never
    /// pays for opening DuckDB.
    @ScanActor private var archiveSync: ArchiveSync?
    private var archiveObserver: NSObjectProtocol?

    /// Append new turns to the raw archive after any cycle that wrote samples.
    ///
    /// Deliberately its own observer rather than a step inside the scan: the
    /// archive is additive, nothing user-visible reads it, and a problem with
    /// it must never be able to slow or break the scan that feeds everything
    /// else. See `ArchiveSync`.
    /// One definition of where the archive lives, so a diagnostic can't end up
    /// pointed at a different file than the writer uses.
    static func archiveURL() -> URL {
        (try? PacerStore.sharedContainerURL())?
            .appendingPathComponent("raw-archive.duckdb")
            ?? URL(fileURLWithPath: "/dev/null")
    }

    private func installArchiveObserver() {
        guard (try? PacerStore.sharedContainerURL()) != nil else { return }
        let archiveURL = Self.archiveURL()
        archiveObserver = NotificationCenter.default.addObserver(
            forName: .pacerScanCycleDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let samplesChanged = (note.object as? ScanCycleSummary)?.samplesChanged ?? false
            guard samplesChanged else { return }
            Task { @ScanActor [weak self] in
                guard let self else { return }
                await self.syncArchive(archiveURL: archiveURL)
            }
        }
    }

    /// Created and used entirely on `ScanActor` — `ArchiveSync` owns a DuckDB
    /// connection, which is a C handle that must not cross actors.
    @ScanActor
    private func syncArchive(archiveURL: URL) {
        if archiveSync == nil {
            archiveSync = ArchiveSync(container: container, archiveURL: archiveURL)
        }
        archiveSync?.syncNewTurns()
    }

    private func installGlobalResetObserver() {
        globalResetObserver = NotificationCenter.default.addObserver(
            forName: .pacerScanCycleDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract the Sendable summary outside the Task — capturing
            // the whole Notification would carry its non-Sendable
            // userInfo across the actor hop.
            let rateLimitsChanged =
                (note.object as? ScanCycleSummary)?.rateLimitsChanged ?? false
            guard rateLimitsChanged else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.checkForGlobalReset()
                // Refresh the engine BEFORE the burn check so the warning
                // never reads a stale fit; the engine's own self-eval
                // recording happens inside recompute (idempotent).
                await self.recomputeEngineIfDue()
                await self.checkBurnRateWarning()
            }
        }
    }

    // MARK: - Intelligence engine

    /// Create the engine on the shared container and warm it once, then keep it
    /// fresh by recomputing (throttled) whenever a scan cycle reports new cost
    /// or rate-limit data. The initial recompute matters because a quiet launch
    /// (no new samples) posts no `samplesChanged`, so without it a freshly
    /// opened view would see an unwarmed engine until the next real change.
    private func startEngine() {
        guard engineRecomputeObserver == nil else { return }
        Task { @MainActor [weak self] in
            self?.refreshModelPalette()
            await self?.recomputeEngineIfDue(force: true)
        }
        installEngineRecomputeObserver()
    }

    private func installEngineRecomputeObserver() {
        engineRecomputeObserver = NotificationCenter.default.addObserver(
            forName: .pacerScanCycleDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Recompute on either cost (`samplesChanged`) or rate-limit data,
            // since the engine answers both cost and rate-limit questions.
            let summary = note.object as? ScanCycleSummary
            let rateLimitsChanged = summary?.rateLimitsChanged ?? false
            let relevant = (summary?.samplesChanged ?? false) || rateLimitsChanged
            guard relevant else { return }
            Task { @MainActor [weak self] in
                self?.refreshModelPalette()
                await self?.recomputeEngineIfDue(rateLimitsChanged: rateLimitsChanged)
            }
        }
    }

    /// Rebuild the model-color palette from the distinct models seen in the
    /// store, so a model the bundled catalog doesn't know about still gets a
    /// proper in-band color (and reflows its family) instead of the fallback.
    /// Cheap — fetches only the `model` column; runs at startup and on each
    /// scan cycle that carried new samples.
    private func refreshModelPalette() {
        let context = ModelContext(container)
        var desc = FetchDescriptor<DailyAggregate>()
        desc.propertiesToFetch = [\.model]
        guard let rows = try? context.fetch(desc) else { return }
        pacerRefreshModelPalette(observed: Array(Set(rows.map(\.model))))
    }

    /// Throttled engine refit. Posts `.pacerEngineDidRecompute` after a real
    /// recompute so every engine-consuming card refreshes exactly when fresh
    /// answers exist — not speculatively on raw scan ticks. Also exports the
    /// compact outlook snapshot the widgets read (they run out-of-process and
    /// can't reach the engine actor).
    /// - Parameter rateLimitsChanged: whether this was prompted by fresh
    ///   rate-limit data (the forecast's real input) rather than by token
    ///   samples alone. Token-only prompts get a much longer floor.
    private func recomputeEngineIfDue(force: Bool = false,
                                      rateLimitsChanged: Bool = true) async {
        let now = Date()
        let floor = rateLimitsChanged
            ? Self.engineRecomputeMinInterval
            : Self.engineRecomputeIdleInterval
        if !force, let last = lastEngineRecomputeAt,
           now.timeIntervalSince(last) < floor { return }
        lastEngineRecomputeAt = now
        // Recompute OFF the main actor. `recomputeEngineIfDue` runs on
        // `@MainActor`, so `await engine.recompute(...)` would resume the
        // heavy forecast fit INLINE on the main thread (uncontended-actor
        // optimization — confirmed on Main via sample(1) during a scroll).
        // A detached task forces it onto the engine's executor.
        let started = Date()
        await Task.detached(priority: .utility) { [engine] in
            await engine.recompute(now: now)
        }.value
        let refitMs = Int(Date().timeIntervalSince(started) * 1000)
        await exportEngineSnapshot()
        NotificationCenter.default.post(name: .pacerEngineDidRecompute, object: nil)

        // The refit is the most expensive recurring thing Pacer does and it
        // had never been timed — which is how it went unnoticed that it runs
        // as often as every 20 s. Cost alone says little; cost against the
        // interval is the duty cycle, and that's the number that decides
        // whether this is a background app or a busy one.
        engineRefitCount += 1
        engineRefitTotalMs += refitMs
        if refitMs >= 1_000 || engineRefitCount % 20 == 0 {
            let duty = Double(engineRefitTotalMs) / max(1, Double(engineRefitCount))
                / floor / 10.0
            Log.write("Engine",
                      "refit \(engineRefitCount): \(refitMs) ms "
                      + String(format: "(avg %d ms, ~%.0f%% duty at %.0fs interval)",
                               engineRefitTotalMs / max(1, engineRefitCount),
                               duty, floor))
        }
    }

    /// Upsert the engine's outlook snapshot into `ClaudeCodeMeta` so the
    /// widget process can draw the same trajectory + outlook the dashboard
    /// shows.
    private func exportEngineSnapshot() async {
        // `engine.snapshot()` fits the forecast models; run it off the main
        // actor (same inline-on-main hazard as recomputeEngineIfDue) so it
        // can't block the UI. The small SwiftData write stays on main.
        let snapshotJSON = await Task.detached(priority: .utility) { [engine] in
            await engine.snapshot().encodedJSON()
        }.value
        guard let json = snapshotJSON else { return }
        let context = ModelContext(container)
        let key = EngineSnapshot.metaKey
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key })
        if let existing = try? context.fetch(descriptor).first {
            guard existing.value != json else { return }
            existing.value = json
        } else {
            context.insert(ClaudeCodeMeta(key: key, value: json))
        }
        try? context.save()
    }

    /// Run `GlobalRateLimitReset.detect` over recent OAuth samples for
    /// each window and dispatch an early-reset banner on a hit. The
    /// detector is the gatekeeper for "is this real / not a blip"; the
    /// coordinator handles the settings gate and per-cycle dedup.
    private func checkForGlobalReset() async {
        let context = ModelContext(container)
        let oauthSource = RateLimitSource.oauth

        for window in [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay] {
            let cutoff = Date().addingTimeInterval(-globalResetLookback(forWindow: window))
            let descriptor = FetchDescriptor<RateLimitSample>(
                predicate: #Predicate {
                    $0.source == oauthSource
                        && $0.window == window
                        && $0.sampledAt >= cutoff
                },
                sortBy: [SortDescriptor(\.sampledAt, order: .forward)]
            )
            guard let rows = try? context.fetch(descriptor) else { continue }
            let observations = rows.map {
                GlobalRateLimitReset.Observation(
                    sampledAt: $0.sampledAt,
                    usedPercentage: $0.usedPercentage,
                    resetsAt: $0.resetsAt
                )
            }
            // Window-aware gates. The 5-hour window rolls over constantly and
            // naturally touches 0%, so keep its high bar (25%) and a short
            // cut-short lead. The 7-day window hitting 0% is rare and almost
            // always a real reset, so a lower bar (15%) catches a modest-but-
            // genuine early reset (Anthropic's 2026-06-20 reset dropped 7-day
            // from ~17% and nulled the anchor), and a larger lead (10% of the
            // window) keeps a sleep-gap rollover from masquerading as one.
            let windowDuration = PaceMath.windowDuration(for: window) ?? (7 * 24 * 3600)
            let highWatermark: Double = window == RateLimitWindowName.sevenDay ? 15 : 25
            let minAnchorLead = max(GlobalRateLimitReset.defaultMinAnchorLead, windowDuration * 0.1)
            guard let detection = GlobalRateLimitReset.detect(
                observations,
                highWatermark: highWatermark,
                minAnchorLead: minAnchorLead
            ) else { continue }
            await NotificationCoordinator.shared.handleGlobalRateLimitReset(
                window: window,
                detection: detection,
                context: context
            )
        }
    }

    // MARK: - Burn-rate (slope) warning

    /// Warn when the *rate* you're burning a window will blow the cap before
    /// it resets. The crossing now comes from the intelligence engine's
    /// selected model per window — for the 7-day window that's typically the
    /// diurnal shape, which knows an overnight/weekend lull is coming and so
    /// stops projecting "limit tonight" off one busy afternoon (the validated
    /// improvement over the old linear/recency-weighted slopes). The
    /// coordinator still owns the warning decision (`BurnRate.warrantsWarning`),
    /// the per-cycle dedup, and the opt-in gate.
    private func checkBurnRateWarning() async {
        let context = ModelContext(container)
        for window in RateLimitWindowKind.allCases {
            guard let outlook = await engine.burnOutlook(window: window) else {
                burnHitStreak[window.rawValue] = 0
                continue
            }
            // Debounce (industry-converged forecast-alert pattern: lead-time
            // AND level gate AND k-consecutive confirmation): require the
            // pre-reset crossing to hold across two consecutive engine refits
            // before the coordinator may fire, so one transient burst between
            // OAuth polls can't page the user. The level gate (≥50% used)
            // stays in BurnRate.warrantsWarning; the per-cycle dedup stays in
            // the coordinator.
            if outlook.willHitLimitBeforeReset {
                burnHitStreak[window.rawValue, default: 0] += 1
            } else {
                burnHitStreak[window.rawValue] = 0
            }
            guard (burnHitStreak[window.rawValue] ?? 0) >= 2 else { continue }
            let projection = BurnRate.Projection(
                slopePercentPerHour: outlook.slopePercentPerHour,
                projectedFullAt: outlook.projectedFullAt,
                etaSeconds: outlook.etaSeconds)
            let duration = PaceMath.windowDuration(for: window.rawValue) ?? 1
            await NotificationCoordinator.shared.handleBurnRateWarning(
                window: window.rawValue,
                projection: projection,
                resetsAt: outlook.resetsAt,
                usedPct: outlook.usedPct,
                hitRangeEarliest: outlook.projectedFullAtEarliest,
                hitRangeLatest: outlook.projectedFullAtLatest,
                capPaceRatio: outlook.slopePercentPerHour / (100.0 / (duration / 3600)),
                context: context
            )
        }
        await checkScopedBurnRateWarnings(context: context)
    }

    /// Burn-rate warnings for **scoped per-model windows** (a "Fable · weekly"
    /// cap, etc.), driven by the SAME engine projection surface as the fixed
    /// 5h/7d path — `engine.scopedWindows()` for the live account-scoped windows
    /// and `engine.burnOutlook(windowKey:)` for each one's crossing. It reuses
    /// the fixed path's k-consecutive-refit debounce (`burnHitStreak`, namespaced
    /// by identity) and fires the identical banner via `handleBurnRateWarning`,
    /// labelled with the window's `displayName`.
    ///
    /// Two guards make scoped windows behave correctly and honestly:
    ///   - **Opt-in** — scoped windows default to no alert, so a burn-rate
    ///     warning fires only for a window the user configured a scoped
    ///     threshold alert for (`ScopedRateLimitAlerts.shouldWarnBurnRate`,
    ///     which also re-applies the ≥50% used floor). Nothing fires by default,
    ///     and no new per-window toggle is needed.
    ///   - **Cold-start** — the same helper suppresses a warning until the engine
    ///     has watched the window complete enough cycles to leave its low-
    ///     confidence band, so a freshly discovered scoped window can't page the
    ///     user off one thin cycle.
    /// Dormancy falls out for free: `scopedWindows()` only lists identities
    /// present in the latest poll, so a vanished window is never evaluated (its
    /// alert rules are kept, untouched) and resumes when it reappears.
    private func checkScopedBurnRateWarnings(context: ModelContext) async {
        let scopedSpecs = await engine.scopedWindows()
        guard !scopedSpecs.isEmpty else { return }
        let rules = (try? context.fetch(FetchDescriptor<AlertRule>())) ?? []

        for spec in scopedSpecs {
            let identity = spec.key
            guard let outlook = await engine.burnOutlook(windowKey: identity) else {
                burnHitStreak[identity] = 0
                continue
            }
            // Debounce on the raw pre-reset crossing, identical to the fixed
            // path: require two consecutive refits before the coordinator may
            // fire, so one transient burst between polls can't page the user.
            if outlook.willHitLimitBeforeReset {
                burnHitStreak[identity, default: 0] += 1
            } else {
                burnHitStreak[identity] = 0
            }
            guard (burnHitStreak[identity] ?? 0) >= 2 else { continue }
            // Opt-in + cold-start + used-floor gate (pure, unit-tested). A window
            // with no configured scoped alert, too few completed cycles, or below
            // the floor is not warned.
            guard ScopedRateLimitAlerts.shouldWarnBurnRate(
                identity: identity,
                willHitLimitBeforeReset: outlook.willHitLimitBeforeReset,
                usedPct: outlook.usedPct,
                cyclesObserved: outlook.cyclesObserved,
                in: rules
            ) else { continue }

            let projection = BurnRate.Projection(
                slopePercentPerHour: outlook.slopePercentPerHour,
                projectedFullAt: outlook.projectedFullAt,
                etaSeconds: outlook.etaSeconds)
            let durationHours = spec.duration / 3600
            await NotificationCoordinator.shared.handleBurnRateWarning(
                window: identity,
                projection: projection,
                resetsAt: outlook.resetsAt,
                usedPct: outlook.usedPct,
                hitRangeEarliest: outlook.projectedFullAtEarliest,
                hitRangeLatest: outlook.projectedFullAtLatest,
                capPaceRatio: durationHours > 0
                    ? outlook.slopePercentPerHour / (100.0 / durationHours) : nil,
                labelOverride: spec.displayName,
                windowDurationHours: durationHours,
                context: context
            )
        }
    }
}
