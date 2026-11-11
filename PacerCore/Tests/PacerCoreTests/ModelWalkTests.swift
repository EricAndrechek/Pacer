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

    /// Each page starts after the last row it handed out, not at an offset
    /// (#394). A row deleted from a page already walked moves every later row
    /// one place up, so an offset page would start one row late and skip the
    /// row that slid across the boundary; this walk misses nothing.
    @ScanActor
    @Test func aRowDeletedBehindTheWalkSkipsNothingAhead() throws {
        let c = try container()
        let context = ModelContext(c)
        let persister = try SamplePersister(context: context)
        for i in 0..<23 { try persister.insert(entry(i)) }
        try persister.flush()
        try context.save()
        let all = try ModelContext(c).fetch(FetchDescriptor<TokenSample>()).map { $0.dedupKey ?? "-" }

        var walked: [String] = []
        try ModelWalk.forEach(FetchDescriptor<TokenSample>(), in: c, pageSize: 5) { s in
            walked.append(s.dedupKey ?? "-")
            guard walked.count == 5 else { return }
            // End of the first page: drop its second row.
            let gone = all[1]
            let other = ModelContext(c)
            for row in try other.fetch(FetchDescriptor<TokenSample>(predicate: #Predicate { $0.dedupKey == gone })) {
                other.delete(row)
            }
            try other.save()
        }
        #expect(walked == all)
    }

    /// A walk in `sampledAt` order returns what one sorted fetch does, ties
    /// included: a page boundary that falls inside a run of equal instants
    /// carries on from the row id it stopped at. With and without a predicate
    /// of the caller's own, which the walk's own condition is added to.
    @ScanActor
    @Test func aSortedWalkMatchesASortedFetch() throws {
        let c = try container()
        let context = ModelContext(c)
        // Seven instants, each shared by several rows, inserted out of order.
        for i in 0..<30 {
            let at = Date(timeIntervalSince1970: 1_800_000_000 + Double((i * 11) % 7) * 60)
            context.insert(TokenSample(
                sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5",
                inputTokens: Int64(i), outputTokens: 1, cacheReadTokens: 0,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, dedupKey: "k\(i)"))
        }
        try context.save()
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000 + 120)
        for predicate in [nil, #Predicate<TokenSample> { $0.sampledAt >= cutoff }] {
            let fetched = try ModelContext(c).fetch(FetchDescriptor<TokenSample>(
                predicate: predicate, sortBy: [SortDescriptor(\.sampledAt)])).map { $0.dedupKey ?? "-" }
            for pageSize in [1, 3, 4, 5, 30, 31] {
                var walked: [String] = []
                try ModelWalk.forEach(FetchDescriptor<TokenSample>(predicate: predicate),
                                      orderedBy: \.sampledAt, in: c, pageSize: pageSize) {
                    walked.append($0.dedupKey ?? "-")
                }
                #expect(walked == fetched, "page size \(pageSize), predicate \(predicate != nil)")
            }
        }
    }

    /// Pages are cut by the last row's key, so a walk has to own the order:
    /// a descriptor that brings its own is refused, not walked in pieces.
    @ScanActor
    @Test func aDescriptorWithItsOwnSortIsRefused() throws {
        let c = try container()
        let owner = ModelContext(c)
        let sorted = FetchDescriptor<TokenSample>(sortBy: [SortDescriptor(\.sampledAt)])
        #expect(throws: ModelWalk.WalkError.sortedDescriptor) {
            try ModelWalk.forEach(sorted, in: c) { _ in }
        }
        #expect(throws: ModelWalk.WalkError.sortedDescriptor) {
            try ModelWalk.forEach(sorted, orderedBy: \.sampledAt, in: c) { _ in }
        }
        #expect(throws: ModelWalk.WalkError.sortedDescriptor) {
            try ModelWalk.update(sorted, in: c, owner: owner) { _ in }
        }
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
