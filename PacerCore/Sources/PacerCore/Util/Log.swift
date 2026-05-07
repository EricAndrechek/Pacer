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

    public static func write(_ tag: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
