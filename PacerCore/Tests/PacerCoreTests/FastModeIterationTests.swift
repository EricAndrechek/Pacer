import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// #218: `usage.speed` selects the fast-mode price; `usage.iterations[]`
/// turns one response into one entry per model call, each priced on its own
/// model.
@Suite("Fast mode and iterations")
struct FastModeIterationTests {

    static let fastLine = """
    {"type":"assistant","timestamp":"2026-10-10T12:00:00.000Z","sessionId":"s1","cwd":"/tmp/p",\
    "requestId":"r1","message":{"id":"m1","model":"claude-opus-5-5","stop_reason":"end_turn",\
    "usage":{"input_tokens":1000,"output_tokens":2000,"cache_read_input_tokens":0,\
    "cache_creation_input_tokens":0,"speed":"fast","inference_geo":"us"}}}
    """

    /// The observed shape: a Fable 5.1 attempt that fell back to Opus 4.8,
    /// with top-level fields mixed from both calls (the 5m/1h split from the
    /// first, the summed write from the second).
    static func fallbackLine(output: Int = 900, stop: String? = "end_turn") -> String {
        let stopJSON = stop.map { "\"\($0)\"" } ?? "null"
        return """
        {"type":"assistant","timestamp":"2026-10-10T13:00:00.000Z","sessionId":"s1","cwd":"/tmp/p",\
        "requestId":"r2","message":{"id":"m2","model":"claude-opus-4-8","stop_reason":\(stopJSON),\
        "usage":{"input_tokens":50,"output_tokens":\(output),"cache_read_input_tokens":10000,\
        "cache_creation_input_tokens":3000,\
        "cache_creation":{"ephemeral_5m_input_tokens":27000,"ephemeral_1h_input_tokens":0},\
        "iterations":[\
        {"type":"message","model":"claude-fable-5-1","input_tokens":40,"output_tokens":4200,\
        "cache_read_input_tokens":0,"cache_creation_input_tokens":27000,\
        "cache_creation":{"ephemeral_5m_input_tokens":27000,"ephemeral_1h_input_tokens":0}},\
        {"type":"fallback_message","model":"claude-opus-4-8","input_tokens":50,"output_tokens":\(output),\
        "cache_read_input_tokens":10000,"cache_creation_input_tokens":3000,\
        "cache_creation":{"ephemeral_5m_input_tokens":3000,"ephemeral_1h_input_tokens":0}}]}}}
        """
    }

    // MARK: Parsing

    @Test func speedAndGeoAreParsed() throws {
        let entry = try #require(JSONLLineParser.parse(line: Self.fastLine))
        #expect(entry.speed == "fast")
        #expect(entry.inferenceGeo == "us")
        let sample = TokenSample(from: entry)
        #expect(sample.speed == "fast" && sample.inferenceGeo == "us")
    }

