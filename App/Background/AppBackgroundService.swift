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
