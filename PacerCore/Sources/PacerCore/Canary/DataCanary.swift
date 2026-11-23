import Foundation
import SwiftData

/// The data canary (#353): once a day, compare Claude Code's own totals for each
/// project's latest session with Pacer's, and say so when they disagree.
///
/// **Cost.** Off the main actor, on a context of its own, about once a day.
/// Reads each config (~350 KB of JSON on a heavy install), then only the
/// handful of sessions saved since the last run: one `SessionInfo` fetch by id
/// (twice: once to drop what can't be judged before touching the disk, once
/// for the final numbers), a `stat` per project folder per session to find the
/// transcripts, one `JSONLFileCursor` fetch by path, then one streamed pass
/// over each judged session's transcripts (`TranscriptEvidenceReader`, at most
/// `Policy.maxTranscriptBytes`) and a `TokenSample` count per 500 of its
/// answered requests: counted by dedup key on its index, never fetched.
///
/// **What it reports** (`publish`): a local log line per judged session and a
/// summary; three health counters; on a mismatch, one `Telemetry.problem` per
/// token kind and ratio band per run, carrying only the kind, the band and the
/// Claude Code version. Never a count, a path, a project or a session id.
public enum DataCanary {

    public typealias Policy = SessionTotalsCanary.Policy
    public typealias SkipReason = SessionTotalsCanary.SkipReason

    public struct CheckedSession: Sendable, Equatable {
        public let sessionId: String
        public let ccVersion: String?
        public let comparison: SessionTotalsCanary.Comparison
        /// What the transcripts said: for the local log.
        public let evidence: SessionTotalsCanary.TranscriptEvidence

        public init(sessionId: String, ccVersion: String?,
                    comparison: SessionTotalsCanary.Comparison,
                    evidence: SessionTotalsCanary.TranscriptEvidence = .none) {
            self.sessionId = sessionId
            self.ccVersion = ccVersion
            self.comparison = comparison
            self.evidence = evidence
        }
    }

    public struct Report: Sendable, Equatable {
        /// Config files read.
        public var configFiles = 0
        /// Distinct sessions those configs named.
        public var sessions = 0
        /// Sessions judged on an earlier run, not judged again.
        public var alreadyJudged = 0
        public var checked: [CheckedSession] = []
        public var skipped: [SkipReason: Int] = [:]

        public var mismatched: [CheckedSession] { checked.filter { !$0.comparison.matched } }

        public init() {}
    }

    /// Where to look.
    public struct Sources: Sendable {
        /// Claude Code's global configs.
        public var configFiles: [URL]
        /// The data roots whose `projects/` hold the transcripts.
        public var roots: [ClaudePathResolver.ResolvedRoot]

        public init(configFiles: [URL], roots: [ClaudePathResolver.ResolvedRoot]) {
            self.configFiles = configFiles
            self.roots = roots
        }

        /// Every root the scan reads, the way `ScanCoordinator` finds them —
        /// the environment's (correctness rule 4), a switcher's session
        /// profiles, Claude Desktop's — and the config each one's Claude Code
        /// keeps its totals in.
        public static func machine(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            desktop: DesktopSessionDirectory? = .shared
        ) -> Sources {
            let resolver = ClaudePathResolver(environment: environment, homeDirectory: homeDirectory)
            let primary = (try? resolver.resolve()) ?? []
            let profiles = resolver.resolveAdditional(
                ExternalAccountDirectory.discoverProfileRoots(homeDirectory: homeDirectory))
            var seen = Set<String>()
            let roots = (primary + profiles + (desktop?.scanRoots ?? []))
                .filter { seen.insert($0.root.path).inserted }
            let configs = ClaudeSessionTotalsReader.configFiles(
                roots: roots, homeLayout: resolver.loginConfigRoot == nil,
                homeDirectory: homeDirectory)
            return Sources(configFiles: configs, roots: roots)
        }
    }

    // MARK: - Run

