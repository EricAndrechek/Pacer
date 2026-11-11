import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The daily integrity walk compares what the samples fill against the rollup
/// tables: a bucket with samples and no rollup row is rebuilt, an hourly row
/// with no samples behind it is rebuilt away (#388).
///
/// It used to be a side effect of the dedup preload, which a valid dedup index
/// skips — so on a Mac that kept a good index it never ran. Real damage it
/// exists for: 4 hourly buckets missing their rows after a quit caught a
/// cycle part-way (the turns were committed by a batch save, the rollups by
/// nothing), and once 34 hourly rows stranded by an hour shift.
@Suite struct IntegrityWalkTests {

    private func entry(_ i: Int) -> ParsedUsageEntry {
        ParsedUsageEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 1_800),
            model: i.isMultiple(of: 2) ? "claude-opus-5" : "claude-sonnet-5-5",
            breakdown: TokenBreakdown(inputTokens: Int64(10 + i), outputTokens: Int64(20 + i),
                                      cacheReadTokens: 0, cacheCreation5mTokens: 0,
                                      cacheCreation1hTokens: 0),
            storedCostUSD: nil,
            dedupKey: "m\(i):r\(i)",
            sessionId: "s\(i % 2)",
            projectPath: "/Users/dev/code/p\(i % 2)",
            claudeCodeVersion: nil)
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(PacerStore.allModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func indexURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dedup-\(UUID().uuidString).bin")
    }

    /// Samples with no rollups at all, a valid index, and an hourly row no
    /// sample is behind. Loading the index finds none of it; the walk finds
    /// all of it.
    @ScanActor
    @Test func theWalkFindsDriftAValidIndexHides() throws {
        let c = try container()
        let url = indexURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ModelContext(c)
        let writer = try SamplePersister(context: first, indexURL: url)
        for i in 0..<4 { try writer.insert(entry(i)) }
        try writer.flush()
        try first.save()
        writer.writeDedupIndexIfNeeded(force: true)
        let strandedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let stranded = DateHourModelTriple(
            date: TokenSample.formatDate(strandedAt),
            hour: Calendar.current.component(.hour, from: strandedAt), model: "claude-opus-5")
        first.insert(HourlyAggregate(
            date: stranded.date, hour: stranded.hour, model: stranded.model,
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: 0, sampleCount: 1))
        try first.save()

        let persister = try SamplePersister(context: ModelContext(c), indexURL: url)
        try persister.ensurePreloaded()
        #expect(persister.loadedDedupIndex)
        #expect(!persister.consumeIntegrityCheck(), "an index seeds no integrity check")
        #expect(persister.consumeMissingHourBuckets().isEmpty)

        let stored = try StoredBuckets.read(from: c)
        #expect(stored.rows == 4)
        try persister.checkIntegrity(against: stored)
        #expect(persister.consumeIntegrityCheck())
        let samples = (0..<4).map { TokenSample(from: entry($0)) }
        #expect(persister.consumeMissingAggregatePairs()
                == Set(samples.map { DateModelPair(date: $0.date, model: $0.model) }))
        #expect(persister.consumeMissingHourBuckets()
                == Set(samples.map { DateHourModelTriple(date: $0.date, hour: $0.localHour, model: $0.model) }))
        #expect(persister.consumeMissingProjectAggregatePairs()
                == Set(samples.map { ProjectDatePair(projectPath: $0.projectPath!, date: $0.date) }))
        #expect(persister.consumeMissingSessionIds() == ["s0", "s1"])
        #expect(persister.consumeStrandedHourBuckets() == [stranded])
    }

    /// The samples are read before the rollups are, off the scan actor, so a
    /// row can look stranded only because its first sample arrived in
    /// between. It is rebuilt from its samples, not deleted; one with none is
    /// deleted by the same rebuild.
    @ScanActor
    @Test func aStrandedBucketIsRebuiltFromWhatItHoldsByThen() async throws {
        let c = try container()
        let context = ModelContext(c)
        let persister = try SamplePersister(context: context)
        let read = try StoredBuckets.read(from: c)   // an empty store

        // Its first sample, and its rollup, land after the read.
        try persister.insert(entry(0))
        try persister.flush()
        let hourly = HourlyAggregateRecomputer(container: c, context: context, mode: .display)
        _ = try await hourly.recompute(buckets: persister.dirtyHourBuckets)
        try context.save()
        persister.clearDirtyPairs()
        // …and an hourly row that really has nothing behind it.
        let emptyAt = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = DateHourModelTriple(date: TokenSample.formatDate(emptyAt),
                                        hour: Calendar.current.component(.hour, from: emptyAt),
                                        model: "claude-opus-5")
        context.insert(HourlyAggregate(
            date: empty.date, hour: empty.hour, model: empty.model,
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: 0, sampleCount: 1))
        try context.save()

        try persister.checkIntegrity(against: read)
        let stranded = persister.consumeStrandedHourBuckets()
        #expect(stranded.count == 2)
        persister.addDirtyHourBuckets(stranded)
        _ = try await hourly.recompute(buckets: persister.dirtyHourBuckets)
        try context.save()

        let rows = try ModelContext(c).fetch(FetchDescriptor<HourlyAggregate>())
        #expect(rows.count == 1)
        #expect(rows.first?.inputTokens == 10)
        #expect(rows.first?.outputTokens == 20)
    }

    /// End to end, on a store file with a valid index: a walk that is due
    /// reads in the background, and the next cycle rebuilds what it found.
    @ScanActor
    @Test func aDueWalkRunsAndRepairsWithAValidIndex() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("claude")
        let project = root.appendingPathComponent("projects/-Users-test-alpha")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try (Self.lines.joined(separator: "\n") + "\n").write(
            to: project.appendingPathComponent("sess-integrity.jsonl"), atomically: true, encoding: .utf8)
        let c = try PacerStore.makeModelContainer(at: dir.appendingPathComponent("pacer.sqlite"))

        func coordinator() -> ScanCoordinator {
            ScanCoordinator(
                container: c,
                configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
                resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]))
        }
        let first = coordinator()
        _ = try await first.runOnce()
        await first.stop()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(DedupIndex.fileName).path))

        // Damage the rollups, and make the walk due.
        let edit = ModelContext(c)
        for row in try edit.fetch(FetchDescriptor<HourlyAggregate>()) { edit.delete(row) }
        for row in try edit.fetch(FetchDescriptor<ClaudeCodeMeta>()) where row.key == ClaudeCodeMetaKey.lastIntegrityWalkAt {
            row.value = "0"
        }
        try edit.save()

        let second = coordinator()
        _ = try await second.runOnce()          // loads the index, starts the read
        await second.awaitIntegrityRead()
        _ = try await second.runOnce()          // rebuilds what it found
        let hourly = try ModelContext(c).fetch(FetchDescriptor<HourlyAggregate>())
        #expect(hourly.reduce(0) { $0 + $1.inputTokens } == 300)
        #expect(hourly.reduce(0) { $0 + $1.outputTokens } == 130)
        await second.stop()
    }

    private static func line(at timestamp: String, input: Int, output: Int, id: String) -> String {
        let fields: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "requestId": "req-\(id)",
            "cwd": "/Users/test/alpha",
            "sessionId": "sess-integrity",
            "message": [
                "model": "claude-opus-4-7",
                "id": "msg-\(id)",
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": 0,
                    "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0],
                ],
            ] as [String: Any],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
    }

    private static let lines = [
        line(at: "2026-04-30T12:00:00.000Z", input: 100, output: 50, id: "1"),
        line(at: "2026-04-30T12:05:00.000Z", input: 200, output: 80, id: "2"),
    ]
}
