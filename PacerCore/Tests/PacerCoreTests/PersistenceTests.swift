import Foundation
import SwiftData
import Testing
@testable import PacerCore

private func makeInMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: Heartbeat.self,
        TokenSample.self,
        DailyAggregate.self,
        RateLimitSample.self,
        SessionInfo.self,
        ClaudeCodeMeta.self,
        configurations: config
    )
}

private func makeEntry(
    timestamp: Date = Date(timeIntervalSince1970: 1_756_800_000),
    model: String = "claude-opus-4-7",
    input: Int64 = 100,
    output: Int64 = 200,
    cacheRead: Int64 = 0,
    cache5m: Int64 = 0,
    cache1h: Int64 = 0,
    storedCost: Double? = nil,
    dedup: String? = nil
) -> ParsedUsageEntry {
    ParsedUsageEntry(
        timestamp: timestamp,
        model: model,
        breakdown: TokenBreakdown(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreation5mTokens: cache5m,
            cacheCreation1hTokens: cache1h
        ),
        storedCostUSD: storedCost,
        dedupKey: dedup,
        sessionId: nil,
        projectPath: nil,
        claudeCodeVersion: nil,
        isApiErrorMessage: false
    )
}

// MARK: - SamplePersister

@MainActor
@Test func samplePersisterInsertsNewEntries() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    #expect(try persister.insert(makeEntry(dedup: "msg1:req1")) == true)
    #expect(try persister.insert(makeEntry(dedup: "msg2:req2")) == true)
    try persister.flush()

    #expect(try context.fetchCount(FetchDescriptor<TokenSample>()) == 2)
    #expect(persister.stats.inserted == 2)
    #expect(persister.stats.skippedAsDuplicate == 0)
}

@MainActor
@Test func samplePersisterDedupesByKey() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    #expect(try persister.insert(makeEntry(dedup: "msg1:req1")) == true)
    // Same dedup key — should be rejected without a DB query.
    #expect(try persister.insert(makeEntry(dedup: "msg1:req1")) == false)
    #expect(try persister.insert(makeEntry(dedup: "msg1:req1")) == false)
    try persister.flush()

    #expect(try context.fetchCount(FetchDescriptor<TokenSample>()) == 1)
    #expect(persister.stats.inserted == 1)
    #expect(persister.stats.skippedAsDuplicate == 2)
}

@MainActor
@Test func samplePersisterAcceptsAllNilDedupEntries() throws {
    // The "no dedup key, accept everything" path. We deliberately
    // accept duplicates here rather than guess at heuristic dedup —
    // ccusage makes the same call.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    for _ in 0..<5 {
        _ = try persister.insert(makeEntry(dedup: nil))
    }
    try persister.flush()

    #expect(try context.fetchCount(FetchDescriptor<TokenSample>()) == 5)
    #expect(persister.stats.skippedAsDuplicate == 0)
}

@MainActor
@Test func samplePersisterPreloadsExistingDedupKeys() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    // Pre-populate: simulate a prior scan having inserted this row.
    context.insert(TokenSample(from: makeEntry(dedup: "preexisting:1")))
    try context.save()

    let persister = try SamplePersister(context: context)
    #expect(try persister.insert(makeEntry(dedup: "preexisting:1")) == false)
    #expect(try persister.insert(makeEntry(dedup: "fresh:1")) == true)
    try persister.flush()

    // Original + one new = 2 total.
    #expect(try context.fetchCount(FetchDescriptor<TokenSample>()) == 2)
}

@MainActor
@Test func samplePersisterTracksDirtyPairs() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day1 = Date(timeIntervalSince1970: 1_756_800_000) // some specific instant
    let day2 = day1.addingTimeInterval(86_400 * 5)
    _ = try persister.insert(makeEntry(timestamp: day1, model: "claude-opus-4-7", dedup: "a:1"))
    _ = try persister.insert(makeEntry(timestamp: day1, model: "claude-sonnet-4-6", dedup: "b:1"))
    _ = try persister.insert(makeEntry(timestamp: day2, model: "claude-opus-4-7", dedup: "c:1"))
    try persister.flush()

    // Three distinct (date, model) pairs.
    #expect(persister.dirtyPairs.count == 3)
}

@MainActor
@Test func samplePersisterSavesEveryBatch() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    // Tiny batch size so we trigger save() inside insert().
    let persister = try SamplePersister(context: context, saveBatchSize: 2)

    _ = try persister.insert(makeEntry(dedup: "a:1"))
    _ = try persister.insert(makeEntry(dedup: "b:1"))
    // After the second insert, save() should have fired automatically.
    // Open a fresh context to check committed state.
    let otherContext = ModelContext(container)
    #expect(try otherContext.fetchCount(FetchDescriptor<TokenSample>()) == 2)
}

// MARK: - AggregateRecomputer

