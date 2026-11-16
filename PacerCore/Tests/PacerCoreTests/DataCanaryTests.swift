import Foundation
import SwiftData
import Testing
@testable import PacerCore

// The data canary (#353): Claude Code's own session totals against Pacer's.
// Every fixture here is fictional: the Acme and Globex projects of a user
// called "someone".

private typealias Canary = SessionTotalsCanary
private typealias Kind = SessionTotalsCanary.TokenKind

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let start = now.addingTimeInterval(-3 * 3600)
private let saved = now.addingTimeInterval(-3600)

/// A healthy session's two sides: Claude Code saw 100k main-model output plus
/// its own Haiku housekeeping, and more cache reads and input than any
/// transcript holds, as real sessions do.
private func claude(
    output: Int64 = 100_000, haikuOutput: Int64 = 9_000,
    input: Int64 = 50_000, cacheRead: Int64 = 3_000_000, cacheCreation: Int64 = 200_000,
    startedAt: Date? = start, duration: TimeInterval? = saved.timeIntervalSince(start),
    sessionId: String = "11111111-aaaa-4bbb-8ccc-000000000001"
) -> ClaudeSessionTotals {
    ClaudeSessionTotals(
        sessionId: sessionId,
        inputTokens: input,
        outputTokens: output + haikuOutput,
        cacheReadTokens: cacheRead,
        cacheCreationTokens: cacheCreation,
        outputTokensByModel: ["claude-opus-5-5[1m]": output * 3 / 4,
                              "claude-sonnet-5-5": output - output * 3 / 4,
                              "claude-haiku-5-5": haikuOutput],
        startedAt: startedAt,
        duration: duration)
}

private func pacer(
    output: Int64 = 100_000, input: Int64 = 500, cacheRead: Int64 = 2_400_000,
    cache5m: Int64 = 150_000, cache1h: Int64 = 50_000,
    firstSeenAt: Date = start.addingTimeInterval(60),
    lastSeenAt: Date = saved.addingTimeInterval(-60),
    ccVersion: String? = "2.1.323"
) -> Canary.PacerTotals {
    Canary.PacerTotals(
        inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
        cacheWriteTokens: cache5m + cache1h, firstSeenAt: firstSeenAt,
        lastSeenAt: lastSeenAt, ccVersion: ccVersion)
}

private let settled = Canary.TranscriptState(
    files: 3, newestModification: saved.addingTimeInterval(-30), filesBehind: 0, filesUnread: 0)

// MARK: - The comparison

@Suite("Data canary: the comparison")
struct DataCanaryComparisonTests {

    @Test("matching totals pass, Claude Code's own extra calls notwithstanding")
    func match() throws {
        let result = try #require(Canary.compare(claude: claude(), pacer: pacer()))
        #expect(result.matched)
        #expect(result.ratios[.output] == 1.0)
        // Its Haiku titles, uncached input and re-read cache are not Pacer's.
        #expect(result.ratios[.input]! > 1)
        #expect(result.ratios[.cacheRead]! > 1)
    }

    @Test("lost subagent output, the 09-23 defect, is an output mismatch above 1.1")
    func underCount() throws {
        // Claude Code counted 2.3× what the transcripts held.
        let result = try #require(Canary.compare(claude: claude(output: 230_000), pacer: pacer()))
        #expect(result.mismatches == [Canary.Mismatch(kind: .output, ratio: 2.3)])
        #expect(result.mismatches.first?.band == ">1.1")
    }

    @Test("a mild under-count lands in its own band")
    func mildUnderCount() throws {
        let result = try #require(Canary.compare(claude: claude(output: 105_000), pacer: pacer()))
        #expect(result.mismatches.map(\.kind) == [.output])
        #expect(result.mismatches.first?.band == "1.02-1.1")
    }

