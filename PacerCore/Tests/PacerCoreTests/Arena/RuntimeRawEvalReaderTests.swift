import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `RawEvalReader` against SwiftData: rows go in through SwiftData into a
/// store on disk and both reads must return the same set (the column names
/// are Core Data's mangled ones; see `RawLimitReaderParityTests`).
@Suite("Arena runtime: raw record reads match SwiftData")
struct RuntimeRawEvalReaderTests {

    static func store() throws -> (ModelContainer, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).sqlite")
        let container = try ModelContainer(for: EngineEvalOutcome.self, ClaudeCodeMeta.self,
                                           configurations: ModelConfiguration(url: url))
        return (container, url)
    }

    static func seed(_ ctx: ModelContext) throws {
        let surfaces = ["eod", "rl-five_hour", "rl-five_hour#acct-a", "rl-seven_day#acct-a",
                        "rl-weekly_scoped|claude-fable|#acct-a", "rl-five_hour#acct-b", "rl-five_hour#xacct-a"]
        for (i, s) in surfaces.enumerated() {
            for m in ["linear-recent", "test-arena"] {
                for p in 0..<5 {
                    ctx.insert(EngineEvalOutcome(surface: s, method: m, bucket: "cut=0.\(p + 2)0|v2",
                                                 periodKey: "2026-10-0\(p + 1)T00:00:00Z",
                                                 predicted: Double(i * 10 + p) + 0.25, truth: Double(i + p) * 1.5))
                }
            }
        }
        try ctx.save()
    }

    struct Key: Hashable { let surface, method, bucket, period: String; let predicted, truth: Double }

    @Test func scopeRowsMatch() throws {
        let (container, url) = try Self.store()
        try Self.seed(ModelContext(container))
        let all = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
        for scope in [EngineScope.allAccounts, .account("acct-a"), .account("acct-b")] {
            let raw = try #require(RawEvalReader.scopeRows(storeURL: url, suffix: scope.suffix))
            let viaRaw = Set(raw.map { Key(surface: $0.surface, method: $0.method, bucket: $0.bucket,
                                           period: $0.periodKey, predicted: $0.predicted, truth: $0.truth) })
            let viaData = Set(all.filter { scope.unqualify($0.surface) != nil }.map {
                Key(surface: $0.surface, method: $0.method, bucket: $0.bucket, period: $0.periodKey,
                    predicted: $0.predicted, truth: $0.truth)
            })
            #expect(viaRaw == viaData, "\(scope.key)")
            #expect(!viaRaw.isEmpty)
        }
        // "#xacct-a" ends in "acct-a" but is not that account's.
        let a = try #require(RawEvalReader.scopeRows(storeURL: url, suffix: EngineScope.account("acct-a").suffix))
        #expect(!a.contains { $0.surface.hasSuffix("#xacct-a") })
    }

    @Test func surfaceRowsMatch() throws {
        let (container, url) = try Self.store()
        try Self.seed(ModelContext(container))
        let periods = ["2026-10-02T00:00:00Z", "2026-10-04T00:00:00Z"]
        let raw = try #require(RawEvalReader.surfaceRows(storeURL: url, surface: "rl-five_hour#acct-a", periods: periods))
        let all = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
            .filter { $0.surface == "rl-five_hour#acct-a" && periods.contains($0.periodKey) }
        #expect(raw.count == all.count)
        #expect(Set(raw.map { "\($0.method)|\($0.bucket)|\($0.periodKey)|\($0.predicted)" })
                == Set(all.map { "\($0.method)|\($0.bucket)|\($0.periodKey)|\($0.predicted)" }))
    }

    /// A grade's inputs come back as stored (nil on rows written before
    /// them), and the scorer can ask for one grading's rows only.
    @Test func inputsAndOneGradingsRows() throws {
        let (container, url) = try Self.store()
        let ctx = ModelContext(container)
        try Self.seed(ctx)
        for p in 0..<3 {
            ctx.insert(EngineEvalOutcome(surface: "rl-five_hour#acct-a", method: "test-arena",
                                         bucket: EngineSelfEval.rlBucket(0.175), periodKey: "2026-10-0\(p + 1)T00:00:00Z",
                                         predicted: 1, truth: 2, inputs: "m1.p3.h4"))
        }
        try ctx.save()
        let periods = (1...5).map { "2026-10-0\($0)T00:00:00Z" }
        let current = try #require(RawEvalReader.surfaceRows(storeURL: url, surface: "rl-five_hour#acct-a",
                                                             periods: periods, bucketSuffix: "|v3"))
        #expect(current.count == 3)
        #expect(Set(current.map(\.inputs)) == ["m1.p3.h4"])
        let all = try #require(RawEvalReader.surfaceRows(storeURL: url, surface: "rl-five_hour#acct-a", periods: periods))
        #expect(all.filter { $0.inputs == nil }.count == all.count - 3)
        let viaData = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
            .filter { $0.surface == "rl-five_hour#acct-a" }
        #expect(Set(all.map { "\($0.bucket)|\($0.periodKey)|\($0.method)|\($0.inputs ?? "-")" })
                == Set(viaData.map { "\($0.bucket)|\($0.periodKey)|\($0.method)|\($0.inputs ?? "-")" }))
    }

    /// The engine reads its record through it when the store is a file, and
    /// gets the same fit as through SwiftData.
    @Test func theEngineReadsItsRecordRaw() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).sqlite")
        let onDisk = try PacerStore.makeModelContainer(at: url)
        let inMemory = try PacerStore.makeInMemoryContainer()
        for c in [onDisk, inMemory] { try Self.seed(ModelContext(c)) }
        var picks: [EngineSelfEval.Accuracy?] = []
        for c in [onDisk, inMemory] {
            let e = UsageIntelligenceEngine(modelContainer: c)
            await e.adopt(scope: .account("acct-a"))
            await e.recompute(now: Date(timeIntervalSince1970: 1_790_000_000))
            picks.append(await e.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("five_hour")))
        }
        #expect(picks[0] != nil)
        // Without the runtime only the app's roster is ranked: the test
        // model's rows are read, and left out.
        #expect(picks[0]?.methods.map(\.method).sorted() == ["linear-recent"])
        // Same stats; the order of exact ties is the dictionary's.
        #expect(picks[0]?.methods.sorted { $0.method < $1.method } == picks[1]?.methods.sorted { $0.method < $1.method })
    }
}
