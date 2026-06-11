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

    init(container: ModelContainer) {
        self.container = container
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
        let oauthClient = OAuthClient()
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
        widgetRefreshCoordinator.start()
        startPricingRefreshTask()
        startHistoryPruneTask()
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
        widgetRefreshCoordinator.stop()
        pricingRefreshTask?.cancel()
        pricingRefreshTask = nil
        historyPruneTask?.cancel()
        historyPruneTask = nil
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
                await self.checkBurnRateWarning()
                // Score any rate-limit cycles that finished since last scan,
                // feeding the self-improving model scoreboard. Idempotent.
                ForecastOutcomeRecorder.record(in: ModelContext(self.container))
            }
        }
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
            guard let detection = GlobalRateLimitReset.detect(observations) else { continue }
            await NotificationCoordinator.shared.handleGlobalRateLimitReset(
                window: window,
                detection: detection,
                context: context
            )
        }
    }

    // MARK: - Burn-rate (slope) warning

    /// Warn when the *rate* you're burning a window will blow the cap before
    /// it resets. Both windows flow through the same coordinator path; only
    /// the projection math differs:
    ///
    /// - **5-hour**: short window, so the first-to-last linear `BurnRate.project`
    ///   over a 90-minute lookback is actionable and stays as-is (its
    ///   displayed ETA is unchanged).
    /// - **7-day**: a 90-minute linear slope projects alarming nonsense from
    ///   one busy hour, so it uses the recency-weighted `TrendEstimator`
    ///   (`projectRecencyWeighted`) over a multi-day lookback — the piece
    ///   deferred from the 5-hour-only warning.
    private func checkBurnRateWarning() async {
        let context = ModelContext(container)
        let now = Date()
        await evaluateBurnWarning(
            window: RateLimitWindowName.fiveHour,
            fetchCutoff: now.addingTimeInterval(-2 * 3600),   // covers the 90-min lookback
            context: context,
            project: { samples, resetsAt in
                BurnRate.project(samples: samples, resetsAt: resetsAt)
            })
        await evaluateBurnWarning(
            window: RateLimitWindowName.sevenDay,
            fetchCutoff: now.addingTimeInterval(-BurnRate.sevenDayLookbackSeconds),
            context: context,
            project: { samples, resetsAt in
                BurnRate.projectRecencyWeighted(samples: samples, resetsAt: resetsAt, now: now)
            })
    }

    /// Fetch a window's recent OAuth samples, build a projection via the
    /// supplied strategy, and hand it to the coordinator. The coordinator
    /// owns the warning decision (`BurnRate.warrantsWarning`), the
    /// per-cycle dedup, and the opt-in gate — shared verbatim across windows.
    private func evaluateBurnWarning(
        window: String,
        fetchCutoff: Date,
        context: ModelContext,
        project: ([BurnRate.Sample], Date?) -> BurnRate.Projection?
    ) async {
        let oauthSource = RateLimitSource.oauth
        let descriptor = FetchDescriptor<RateLimitSample>(
            predicate: #Predicate {
                $0.source == oauthSource
                    && $0.window == window
                    && $0.sampledAt >= fetchCutoff
            },
            sortBy: [SortDescriptor(\.sampledAt, order: .forward)]
        )
        guard let rows = try? context.fetch(descriptor), let latest = rows.last else { return }
        let samples = rows.map {
            BurnRate.Sample(sampledAt: $0.sampledAt, usedPercentage: $0.usedPercentage)
        }
        guard let projection = project(samples, latest.resetsAt) else { return }
        await NotificationCoordinator.shared.handleBurnRateWarning(
            window: window,
            projection: projection,
            resetsAt: latest.resetsAt,
            usedPct: latest.usedPercentage,
            context: context
        )
    }
}
