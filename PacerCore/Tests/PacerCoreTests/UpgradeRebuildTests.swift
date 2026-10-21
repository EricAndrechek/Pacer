import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The one-time rebuild a new build's first launch performs walks the whole
/// sample table more than once. These pin that the batched walks (#327) read
/// and write exactly what the whole-table fetches they replaced did.
@Suite struct UpgradeRebuildTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(PacerStore.allModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func entry(_ i: Int, key: String? = nil, output: Int64 = 1,
                       complete: Bool = false) -> ParsedUsageEntry {
        ParsedUsageEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 37),
            model: ["claude-opus-5", "claude-sonnet-5-5", "claude-haiku-5-5"][i % 3],
            breakdown: TokenBreakdown(inputTokens: Int64(i % 17), outputTokens: output,
                                      cacheReadTokens: Int64(i * 3),
                                      cacheCreation5mTokens: Int64(i % 5),
                                      cacheCreation1hTokens: Int64(i % 7)),
            storedCostUSD: i.isMultiple(of: 4) ? Double(i) / 1000 : nil,
            dedupKey: key ?? "m\(i):r\(i)",
            sessionId: i.isMultiple(of: 11) ? nil : "s\(i % 23)",
            projectPath: i.isMultiple(of: 13) ? nil : "/Users/dev/code/p\(i % 9)",
            claudeCodeVersion: i.isMultiple(of: 2) ? "2.1.\(i % 4)" : nil,
            isComplete: complete,
            speed: i.isMultiple(of: 29) ? "fast" : nil,
            inferenceGeo: i.isMultiple(of: 31) ? "us" : nil)
    }

    private func describe(_ r: SampleSnapshot.Row) -> String {
        // Built in typed steps: as one literal Xcode 16's type checker
        // gives up on it (macOS 15 CI).
        let cost: String = r.sourceCostUSD.map { "\($0)" } ?? "-"
        var parts: [String] = [r.date, r.model, r.projectPath ?? "-", r.sessionId ?? "-"]
        parts += [String(r.sampledAt.timeIntervalSince1970), String(r.localHour), r.ccVersion ?? "-"]
        parts += ["\(r.breakdown)", cost, r.accountId ?? "-"]
        parts += [r.speed ?? "-", r.inferenceGeo ?? "-"]
        return parts.joined(separator: "|")
    }

    /// More rows than one batch, so the walk crosses batch boundaries; the
    /// snapshot must equal the old whole-table projection row for row, in
    /// the same order — the bulk rollups sum costs in that order.
    @ScanActor
    @Test func theBatchedSnapshotEqualsAWholeTableFetch() throws {
        let c = try container()
        let context = ModelContext(c)
        let persister = try SamplePersister(context: context)
        for i in 0..<12_345 { try persister.insert(entry(i)) }
        try persister.flush()
        try context.save()

        let snapshot = try SampleSnapshot.fetch(from: ModelContext(c))
        let whole = try ModelContext(c).fetch(FetchDescriptor<TokenSample>())
        #expect(snapshot.rows.count == 12_345)
        #expect(snapshot.rows.count == whole.count)
        let expected = whole.map { s in
            describe(SampleSnapshot.Row(
                date: s.date, model: s.model, projectPath: s.projectPath, sessionId: s.sessionId,
                sampledAt: s.sampledAt, localHour: s.localHour, ccVersion: s.ccVersion,
                breakdown: s.breakdown, sourceCostUSD: s.sourceCostUSD, accountId: s.accountId,
                speed: s.speed, inferenceGeo: s.inferenceGeo))
        }
        #expect(snapshot.rows.map(describe) == expected)
    }

    /// Above the bulk threshold the upgrades are applied by a batched walk of
    /// the table. Rows stored earlier and rows this same pass inserted (not
    /// on disk yet) must both be upgraded, each exactly once.
    @ScanActor
    @Test func theBatchedUpgradeWalkReachesStoredAndPendingRows() throws {
        let c = try container()
        let context = ModelContext(c)
        let first = try SamplePersister(context: context)
        for i in 0..<40 { try first.insert(entry(i)) }   // partial copies, output 1
        try first.flush()
        try context.save()

        // As after a relaunch: a fresh persister, ten new partial rows left
        // unsaved, then the finished copy of all fifty.
        let reread = try SamplePersister(context: context)
        for i in 40..<50 { try reread.insert(entry(i)) }
        for i in 0..<50 { try reread.insert(entry(i, output: 500 + Int64(i), complete: true)) }
        #expect(reread.stats.upgradedFromPartial == 50)
        try reread.flush()
        try context.save()

        let rows = try ModelContext(c).fetch(FetchDescriptor<TokenSample>())
        #expect(rows.count == 50)
        for row in rows {
            let i = Int(row.dedupKey!.dropFirst().prefix { $0 != ":" })!
            #expect(row.outputTokens == 500 + Int64(i), "row \(i) kept its partial output")
        }
        // Every upgraded row's buckets are rebuilt from samples, not patched.
        let days = Set(rows.map { DateModelPair(date: $0.date, model: $0.model) })
        #expect(days.isSubset(of: reread.pollutedDailyPairs))
    }

    /// Only what pricing reads is pricing detail. Claude Code writes
    /// `inference_geo: "not_available"` on a third of turns; `Region(usageGeo:)`
    /// prices that as global, so a re-read must not rewrite rows for it.
    @Test func onlyAPricedGeoOrFastModeIsPricingDetail() {
        func entry(speed: String? = nil, geo: String? = nil) -> ParsedUsageEntry {
            ParsedUsageEntry(timestamp: Date(), model: "claude-opus-5", breakdown: TokenBreakdown(),
                             dedupKey: "m:r", speed: speed, inferenceGeo: geo)
        }
        #expect(!entry().carriesPricingDetail)
        #expect(!entry(speed: "standard", geo: "not_available").carriesPricingDetail)
        #expect(!entry(geo: "global").carriesPricingDetail)
        #expect(!entry(geo: "").carriesPricingDetail)
        #expect(!entry(geo: "somewhere-new").carriesPricingDetail)
        #expect(entry(speed: "fast").carriesPricingDetail)
        #expect(entry(geo: "us").carriesPricingDetail)
        #expect(entry(geo: "EU").carriesPricingDetail)
    }

    /// The re-read itself: a stored row that predates the fields is left
    /// alone for a geo that prices as global, and patched for one that
    /// doesn't.
    @ScanActor
    @Test func aReReadPatchesOnlyRowsWhosePriceTheDetailChanges() throws {
        let c = try container()
        let context = ModelContext(c)
        let first = try SamplePersister(context: context)
        try first.insert(entry(1, complete: true))
        try first.insert(entry(2, complete: true))
        try first.flush()
        try context.save()

        let reread = try SamplePersister(context: context)
        reread.backfillsPricingDetail = true
        var unavailable = entry(1, complete: true)
        unavailable = ParsedUsageEntry(
            timestamp: unavailable.timestamp, model: unavailable.model, breakdown: unavailable.breakdown,
            storedCostUSD: unavailable.storedCostUSD, dedupKey: unavailable.dedupKey,
            sessionId: unavailable.sessionId, projectPath: unavailable.projectPath,
            isComplete: true, speed: "standard", inferenceGeo: "not_available")
        let us = entry(2, complete: true)
        let usCopy = ParsedUsageEntry(
            timestamp: us.timestamp, model: us.model, breakdown: us.breakdown,
            storedCostUSD: us.storedCostUSD, dedupKey: us.dedupKey,
            sessionId: us.sessionId, projectPath: us.projectPath,
            isComplete: true, speed: "standard", inferenceGeo: "us")
        try reread.insert(unavailable)
        try reread.insert(usCopy)
        try reread.flush()
        try context.save()
        #expect(reread.stats.patchedPricingDetail == 1)

        let rows = try ModelContext(c).fetch(FetchDescriptor<TokenSample>())
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.dedupKey ?? "", $0) })
        #expect(byKey["m1:r1"]?.inferenceGeo == nil)
        #expect(byKey["m2:r2"]?.inferenceGeo == "us")
    }
}
