import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `ModelWalk` replaced `enumerate` on the full-table walks because
/// `enumerate` held gigabytes on a real store (#337). These pin that it reads
/// exactly what a whole fetch does, in the same order.
@Suite struct ModelWalkTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(PacerStore.allModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func entry(_ i: Int) -> ParsedUsageEntry {
        ParsedUsageEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 600),
            model: i.isMultiple(of: 2) ? "claude-opus-5" : "claude-sonnet-5-5",
            breakdown: TokenBreakdown(inputTokens: Int64(i), outputTokens: 1,
                                      cacheReadTokens: 0, cacheCreation5mTokens: 0,
                                      cacheCreation1hTokens: 0),
            storedCostUSD: nil,
            dedupKey: "m\(i):r\(i)",
            sessionId: "s\(i % 4)",
            projectPath: "/Users/dev/code/p\(i % 3)",
            claudeCodeVersion: nil)
    }

    @ScanActor
    @Test func walksEveryRowOnceInFetchOrder() throws {
        let c = try container()
        let context = ModelContext(c)
        let persister = try SamplePersister(context: context)
        for i in 0..<23 { try persister.insert(entry(i)) }
        try persister.flush()
        try context.save()

        // A page size that doesn't divide the row count, so the last page is
        // short, and one that does, so the walk ends on an empty page.
        for pageSize in [5, 23, 1] {
            var walked: [String] = []
            try ModelWalk.forEach(FetchDescriptor<TokenSample>(), in: c, pageSize: pageSize) {
                walked.append($0.dedupKey ?? "-")
            }
            let fetched = try ModelContext(c).fetch(FetchDescriptor<TokenSample>()).map { $0.dedupKey ?? "-" }
            #expect(walked == fetched)
            #expect(Set(walked).count == 23)
        }

        let opus = FetchDescriptor<TokenSample>(predicate: #Predicate { $0.model == "claude-opus-5" })
        var count = 0
        try ModelWalk.forEach(opus, in: c, pageSize: 4) { _ in count += 1 }
        #expect(count == 12)
    }

    /// The marking walk reads the store; turns this cycle hasn't saved are
    /// marked from the context, so a cost rebuild still covers them.
    @ScanActor
    @Test func markEverySampleDirtyCoversUnsavedTurns() throws {
        let c = try container()
        let context = ModelContext(c)
        let persister = try SamplePersister(context: context)
        for i in 0..<6 { try persister.insert(entry(i)) }
        try persister.flush()
        try context.save()
        // One more, inserted and not saved.
        try persister.insert(entry(1_000))
        persister.clearDirtyPairs()

        try persister.markEverySampleDirty()
        let dates = Set((0..<6).map { entry($0) }.map { TokenSample(from: $0).date })
            .union([TokenSample(from: entry(1_000)).date])
        #expect(Set(persister.dirtyPairs.map(\.date)) == dates)
        #expect(persister.dirtySessionIds == ["s0", "s1", "s2", "s3"])
        #expect(persister.pollutedDailyPairs == persister.dirtyPairs)
    }
}
