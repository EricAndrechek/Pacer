import Foundation

/// Tiny stderr logging helper. Writes ISO-8601 timestamps + a tag so
/// the daemon log is reasoned-about-able after the fact ("when did
/// the OAuth poller fail?" needs a clock).
///
/// Format: `2026-05-07T01:42:13Z [Tag] message`
///
/// Writes are short enough (well under PIPE_BUF) that a single
/// `FileHandle.write` is atomic; we don't need to add a lock just to
/// avoid interleaving across the daemon's two log streams (signal
/// handler vs main task).
public enum Log {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
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

    public static func write(_ tag: String, _ message: String) {
        let prefix = processTag.map { "\($0):" } ?? ""
        let line = "\(formatter.string(from: Date())) [\(prefix)\(tag)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
