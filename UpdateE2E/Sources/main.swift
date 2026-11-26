import AppKit
import PacerCore
import Sparkle

// The update end-to-end test app (#470). It starts Pacer's own updater
// (`PacerUpdater`, from App/Update) and gives bin/update-e2e.sh three handles,
// all through files in one directory, because the Sparkle relaunch starts the
// new version through LaunchServices with none of the first launch's
// environment:
//
// - `app.log`: everything `Log.write` says (Pacer's "[Update]" lines included),
//   plus a `STATUS` line whenever the scheduler's phase, the offered version,
//   Sparkle's session, the last recorded outcome or the `update.*` counters
//   change, and one `launched build=N` line per launch.
// - `check-now`: run a background check now, the call Pacer itself makes for
//   its catch-up check and its retries (`checkForUpdatesInBackground`). Sparkle's
//   six-hour timer runs the same driver (`SPUUpdater.m:603-640`).
// - `install-now`: while it exists, the Mac reads as idle for a day and Pacer
//   unused as long, so `UpdateInstallPolicy` itself says install (no window
//   open: `noWindow`). Pacer's decision code is unchanged; only its inputs are.
//
// Never run on a Mac someone uses: it replaces itself (docs/releasing.md).

enum E2E {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PacerUpdateE2E", isDirectory: true)

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }
}

try? FileManager.default.createDirectory(at: E2E.directory, withIntermediateDirectories: true)
// Log.write goes to stderr; append it to the log, across the relaunch too.
let logDescriptor = open(E2E.url("app.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
if logDescriptor >= 0 { dup2(logDescriptor, STDERR_FILENO) }

let info = Bundle.main.infoDictionary ?? [:]
Log.write("E2E", "launched build=\(info["CFBundleVersion"] as? String ?? "?") "
          + "version=\(info["CFBundleShortVersionString"] as? String ?? "?") pid=\(getpid()) "
          + "path=\(Bundle.main.bundlePath)")


@MainActor
final class E2EDelegate: NSObject, NSApplicationDelegate {
    private var updater: PacerUpdater?
    private var timer: Timer?
    private var lastStatus = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater = PacerUpdater()
        // No store here: nothing for the policy to wait on.
        UpdateInstallScheduler.shared.noteStoreReady()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        guard let sparkle = updater?.updater else { return }
        if E2E.exists("check-now"), !sparkle.sessionInProgress {
            try? FileManager.default.removeItem(at: E2E.url("check-now"))
            Log.write("E2E", "check requested")
            sparkle.checkForUpdatesInBackground()
        }
        let scheduler = UpdateInstallScheduler.shared
        let counters = TelemetryCounters.peek()
            .filter { $0.key.hasPrefix("update.") }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let outcome = UpdateOutcomeLog.last().map { "\($0.result)@\($0.version ?? "-")" } ?? "-"
        let status = "phase=\(Self.name(scheduler.schedule.phase)) offered=\(scheduler.offeredVersion ?? "-") "
            + "ready=\(scheduler.readyVersion ?? "-") session=\(sparkle.sessionInProgress) "
            + "outcome=\(outcome) counters=\(counters.isEmpty ? "-" : counters)"
        guard status != lastStatus else { return }
        lastStatus = status
        Log.write("E2E", "STATUS \(status)")
    }

    private static func name(_ phase: UpdateSchedule.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .available: return "available"
        case .arming(_, let reason): return "arming-\(reason.rawValue)"
        case .held: return "held"
        case .installing: return "installing"
        }
    }
}

MainActor.assumeIsolated {
    // Seconds instead of minutes, set before anything touches the scheduler.
    UpdateInstallScheduler.tuning = .init(tick: 1, armSpacing: 10, retryAfter: 60, adjustSignals: { signals in
        if E2E.exists("install-now") {
            signals.sinceUsed = 86_400
            signals.userIdle = 86_400
        }
    })
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = E2EDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
