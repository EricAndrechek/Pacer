import Foundation
import SwiftData
import PacerCore

@main
struct PacerDaemonMain {
    static func main() async {
        do {
            try await runDaemon()
        } catch {
            FileHandle.standardError.write(Data("[PacerDaemon] fatal: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func runDaemon() async throws {
        let container = try PacerStore.makeModelContainer()
        let storeURL = try PacerStore.storeURL()
        log("starting; SwiftData container at \(storeURL.path)")

        // Honor `PACER_RUN_ONCE=1` for one-shot CLI use (manual scan,
        // CI test runs). Production LaunchAgent invocation runs the
        // forever loop.
        let runOnce = ProcessInfo.processInfo.environment["PACER_RUN_ONCE"] == "1"
        let coordinator = ScanCoordinator(container: container)

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
        FileHandle.standardError.write(Data("[PacerDaemon] \(message)\n".utf8))
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
