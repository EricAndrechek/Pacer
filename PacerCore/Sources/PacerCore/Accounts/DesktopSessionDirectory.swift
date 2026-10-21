import Foundation

/// Which account each of Claude Desktop's Claude Code sessions ran under, read
/// from Desktop's own session records (#244), and where Desktop's agent mode
/// keeps the transcripts Pacer would otherwise never see (#250).
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
///     <data dir>/claude-code-sessions/<user>/<org>/local_<id>.json
///
/// whose `cliSessionId` is the transcript's `sessionId`, and whose folder is
/// the organization it ran under, which is exactly `Account.id`. That is a
/// per-session record made at the time. A trail inferred from Desktop's tokens
/// would be neither: Desktop can hold tokens for more than one org, and can
/// change org.
///
/// **Agent mode (Cowork) is the same layout under another folder,** except that
/// its transcripts are not in `~/.claude/projects` at all. Each session gets a
/// sandboxed Claude Code config of its own:
///
///     <data dir>/local-agent-mode-sessions/<user>/<org>/local_<id>.json
///     <data dir>/local-agent-mode-sessions/<user>/<org>/local_<id>/.claude/projects/…
///
/// (and the long-lived "ditto" agent the same way one level down, under
/// `agent/`). Those `.claude` folders are scan roots like a pinned profile:
/// each one belongs to exactly one org, the folder it sits in, so the root a
/// turn was read from decides its account without asking the trail. Every
/// turn they hold goes to one project, `agentProjectPath`, because the `cwd`
/// they record is a sandbox (`/sessions/<random-name>`, or an `outputs` folder
/// inside this one) rather than anything the user would recognise. A record
/// can be missing (one real session had none), which is why the root decides
/// rather than the record; the transcript's own file name supplies the
/// session id so a missing record leaves no gap in `accounts` either.
///
/// Only the org folder's name and the record's first few kilobytes are read.
/// A record's session and org never change, so each file is read once. And
/// only its first few kilobytes: records run to megabytes (one MCP server
/// configuration is 1.8 MB of a real one, 51 MB across 86 of them), and
/// parsing them whole cost the first snapshot after launch most of a second.
/// Desktop writes `cliSessionId` second or third, well inside that.
///
/// **One reader per process, shared by reference** (`shared`): the scan
/// attributes turns from it and the HTTP API binds sessions to it (#211), and
/// two copies would each list the folder and could disagree. Every member is
/// safe from any thread; a read that has to touch the disk does so under the
/// lock, which only ever guards a directory listing and any new small files.
public final class DesktopSessionDirectory: @unchecked Sendable {
    /// Where Desktop keeps its data, or nil when Pacer should not look (tests,
    /// which must never read the developer's own Desktop).
    public static var standardDataDirectory: URL? {
        guard !PacerPreferences.isTestProcess else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude", directoryHint: .isDirectory)
    }

    /// The process's reader of the standard install.
    public static let shared = DesktopSessionDirectory(
        dataDirectories: standardDataDirectory.map { [$0] } ?? [])

    /// The project every agent-mode turn is counted under. Not a path: the
    /// sandbox `cwd` those sessions record means nothing to the user, and it
    /// differs per session, so the turns would otherwise scatter across a
    /// dozen one-session "projects" named after random words.
    public static let agentProjectPath = "Claude Desktop (agent)"

    /// How long a session Desktop has no record for waits before its next
    /// turn reads the folder again. A record is written when a session starts,
    /// before its first turn, so a miss is either that race (gone on the next
    /// read) or a record Desktop has since deleted (gone for good). Either way
    /// one listing per session every few seconds is plenty, and costs a
    /// directory listing plus any new file.
    public static let missRefreshInterval: TimeInterval = 5

    /// The two folders of one data directory that hold session records.
    static let codeSessionsFolder = "claude-code-sessions"
    static let agentSessionsFolder = "local-agent-mode-sessions"

    private let dataDirectories: [URL]
    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    /// `sessionId` → `Account.id`, for every record read so far.
    private var accountsBySession: [String: String] = [:]
    /// Agent-mode `.claude` roots (by `ResolvedRoot.root.path`) → the org they
    /// belong to.
    private var agentRootAccounts: [String: String] = [:]
    /// The same roots, ready to scan, in a stable order.
    private var agentRootList: [ClaudePathResolver.ResolvedRoot] = []
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