    @Test func linesWithoutTheFieldsParseAsBefore() throws {
        let plain = Self.fastLine.replacingOccurrences(of: #","speed":"fast","inference_geo":"us""#, with: "")
        let entry = try #require(JSONLLineParser.parse(line: plain))
        #expect(entry.speed == nil && entry.inferenceGeo == nil)
        #expect(JSONLLineParser.parseAll(line: Data(plain.utf8)).count == 1)
    }

    @Test func anOddIterationsFieldDropsTheFieldNotTheTurn() throws {
        let odd = Self.fastLine.replacingOccurrences(of: #""speed":"fast""#, with: #""speed":7,"iterations":"x""#)
        let entries = JSONLLineParser.parseAll(line: Data(odd.utf8))
        #expect(entries.count == 1)
        #expect(entries.first?.breakdown.outputTokens == 2000)
    }

    @Test func eachIterationIsItsOwnEntryOnItsOwnModel() throws {
        let entries = JSONLLineParser.parseAll(line: Data(Self.fallbackLine().utf8))
        #expect(entries.count == 2)
        let fable = entries[0], opus = entries[1]
        #expect(fable.model == "claude-fable-5-1")
        #expect(fable.breakdown == TokenBreakdown(inputTokens: 40, outputTokens: 4200,
                                                  cacheCreation5mTokens: 27000))
        #expect(opus.model == "claude-opus-4-8")
        // The cache-write split is the iteration's own, not the top level's.
        #expect(opus.breakdown == TokenBreakdown(inputTokens: 50, outputTokens: 900,
                                                 cacheReadTokens: 10000, cacheCreation5mTokens: 3000))
        // Keys stay unique; the final call keeps the response's own.
        #expect(opus.dedupKey == "m2:r2")
        #expect(fable.dedupKey == "m2:r2#0")
        #expect(JSONLLineParser.parse(line: Self.fallbackLine())?.model == "claude-opus-4-8")
    }

    @Test func streamedCopiesStillSupersedePerIteration() throws {
        // Rule 7 is unchanged: the finished copy wins, per derived key.
        let partial = JSONLLineParser.parseAll(line: Data(Self.fallbackLine(output: 1, stop: nil).utf8))
        let finished = JSONLLineParser.parseAll(line: Data(Self.fallbackLine().utf8))
        #expect(partial.map(\.dedupKey) == finished.map(\.dedupKey))
        for (p, f) in zip(partial, finished) {
            #expect(f.supersedes(p))
            #expect(!p.supersedes(f))
        }
    }

    @Test func theBulkImporterSplitsIterationsTheSameWay() throws {
        let line = Self.fallbackLine()
        let base = try #require(JSONLLineParser.entry(
            from: try JSONDecoder().decode(RawJSONLine.self, from: Data(line.utf8))))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let iterations = ((json["message"] as? [String: Any])?["usage"] as? [String: Any])?["iterations"]
        let raw = String(data: try JSONSerialization.data(withJSONObject: iterations!), encoding: .utf8)
        #expect(JSONLLineParser.expand(base, iterationsJSON: raw)
                == JSONLLineParser.parseAll(line: Data(line.utf8)))
    }

    // MARK: Pricing, end to end

    @ScanActor
    @Test func eachCallIsPricedOnItsOwnModelAndFastAtItsPremium() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-fast-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("projects/-tmp-p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ([Self.fastLine, Self.fallbackLine()].joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let container = try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        await SampleCostCache.reload()
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .calculate, watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]))
        _ = try await coordinator.runOnce()

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<TokenSample>()) == 3)
        var byModel: [String: DailyAggregate] = [:]
        for row in try context.fetch(FetchDescriptor<DailyAggregate>()) { byModel[row.model] = row }

        // Fast Opus 5.5 with US residency: ($8 in, $40 out) x 1.1.
        let fast = try #require(byModel["claude-opus-5-5"])
        #expect(abs(fast.totalCostUSD - (1000 * 8e-6 + 2000 * 40e-6) * 1.1) < 1e-9)
        // The Fable 5.1 attempt: 40 in, 4,200 out, 27k 5m writes.
        let fable = try #require(byModel["claude-fable-5-1"])
        #expect(fable.outputTokens == 4200 && fable.cacheCreation5mTokens == 27000)
        #expect(abs(fable.totalCostUSD - (40 * 10e-6 + 4200 * 50e-6 + 27000 * 12.5e-6)) < 1e-9)
        // The Opus 4.8 fallback, with its own cache-write split.
        let opus = try #require(byModel["claude-opus-4-8"])
        #expect(opus.cacheCreation5mTokens == 3000 && opus.outputTokens == 900)
        #expect(abs(opus.totalCostUSD - (50 * 5e-6 + 900 * 25e-6 + 10000 * 0.5e-6 + 3000 * 6.25e-6)) < 1e-9)
    }

    // MARK: Re-reading history

    /// A store written before #218 holds fast-mode turns with no marker and a
    /// multi-call response as one row with mixed fields. The full re-read a
    /// scan-version bump forces must fix both in place.
    @ScanActor
    @Test func aFullReReadPatchesRowsStoredBeforeTheFields() throws {
        let context = ModelContext(try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

        // As an older build stored them: no speed, and the response's
        // top-level fields (27k 5m writes borrowed from the first call).
        let fast = try #require(JSONLLineParser.parse(line: Self.fastLine))
        let stale = ParsedUsageEntry(
            timestamp: fast.timestamp, model: fast.model, breakdown: fast.breakdown,
            dedupKey: fast.dedupKey, sessionId: fast.sessionId, projectPath: fast.projectPath)
        let mixedLine = try JSONDecoder().decode(RawJSONLine.self, from: Data(Self.fallbackLine().utf8))
        let mixed = try #require(JSONLLineParser.entry(from: mixedLine))
        let first = try SamplePersister(context: context)
        try first.insert(stale)
        try first.insert(mixed)
        try first.flush()
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<TokenSample>()) == 2)

        // The re-read, through a fresh persister as after a relaunch.
        let reread = try SamplePersister(context: context)
        reread.backfillsPricingDetail = true
        for entry in JSONLLineParser.parseAll(line: Data(Self.fastLine.utf8))
            + JSONLLineParser.parseAll(line: Data(Self.fallbackLine().utf8)) {
            try reread.insert(entry)
        }
        try reread.flush()
        try context.save()
        #expect(reread.stats.patchedPricingDetail == 2)

        let rows = try context.fetch(FetchDescriptor<TokenSample>())
        #expect(rows.count == 3)
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.dedupKey ?? "", $0) })
        #expect(byKey["m1:r1"]?.speed == "fast")
        #expect(byKey["m1:r1"]?.inferenceGeo == "us")
        #expect(byKey["m2:r2"]?.cacheCreation5mTokens == 3000)
        #expect(byKey["m2:r2#0"]?.model == "claude-fable-5-1")
        #expect(reread.dirtyPairs.contains(DateModelPair(date: byKey["m2:r2"]!.date, model: "claude-opus-4-8")))

        // Live cycles never patch: the first copy already carried the detail.
        let live = try SamplePersister(context: context)
        try live.insert(try #require(JSONLLineParser.parse(line: Self.fastLine)))
        #expect(live.stats.patchedPricingDetail == 0)
    }
}