    @Test("within the tolerance is a match, either way")
    func withinTolerance() throws {
        #expect(try #require(Canary.compare(claude: claude(output: 101_900), pacer: pacer())).matched)
        // Pacer 1.5% above Claude Code's total output, Haiku included.
        #expect(try #require(Canary.compare(
            claude: claude(output: 100_000, haikuOutput: 0), pacer: pacer(output: 101_500))).matched)
    }

    @Test("Pacer holding more output than Claude Code counted at all is a mismatch below 1")
    func overCount() throws {
        let result = try #require(Canary.compare(
            claude: claude(output: 100_000, haikuOutput: 1_000), pacer: pacer(output: 160_000)))
        #expect(result.mismatches.map(\.kind) == [.output])
        let ratio = try #require(result.mismatches.first?.ratio)
        #expect(abs(ratio - 101_000.0 / 160_000.0) < 1e-12)
        #expect(result.mismatches.first?.band == "0.5-0.9")
    }

    @Test("Pacer's own Haiku subagents do not read as an over-count")
    func pacerHaikuSubagents() throws {
        // Explore agents on Haiku: 20k of Pacer's output is Haiku, and Claude
        // Code's Haiku total (housekeeping plus those agents) is larger still.
        let result = try #require(Canary.compare(
            claude: claude(output: 100_000, haikuOutput: 60_000), pacer: pacer(output: 120_000)))
        #expect(result.matched)
    }

    @Test("Claude Code's Haiku housekeeping never reads as an under-count")
    func haikuExcluded() throws {
        let result = try #require(Canary.compare(
            claude: claude(haikuOutput: 2_000_000), pacer: pacer()))
        #expect(result.matched)
    }

    @Test("every other kind is judged below 1 only, per kind")
    func perKind() throws {
        // Pacer holds more cache writes than Claude Code wrote: counted twice.
        let doubled = try #require(Canary.compare(
            claude: claude(cacheCreation: 200_000), pacer: pacer(cache5m: 300_000, cache1h: 100_000)))
        #expect(doubled.mismatches == [Canary.Mismatch(kind: .cacheWrite, ratio: 0.5)])
        #expect(doubled.mismatches.first?.band == "0.5-0.9")

        // The 5-minute and 1-hour writes are summed against the one number.
        let split = try #require(Canary.compare(
            claude: claude(cacheCreation: 200_000), pacer: pacer(cache5m: 20_000, cache1h: 180_000)))
        #expect(split.ratios[.cacheWrite] == 1.0)
        #expect(split.matched)

        let reads = try #require(Canary.compare(
            claude: claude(cacheRead: 1_000_000), pacer: pacer(cacheRead: 2_400_000)))
        #expect(reads.mismatches.map(\.kind) == [.cacheRead])
        #expect(reads.mismatches.first?.band == "<0.5")

        let input = try #require(Canary.compare(claude: claude(input: 400), pacer: pacer(input: 500)))
        #expect(input.mismatches.map(\.kind) == [.input])

        // Above 1 is Claude Code's own calls, for these three.
        let above = try #require(Canary.compare(
            claude: claude(input: 5_000_000, cacheRead: 9_000_000, cacheCreation: 400_000), pacer: pacer()))
        #expect(above.matched)
    }

    @Test("below the minimum size, on both sides, a session is not judged")
    func belowMinimum() {
        #expect(Canary.compare(claude: claude(output: 19_000), pacer: pacer(output: 19_000)) == nil)
        // Either side reaching it is enough: a session Pacer nearly missed
        // whole is exactly the one to judge.
        #expect(Canary.compare(claude: claude(output: 19_000), pacer: pacer(output: 20_000)) != nil)
        #expect(Canary.compare(claude: claude(output: 25_000), pacer: pacer(output: 0)) != nil)
    }

    @Test("a session Pacer has no output for is infinitely under-counted")
    func nothingRecorded() throws {
        let result = try #require(Canary.compare(claude: claude(output: 50_000), pacer: pacer(output: 0)))
        #expect(result.mismatches.map(\.kind) == [.output])
        #expect(result.mismatches.first?.ratio == .infinity)
        #expect(result.mismatches.first?.band == ">1.1")
    }

    @Test("ratio bands")
    func bands() {
        #expect(Canary.ratioBand(0.2) == "<0.5")
        #expect(Canary.ratioBand(0.5) == "0.5-0.9")
        #expect(Canary.ratioBand(0.95) == "0.9-0.98")
        #expect(Canary.ratioBand(0.98) == "0.98-1.02")
        #expect(Canary.ratioBand(1.02) == "0.98-1.02")
        #expect(Canary.ratioBand(1.05) == "1.02-1.1")
        #expect(Canary.ratioBand(1.1) == "1.02-1.1")
        #expect(Canary.ratioBand(2.3) == ">1.1")
        #expect(Canary.ratioBand(.infinity) == ">1.1")
        #expect(Canary.ratio(0, 0) == 1)
    }
}

// MARK: - Finished and ingested