    /// Judge every session the configs name that was saved within the
    /// lookback and is not in `alreadyJudged`. Synchronous and blocking: call
    /// it off the main actor. `cursorPath` maps a transcript's path to the key
    /// its cursor is stored under; identity except for a probe run against a
    /// copied tree.
    public static func run(
        container: ModelContainer,
        sources: Sources,
        alreadyJudged: Set<String> = [],
        now: Date = Date(),
        policy: Policy = .standard,
        cursorPath: (String) -> String = { $0 }
    ) -> Report {
        var report = Report()
        report.configFiles = sources.configFiles.count

        // The latest save per session: two configs can name one session only
        // if a root was copied, and then the later save is the fuller one.
        var latest: [String: ClaudeSessionTotals] = [:]
        for url in sources.configFiles {
            for totals in ClaudeSessionTotalsReader.read(configAt: url) {
                if let held = latest[totals.sessionId],
                   (held.savedAt ?? .distantPast) >= (totals.savedAt ?? .distantPast) { continue }
                latest[totals.sessionId] = totals
            }
        }
        report.sessions = latest.count

        // Cheap filters first: nothing below this touches the store or disk
        // for a session saved weeks ago.
        let oldest = now.addingTimeInterval(-policy.lookback)
        var candidates: [ClaudeSessionTotals] = []
        for totals in latest.values {
            if alreadyJudged.contains(totals.sessionId) { report.alreadyJudged += 1; continue }
            guard let saved = totals.savedAt else { report.skipped[.noTiming, default: 0] += 1; continue }
            guard saved >= oldest else { report.skipped[.tooOld, default: 0] += 1; continue }
            candidates.append(totals)
        }
        guard !candidates.isEmpty else { return report }

        let context = ModelContext(container)
        // Span rules need only the rollup. Most span skips rule out only the
        // token comparison: the request check needs just the transcripts and
        // the store. These three rule out both: the counters are not final
        // yet, or the session is history.
        let first = sessionTotals(ids: candidates.map(\.sessionId), context: context)
        var survivors: [ClaudeSessionTotals] = []
        for claude in candidates {
            switch SessionTotalsCanary.spanSkip(
                claude: claude, pacer: first[claude.sessionId], now: now, policy: policy) {
            case let skip? where skip == .noTiming || skip == .tooOld || skip == .notFinished:
                report.skipped[skip, default: 0] += 1
            default:
                survivors.append(claude)
            }
        }
        guard !survivors.isEmpty else { return report }

        // Cursors before the final rollup read: a cursor at a file's end means
        // the rows it covered were saved, so a rollup read after it holds them.
        let files = locateTranscripts(sessionIds: Set(survivors.map(\.sessionId)), roots: sources.roots)
        let cursors = cursorOffsets(paths: files.values.flatMap { $0.map { cursorPath($0.path) } },
                                    context: context)
        let final = sessionTotals(ids: survivors.map(\.sessionId), context: context)

        for claude in survivors.sorted(by: { $0.sessionId < $1.sessionId }) {
            let sessionFiles = files[claude.sessionId] ?? []
            let pacer = final[claude.sessionId]
            if pacer == nil, sessionFiles.isEmpty {
                report.skipped[.noSession, default: 0] += 1
                continue
            }
            let state = transcriptState(sessionFiles, cursors: cursors, cursorPath: cursorPath)
            if let skip = SessionTotalsCanary.transcriptSkip(state, now: now, policy: policy) {
                report.skipped[skip, default: 0] += 1
                continue
            }
            // On the final rollup: rows can have arrived since the first read.
            let tokenSkip = SessionTotalsCanary.spanSkip(
                claude: claude, pacer: pacer, now: now, policy: policy)
            guard sessionFiles.reduce(Int64(0), { $0 + $1.size }) <= policy.maxTranscriptBytes else {
                report.skipped[.tooLarge, default: 0] += 1
                continue
            }
            let evidence = gatherEvidence(
                sessionId: claude.sessionId, files: sessionFiles, claude: claude,
                policy: policy, context: context)
            guard let comparison = SessionTotalsCanary.compare(
                claude: claude, pacer: pacer ?? .nothing(during: claude), evidence: evidence,
                judgeTokens: tokenSkip == nil, policy: policy) else {
                report.skipped[tokenSkip ?? .tooSmall, default: 0] += 1
                continue
            }
            report.checked.append(CheckedSession(
                sessionId: claude.sessionId, ccVersion: pacer?.ccVersion,
                comparison: comparison, evidence: evidence))
        }
        return report
    }

    /// The transcripts' evidence for one session, with the request check's
    /// answer from the store: how many answered requests have no row.
    static func gatherEvidence(
        sessionId: String, files: [TranscriptFile], claude: ClaudeSessionTotals,
        policy: Policy, context: ModelContext
    ) -> SessionTotalsCanary.TranscriptEvidence {
        // A negative duration in a hand-edited or corrupt config must not trap
        // the range; markers are then counted over the whole session.
        var window: ClosedRange<Date>?
        if let start = claude.startedAt, let saved = claude.savedAt, saved >= start {
            window = start.addingTimeInterval(-policy.clockSlack)...saved.addingTimeInterval(policy.clockSlack)
        }
        let scan = TranscriptEvidenceReader.read(
            files: files.map { URL(fileURLWithPath: $0.path) }, sessionId: sessionId, window: window)
        let keys = scan.answeredKeys
        return SessionTotalsCanary.TranscriptEvidence(
            answeredRequests: keys.count,
            missingRequests: keys.isEmpty ? 0 : missingRequests(keys: keys, context: context),
            unansweredRequests: scan.unanswered,
            compactions: scan.compactions,
            recaps: scan.recaps,
            desktop: scan.desktop)
    }

    // MARK: - Store reads

