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
/// Lines are written with `write(2)` on stderr's descriptor, never through
/// `FileHandle`: see `writeAll` for why.
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

    /// A test's replacement for stderr: nil in the app. Called on the writer
    /// queue.
    ///
    /// Wrapped in a struct, never stored as a bare closure. 0.9.0 kept it as
    /// `Mutex<@Sendable (Data) -> Void>` and read it with `withLock { $0 }`.
    /// `withLock` hands its body an `inout` value, so the closure is
    /// reabstracted on the way in and again on the write-back: every read
    /// stored it two thunks deeper. One read per log line meant the writer's
    /// stack grew by two frames a line, in Release as well as Debug, until it
    /// overflowed. The owner's crash report shows the recursion 6,672 deep
    /// (13,359 frames) after 4.4 hours, and that crash stopped Pacer
    /// recording for 15 hours. A struct (or any non-function type) is stored
    /// as itself, so a round trip through the lock adds nothing.
    /// `LogAsyncTests.sinkRoundTripsDoNotDeepenTheStack` holds it there.
    struct Sink: Sendable {
        let write: @Sendable (Data) -> Void
    }
    static let sink = Mutex<Sink?>(nil)

    /// Write all of `data` to `fd` with `write(2)`, retrying on `EINTR` and
    /// finishing short writes. Any other error drops the rest of the line:
    /// a log must never take the app down. Plain `write(2)` rather than
    /// `FileHandle.write`: one system call, no Foundation objects per line,
    /// and nothing it calls can throw an Objective-C exception on a closed
    /// descriptor.
    static func writeAll(_ data: Data, to fd: Int32 = STDERR_FILENO) {
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n > 0 {
                    p += n
                    left -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

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
            let override = sink.withLock { $0 }
            let emit: (Data) -> Void = { line in
                if let override { override.write(line) } else { writeAll(line) }
            }
            emit(data)
            pending.withLock { $0 -= 1 }
            let lost = dropped.withLock { n -> Int in defer { n = 0 }; return n }
            if lost > 0 {
                emit(Data("\(formatter.string(from: Date())) [Log] dropped \(lost) lines while the log file was not accepting writes\n".utf8))
            }
        }
    }

    /// Wait until every line written so far has reached the sink, for at most
    /// `timeout`. Bounded because it runs on the terminate path and in the
    /// `atexit` handler: during a disk stall (the reason the writer is off
    /// the main thread at all, PACER-15) an unbounded wait would hold up a
    /// quit or an update's relaunch for the whole stall. Returns false if it
    /// gave up. Never deadlocks if called on the writer queue itself; it just
    /// times out.
    @discardableResult
    public static func flush(timeout: TimeInterval = 2) -> Bool {
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        return drained.wait(timeout: .now() + timeout) == .success
    }
}