@Suite("Data canary: finished and ingested")
struct DataCanaryEligibilityTests {

    private func skip(
        _ c: ClaudeSessionTotals = claude(), _ p: Canary.PacerTotals? = pacer(),
        _ t: Canary.TranscriptState = settled
    ) -> Canary.SkipReason? {
        Canary.eligibility(claude: c, pacer: p, transcripts: t, now: now)
    }

    @Test("a session saved an hour ago, read to its end, inside the process, is judged")
    func eligible() {
        #expect(skip() == nil)
    }

    @Test("counters without a start or duration cannot be placed")
    func noTiming() {
        #expect(skip(claude(startedAt: nil)) == .noTiming)
        #expect(skip(claude(duration: nil)) == .noTiming)
    }

    @Test("a session Pacer has no rows for is not judged")
    func noSession() {
        #expect(skip(claude(), nil) == .noSession)
    }

    @Test("sessions that began or were saved before the lookback are history")
    func tooOld() {
        let weekAgo = now.addingTimeInterval(-8 * 86_400)
        #expect(skip(claude(), pacer(firstSeenAt: weekAgo)) == .tooOld)
        #expect(skip(claude(startedAt: weekAgo, duration: 3600),
                     pacer(firstSeenAt: weekAgo, lastSeenAt: weekAgo)) == .tooOld)
    }

    @Test("a resumed session whose first turn predates the process is not like for like")
    func beganBeforeProcess() {
        #expect(skip(claude(), pacer(firstSeenAt: start.addingTimeInterval(-3600))) == .beganBeforeProcess)
        // A minute's clock difference is not a resume.
        #expect(skip(claude(), pacer(firstSeenAt: start.addingTimeInterval(-60))) == nil)
    }

    @Test("a process that ran other work before the session holds that work too")
    func ranOtherWorkFirst() {
        #expect(skip(claude(), pacer(firstSeenAt: start.addingTimeInterval(45 * 60))) == .ranOtherWorkFirst)
        #expect(skip(claude(), pacer(firstSeenAt: start.addingTimeInterval(20 * 60))) == nil)
    }

    @Test("turns after the save are not in the counters")
    func turnsAfterSave() {
        #expect(skip(claude(), pacer(lastSeenAt: saved.addingTimeInterval(10 * 60))) == .turnsAfterSave)
    }

    @Test("not finished: saved, or a transcript written, within the quiet period")
    func notFinished() {
        let recent = now.addingTimeInterval(-5 * 60)
        #expect(skip(claude(duration: recent.timeIntervalSince(start)),
                     pacer(lastSeenAt: recent)) == .notFinished)
        var touched = settled
        touched.newestModification = recent
        #expect(skip(claude(), pacer(), touched) == .notFinished)
    }

    @Test("not ingested: a transcript Pacer has not read to its end, or at all")
    func notIngested() {
        var behind = settled
        behind.filesBehind = 1
        #expect(skip(claude(), pacer(), behind) == .notIngested)
        var unread = settled
        unread.filesUnread = 1
        #expect(skip(claude(), pacer(), unread) == .notIngested)
    }

    @Test("no transcript on disk: ingestion cannot be confirmed")
    func noTranscript() {
        #expect(skip(claude(), pacer(), Canary.TranscriptState()) == .noTranscript)
    }
}

// MARK: - Reading Claude Code's config

@Suite("Data canary: reading .claude.json")
struct DataCanaryConfigTests {