    private static func sessionTotals(
        ids: [String], context: ModelContext
    ) -> [String: SessionTotalsCanary.PacerTotals] {
        var out: [String: SessionTotalsCanary.PacerTotals] = [:]
        for chunk in chunked(ids) {
            let descriptor = FetchDescriptor<SessionInfo>(
                predicate: #Predicate { chunk.contains($0.sessionId) })
            for info in (try? context.fetch(descriptor)) ?? [] {
                out[info.sessionId] = SessionTotalsCanary.PacerTotals(info)
            }
        }
        return out
    }

    private static func cursorOffsets(paths: [String], context: ModelContext) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for chunk in chunked(paths) {
            let descriptor = FetchDescriptor<JSONLFileCursor>(
                predicate: #Predicate { chunk.contains($0.path) })
            for cursor in (try? context.fetch(descriptor)) ?? [] {
                out[cursor.path] = cursor.byteOffset
            }
        }
        return out
    }

    /// How many of `keys` (answered requests' dedup keys) have no row in the
    /// store, under any session. Counted, not fetched: an index lookup per
    /// batch, no rows materialised, so a session of 100k requests costs a few
    /// hundred counts once a day. nil when the store could not be asked, which
    /// leaves the request check unjudged rather than reporting every request
    /// lost. A key the store holds twice can hide one missing in its batch;
    /// the store repairs duplicates, so that is a transient blind spot.
    static func missingRequests(keys: Set<String>, context: ModelContext) -> Int? {
        var missing = 0
        for chunk in chunked(Array(keys)) {
            let wanted: [String?] = chunk
            let descriptor = FetchDescriptor<TokenSample>(
                predicate: #Predicate { wanted.contains($0.dedupKey) })
            guard let found = try? context.fetchCount(descriptor) else { return nil }
            missing += max(0, chunk.count - found)
        }
        return missing
    }

    /// Batches for an `IN (…)` predicate, well under SQLite's variable limit.
    private static func chunked(_ items: [String], size: Int = 500) -> [[String]] {
        stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }

    // MARK: - Transcripts on disk

    struct TranscriptFile: Equatable {
        let path: String
        let size: Int64
        let modified: Date
    }

    /// Each session's transcripts: `<projects>/<folder>/<id>.jsonl` and every
    /// `.jsonl` under `<projects>/<folder>/<id>/` (subagents, workflows), in
    /// any root and any project folder. Searched rather than derived from the
    /// project's path, because Claude Code files a session under the folder of
    /// the directory it started in, which a worktree or `cd` makes differ from
    /// the project the config files it under (3 of 17 on a real install).
    /// Paths are spelled the way `JSONLScanner` keys its cursors.
    static func locateTranscripts(
        sessionIds: Set<String>,
        roots: [ClaudePathResolver.ResolvedRoot]
    ) -> [String: [TranscriptFile]] {
        guard !sessionIds.isEmpty else { return [:] }
        let fm = FileManager.default
        var out: [String: [TranscriptFile]] = [:]
        var seenRoots = Set<String>()
        var seenFiles = Set<String>()
        func add(_ url: URL, to sessionId: String) {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { return }
            let path = url.standardizedFileURL.path
            guard seenFiles.insert(path).inserted else { return }
            out[sessionId, default: []].append(
                TranscriptFile(path: path, size: Int64(size), modified: modified))
        }
        for root in roots where seenRoots.insert(root.projectsDirectory.path).inserted {
            let folders = (try? fm.contentsOfDirectory(
                at: root.projectsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for folder in folders {
                for id in sessionIds {
                    add(folder.appendingPathComponent("\(id).jsonl"), to: id)
                    let nested = folder.appendingPathComponent(id, isDirectory: true)
                    var isDirectory: ObjCBool = false
                    guard fm.fileExists(atPath: nested.path, isDirectory: &isDirectory),
                          isDirectory.boolValue,
                          let walk = fm.enumerator(
                            at: nested,
                            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey,
                                                         .contentModificationDateKey],
                            options: [.skipsHiddenFiles])
                    else { continue }
                    while let next = walk.nextObject() as? URL { add(next, to: id) }
                }
            }
        }
        return out
    }

    static func transcriptState(
        _ files: [TranscriptFile],
        cursors: [String: Int64],
        cursorPath: (String) -> String
    ) -> SessionTotalsCanary.TranscriptState {
        var state = SessionTotalsCanary.TranscriptState(files: files.count)
        for file in files {
            if state.newestModification.map({ file.modified > $0 }) ?? true {
                state.newestModification = file.modified
            }
            guard let offset = cursors[cursorPath(file.path)] else {
                state.filesUnread += 1
                continue
            }
            // The scanner's cursor stops before a trailing partial line, so a
            // file is read to its end exactly when the offset is its size.
            if offset != file.size { state.filesBehind += 1 }
        }
        return state
    }
}
