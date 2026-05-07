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

    init(container: ModelContainer) {
        self.container = container
    }

    func start() {
        guard coordinator == nil else { return }

        let costMode = PacerPreferences.costMode()
        Log.write("AppBackground", "starting; cost mode: \(costMode)")

        // The first OAuth poll triggers a Keychain ACL prompt the
        // user has to approve.
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
    }
}