    static let fixture = """
    {
      "numStartups": 12,
      "oauthAccount": { "organizationUuid": "org-acme" },
      "projects": {
        "/Users/someone/Code/acme": {
          "allowedTools": [],
          "lastCost": 4.25,
          "lastSessionId": "11111111-aaaa-4bbb-8ccc-000000000001",
          "lastTotalInputTokens": 50000,
          "lastTotalOutputTokens": 109000,
          "lastTotalCacheCreationInputTokens": 200000,
          "lastTotalCacheReadInputTokens": 3000000,
          "lastTotalWebSearchRequests": 0,
          "lastModelUsage": {
            "claude-opus-5-5[1m]": { "inputTokens": 400, "outputTokens": 75000,
                                     "cacheReadInputTokens": 2500000,
                                     "cacheCreationInputTokens": 180000,
                                     "webSearchRequests": 0, "costUSD": 3.9 },
            "claude-sonnet-5-5": { "inputTokens": 100, "outputTokens": 25000,
                                   "cacheReadInputTokens": 500000,
                                   "cacheCreationInputTokens": 20000,
                                   "webSearchRequests": 0, "costUSD": 0.3 },
            "claude-haiku-5-5": { "inputTokens": 49500, "outputTokens": 9000,
                                  "cacheReadInputTokens": 0,
                                  "cacheCreationInputTokens": 0,
                                  "webSearchRequests": 0, "costUSD": 0.05 }
          },
          "lastStartTime": 1799989200000,
          "lastDuration": 7200000,
          "lastGracefulShutdown": true,
          "lastVersionBase": "2.1.323"
        },
        "/Users/someone/Code/globex": {
          "allowedTools": [],
          "hasTrustDialogAccepted": true
        },
        "/Users/someone/Code/acme-tools": {
          "lastSessionId": "22222222-aaaa-4bbb-8ccc-000000000002",
          "lastTotalInputTokens": 10,
          "lastTotalOutputTokens": 20,
          "lastTotalCacheCreationInputTokens": 30,
          "lastTotalCacheReadInputTokens": 40
        }
      }
    }
    """

    @Test("each project's latest session, with its per-model output and its span")
    func parse() throws {
        let parsed = ClaudeSessionTotalsReader.parse(Data(Self.fixture.utf8))
            .sorted { $0.sessionId < $1.sessionId }
        #expect(parsed.count == 2)
        let acme = try #require(parsed.first)
        #expect(acme.sessionId == "11111111-aaaa-4bbb-8ccc-000000000001")
        #expect(acme.inputTokens == 50_000)
        #expect(acme.outputTokens == 109_000)
        #expect(acme.cacheReadTokens == 3_000_000)
        #expect(acme.cacheCreationTokens == 200_000)
        #expect(acme.outputTokensByModel["claude-opus-5-5[1m]"] == 75_000)
        #expect(acme.outputTokensExcludingSmallModel == 100_000)
        #expect(acme.startedAt == Date(timeIntervalSince1970: 1_799_989_200))
        #expect(acme.duration == 7200)
        #expect(acme.savedAt == Date(timeIntervalSince1970: 1_799_996_400))

        // No model usage and no timing: still read, judged as `noTiming` later.
        let tools = parsed[1]
        #expect(tools.outputTokensByModel.isEmpty)
        #expect(tools.outputTokensExcludingSmallModel == 20)
        #expect(tools.startedAt == nil && tools.savedAt == nil)
    }

    @Test("not JSON, or no projects, gives nothing")
    func garbage() {
        #expect(ClaudeSessionTotalsReader.parse(Data("{\"projects\": ".utf8)).isEmpty)
        #expect(ClaudeSessionTotalsReader.parse(Data("{}".utf8)).isEmpty)
        #expect(ClaudeSessionTotalsReader.parse(Data("[]".utf8)).isEmpty)
    }

    @Test("the home config for the home layout, and each pinned root's own")
    func configFiles() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let dotClaude = home.appendingPathComponent(".claude")
        let profile = home.appendingPathComponent(".claude-swap-backup/sessions/acme")
        for dir in [dotClaude, profile] {
            try fm.createDirectory(at: dir.appendingPathComponent("projects"),
                                   withIntermediateDirectories: true)
        }
        try Data(Self.fixture.utf8).write(to: home.appendingPathComponent(".claude.json"))
        try Data(Self.fixture.utf8).write(to: profile.appendingPathComponent(".claude.json"))

        let resolver = ClaudePathResolver(environment: [:], homeDirectory: home)
        let roots = try resolver.resolve() + resolver.resolveAdditional([profile])
        let files = ClaudeSessionTotalsReader.configFiles(
            roots: roots, homeLayout: true, homeDirectory: home)
        #expect(files.map(\.lastPathComponent) == [".claude.json", ".claude.json"])
        #expect(files.map { $0.deletingLastPathComponent().canonicalPathURL } ==
                [home.canonicalPathURL, profile.canonicalPathURL])

        // `CLAUDE_CONFIG_DIR` is exclusive: the home config is not one of them.
        let pinned = ClaudeSessionTotalsReader.configFiles(
            roots: resolver.resolveAdditional([profile]), homeLayout: false, homeDirectory: home)
        #expect(pinned.map { $0.deletingLastPathComponent().canonicalPathURL } == [profile.canonicalPathURL])
    }
}

