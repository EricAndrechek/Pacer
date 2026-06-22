import Foundation
import SwiftData
import PacerCore

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
    private static let engineRecomputeMinInterval: TimeInterval = 20
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
        let oauthClient = OAuthClient(heldStore: KeychainCredentialStore())
        let scanCoordinator = ScanCoordinator(
            container: container,
            configuration: ScanCoordinator.Configuration(costMode: costMode),
            oauthClient: oauthClient
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
            let relevant = (summary?.samplesChanged ?? false) || (summary?.rateLimitsChanged ?? false)
            guard relevant else { return }
            Task { @MainActor [weak self] in
                await self?.recomputeEngineIfDue()
            }
        }
    }

    /// Throttled engine refit. Posts `.pacerEngineDidRecompute` after a real
    /// recompute so every engine-consuming card refreshes exactly when fresh
    /// answers exist — not speculatively on raw scan ticks. Also exports the
    /// compact outlook snapshot the widgets read (they run out-of-process and
    /// can't reach the engine actor).
    private func recomputeEngineIfDue(force: Bool = false) async {
        let now = Date()
        if !force, let last = lastEngineRecomputeAt,
           now.timeIntervalSince(last) < Self.engineRecomputeMinInterval { return }
        lastEngineRecomputeAt = now
        await engine.recompute(now: now)
        await exportEngineSnapshot()
        NotificationCenter.default.post(name: .pacerEngineDidRecompute, object: nil)
    }

    /// Upsert the engine's outlook snapshot into `ClaudeCodeMeta` so the
    /// widget process can draw the same trajectory + outlook the dashboard
    /// shows.
    private func exportEngineSnapshot() async {
        guard let json = await engine.snapshot().encodedJSON() else { return }
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
    }
}