    /// A reader of the given Desktop data directories (each the folder that
    /// holds `claude-code-sessions` and `local-agent-mode-sessions`).
    public init(dataDirectories: [URL]) {
        self.dataDirectories = dataDirectories.map(\.canonicalPathURL)
    }

    /// Every recorded session and its account, as of the last read.
    public var accounts: [String: String] {
        lock.withLock {
            loadIfNeededLocked()
            return accountsBySession
        }
    }

    /// The account Desktop recorded for `sessionId`, without reading anything
    /// new.
    public func recordedAccount(forSession sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        return lock.withLock {
            loadIfNeededLocked()
            return accountsBySession[sessionId]
        }
    }

    /// The account for a session Desktop's Claude Code wrote, reading any new
    /// records first when it is not known yet.
    public func accountForDesktopSession(_ sessionId: String?, now: Date = Date()) -> String? {
        guard let sessionId else { return nil }
        return lock.withLock {
            loadIfNeededLocked()
            if let known = accountsBySession[sessionId] { return known }
            if let last = lastMissRead[sessionId],
               now.timeIntervalSince(last) < Self.missRefreshInterval { return nil }
            lastMissRead[sessionId] = now
            refreshLocked()
            return accountsBySession[sessionId]
        }
    }

    /// The org an agent-mode root belongs to, for a turn read from it, or nil
    /// when `rootPath` is not one. Never reads the disk: the scan only reads
    /// roots this reader listed.
    public func account(forAgentRoot rootPath: String?) -> String? {
        guard let rootPath else { return nil }
        return lock.withLock {
            loadIfNeededLocked()
            return agentRootAccounts[rootPath]
        }
    }

    /// Every agent-mode root that has a `projects/` folder, as of the last
    /// read. Each carries `agentProjectPath` as its fixed project.
    public var agentRoots: [ClaudePathResolver.ResolvedRoot] {
        lock.withLock {
            loadIfNeededLocked()
            return agentRootList
        }
    }

    /// The agent-mode folders worth watching: every session root sits under
    /// one, including those of sessions that have not started yet.
    public var agentSessionDirectories: [URL] {
        let fm = FileManager.default
        return dataDirectories
            .map { $0.appendingPathComponent(Self.agentSessionsFolder) }
            .filter { Self.isDirectory($0, fm) }
    }

    /// Whether `path` lies under one of the agent-mode folders. String-only,
    /// no disk: the scan asks it about every hinted path that no root claims.
    public func isUnderAgentSessions(_ path: String) -> Bool {
        dataDirectories.contains {
            path.hasPrefix($0.appendingPathComponent(Self.agentSessionsFolder).path + "/")
        }
    }

    /// Sessions that gained an account since the last call: what the caller
    /// re-stamps history for. On the first call that is every recorded session.
    public func drainDiscovered() -> [String: String] {
        lock.withLock {
            loadIfNeededLocked()
            defer { discovered.removeAll() }
            return discovered
        }
    }