// MARK: - A whole run

@Suite("Data canary: a run against a store and transcripts", .serialized)
struct DataCanaryRunTests {

    private struct Fixture {
        let home: URL
        let projects: URL
        let container: ModelContainer
        var sources: DataCanary.Sources {
            let resolver = ClaudePathResolver(environment: [:], homeDirectory: home)
            let roots = (try? resolver.resolve()) ?? []
            return DataCanary.Sources(
                configFiles: ClaudeSessionTotalsReader.configFiles(
                    roots: roots, homeLayout: true, homeDirectory: home),
                roots: roots)
        }
    }

    private static let healthy = "11111111-aaaa-4bbb-8ccc-000000000001"
    private static let lossy = "33333333-aaaa-4bbb-8ccc-000000000003"
    private static let unread = "44444444-aaaa-4bbb-8ccc-000000000004"

    /// Three finished sessions: one healthy, one whose subagent output went
    /// missing (filed under a worktree's folder, not the project's), one with
    /// a subagent transcript Pacer has not read to its end.
    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let home = try makeTempDirectory()
        let projects = home.appendingPathComponent(".claude/projects")
        let acme = projects.appendingPathComponent("-Users-someone-Code-acme")
        let worktree = projects.appendingPathComponent("-Users-someone-Code-acme--worktrees-feature")
        try fm.createDirectory(at: acme, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree.appendingPathComponent("\(Self.lossy)/subagents"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: acme.appendingPathComponent("\(Self.unread)/subagents"),
                               withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: SessionInfo.self, JSONLFileCursor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        func transcript(_ url: URL, bytes: Int, cursor: Int64?) throws {
            try Data(repeating: 0x0a, count: bytes).write(to: url)
            try fm.setAttributes([.modificationDate: saved.addingTimeInterval(-120)],
                                 ofItemAtPath: url.path)
            if let cursor {
                context.insert(JSONLFileCursor(path: url.standardizedFileURL.path,
                                               byteOffset: cursor, lastSeenMtime: saved))
            }
        }
        try transcript(acme.appendingPathComponent("\(Self.healthy).jsonl"), bytes: 400, cursor: 400)
        try transcript(worktree.appendingPathComponent("\(Self.lossy).jsonl"), bytes: 300, cursor: 300)
        try transcript(worktree.appendingPathComponent("\(Self.lossy)/subagents/agent-a1.jsonl"),
                       bytes: 200, cursor: 200)
        try transcript(acme.appendingPathComponent("\(Self.unread).jsonl"), bytes: 300, cursor: 300)
        try transcript(acme.appendingPathComponent("\(Self.unread)/subagents/agent-b2.jsonl"),
                       bytes: 200, cursor: 120)

        for id in [Self.healthy, Self.lossy, Self.unread] {
            let p = pacer()
            context.insert(SessionInfo(
                sessionId: id, firstSeenAt: p.firstSeenAt, lastSeenAt: p.lastSeenAt,
                projectPath: "/Users/someone/Code/acme", ccVersion: "2.1.323",
                cumulativeInputTokens: p.inputTokens, cumulativeOutputTokens: p.outputTokens,
                cumulativeCacheReadTokens: p.cacheReadTokens,
                cumulativeCacheCreation5mTokens: p.cacheWriteTokens, cumulativeCacheCreation1hTokens: 0))
        }
        try context.save()

        let startMs = Int(start.timeIntervalSince1970 * 1000)
        let durationMs = Int(saved.timeIntervalSince(start) * 1000)
        func entry(_ id: String, output: Int) -> String {
            """
            {"lastSessionId": "\(id)", "lastTotalInputTokens": 50000,
             "lastTotalOutputTokens": \(output + 9000),
             "lastTotalCacheCreationInputTokens": 200000, "lastTotalCacheReadInputTokens": 3000000,
             "lastModelUsage": {"claude-opus-5-5": {"outputTokens": \(output)},
                                "claude-haiku-5-5": {"outputTokens": 9000}},
             "lastStartTime": \(startMs), "lastDuration": \(durationMs)}
            """
        }
        let config = """
        {"projects": {
          "/Users/someone/Code/acme": \(entry(Self.healthy, output: 100_000)),
          "/Users/someone/Code/acme-feature": \(entry(Self.lossy, output: 230_000)),
          "/Users/someone/Code/acme-api": \(entry(Self.unread, output: 100_000)),
          "/Users/someone/Code/globex": {"lastSessionId": "55555555-aaaa-4bbb-8ccc-000000000005",
            "lastTotalInputTokens": 0, "lastTotalOutputTokens": 0,
            "lastTotalCacheCreationInputTokens": 0, "lastTotalCacheReadInputTokens": 0,
            "lastStartTime": \(startMs), "lastDuration": \(durationMs)}
        }}
        """
        try Data(config.utf8).write(to: home.appendingPathComponent(".claude.json"))
        return Fixture(home: home, projects: projects, container: container)
    }

    @Test("judges what is finished and read, finds the lost output, skips the rest")
    func run() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let report = DataCanary.run(container: fixture.container, sources: fixture.sources, now: now)
        #expect(report.configFiles == 1)
        #expect(report.sessions == 4)
        #expect(report.checked.map(\.sessionId) == [Self.healthy, Self.lossy])
        #expect(report.checked.first?.comparison.matched == true)
        #expect(report.mismatched.map(\.sessionId) == [Self.lossy])
        #expect(report.mismatched.first?.comparison.mismatches.map(\.band) == [">1.1"])
        #expect(report.skipped == [.notIngested: 1, .noSession: 1])
    }

