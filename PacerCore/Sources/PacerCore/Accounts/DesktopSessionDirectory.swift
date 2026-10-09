import Foundation

/// Which account each of Claude Desktop's Claude Code sessions ran under, read
/// from Desktop's own session records (#244).
///
/// Desktop runs its own Claude Code and writes the transcripts into the same
/// `~/.claude/projects` as the CLI, marked `"entrypoint":"claude-desktop"`. It
/// bills Desktop's login, which need not be the CLI's. A turn carries no
/// account (see `AccountActivation`), and both things the trail answers from
/// point at the CLI: the timestamp, and a root that is the default one. So
/// Desktop's turns were counted against whichever account the CLI was on.
///
/// Desktop records the answer. Every session it runs has a file at
///
///     ~/Library/Application Support/Claude/claude-code-sessions/<user>/<org>/local_<id>.json
///
/// whose `cliSessionId` is the transcript's `sessionId`, and whose folder is
/// the organization it ran under, which is exactly `Account.id`. That is a
/// per-session record made at the time. A trail inferred from Desktop's tokens
/// would be neither: Desktop can hold tokens for more than one org, and can
/// change org.
///
/// Only the org folder's name and that one field are read. A record's session
/// and org never change, so each file is read once. And only its first few
/// kilobytes: records run to megabytes (one MCP server configuration is
/// 1.8 MB of a real one, 51 MB across 86 of them), and parsing them whole cost
/// the first snapshot after launch most of a second. Desktop writes
/// `cliSessionId` second, at byte 58.
@ScanActor
public final class DesktopSessionDirectory {
    /// Where Desktop keeps its session records, or nil when Pacer should not
    /// look (tests, which must never read the developer's own Desktop).
    nonisolated public static var defaultRoot: URL? {
        guard !PacerPreferences.isTestProcess else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/claude-code-sessions",
                       directoryHint: .isDirectory)
    }

    /// How long a session Desktop has no record for waits before its next
    /// turn reads the folder again. A record is written when a session starts,
    /// before its first turn, so a miss is either that race (gone on the next
    /// read) or a record Desktop has since deleted (gone for good). Either way
    /// one listing per session every few seconds is plenty, and costs a
    /// directory listing plus any new file.
    nonisolated public static let missRefreshInterval: TimeInterval = 5

    private let root: URL?
    /// `sessionId` → `Account.id`, for every record read so far.
    public private(set) var accounts: [String: String] = [:]
    /// Record files that yielded a session. Others are read again, since a
    /// record can be written before its `cliSessionId` is.
    private var readFiles: Set<String> = []
    /// Record files that yielded no session, by modification date: read again
    /// only once they change, so one empty record does not cost a whole-file
    /// parse on every listing.
    private var emptyFiles: [String: Date] = [:]
    /// Sessions that gained an account since `drainDiscovered`.
    private var discovered: [String: String] = [:]
    /// When each unrecorded session last caused a read.
    private var lastMissRead: [String: Date] = [:]
    private var loaded = false

    public init(root: URL?) {
        self.root = root
    }

    /// The account Desktop recorded for `sessionId`, without touching the disk.
    public func recordedAccount(forSession sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        loadIfNeeded()
        return accounts[sessionId]
    }

    /// The account for a session Desktop's Claude Code wrote, reading any new
    /// records first when it is not known yet.
    public func accountForDesktopSession(_ sessionId: String?, now: Date = Date()) -> String? {
        guard let sessionId else { return nil }
        if let known = recordedAccount(forSession: sessionId) { return known }
        if let last = lastMissRead[sessionId],
           now.timeIntervalSince(last) < Self.missRefreshInterval { return nil }
        lastMissRead[sessionId] = now
        refresh()
        return accounts[sessionId]
    }

    /// Sessions that gained an account since the last call: what the caller
    /// re-stamps history for. On the first call that is every recorded session.
    public func drainDiscovered() -> [String: String] {
        loadIfNeeded()
        defer { discovered.removeAll() }
        return discovered
    }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        refresh()
    }

    /// Read every record not read before.
    public func refresh() {
        guard let root else { return }
        let fm = FileManager.default
        for user in Self.subdirectories(of: root, fm) {
            for org in Self.subdirectories(of: user, fm) {
                // The folder *is* the account id; anything not shaped like an
                // org id is some other kind of folder and says nothing.
                let accountId = org.lastPathComponent
                guard UUID(uuidString: accountId) != nil else { continue }
                let files = (try? fm.contentsOfDirectory(
                    at: org, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                for file in files where file.pathExtension == "json"
                    && file.lastPathComponent.hasPrefix("local_") {
                    let path = file.path
                    guard !readFiles.contains(path) else { continue }
                    let modified = (try? file.resourceValues(
                        forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if let seen = emptyFiles[path], seen == modified { continue }
                    guard let sessionId = Self.cliSessionId(in: file) else {
                        emptyFiles[path] = modified
                        continue
                    }
                    emptyFiles[path] = nil
                    readFiles.insert(path)
                    guard accounts[sessionId] != accountId else { continue }
                    accounts[sessionId] = accountId
                    discovered[sessionId] = accountId
                    lastMissRead[sessionId] = nil
                }
            }
        }
    }

    private static func subdirectories(of url: URL, _ fm: FileManager) -> [URL] {
        let entries = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    /// The transcript session a record describes. Nothing else in the file is
    /// kept.
    ///
    /// Looks in the first `headBytes` for the key, and takes the value only if
    /// it is a UUID, which every Claude Code session id is. A record written
    /// some other way (keys reordered, pretty-printed) is parsed whole instead.
    nonisolated static func cliSessionId(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        try? handle.close()
        let key = Data(#""cliSessionId":""#.utf8)
        if let found = head.range(of: key),
           let end = head[found.upperBound...].firstIndex(of: UInt8(ascii: "\"")) {
            let id = String(decoding: head[found.upperBound..<end], as: UTF8.self)
            if UUID(uuidString: id) != nil { return id }
        }
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["cliSessionId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Enough for the handful of short fields Desktop writes first.
    nonisolated static let headBytes = 4096
}
