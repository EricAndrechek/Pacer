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
        HourlyAggregate.self,
        ProjectDailyAggregate.self,
        RateLimitSample.self,
        SessionInfo.self,
        ClaudeCodeMeta.self,
        JSONLFileCursor.self,
        ProjectPathAlias.self,
        configurations: config
    )
}

private func makeEntry(
    timestamp: Date,
    model: String = "claude-opus-4-7",
    input: Int64 = 100,
    output: Int64 = 200,
    cacheRead: Int64 = 0,
    storedCost: Double? = 0.10,
    dedup: String? = nil
) -> ParsedUsageEntry {
    ParsedUsageEntry(
        timestamp: timestamp,
        model: model,
        breakdown: TokenBreakdown(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0
        ),
        storedCostUSD: storedCost,
        dedupKey: dedup,
        sessionId: nil,
        projectPath: nil,
        claudeCodeVersion: nil,
        isApiErrorMessage: false
    )
}

/// Build a Date pinned to a specific local hour today. The persister
/// hashes hour-of-day via `Calendar.current`, so tests use the same.
private func dateAt(hour: Int, minute: Int = 0) -> Date {
    let cal = Calendar.current
    let comps = DateComponents(
        year: 2026, month: 3, day: 15,
        hour: hour, minute: minute, second: 0
    )
    return cal.date(from: comps) ?? Date()
}

private func sortedByKey(_ rows: [HourlyAggregate]) -> [HourlyAggregate] {
    rows.sorted { $0.dateHourModelKey < $1.dateHourModelKey }
}

// MARK: - Dirty-set tracking

@MainActor
@Test func samplePersisterMarksHourBucketDirtyOnInsert() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 14), dedup: "msg1:req1"))
    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 14, minute: 30), dedup: "msg2:req2"))
    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 15), dedup: "msg3:req3"))
    try persister.flush()

    let buckets = persister.dirtyHourBuckets
    // Same model, two distinct hours (14, 15) — two buckets.
    #expect(buckets.count == 2)
    #expect(buckets.contains(where: { $0.hour == 14 }))
    #expect(buckets.contains(where: { $0.hour == 15 }))
}

@MainActor
@Test func samplePersisterClearDirtyAlsoClearsHourBuckets() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 10), dedup: "msg1:req1"))
    try persister.flush()
    #expect(!persister.dirtyHourBuckets.isEmpty)

    persister.clearDirtyPairs()
    #expect(persister.dirtyHourBuckets.isEmpty)
}

// MARK: - Recomputer

@MainActor
@Test func recomputerWritesOneRowPerHourBucket() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 14), input: 100, storedCost: 0.10,
        dedup: "msg1:req1"))
    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 14, minute: 30), input: 150, storedCost: 0.15,
        dedup: "msg2:req2"))
    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 15), input: 200, storedCost: 0.20,
        dedup: "msg3:req3"))
    try context.save()
    try persister.flush()

    let recomputer = HourlyAggregateRecomputer(
        container: container, context: context, mode: .display)
    let stats = try await recomputer.recompute(buckets: persister.dirtyHourBuckets)
    try context.save()

    #expect(stats.bucketsRecomputed == 2)
    #expect(stats.aggregatesUpserted == 2)

    let rows = sortedByKey(try context.fetch(FetchDescriptor<HourlyAggregate>()))
    #expect(rows.count == 2)
    // Hour 14 bucket has two samples summed.
    let h14 = rows.first { $0.hour == 14 }
    #expect(h14?.inputTokens == 250)
    #expect(h14?.totalCostUSD == 0.25)
    #expect(h14?.sampleCount == 2)
    // Hour 15 bucket has one sample.
    let h15 = rows.first { $0.hour == 15 }
    #expect(h15?.inputTokens == 200)
    #expect(h15?.totalCostUSD == 0.20)
    #expect(h15?.sampleCount == 1)
}

@MainActor
@Test func recomputerSplitsByModelWithinSameHour() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 9), model: "claude-opus-4-7",
        input: 100, storedCost: 0.50, dedup: "msg1:req1"))
    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 9, minute: 15), model: "claude-sonnet-4-6",
        input: 100, storedCost: 0.05, dedup: "msg2:req2"))
    try context.save()
    try persister.flush()

    let recomputer = HourlyAggregateRecomputer(
        container: container, context: context, mode: .display)
    _ = try await recomputer.recompute(buckets: persister.dirtyHourBuckets)
    try context.save()

    let rows = try context.fetch(FetchDescriptor<HourlyAggregate>())
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.hour == 9 })
    #expect(Set(rows.map(\.model)) == ["claude-opus-4-7", "claude-sonnet-4-6"])
}

@MainActor
@Test func recomputerUpsertsExistingRowOnSecondPass() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 8), input: 100, storedCost: 0.10,
        dedup: "msg1:req1"))
    try context.save()
    try persister.flush()
    let recomputer = HourlyAggregateRecomputer(
        container: container, context: context, mode: .display)
    _ = try await recomputer.recompute(buckets: persister.dirtyHourBuckets)
    try context.save()
    persister.clearDirtyPairs()

    // Second sample lands in the same hour bucket; recomputer should
    // UPDATE in place rather than insert a second row.
    _ = try persister.insert(makeEntry(
        timestamp: dateAt(hour: 8, minute: 45), input: 50, storedCost: 0.05,
        dedup: "msg2:req2"))
    try context.save()
    try persister.flush()
    _ = try await recomputer.recompute(buckets: persister.dirtyHourBuckets)
    try context.save()

    let rows = try context.fetch(FetchDescriptor<HourlyAggregate>())
    #expect(rows.count == 1)
    #expect(rows.first?.inputTokens == 150)
    // 0.10 + 0.05 == 0.15000…2 in IEEE-754, so compare with epsilon.
    #expect(abs((rows.first?.totalCostUSD ?? 0) - 0.15) < 1e-9)
    #expect(rows.first?.sampleCount == 2)
}

// MARK: - Missing-bucket recovery (bootstrap path)

@MainActor
@Test func missingHourBucketsDetectedAtPreload() throws {
    // Seed the container with samples but no HourlyAggregate rows,
    // then construct a fresh persister and verify it surfaces every
    // (date, hour, model) triple in the missing-bucket set.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let first = try SamplePersister(context: context)
    _ = try first.insert(makeEntry(
        timestamp: dateAt(hour: 10), dedup: "msg1:req1"))
    _ = try first.insert(makeEntry(
        timestamp: dateAt(hour: 11), dedup: "msg2:req2"))
    try context.save()
    try first.flush()
    // Deliberately do NOT run the recomputer — leaves the gap.

    // Fresh persister rediscovers the same samples; preload should
    // flag both hour buckets as missing.
    let second = try SamplePersister(context: context)
    let missing = second.consumeMissingHourBuckets()
    #expect(missing.count == 2)
    #expect(missing.contains(where: { $0.hour == 10 }))
    #expect(missing.contains(where: { $0.hour == 11 }))
    // Second drain returns empty (one-shot semantics).
    #expect(second.consumeMissingHourBuckets().isEmpty)
}

@MainActor
@Test func recomputerEmptyBucketSetIsNoop() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let recomputer = HourlyAggregateRecomputer(
        container: container, context: context, mode: .display)
    let stats = try await recomputer.recompute(buckets: [])
    #expect(stats.bucketsRecomputed == 0)
    #expect(stats.aggregatesUpserted == 0)
    #expect(stats.aggregatesDeleted == 0)
}
