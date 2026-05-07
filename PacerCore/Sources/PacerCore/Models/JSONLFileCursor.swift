import Foundation
import SwiftData

/// One byte-offset cursor per JSONL file we've scanned. Lets the scanner
/// resume from where it left off instead of re-parsing the whole file
/// every time FSEvents fires.
///
/// Without cursors a single new line costs an entire file re-parse plus
/// a dedup-set lookup per line — exactly the loop that pegged daemon
/// CPU at 100% before the fix landed (every Claude Code write triggered
/// a ~10s re-scan on a moderately-sized active session).
///
/// `path` is the standardized absolute path of the file (key).
/// `byteOffset` is where the next read should start; equals the file's
/// observed size at the end of the last successful read.
/// `lastSeenMtime` is checked against the file's current mtime so the
/// scanner can fast-skip files that haven't changed (no open, no read).
@Model
public final class JSONLFileCursor {
    @Attribute(.unique) public var path: String
    public var byteOffset: Int64
    public var lastSeenMtime: Date

    public init(path: String, byteOffset: Int64, lastSeenMtime: Date) {
        self.path = path
        self.byteOffset = byteOffset
        self.lastSeenMtime = lastSeenMtime
    }
}
