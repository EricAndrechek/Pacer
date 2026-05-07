import Foundation
import SwiftData
import PacerCore

@main
struct PacerDaemonMain {
    static func main() async {
        do {
            try await runDaemon()
        } catch {
            Log.write("PacerDaemon", "fatal: \(error)")
            exit(1)
        }
    }

    @MainActor
    static func runDaemon() async throws {
        // SwiftData / SQLite uses guarded file descriptors. A zombie
        // daemon holding a guarded fd on `pacer.sqlite` will block
        // `makeModelContainer()` indefinitely inside `__guarded_open_np`
        // — the syscall doesn't honor signals. Without this watchdog
        // the daemon would silently hang at startup with no log output.
        // The cancel-or-fire pattern only logs when container creation
        // takes longer than the threshold; a healthy startup is silent.
        let watchdog = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            Log.write(
                "PacerDaemon",
                "WARNING: SwiftData container creation has not completed after 30s. Likely a stuck SQLite lock — check `lsof <store-path>` for orphan PacerDaemon processes (especially in SX 'kernel-stuck' state). A reboot clears them."
            )
        }
        let container: ModelContainer
        do {
            container = try PacerStore.makeModelContainer()
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            throw error
        }
        let storeURL = try PacerStore.storeURL()
        log("starting; SwiftData container at \(storeURL.path)")

        // Honor `PACER_RUN_ONCE=1` for one-shot CLI use (manual scan,
        // CI test runs). Production LaunchAgent invocation runs the
        // forever loop.
        let env = ProcessInfo.processInfo.environment
        let runOnce = env["PACER_RUN_ONCE"] == "1"

        // OAuth polling on by default; opt-out via env for ops contexts
        // that don't want network calls (sandboxed CI, JSONL-only runs).
        // The first poll from this binary may surface a Keychain ACL
        // prompt; the poller treats `accessDenied` as a soft failure
        // and keeps running, so the JSONL pipeline is never blocked.
        let oauthEnabled = env["PACER_DISABLE_OAUTH"] != "1" && !runOnce
        let oauthClient: OAuthClient? = oauthEnabled ? OAuthClient() : nil

        // Read user prefs from the App Group store so the Settings →
        // Data → Cost-mode picker actually takes effect on the daemon.
        // Falls back to `.auto` if the user has never opened the app
        // (no defaults registered yet).
        let costMode = PacerPreferences.costMode()
        log("cost mode: \(costMode)")

        let coordinator = ScanCoordinator(
            container: container,
            configuration: ScanCoordinator.Configuration(costMode: costMode),
            oauthClient: oauthClient
        )

        if runOnce {
            let report = try await coordinator.runOnce()
            log("scan complete: full=\(report.wasFullScan) inserted=\(report.persisterStats.inserted) dups=\(report.persisterStats.skippedAsDuplicate) aggs=\(report.recomputeStats.aggregatesUpserted) ms=\(Int(report.durationSeconds * 1000))")
            return
        }

        // SIGTERM/SIGINT → cleanly stop the watcher so the for-await
        // loop exits and `main` returns. Without these, launchctl's
        // stop signal would just kill the process; SwiftData's WAL
        // recovers fine, but graceful shutdown is the better default.
        let sigtermSource = installSignalHandler(SIGTERM) {
            Task { await coordinator.stop() }
        }
        let sigintSource = installSignalHandler(SIGINT) {
            Task { await coordinator.stop() }
        }
        defer {
            sigtermSource.cancel()
            sigintSource.cancel()
        }

        try await coordinator.runForever()
        log("event loop exited; daemon shutting down")
    }

    static func log(_ message: String) {
        Log.write("PacerDaemon", message)
    }

    /// Installs a SIGTERM/SIGINT handler via DispatchSourceSignal. The
    /// default signal disposition on macOS is to terminate the process
    /// immediately; we have to mask it AND register the dispatch source.
    static func installSignalHandler(_ signo: Int32, handler: @escaping () -> Void) -> DispatchSourceSignal {
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}