@MainActor
@Test func aggregateRecomputerRollsUpDailySums() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(timestamp: day, input: 100, output: 50, dedup: "a:1"))
    _ = try persister.insert(makeEntry(timestamp: day, input: 200, output: 80, dedup: "b:1"))
    try persister.flush()

    let dirtyDate = TokenSample.formatDate(day)
    // Cost mode .display so we don't need network/pricing for this test.
    let recomputer = AggregateRecomputer(context: context, mode: .display)
    let stats = try await recomputer.recompute(pairs: persister.dirtyPairs)
    #expect(stats.aggregatesUpserted == 1)

    let aggs = try context.fetch(FetchDescriptor<DailyAggregate>())
    #expect(aggs.count == 1)
    #expect(aggs[0].date == dirtyDate)
    #expect(aggs[0].inputTokens == 300)
    #expect(aggs[0].outputTokens == 130)
}

@MainActor
@Test func aggregateRecomputerSplitsByModel() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(timestamp: day, model: "claude-opus-4-7", input: 100, dedup: "a:1"))
    _ = try persister.insert(makeEntry(timestamp: day, model: "claude-sonnet-4-6", input: 50, dedup: "b:1"))
    try persister.flush()

    let recomputer = AggregateRecomputer(context: context, mode: .display)
    let stats = try await recomputer.recompute(pairs: persister.dirtyPairs)
    #expect(stats.aggregatesUpserted == 2)

    let aggs = try context.fetch(FetchDescriptor<DailyAggregate>(sortBy: [SortDescriptor(\.model)]))
    #expect(aggs.count == 2)
    #expect(aggs[0].model == "claude-opus-4-7")
    #expect(aggs[0].inputTokens == 100)
    #expect(aggs[1].model == "claude-sonnet-4-6")
    #expect(aggs[1].inputTokens == 50)
}

@MainActor
@Test func aggregateRecomputerUpsertsOnSecondPass() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(timestamp: day, input: 100, dedup: "a:1"))
    try persister.flush()
    let recomputer = AggregateRecomputer(context: context, mode: .display)
    _ = try await recomputer.recompute(pairs: persister.dirtyPairs)

    // Second insert into same bucket; recompute should overwrite, not duplicate.
    _ = try persister.insert(makeEntry(timestamp: day, input: 50, dedup: "b:1"))
    try persister.flush()
    _ = try await recomputer.recompute(pairs: persister.dirtyPairs)

    let aggs = try context.fetch(FetchDescriptor<DailyAggregate>())
    #expect(aggs.count == 1)
    #expect(aggs[0].inputTokens == 150)
}

@MainActor
@Test func aggregateRecomputerSumsAllFiveCacheCategories() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(
        timestamp: day, input: 1, output: 2, cacheRead: 3, cache5m: 4, cache1h: 5, dedup: "a:1"))
    _ = try persister.insert(makeEntry(
        timestamp: day, input: 10, output: 20, cacheRead: 30, cache5m: 40, cache1h: 50, dedup: "b:1"))
    try persister.flush()

    let recomputer = AggregateRecomputer(context: context, mode: .display)
    _ = try await recomputer.recompute(pairs: persister.dirtyPairs)

    let agg = try context.fetch(FetchDescriptor<DailyAggregate>()).first!
    #expect(agg.inputTokens == 11)
    #expect(agg.outputTokens == 22)
    #expect(agg.cacheReadTokens == 33)
    #expect(agg.cacheCreation5mTokens == 44)
    #expect(agg.cacheCreation1hTokens == 55)
}

@MainActor
@Test func aggregateRecomputerDisplayModeSumsStoredCosts() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(timestamp: day, storedCost: 0.10, dedup: "a:1"))
    _ = try persister.insert(makeEntry(timestamp: day, storedCost: 0.30, dedup: "b:1"))
    _ = try persister.insert(makeEntry(timestamp: day, storedCost: nil, dedup: "c:1"))
    try persister.flush()

    let recomputer = AggregateRecomputer(context: context, mode: .display)
    _ = try await recomputer.recompute(pairs: persister.dirtyPairs)

    let agg = try context.fetch(FetchDescriptor<DailyAggregate>()).first!
    // .display sums storedCost only, treating nil as 0.
    #expect(abs(agg.totalCostUSD - 0.40) < 0.0001)
}

@MainActor
@Test func aggregateRecomputerDeletesEmptyBucket() async throws {
    // Edge case: a (date, model) pair gets passed in with no underlying
    // samples. Shouldn't happen in normal flow but defensive: the
    // existing aggregate row, if any, gets removed.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let date = "2026-05-06"
    let model = "claude-opus-4-7"
    context.insert(DailyAggregate(date: date, model: model, inputTokens: 999))
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<DailyAggregate>()) == 1)

    let recomputer = AggregateRecomputer(context: context, mode: .display)
    let stats = try await recomputer.recompute(pairs: [DateModelPair(date: date, model: model)])
    #expect(stats.aggregatesDeleted == 1)
    #expect(try context.fetchCount(FetchDescriptor<DailyAggregate>()) == 0)
}
