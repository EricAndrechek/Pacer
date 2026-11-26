import Darwin
import Foundation

/// Ends the process if AppKit has not, a few seconds after Pacer replied yes
/// to `applicationShouldTerminate` (#475).
///
/// **Why.** The reply is the point of no return, and Launch Services acts on
/// it too. In the #475 probe a new Pacer was launched (by Launch Services, a
/// second after the reply) while the old process was still alive. AppKit's
/// end of the quit (the termination notification, then `exit`) runs on the
/// main run loop, and on that starved Mac the run loop was still busy laying
/// out the dashboard. So two Pacers had the same store open. Pacer's own
/// shutdown is done by the time it replies: the poller and watcher are
/// stopped, telemetry and the log are flushed. Nothing waits on the rest, so
/// this bounds it.
///
/// **What it costs, when it fires.** Whatever AppKit had left: the
/// `willTerminate` notification and its observers, and AppKit's last save of
/// the window's restorable state. Pacer restores the dashboard itself
/// (`MainWindowPlacement`: its frame and whether it was open, written when
/// they changed), and Sparkle's waiting installer watches the process, not
/// the notification. So the window comes back open and an update still
/// installs. A normal quit ends well inside the grace, and then this never
/// fires.
///
/// **`_exit`, not `exit`.** `exit` runs atexit handlers and C++ static
/// destructors on this thread, while the main thread may still be inside
/// SwiftUI using what they tear down. That turns a late quit into a crash at
/// exit, and a crash report. `_exit` ends the process at once. The store
/// needs nothing from it: SQLite's WAL keeps every committed transaction,
/// and a transaction still open is rolled back on the next open, as after
/// any kill. (One can be open only when the scan's last pass outran
/// `ScanCoordinator.stopDrainBound`; the reply's log line says so.)
public enum QuitExitGuard {

    /// How long AppKit gets after the reply. A quit that is not starved ends
    /// in well under a second.
    public static let grace: Duration = .seconds(5)

    /// Arm it. Call right before `reply(toApplicationShouldTerminate: true)`.
    /// Runs off the main thread, which may be the thing that is stuck.
    ///
    /// `exit` and `log` are for tests; the app's are `_exit(0)` and the log,
    /// flushed before the process ends.
    public static func arm(grace: Duration = grace,
                           log: @escaping @Sendable (String) -> Void = { Log.write("Lifecycle", $0) },
                           exit: @escaping @Sendable () -> Void = { _ = Log.flush(); Darwin._exit(0) }) {
        let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            log("still running \(Int(seconds.rounded())) s after replying to terminate; exiting")
            exit()
        }
    }
}
