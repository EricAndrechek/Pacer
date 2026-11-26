import Darwin
import Foundation
import Synchronization

/// Bounds a quit (#475). Two deadlines, both off the main thread, which may be
/// the thing that is stuck:
///
/// - **after the reply** (`armAfterReply`, 5 s): AppKit has not ended the
///   process a few seconds after Pacer replied yes to
///   `applicationShouldTerminate`;
/// - **before it** (`armShutdownBackstop`, 90 s from the quit's start): the
///   reply itself has not been sent, because Pacer's own shutdown is stuck.
///
/// **Why after the reply.** The reply is the point of no return, and Launch
/// Services treats Pacer as gone from that moment. In the #475 probe a new
/// Pacer was launched a second after the reply while the old process was
/// still alive. AppKit's end of the quit (the termination notification, then
/// `exit`) runs on the main run loop, and on that starved Mac the run loop was
/// still busy laying out the dashboard, so two Pacers had the same store open.
/// Pacer's own shutdown is done by the time it replies: the scan pass in
/// flight has finished (or `ScanCoordinator.stopDrainBound` ran out), the
/// poller and watcher are stopped, telemetry and the log are flushed. This
/// keeps any overlap with a relaunch to about `grace`.
///
/// **Why before it.** Each step of the shutdown before the reply has a bound
/// of its own, or is short in practice: stopping the watcher and the poller,
/// getting the scan actor back after the drain's bound ran out, waiting for
/// the main actor. Nothing bounded them all together. A quit stuck there
/// never replies, and `make install` or logout kills it in the end. The
/// backstop ends it first, the same way, and it says so in the log.
///
/// **What it costs, when it fires.** Whatever AppKit had left: the
/// `willTerminate` notification and its observers, and AppKit's last save of
/// the window's restorable state. Pacer restores the dashboard itself
/// (`MainWindowPlacement`: its frame and whether it was open, written when
/// they changed). Sparkle's installer does not need the notification
/// either: its progress agent (2.10) waits on `NSRunningApplication`'s
/// `isTerminated`, which an ended process sets however it ended, and it has
/// no timeout. So the window comes back open and an update still installs.
/// Before the reply it also costs the steps of the shutdown not yet run: the
/// clean-exit mark, so the next launch counts it as an unclean exit, which is
/// accurate. A normal quit ends well inside both deadlines, and then neither
/// fires.
///
/// **`_exit`, not `exit`.** `exit` runs atexit handlers and C++ static
/// destructors on this thread, while the main thread may still be inside
/// SwiftUI using what they tear down. That turns a late quit into a crash at
/// exit, and a crash report. `_exit` ends the process at once. The store
/// needs nothing from it: SQLite's WAL keeps every committed transaction,
/// and a transaction still open is rolled back on the next open, as after
/// any kill.
public final class QuitExitGuard: Sendable {

    public static let shared = QuitExitGuard()

    /// How long AppKit gets after the reply. A quit that is not starved ends
    /// in well under a second.
    public static let grace: Duration = .seconds(5)

    /// How long the shutdown before the reply may take. On the loaded Mac of
    /// #475 it took 11 s. Past this, something in it is not coming back.
    public static let shutdownBound: Duration = .seconds(90)

    private let replied = Mutex(false)

    private let log: @Sendable (String) -> Void
    private let exit: @Sendable () -> Void

    /// `log` and `exit` are for tests; the app's are the log and `_exit(0)`,
    /// with the log flushed first.
    public init(log: @escaping @Sendable (String) -> Void = { Log.write("Lifecycle", $0) },
                exit: @escaping @Sendable () -> Void = { _ = Log.flush(); Darwin._exit(0) }) {
        self.log = log
        self.exit = exit
    }

    /// Call as the quit begins. Ends the process if the reply has not been
    /// sent `bound` later; does nothing once it has.
    public func armShutdownBackstop(bound: Duration = shutdownBound) {
        let seconds = Self.seconds(bound)
        after(seconds) { [self] in
            guard !replied.withLock({ $0 }) else { return }
            log("no reply to terminate \(Int(seconds.rounded())) s after the quit began; exiting")
            exit()
        }
    }

    /// Call right before `reply(toApplicationShouldTerminate: true)`. Ends the
    /// process if it is still running `grace` later, and stands the backstop
    /// down.
    public func armAfterReply(grace: Duration = grace) {
        replied.withLock { $0 = true }
        let seconds = Self.seconds(grace)
        after(seconds) { [self] in
            log("still running \(Int(seconds.rounded())) s after replying to terminate; exiting")
            exit()
        }
    }

    private func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
