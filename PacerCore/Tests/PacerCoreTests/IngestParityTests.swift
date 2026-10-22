import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The two ingest paths must leave the same rows (#334).
///
/// A full scan reads every transcript through the DuckDB bulk importer
/// (`ArchiveImporter`), and through the line parser (`JSONLScanner`) when the
/// import fails. On a real store they once disagreed: the line parser
/// "upgraded" rows the importer left alone. None of those were stored rows
/// left short — both paths gave every message the same tokens. They were new
/// messages whose first mid-stream copy the line parser inserted and then
/// upgraded in the same pass, keeping the partial copy's timestamp; the
/// importer inserted the finished copy. And where copies tied (replays into
/// subagent and resumed transcripts, one message logged twice), the line
/// parser kept the first it read, in file-mtime order, and the importer the
/// earliest. Both now keep each key's copy by one rule,
/// `ParsedUsageEntry.isKept`, and hand the persister that copy only.
///
/// The fixture is one transcript tree holding every shape behind that: a
/// streamed message, a stored mid-stream row a full scan must repair, finished
/// copies replayed into a subagent transcript and a resumed one, a message
/// logged twice, multi-call responses streamed and never finished, timestamps
/// whose text order is not their time order, a line with no dedup key, and a
/// copy under a hidden directory.
///
/// The line parser's half runs everywhere. The comparison runs where DuckDB
/// is linked: `bin/dev-ingest-parity.sh --fixtures` (CI's app job runs it).
@Suite("Ingest parity")
struct IngestParityTests {

    // MARK: - The fixture

    static let opus = "claude-opus-5-5"
    static let fable = "claude-fable-5-1"

    /// One assistant line. `iterations` is raw JSON for `usage.iterations`.
    static func line(
        _ id: String, _ ts: String, output: Int64, stop: String?,
        session: String = "s-main", sidechain: Bool = false, request: String? = nil,
        iterations: String? = nil
    ) -> String {
        let stopJSON: String = stop.map { "\"\($0)\"" } ?? "null"
        let requestId: String = request ?? "r-\(id)"
        let requestJSON: String = requestId.isEmpty ? "" : "\"requestId\":\"\(requestId)\","
        let iterationsJSON: String = iterations.map { ",\"iterations\":\($0)" } ?? ""
        // Typed pieces, joined: as one long `+` chain of interpolated
        // literals Xcode 16's type checker times out (macOS 15 CI).
        let parts: [String] = [
            "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\(requestJSON)",
            "\"sessionId\":\"\(session)\",\"isSidechain\":\(sidechain),\"cwd\":\"/tmp/acme\",",
            "\"version\":\"2.1.0\",\"message\":{\"id\":\"m-\(id)\",\"model\":\"\(opus)\",",
            "\"stop_reason\":\(stopJSON),\"usage\":{\"input_tokens\":10,\"output_tokens\":\(output),",
            "\"cache_read_input_tokens\":1000\(iterationsJSON)}}}",
        ]
        return parts.joined()
    }

    /// A two-call response: a Fable attempt, then the Opus fallback.
    static func calls(fable: Int64, opus: Int64) -> String {
        let first: String = "{\"type\":\"message\",\"model\":\"\(Self.fable)\",\"input_tokens\":40,"
            + "\"output_tokens\":\(fable),\"cache_read_input_tokens\":0}"
        let second: String = "{\"type\":\"fallback_message\",\"model\":\"\(Self.opus)\",\"input_tokens\":10,"
            + "\"output_tokens\":\(opus),\"cache_read_input_tokens\":1000}"
        return "[\(first),\(second)]"
    }

    /// The tree, under a fresh config root. File mtimes are set so the line
    /// scanner reads the copies in the order that used to pick the wrong one:
    /// the resumed transcript first, the subagent's last.
    static func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-parity-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("projects/-tmp-acme", isDirectory: true)
        let subagents = project.appendingPathComponent("s-main/subagents", isDirectory: true)
        let hidden = project.appendingPathComponent(".trash", isDirectory: true)
        for dir in [subagents, hidden] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let main: [String] = [
            // A: streamed — two mid-stream copies, then the finished one.
            line("A", "2026-03-01T10:00:00.000Z", output: 1, stop: nil),
            line("A", "2026-03-01T10:00:01.000Z", output: 1, stop: nil),
            line("A", "2026-03-01T10:00:02.000Z", output: 289, stop: "tool_use"),
            // B: stored mid-stream by an older build; this repairs it.
            line("B", "2026-03-01T10:05:00.000Z", output: 500, stop: "end_turn"),
            // C: one finished message logged twice; the subagent has it earlier.
            line("C", "2026-03-01T10:10:05.000Z", output: 40, stop: "end_turn"),
            line("C", "2026-03-01T10:10:09.000Z", output: 40, stop: "end_turn"),
            // D: streamed here; the subagent's finished copy carries the
            // partial copy's timestamp.
            line("D", "2026-03-01T10:20:00.000Z", output: 8, stop: nil),
            line("D", "2026-03-01T10:20:04.000Z", output: 584, stop: "tool_use"),
            // F: a two-call response that never finished. Each call keeps its
            // own best copy: the Fable call ties, so its earliest; the Opus
            // call grew, so the later line.
            line("F", "2026-03-01T10:30:00.000Z", output: 1, stop: nil,
                 iterations: calls(fable: 4200, opus: 1)),
            line("F", "2026-03-01T10:30:03.000Z", output: 50, stop: nil,
                 iterations: calls(fable: 4200, opus: 50)),
            // G: a streamed two-call response; only the finished line has calls.
            line("G", "2026-03-01T10:40:00.000Z", output: 1, stop: nil),
            line("G", "2026-03-01T10:40:05.000Z", output: 120, stop: "end_turn",
                 iterations: calls(fable: 3000, opus: 120)),
            // K: no requestId, so no dedup key: kept as it is, by both.
            line("K", "2026-03-01T10:50:00.000Z", output: 5, stop: "end_turn", request: ""),
            // I, J: the resumed copy is earlier, though its text sorts later.
            line("I", "2026-03-01T11:00:00.500Z", output: 10, stop: "end_turn"),
            line("J", "2026-03-01T11:10:00.000Z", output: 12, stop: "end_turn"),
            // H: a fuller copy sits under a hidden directory, which the line
            // scanner never walks.
            line("H", "2026-03-01T11:20:00.000Z", output: 30, stop: "end_turn"),
            // E: replayed verbatim into the resumed transcript, but for its
            // session: everything ties but the file.
            line("E", "2026-03-01T11:30:00.000Z", output: 77, stop: "end_turn"),
        ]
        let resumed: [String] = [
            line("I", "2026-03-01T11:00:00Z", output: 10, stop: "end_turn", session: "s-resumed"),
            line("J", "2026-03-01T12:09:00.000+02:00", output: 12, stop: "end_turn", session: "s-resumed"),
            line("E", "2026-03-01T11:30:00.000Z", output: 77, stop: "end_turn", session: "s-resumed"),
        ]
        let subagent: [String] = [
            line("C", "2026-03-01T10:10:01.000Z", output: 40, stop: "end_turn", sidechain: true),
            line("D", "2026-03-01T10:20:00.000Z", output: 584, stop: "tool_use", sidechain: true),
        ]
        let trash = [line("H", "2026-03-01T11:20:00.000Z", output: 999, stop: "end_turn")]

        let now = Date()
        let files: [(URL, [String], TimeInterval)] = [
            (project.appendingPathComponent("resumed.jsonl"), resumed, -3 * 3600),
            (project.appendingPathComponent("main.jsonl"), main, -2 * 3600),
            (subagents.appendingPathComponent("agent-1.jsonl"), subagent, -3600),
            (hidden.appendingPathComponent("old.jsonl"), trash, 0),
        ]
        for (url, lines, age) in files {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(age)],
                                                  ofItemAtPath: url.path)
        }
        return root
    }

    /// The store as an older build left it: B's mid-stream copy, and a turn
    /// whose transcript has since been rotated away.
    @ScanActor
    static func seed(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        let persister = try SamplePersister(context: context)
        let stored: [String] = [
            line("B", "2026-03-01T10:04:58.000Z", output: 7, stop: nil),
            line("Z", "2026-02-27T09:00:00.000Z", output: 64, stop: "end_turn"),
        ]
        for raw in stored {
            for entry in JSONLLineParser.parseAll(line: Data(raw.utf8)) { try persister.insert(entry) }
        }
        try persister.flush()
        try context.save()
    }

    // MARK: - Running a path

    /// Every stored field of a sample.
    struct Row: Hashable, Comparable, CustomStringConvertible {
        let fields: [String]
        static func < (a: Row, b: Row) -> Bool { a.fields.lexicographicallyPrecedes(b.fields) }
        var description: String { fields.joined(separator: " ") }
        var key: String { fields[0] }
        var sampledAt: String { fields[1] }
        var model: String { fields[3] }
        var output: Int64 { Int64(fields[6]) ?? -1 }
        var session: String { fields[11] }
    }

    struct Outcome {
        let rows: [Row]
        let stats: SamplePersister.Stats
        /// Daily and hourly rollup tokens, by bucket.
        let rollups: [String]
    }

    /// A full scan of `root` into a seeded store, through the bulk importer
    /// if one is given and through the line parser otherwise.
    @MainActor
    static func ingest(_ root: URL, importer: BulkTranscriptImporter?) async throws -> Outcome {
        let container = try PacerStore.makeInMemoryContainer()
        try await seed(container)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false,
                                 bulkImporter: importer, desktopSessions: nil),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]),
            homeDirectory: home)
        let report = try await coordinator.runOnce()
        #expect(report.wasFullScan)

        let context = ModelContext(container)
        var rows: [Row] = []
        for s in try context.fetch(FetchDescriptor<TokenSample>()) {
            let stamp: String = String(s.sampledAt.timeIntervalSince1970)
            var f: [String] = [s.dedupKey ?? "-", stamp, s.date, s.model, String(s.localHour)]
            f += [String(s.inputTokens), String(s.outputTokens), String(s.cacheReadTokens)]
            f += [String(s.cacheCreation5mTokens), String(s.cacheCreation1hTokens)]
            f += [s.sourceCostUSD.map { String($0) } ?? "-"]
            f += [s.sessionId ?? "-", s.projectPath ?? "-", s.originalProjectPath ?? "-"]
            f += [s.ccVersion ?? "-", s.accountId ?? "-", s.speed ?? "-", s.inferenceGeo ?? "-"]
            rows.append(Row(fields: f))
        }
        var rollups: [String] = []
        for r in try context.fetch(FetchDescriptor<DailyAggregate>()) {
            let t: [Int64] = [r.inputTokens, r.outputTokens, r.cacheReadTokens,
                              r.cacheCreation5mTokens, r.cacheCreation1hTokens]
            rollups.append("daily \(r.dateModelKey) \(t)")
        }
        for r in try context.fetch(FetchDescriptor<HourlyAggregate>()) {
            let t: [Int64] = [r.inputTokens, r.outputTokens, r.cacheReadTokens,
                              r.cacheCreation5mTokens, r.cacheCreation1hTokens]
            rollups.append("hourly \(r.dateHourModelKey) \(t)")
        }
        return Outcome(rows: rows.sorted(), stats: report.persisterStats, rollups: rollups.sorted())
    }

    static func instant(_ iso: String) -> Date {
        JSONLLineParser.parseTimestampForImport(iso)!
    }

    // MARK: - The line parser keeps the right copy of every shape

    /// What both paths must leave. Checked against the line parser here, on
    /// every platform, so the comparison below can't pass by both being wrong.
    static func expectTheRightCopies(_ outcome: Outcome) throws {
        var byKey: [String: Row] = [:]
        for row in outcome.rows where row.key != "-" { byKey[row.key] = row }
        func row(_ key: String) throws -> Row { try #require(byKey[key], "no row for \(key)") }
        func at(_ iso: String) -> String { String(instant(iso).timeIntervalSince1970) }

        // Streamed: the finished copy, inserted as itself — not the first
        // mid-stream copy upgraded in place.
        #expect(try row("m-A:r-A").output == 289)
        #expect(try row("m-A:r-A").sampledAt == at("2026-03-01T10:00:02.000Z"))
        // The stored mid-stream row is repaired; its own timestamp stays.
        #expect(try row("m-B:r-B").output == 500)
        #expect(try row("m-B:r-B").sampledAt == at("2026-03-01T10:04:58.000Z"))
        // Ties go to the earliest copy, wherever it sits.
        #expect(try row("m-C:r-C").sampledAt == at("2026-03-01T10:10:01.000Z"))
        #expect(try row("m-D:r-D").output == 584)
        #expect(try row("m-D:r-D").sampledAt == at("2026-03-01T10:20:00.000Z"))
        // Each call of a multi-call response is ranked on its own.
        #expect(try row("m-F:r-F#0").model == fable)
        #expect(try row("m-F:r-F#0").output == 4200)
        #expect(try row("m-F:r-F#0").sampledAt == at("2026-03-01T10:30:00.000Z"))
        #expect(try row("m-F:r-F").output == 50)
        #expect(try row("m-G:r-G#0").output == 3000)
        #expect(try row("m-G:r-G").output == 120)
        // Earliest by instant, not by text.
        #expect(try row("m-I:r-I").session == "s-resumed")
        #expect(try row("m-J:r-J").session == "s-resumed")
        // Hidden directories are not read.
        #expect(try row("m-H:r-H").output == 30)
        // A full tie goes to the file whose path sorts first.
        #expect(try row("m-E:r-E").session == "s-main")
        // A turn whose transcript is gone is left as it was.
        #expect(try row("m-Z:r-Z").output == 64)
        #expect(outcome.rows.filter { $0.key == "-" }.map(\.output) == [5])

        // Two seeded rows, twelve new (A, C, D, E, F#0, F, G#0, G, H, I, J,
        // and the keyless K), one repair (B), nothing else touched.
        #expect(outcome.rows.count == 14)
        #expect(outcome.stats.inserted == 12)
        #expect(outcome.stats.upgradedFromPartial == 1)
        #expect(outcome.stats.patchedPricingDetail == 0)
    }

    @Test func theLineParserKeepsTheRightCopyOfEveryShape() async throws {
        let root = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.expectTheRightCopies(try await Self.ingest(root, importer: nil))
    }

    /// The order the line scanner reads copies in decides nothing: the same
    /// copies, read in reverse, keep the same one.
    @Test func theKeptCopyDoesNotDependOnReadOrder() throws {
        let copies: [(String, String)] = [
            ("/p/b.jsonl", Self.line("C", "2026-03-01T10:10:05.000Z", output: 40, stop: "end_turn")),
            ("/p/a.jsonl", Self.line("C", "2026-03-01T10:10:09.000Z", output: 40, stop: "end_turn")),
            ("/p/c.jsonl", Self.line("C", "2026-03-01T10:10:01.000Z", output: 40, stop: "end_turn",
                                     session: "s-sub")),
            ("/p/a.jsonl", Self.line("C", "2026-03-01T10:10:00.000Z", output: 3, stop: nil)),
            ("/p/d.jsonl", Self.line("C", "2026-03-01T10:10:01.000Z", output: 40, stop: "end_turn",
                                     session: "s-other")),
        ]
        func keep(_ order: [(String, String)]) throws -> ParsedUsageEntry {
            var kept = CopySelection()
            for (file, raw) in order {
                kept.offer(try #require(JSONLLineParser.parse(line: raw)), from: file)
            }
            #expect(kept.entries.count == 1)
            #expect(kept.repeats == order.count - 1)
            return try #require(kept.entries.first)
        }
        let forward = try keep(copies)
        let backward = try keep(copies.reversed())
        #expect(forward == backward)
        // Finished, then earliest, then the first path: c.jsonl's copy.
        #expect(forward.sessionId == "s-sub")
    }

    #if canImport(CDuckDB)
    /// Both paths, the same tree, the same seeded store: identical rows,
    /// identical counts, identical rollups.
    @Test func bothPathsLeaveIdenticalRows() async throws {
        let root = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let line = try await Self.ingest(root, importer: nil)
        let bulk = try await Self.ingest(root, importer: ArchiveImporter())

        try Self.expectTheRightCopies(bulk)
        #expect(bulk.rows == line.rows)
        for (l, b) in zip(line.rows, bulk.rows) where l != b {
            Issue.record("line: \(l)\nbulk: \(b)")
        }
        #expect(bulk.stats.inserted == line.stats.inserted)
        #expect(bulk.stats.upgradedFromPartial == line.stats.upgradedFromPartial)
        #expect(bulk.stats.patchedPricingDetail == line.stats.patchedPricingDetail)
        #expect(bulk.stats.skippedAsDuplicate == line.stats.skippedAsDuplicate)
        #expect(bulk.rollups == line.rollups)
    }
    #endif
}