    @Test("a session judged once is not judged again")
    func ledger() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let suite = "pacer.tests.dataCanary.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = DataCanaryLedger(defaults: defaults)

        let first = DataCanary.runAndPublish(container: fixture.container, sources: fixture.sources,
                                             ledger: ledger, now: now)
        #expect(first.checked.count == 2)
        let second = DataCanary.runAndPublish(container: fixture.container, sources: fixture.sources,
                                              ledger: ledger, now: now.addingTimeInterval(3600))
        #expect(second.checked.isEmpty)
        #expect(second.alreadyJudged == 2)

        // Forgotten once past the lookback, when the run would skip it anyway.
        #expect(ledger.judged(now: now.addingTimeInterval(9 * 86_400)).isEmpty)
    }
}

// MARK: - What it reports

@Suite("Data canary: reporting")
struct DataCanaryReportingTests {

    private func checked(_ id: String, version: String?, _ mismatches: [Canary.Mismatch]) -> DataCanary.CheckedSession {
        DataCanary.CheckedSession(
            sessionId: id, ccVersion: version,
            comparison: Canary.Comparison(ratios: [.output: mismatches.first?.ratio ?? 1],
                                          mismatches: mismatches))
    }

    @Test("one problem per kind and band per run, with only the kind, band and version")
    func problems() {
        var report = DataCanary.Report()
        report.configFiles = 1
        report.checked = [
            checked("aaaaaaaa-1", version: "2.1.306", [.init(kind: .output, ratio: 2.3)]),
            checked("bbbbbbbb-2", version: "2.1.306", [.init(kind: .output, ratio: 6.8)]),
            checked("cccccccc-3", version: "2.1.306", [.init(kind: .output, ratio: 1.05),
                                                       .init(kind: .cacheRead, ratio: 0.4)]),
            checked("dddddddd-4", version: "2.1.323", []),
        ]
        let problems = DataCanary.problems(report)
        #expect(problems.count == 3)
        #expect(problems.first == [
            "canary.kind": .string("output"),
            "canary.ratio_band": .string(">1.1"),
            "canary.cc_version": .string("2.1.306"),
        ])
        #expect(problems.allSatisfy { Set($0.keys) == ["canary.kind", "canary.ratio_band", "canary.cc_version"] })
    }

    @Test("a version that is not plain dotted digits is sent as other")
    func versions() {
        #expect(DataCanary.enumerableVersion("2.1.323") == "2.1.323")
        #expect(DataCanary.enumerableVersion(nil) == "unknown")
        #expect(DataCanary.enumerableVersion("2.1.323-someone") == "other")
        #expect(DataCanary.enumerableVersion("/Users/someone") == "other")
    }

    @Test("the log names a session by its id's first eight characters")
    func logLine() {
        let line = DataCanary.logLine(checked(
            "11111111-aaaa-4bbb-8ccc-000000000001", version: "2.1.306",
            [.init(kind: .output, ratio: 2.3)]))
        #expect(line.hasPrefix("session 11111111 cc 2.1.306: "))
        #expect(!line.contains("aaaa-4bbb"))
        #expect(line.contains("MISMATCH output 2.300 (>1.1)"))
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pacer-canary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
