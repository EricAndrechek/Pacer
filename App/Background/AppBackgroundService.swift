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
        widgetRefreshCoordinator.start()
        startPricingRefreshTask()
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
        widgetRefreshCoordinator.stop()
        pricingRefreshTask?.cancel()
        pricingRefreshTask = nil
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
}
