import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// A rebuild's snapshot now comes from SQLite directly (#335), through Core
/// Data's mangled column names. Rows go in through SwiftData; the raw reader
/// must hand back what the SwiftData walk does, row for row, in the same
/// order — the rollups sum costs in snapshot order, so order is part of the
/// answer, down to the last bit of a total.
@Suite("Raw SQLite sample reads match the SwiftData walk exactly")
struct RawSampleReaderParityTests {

    private func makeStore() throws -> (ModelContainer, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        return (try PacerStore.makeModelContainer(at: url), url)
    }

    /// The awkward parts: every optional nil somewhere, an unstamped hour,
    /// repeated and changing strings (the reader reuses the previous row's),
    /// an empty string, a long one, a non-ASCII one, costs that aren't
    /// round, and rows deleted and inserted out of time order.
    private func seed(_ c: ModelContainer) throws {
        let context = ModelContext(c)
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000.123_456_7)
        for i in 0..<300 {
            // Out of time order, so table order and time order differ.
            let at = base.addingTimeInterval(Double((i * 7_919) % 300) * 613.25)
            let s = TokenSample(
                sampledAt: at,
                date: TokenSample.formatDate(at),
                model: ["claude-opus-5", "claude-sonnet-5", "claude-fable-5"][(i / 4) % 3],
                inputTokens: Int64(i * 13),
                outputTokens: Int64(i * 7 + 1),
                cacheReadTokens: Int64(i) * 1_000_003,
                cacheCreation5mTokens: Int64(i % 5),
                cacheCreation1hTokens: Int64(i % 3) * 17,
                sourceCostUSD: i.isMultiple(of: 4) ? nil : Double(i) * 0.000_123_456_789,
                dedupKey: "k\(i)",
                sessionId: i.isMultiple(of: 9) ? nil : (i.isMultiple(of: 11) ? "" : "session-\(i / 6)"),
                projectPath: i.isMultiple(of: 10) ? nil
                    : "/work/a-project-path-long-enough-to-live-on-the-heap/\(i / 20)",
                ccVersion: i.isMultiple(of: 8) ? nil : "2.\(i / 50).0")
            if i.isMultiple(of: 13) { s.localHour = -1 }
            s.accountId = i.isMultiple(of: 6) ? nil : (i < 150 ? "org-a" : "org-b-é")
            s.speed = i.isMultiple(of: 17) ? "fast" : nil
            s.inferenceGeo = i.isMultiple(of: 19) ? "us" : nil
            context.insert(s)
        }
        try context.save()
        // Holes in the row ids, and rows added after them.
        for s in try context.fetch(FetchDescriptor<TokenSample>()) where s.inputTokens % 91 == 0 {
            context.delete(s)
        }
        try context.save()
        for i in 300..<320 {
            let at = base.addingTimeInterval(-Double(i) * 37)
            context.insert(TokenSample(
                sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5",
                inputTokens: Int64(i), outputTokens: 1, cacheReadTokens: 0,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                sourceCostUSD: 1.0 / 3.0, dedupKey: "k\(i)", sessionId: "late"))
        }
        try context.save()
    }

    private func describe(_ r: SampleSnapshot.Row) -> String {
        let b = r.breakdown
        let parts: [String] = [
            r.date, r.model, r.projectPath ?? "∅", r.sessionId ?? "∅",
            String(r.sampledAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
            String(r.localHour), r.ccVersion ?? "∅",
            "\(b.inputTokens)/\(b.outputTokens)/\(b.cacheReadTokens)/\(b.cacheCreation5mTokens)/\(b.cacheCreation1hTokens)",
            r.sourceCostUSD.map { String($0.bitPattern, radix: 16) } ?? "∅",
            r.accountId ?? "∅", r.speed ?? "∅", r.inferenceGeo ?? "∅",
        ]
        return parts.joined(separator: "|")
    }

    @Test func sameRowsInTheSameOrder() throws {
        let (c, url) = try makeStore()
        try seed(c)
        let walked = try SampleSnapshot.fetchThroughSwiftData(from: c).rows.map(describe)
        let raw = try #require(RawSampleReader.rows(storeURL: url)).map(describe)
        #expect(walked.count == (try ModelContext(c).fetchCount(FetchDescriptor<TokenSample>())))
        #expect(raw.count == walked.count)
        for (i, pair) in zip(raw, walked).enumerated() where pair.0 != pair.1 {
            Issue.record("row \(i): raw \(pair.0) ≠ walked \(pair.1)")
            break
        }
        #expect(raw == walked)
    }

    /// What the rebuild calls: a store on disk reads raw, and gives the same
    /// snapshot as the walk it replaced.
    @Test func snapshotOfAFileStoreReadsRaw() throws {
        let (c, _) = try makeStore()
        try seed(c)
        let snapshot = try SampleSnapshot.fetch(from: c).rows.map(describe)
        #expect(snapshot == (try SampleSnapshot.fetchThroughSwiftData(from: c).rows.map(describe)))
    }

    /// A cost-recompute bump marks every bucket from the same raw read: the
    /// marks are exactly the buckets the stored samples feed, plus a turn the
    /// context holds unsaved.
    @ScanActor
    @Test func costBumpMarksReadRawMatchTheSamples() throws {
        let (c, url) = try makeStore()
        try seed(c)
        #expect(RawSampleReader.storeURL(of: c) == url)
        let context = ModelContext(c)
        let persister = try SamplePersister(context: context)
        let at = Date(timeIntervalSinceReferenceDate: 805_000_000)
        context.insert(TokenSample(
            sampledAt: at, date: TokenSample.formatDate(at), model: "claude-unsaved-5",
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0, dedupKey: "unsaved", sessionId: "unsaved-session",
            projectPath: "/work/unsaved"))
        try persister.markEverySampleDirty()

        let samples = try context.fetch(FetchDescriptor<TokenSample>())
        let hour = { (s: TokenSample) in
            s.localHour >= 0 ? s.localHour : Calendar.current.component(.hour, from: s.sampledAt)
        }
        let pairs = Set(samples.map { DateModelPair(date: $0.date, model: $0.model) })
        let projects = Set(samples.map {
            ProjectDatePair(projectPath: $0.projectPath ?? ProjectDailyAggregate.unknownProjectPath, date: $0.date)
        })
        let hours = Set(samples.map { DateHourModelTriple(date: $0.date, hour: hour($0), model: $0.model) })
        let sessions = Set(samples.compactMap(\.sessionId).filter { !$0.isEmpty })
        #expect(pairs.contains(DateModelPair(date: TokenSample.formatDate(at), model: "claude-unsaved-5")))
        #expect(persister.dirtyPairs == pairs)
        #expect(persister.pollutedDailyPairs == pairs)
        #expect(persister.dirtyProjectDates == projects)
        #expect(persister.dirtyHourBuckets == hours)
        #expect(persister.dirtySessionIds == sessions)
        #expect(persister.pollutedSessionIds == sessions)
    }

    /// Anything unexpected in the file is nil, never a partial read: the
    /// caller falls back to the walk.
    @Test func aStoreWithoutTheTableIsNil() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        _ = try ModelContainer(for: ClaudeCodeMeta.self, configurations: ModelConfiguration(url: url))
        #expect(RawSampleReader.rows(storeURL: url) == nil)
        #expect(RawSampleReader.rows(storeURL: url.appendingPathExtension("missing")) == nil)
        let inMemory = try ModelContainer(
            for: TokenSample.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        #expect(RawSampleReader.storeURL(of: inMemory) == nil)
    }

    /// A dedup rebuild's columns, the same way: the map and the bucket sets it
    /// builds are only right if these are the rows the walk would have seen.
    @Test func dedupRowsMatchTheWalk() throws {
        let (container, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try seed(container)
        var raw: [RawSampleReader.DedupRow] = []
        #expect(RawSampleReader.forEachDedupRow(storeURL: url) { raw.append($0) })
        let walked = try ModelContext(container).fetch(FetchDescriptor<TokenSample>()).map { s in
            RawSampleReader.DedupRow(
                dedupKey: s.dedupKey, date: s.date, model: s.model, projectPath: s.projectPath,
                sessionId: s.sessionId, sampledAt: s.sampledAt, outputTokens: s.outputTokens,
                localHour: s.localHour >= 0 ? s.localHour : Calendar.current.component(.hour, from: s.sampledAt))
        }
        #expect(!raw.isEmpty)
        #expect(raw == walked)
    }

    /// A store this reader can't make sense of says so, and the caller walks.
    @Test func dedupRowsRefuseAFileThatIsNotAStore() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).sqlite")
        try Data("not a database".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!RawSampleReader.forEachDedupRow(storeURL: url) { _ in Issue.record("no rows expected") })
    }
}
