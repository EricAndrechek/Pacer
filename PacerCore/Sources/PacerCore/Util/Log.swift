import Foundation
import Synchronization

/// Tiny stderr logging helper. Writes ISO-8601 timestamps + a tag so
/// the daemon log is reasoned-about-able after the fact ("when did
/// the OAuth poller fail?" needs a clock).
///
/// Format: `2026-05-07T01:42:13.482Z [Tag] message`
///
/// Milliseconds because whole seconds cannot be lined up against anything
/// faster than a person — a screen recording of a relaunch, or the order of a
/// window move and the display change that caused it, both happen inside one.
///
/// Writes are short enough (well under PIPE_BUF) that a single
/// `FileHandle.write` is atomic; we don't need to add a lock just to
/// avoid interleaving across the daemon's two log streams (signal
/// handler vs main task).
public enum Log {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Marks lines written by a process other than the user's running app.
    ///
    /// The off-screen renderer is a second process of the same bundle writing
    /// to the same log, and its lines were indistinguishable from the app's.
    /// That is actively misleading: the renderer loads every page of every
    /// scope back to back on its main thread, so it logs multi-second
    /// `[MainThread] stalled` lines as a matter of course — and reading those
    /// as the app's is how you end up investigating a beachball nobody had.
    ///
    /// Set once at startup, before anything logs. Nil in the real app, so its
    /// lines are unchanged and old logs stay greppable.
    nonisolated(unsafe) public static var processTag: String?

    /// Lines go to one serial background queue, in order, so a caller never
    /// waits on disk. The main thread used to: `MainThreadStallWatchdog` logs
    /// from the main run loop, and a `write()` to the log file that blocked in
    /// a disk stall became a multi-second app hang (PACER-15).
    ///
    /// Trade-offs, on purpose:
    /// - A normal quit loses nothing: the app calls `flush()` on its terminate
    ///   path, and an `atexit` handler (registered on first write) covers the
    ///   diagnostic modes that call `exit()` directly.
    /// - A crash can lose the lines still queued, normally a few milliseconds'
    ///   worth. That is the price of never blocking; the crash report carries
    ///   the stack, and the lines that matter just before a hang were written
    ///   long before it.
    /// - If the disk stays stuck the queue would grow without bound, so past
    ///   `maxPending` lines new ones are dropped and counted; the count is
    ///   written as one line once the queue drains.
    private static let queue = DispatchQueue(label: "pacer.log.writer", qos: .utility)
    static let maxPending = 20_000
    private static let pending = Mutex(0)
    private static let dropped = Mutex(0)
    private static let installExit: Void = { atexit { Log.flush() } }()

    /// Where lines end up. stderr, except in tests. Called on the writer queue.
    static let sink = Mutex<@Sendable (Data) -> Void>({ FileHandle.standardError.write($0) })

    public static func write(_ tag: String, _ message: String) {
        let prefix = processTag.map { "\($0):" } ?? ""
        let line = "\(formatter.string(from: Date())) [\(prefix)\(tag)] \(message)\n"
        _ = installExit
        let admitted = pending.withLock { count -> Bool in
            guard count < maxPending else { return false }
            count += 1
            return true
        }
        guard admitted else { dropped.withLock { $0 += 1 }; return }
        let data = Data(line.utf8)
        queue.async {
            let write = sink.withLock { $0 }
            write(data)
            pending.withLock { $0 -= 1 }
            let lost = dropped.withLock { n -> Int in defer { n = 0 }; return n }
            if lost > 0 {
                write(Data("\(formatter.string(from: Date())) [Log] dropped \(lost) lines while the log file was not accepting writes\n".utf8))
            }
        }
    }

    /// Wait until every line written so far has reached the sink.
    public static func flush() {
        queue.sync {}
    }
}