    /// Read every record not read before, and list the agent-mode roots again.
    public func refresh() {
        lock.withLock { refreshLocked() }
    }

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true
        refreshLocked()
    }

    private func refreshLocked() {
        let fm = FileManager.default
        var roots: [ClaudePathResolver.ResolvedRoot] = []
        for data in dataDirectories {
            for (org, folder) in Self.orgFolders(
                in: data.appendingPathComponent(Self.codeSessionsFolder), fm) {
                readRecordsLocked(in: folder, accountId: org, fm)
            }
            for (org, folder) in Self.orgFolders(
                in: data.appendingPathComponent(Self.agentSessionsFolder), fm,
                userMustBeUUID: true) {
                // The ordinary sessions, and the long-lived agent one level
                // down. Both keep a record beside a folder of the same name.
                for parent in [folder, folder.appendingPathComponent("agent")] {
                    readRecordsLocked(in: parent, accountId: org, fm)
                    roots += agentRootsLocked(in: parent, accountId: org, fm)
                }
            }
        }
        agentRootList = roots.sorted { $0.root.path < $1.root.path }
    }

    /// Every `local_*.json` record directly inside `folder`.
    private func readRecordsLocked(in folder: URL, accountId: String, _ fm: FileManager) {
        let files = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
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
            noteLocked(session: sessionId, accountId: accountId)
        }
    }

    /// The `.claude` roots of the agent-mode sessions directly inside
    /// `folder`, recording each one's org and the sessions its transcripts
    /// name. Their records are read separately; this covers a session whose
    /// record is gone.
    private func agentRootsLocked(
        in folder: URL, accountId: String, _ fm: FileManager
    ) -> [ClaudePathResolver.ResolvedRoot] {
        let sessions = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var out: [ClaudePathResolver.ResolvedRoot] = []
        for session in sessions where session.lastPathComponent.hasPrefix("local_") {
            let config = session.appendingPathComponent(".claude").canonicalPathURL
            let projects = config.appendingPathComponent("projects").canonicalPathURL
            guard Self.isDirectory(projects, fm) else { continue }
            let root = ClaudePathResolver.ResolvedRoot(
                root: config, projectsDirectory: projects,
                fixedProjectPath: Self.agentProjectPath)
            agentRootAccounts[config.path] = accountId
            out.append(root)
            // `<projects>/<project>/<session>.jsonl`: the file name is the
            // session id, which is what history is re-stamped by.
            for project in (try? fm.contentsOfDirectory(
                at: projects, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? [] {
                for transcript in (try? fm.contentsOfDirectory(
                    at: project, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                where transcript.pathExtension == "jsonl" {
                    let id = transcript.deletingPathExtension().lastPathComponent
                    guard UUID(uuidString: id) != nil else { continue }
                    noteLocked(session: id, accountId: accountId)
                }
            }
        }
        return out
    }

    private func noteLocked(session sessionId: String, accountId: String) {
        guard accountsBySession[sessionId] != accountId else { return }
        accountsBySession[sessionId] = accountId
        discovered[sessionId] = accountId
        lastMissRead[sessionId] = nil
    }

    /// `<root>/<user>/<org>` folders whose `<org>` is an org id. The folder
    /// *is* the account id; anything not shaped like one is some other kind
    /// of folder and says nothing. Agent mode keeps a `skills-plugin` folder
    /// at the user level whose children are org ids too, so there the user
    /// level must be an id as well.
    private static func orgFolders(
        in root: URL, _ fm: FileManager, userMustBeUUID: Bool = false
    ) -> [(String, URL)] {
        var out: [(String, URL)] = []
        for user in subdirectories(of: root, fm) {
            if userMustBeUUID, UUID(uuidString: user.lastPathComponent) == nil { continue }
            for org in subdirectories(of: user, fm) {
                let accountId = org.lastPathComponent
                guard UUID(uuidString: accountId) != nil else { continue }
                out.append((accountId, org))
            }
        }
        return out
    }

    private static func subdirectories(of url: URL, _ fm: FileManager) -> [URL] {
        let entries = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private static func isDirectory(_ url: URL, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The transcript session a record describes. Nothing else in the file is
    /// kept.
    ///
    /// Looks in the first `headBytes` for the key, and takes the value only if
    /// it is a UUID, which every Claude Code session id is. Whitespace around
    /// the colon is allowed: agent mode pretty-prints its records, and its
    /// "ditto" record is 4.6 MB, so falling through to a whole-file parse for
    /// want of a space would cost exactly what reading the head is for. A
    /// record written some other way (keys reordered) is parsed whole instead.
    static func cliSessionId(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        try? handle.close()
        if let id = stringValue(forKey: "cliSessionId", in: head), UUID(uuidString: id) != nil {
            return id
        }
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["cliSessionId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// The string value of `"key"` in a JSON fragment, without parsing it:
    /// `"key"`, optional whitespace, `:`, optional whitespace, then a quoted
    /// value with no escapes. nil for anything else, which sends the caller to
    /// a full parse.
    static func stringValue(forKey key: String, in data: Data) -> String? {
        guard let found = data.range(of: Data("\"\(key)\"".utf8)) else { return nil }
        var i = skipWhitespace(data, from: found.upperBound)
        guard i < data.endIndex, data[i] == UInt8(ascii: ":") else { return nil }
        i = skipWhitespace(data, from: data.index(after: i))
        guard i < data.endIndex, data[i] == UInt8(ascii: "\"") else { return nil }
        let start = data.index(after: i)
        guard let end = data[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    private static func skipWhitespace(_ data: Data, from index: Data.Index) -> Data.Index {
        var i = index
        while i < data.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(data[i]) { i = data.index(after: i) }
        return i
    }

    /// Enough for the handful of short fields Desktop writes first.
    static let headBytes = 4096
}
