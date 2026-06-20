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
    timestamp: Date = Date(timeIntervalSince1970: 1_756_800_000),
    model: String = "claude-opus-4-7",
    input: Int64 = 100,
    output: Int64 = 200,
    cacheRead: Int64 = 0,
    cache5m: Int64 = 0,
    cache1h: Int64 = 0,
    storedCost: Double? = nil,
    dedup: String? = nil,
    sessionId: String? = nil,
    projectPath: String? = nil
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
        sessionId: sessionId,
        projectPath: projectPath,
        claudeCodeVersion: nil,
        isApiErrorMessage: false
    )
}

// MARK: - SamplePersister

@ScanActor
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

@ScanActor
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

@ScanActor
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

@ScanActor
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

@ScanActor
@Test func samplePersisterRecoversMissingAggregatePairs() async throws {
    // Reproduces the bug where a re-scan after a DailyAggregate-loss
    // event (clean wipe of just the aggregate table, partial recompute
    // crash, scanVersion bump that triggered re-read but every entry
    // dedup-skipped, etc.) would never re-create the missing aggregate
    // rows because the dedup path never marks (date, model) dirty.
    //
    // The persister now scans for (date, model) pairs with samples but
    // no aggregate at init time and exposes them via
    // consumeMissingAggregatePairs() so ScanCoordinator can feed them
    // to the recomputer on first cycle.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let day1 = Date(timeIntervalSince1970: 1_756_800_000)
    let day2 = day1.addingTimeInterval(86_400 * 5)
    let day1Str = TokenSample.formatDate(day1)
    let day2Str = TokenSample.formatDate(day2)

    // Three samples: two on day1 (different models), one on day2.
    context.insert(TokenSample(from: makeEntry(timestamp: day1, model: "claude-opus-4-7", dedup: "a:1")))
    context.insert(TokenSample(from: makeEntry(timestamp: day1, model: "claude-sonnet-4-6", dedup: "b:1")))
    context.insert(TokenSample(from: makeEntry(timestamp: day2, model: "claude-opus-4-7", dedup: "c:1")))
    // One DailyAggregate already exists for (day1, opus) — partial
    // recovery state. The other two pairs should be flagged as missing.
    context.insert(DailyAggregate(date: day1Str, model: "claude-opus-4-7", inputTokens: 100))
    try context.save()

    let persister = try SamplePersister(context: context)
    let recovered = persister.consumeMissingAggregatePairs()

    #expect(recovered.count == 2)
    #expect(recovered.contains(DateModelPair(date: day1Str, model: "claude-sonnet-4-6")))
    #expect(recovered.contains(DateModelPair(date: day2Str, model: "claude-opus-4-7")))

    // One-shot: a second consume returns empty.
    #expect(persister.consumeMissingAggregatePairs().isEmpty)

    // End-to-end check: feeding the recovered pairs into the recomputer
    // actually creates the missing aggregates.
    persister.addDirtyPairs(recovered)
    let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)
    _ = try await recomputer.recompute(pairs: persister.dirtyPairs)

    // Three aggregates total: the pre-existing (day1, opus) + the two
    // recovered ones.
    #expect(try context.fetchCount(FetchDescriptor<DailyAggregate>()) == 3)
}

@ScanActor
@Test func samplePersisterRecoveryEmptyOnHealthyStore() throws {
    // Healthy store: every (date, model) pair already has an aggregate.
    // Recovery set should be empty so the first scan cycle is a no-op.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    let dayStr = TokenSample.formatDate(day)
    context.insert(TokenSample(from: makeEntry(timestamp: day, dedup: "a:1")))
    context.insert(DailyAggregate(date: dayStr, model: "claude-opus-4-7", inputTokens: 100))
    try context.save()

    let persister = try SamplePersister(context: context)
    #expect(persister.consumeMissingAggregatePairs().isEmpty)
}

@ScanActor
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

@ScanActor
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

// Regression: a user merging two projects with many sources used to
// crash SwiftData's SQL generator. The predicate used
// `sources.contains(sample.projectPath ?? "")`, which compiled fine
// but threw NSInvalidArgumentException
// ("unimplemented SQL generation for predicate ... bad LHS") at fetch
// time because SwiftData can't put a TERNARY on the left side of IN.
// Mix matching, non-matching, and nil-projectPath rows so the
// per-source iteration has to filter all three.
@ScanActor
@Test func samplePersisterCanonicalizesAffectedSamplesWithManySources() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let pathA = "/Users/eric/Code/work/projA"
    let pathB = "/Users/eric/Code/work/projB"
    let unrelated = "/Users/eric/Code/work/other"
    _ = try persister.insert(makeEntry(dedup: "a:1", projectPath: pathA))
    _ = try persister.insert(makeEntry(dedup: "b:1", projectPath: pathB))
    _ = try persister.insert(makeEntry(dedup: "c:1", projectPath: unrelated))
    _ = try persister.insert(makeEntry(dedup: "d:1", projectPath: nil))
    try persister.flush()

    // Both A and B alias to the same canonical. The unrelated and
    // nil-path rows must be untouched.
    let canonical = "/Users/eric/Code/work/canonical"
    let aliases = [pathA: canonical, pathB: canonical]
    let changed = try persister.canonicalizeAffectedSamples(aliases: aliases)
    #expect(changed == 2)

    let samples = try context.fetch(
        FetchDescriptor<TokenSample>(sortBy: [SortDescriptor(\.dedupKey)])
    )
    #expect(samples[0].projectPath == canonical)
    #expect(samples[1].projectPath == canonical)
    #expect(samples[2].projectPath == unrelated)
    #expect(samples[3].projectPath == nil)
}

// MARK: - AggregateRecomputer

@ScanActor
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
    let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)
    let stats = try await recomputer.recompute(pairs: persister.dirtyPairs)
    #expect(stats.aggregatesUpserted == 1)

    let aggs = try context.fetch(FetchDescriptor<DailyAggregate>())
    #expect(aggs.count == 1)
    #expect(aggs[0].date == dirtyDate)
    #expect(aggs[0].inputTokens == 300)
    #expect(aggs[0].outputTokens == 130)
}

@ScanActor
@Test func aggregateRecomputerSplitsByModel() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(timestamp: day, model: "claude-opus-4-7", input: 100, dedup: "a:1"))
    _ = try persister.insert(makeEntry(timestamp: day, model: "claude-sonnet-4-6", input: 50, dedup: "b:1"))
    try persister.flush()

    let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)
    let stats = try await recomputer.recompute(pairs: persister.dirtyPairs)
    #expect(stats.aggregatesUpserted == 2)

    let aggs = try context.fetch(FetchDescriptor<DailyAggregate>(sortBy: [SortDescriptor(\.model)]))
    #expect(aggs.count == 2)
    #expect(aggs[0].model == "claude-opus-4-7")
    #expect(aggs[0].inputTokens == 100)
    #expect(aggs[1].model == "claude-sonnet-4-6")
    #expect(aggs[1].inputTokens == 50)
}

@ScanActor
@Test func aggregateRecomputerUpsertsOnSecondPass() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(timestamp: day, input: 100, dedup: "a:1"))
    try persister.flush()
    let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)
    _ = try await recomputer.recompute(pairs: persister.dirtyPairs)

    // Second insert into same bucket; recompute should overwrite, not duplicate.
    _ = try persister.insert(makeEntry(timestamp: day, input: 50, dedup: "b:1"))
    try persister.flush()
    _ = try await recomputer.recompute(pairs: persister.dirtyPairs)

    let aggs = try context.fetch(FetchDescriptor<DailyAggregate>())
    #expect(aggs.count == 1)
    #expect(aggs[0].inputTokens == 150)
}

@ScanActor
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

    let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)
    _ = try await recomputer.recompute(pairs: persister.dirtyPairs)

    let agg = try context.fetch(FetchDescriptor<DailyAggregate>()).first!
    #expect(agg.inputTokens == 11)
    #expect(agg.outputTokens == 22)
    #expect(agg.cacheReadTokens == 33)
    #expect(agg.cacheCreation5mTokens == 44)
    #expect(agg.cacheCreation1hTokens == 55)
}

@ScanActor
@Test func aggregateRecomputerDisplayModeSumsStoredCosts() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(timestamp: day, storedCost: 0.10, dedup: "a:1"))
    _ = try persister.insert(makeEntry(timestamp: day, storedCost: 0.30, dedup: "b:1"))
    _ = try persister.insert(makeEntry(timestamp: day, storedCost: nil, dedup: "c:1"))
    try persister.flush()

    let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)
    _ = try await recomputer.recompute(pairs: persister.dirtyPairs)

    let agg = try context.fetch(FetchDescriptor<DailyAggregate>()).first!
    // .display sums storedCost only, treating nil as 0.
    #expect(abs(agg.totalCostUSD - 0.40) < 0.0001)
}

@ScanActor
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

    let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)
    let stats = try await recomputer.recompute(pairs: [DateModelPair(date: date, model: model)])
    #expect(stats.aggregatesDeleted == 1)
    #expect(try context.fetchCount(FetchDescriptor<DailyAggregate>()) == 0)
}

// MARK: - AggregateRecomputer incremental fast path

@ScanActor
@Test func aggregateRecomputerFastPathAddsDeltaToExistingRow() async throws {
    // Verifies the incremental fast path is engaged AND produces a
    // numerically identical result to the legacy full-recompute path
    // for a co-occurring "existing aggregate + new inserts" cycle.
    // Regressions that silently disable the fast path (e.g. all pairs
    // polluted) would show up as `fastPathApplied == 0` here.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)
    let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)

    let day = Date(timeIntervalSince1970: 1_756_800_000)

    // Cycle 1: insert 1 sample, recompute (full path). Aggregate is born.
    _ = try persister.insert(makeEntry(
        timestamp: day, input: 100, output: 10, cacheRead: 1, storedCost: 0.50, dedup: "a:1"))
    try persister.flush()
    _ = try await recomputer.recompute(
        pairs: persister.dirtyPairs,
        pending: persister.pendingPairSamples,
        polluted: persister.pollutedDailyPairs
    )
    persister.clearDirtyPairs()

    // Cycle 2: insert 1 more sample to the same pair, recompute. Fast
    // path should engage because the aggregate already exists and the
    // pair isn't polluted.
    _ = try persister.insert(makeEntry(
        timestamp: day, input: 25, output: 5, cacheRead: 1, storedCost: 0.20, dedup: "b:1"))
    try persister.flush()
    let stats = try await recomputer.recompute(
        pairs: persister.dirtyPairs,
        pending: persister.pendingPairSamples,
        polluted: persister.pollutedDailyPairs
    )

    #expect(stats.fastPathApplied == 1)
    #expect(stats.pairsRecomputed == 1)
    let agg = try context.fetch(FetchDescriptor<DailyAggregate>()).first!
    #expect(agg.inputTokens == 125)
    #expect(agg.outputTokens == 15)
    #expect(abs(agg.totalCostUSD - 0.70) < 1e-9)
}

@ScanActor
@Test func aggregateRecomputerFastPathRespectsPollutedPair() async throws {
    // When ScanCoordinator folds a recovery pair into the dirty set
    // (via `addDirtyPairs`), the pair is polluted and must NOT take
    // the fast path even when pending samples exist for it — the
    // existing aggregate's totals may be stale.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)
    let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)

    let day = Date(timeIntervalSince1970: 1_756_800_000)

    // Seed an existing aggregate that DOESN'T match any underlying
    // sample (simulating a stale row that needs full recompute).
    let pair = DateModelPair(date: TokenSample.formatDate(day), model: "claude-opus-4-7")
    context.insert(DailyAggregate(
        date: pair.date, model: pair.model,
        inputTokens: 999, outputTokens: 999, totalCostUSD: 99.0
    ))
    try context.save()

    // New insert plus mark the pair polluted (recovery path semantics).
    _ = try persister.insert(makeEntry(
        timestamp: day, input: 5, output: 5, storedCost: 0.05, dedup: "x:1"))
    persister.addDirtyPairs([pair])
    try persister.flush()

    let stats = try await recomputer.recompute(
        pairs: persister.dirtyPairs,
        pending: persister.pendingPairSamples,
        polluted: persister.pollutedDailyPairs
    )
    #expect(stats.fastPathApplied == 0)
    let agg = try context.fetch(FetchDescriptor<DailyAggregate>()).first!
    // Full recompute reset the bogus 999/99.0 numbers to the actual
    // sample totals — 5 input, 5 output, $0.05.
    #expect(agg.inputTokens == 5)
    #expect(agg.outputTokens == 5)
    #expect(abs(agg.totalCostUSD - 0.05) < 1e-9)
}

/// Sendable snapshot of the bits of `DailyAggregate` this test compares.
/// SwiftData @Model classes are not Sendable (Swift 6 strict
/// concurrency); copying out the value-typed fields inside the
/// MainActor closure lets us return the snapshot across the async
/// boundary without bridging the persistent model itself.
private struct AggregateSnapshot: Sendable {
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreation5mTokens: Int64
    let cacheCreation1hTokens: Int64
    let totalCostUSD: Double
}

@ScanActor
@Test func aggregateRecomputerFastPathProducesSameResultAsFullPath() async throws {
    // Property: the fast path and the full-recompute path agree on
    // the resulting `DailyAggregate` for the same input. Run both
    // against equivalent contexts and compare token totals.
    let dayInstant = Date(timeIntervalSince1970: 1_756_800_000)
    let runScenario = { @ScanActor (forceFullPath: Bool) async throws -> AggregateSnapshot in
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let persister = try SamplePersister(context: context)
        let recomputer = AggregateRecomputer(container: container, context: context, mode: .display)

        // Cycle 1.
        _ = try persister.insert(makeEntry(
            timestamp: dayInstant, input: 7, output: 3, cacheRead: 1,
            cache5m: 2, cache1h: 4, storedCost: 0.11, dedup: "a:1"))
        try persister.flush()
        _ = try await recomputer.recompute(
            pairs: persister.dirtyPairs,
            pending: persister.pendingPairSamples,
            polluted: persister.pollutedDailyPairs
        )
        persister.clearDirtyPairs()

        // Cycle 2.
        _ = try persister.insert(makeEntry(
            timestamp: dayInstant, input: 13, output: 9, cacheRead: 2,
            cache5m: 0, cache1h: 8, storedCost: 0.23, dedup: "b:1"))
        try persister.flush()
        // forceFullPath simulates a polluted pair so the fast path
        // is bypassed even though deltas exist.
        let pending = forceFullPath ? [:] : persister.pendingPairSamples
        let polluted: Set<DateModelPair> = forceFullPath ? persister.dirtyPairs : []
        _ = try await recomputer.recompute(
            pairs: persister.dirtyPairs, pending: pending, polluted: polluted
        )
        let agg = try context.fetch(FetchDescriptor<DailyAggregate>()).first!
        return AggregateSnapshot(
            inputTokens: agg.inputTokens,
            outputTokens: agg.outputTokens,
            cacheReadTokens: agg.cacheReadTokens,
            cacheCreation5mTokens: agg.cacheCreation5mTokens,
            cacheCreation1hTokens: agg.cacheCreation1hTokens,
            totalCostUSD: agg.totalCostUSD
        )
    }

    let fastPath = try await runScenario(false)
    let fullPath = try await runScenario(true)
    #expect(fastPath.inputTokens == fullPath.inputTokens)
    #expect(fastPath.outputTokens == fullPath.outputTokens)
    #expect(fastPath.cacheReadTokens == fullPath.cacheReadTokens)
    #expect(fastPath.cacheCreation5mTokens == fullPath.cacheCreation5mTokens)
    #expect(fastPath.cacheCreation1hTokens == fullPath.cacheCreation1hTokens)
    #expect(abs(fastPath.totalCostUSD - fullPath.totalCostUSD) < 1e-9)
}

// MARK: - ProjectAggregateRecomputer

@ScanActor
@Test func projectAggregateRecomputerUpsertsBucket() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    let dayStr = TokenSample.formatDate(day)
    _ = try persister.insert(makeEntry(
        timestamp: day, model: "claude-opus-4-7",
        storedCost: 0.10, dedup: "a:1",
        sessionId: "sess-1", projectPath: "/Users/eric/repo-a"))
    _ = try persister.insert(makeEntry(
        timestamp: day, model: "claude-sonnet-4-6",
        storedCost: 0.05, dedup: "b:1",
        sessionId: "sess-2", projectPath: "/Users/eric/repo-a"))
    _ = try persister.insert(makeEntry(
        timestamp: day, model: "claude-opus-4-7",
        storedCost: 0.20, dedup: "c:1",
        sessionId: "sess-3", projectPath: "/Users/eric/repo-b"))
    try persister.flush()

    let recomputer = ProjectAggregateRecomputer(container: container, context: context)
    let stats = try await recomputer.recompute(pairs: persister.dirtyProjectDates)
    #expect(stats.pairsRecomputed == 2)
    #expect(stats.aggregatesUpserted == 2)

    let aggregates = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
    #expect(aggregates.count == 2)

    let repoA = aggregates.first { $0.projectPath == "/Users/eric/repo-a" }!
    #expect(repoA.date == dayStr)
    #expect(abs(repoA.totalCostUSD - 0.15) < 0.0001)
    #expect(repoA.sessionCount == 2)
    #expect(repoA.modelCount == 2)

    let repoB = aggregates.first { $0.projectPath == "/Users/eric/repo-b" }!
    #expect(repoB.sessionCount == 1)
    #expect(repoB.modelCount == 1)
    #expect(abs(repoB.totalCostUSD - 0.20) < 0.0001)
}

@ScanActor
@Test func projectAggregateRecomputerHandlesMissingProjectPath() async throws {
    // Samples with `projectPath == nil` land in the "(unknown)" bucket
    // so they still show up in the Projects list.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(timestamp: day, dedup: "a:1", projectPath: nil))
    _ = try persister.insert(makeEntry(timestamp: day, dedup: "b:1", projectPath: nil))
    try persister.flush()

    let recomputer = ProjectAggregateRecomputer(container: container, context: context)
    _ = try await recomputer.recompute(pairs: persister.dirtyProjectDates)

    let aggregates = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
    #expect(aggregates.count == 1)
    #expect(aggregates.first?.projectPath == ProjectDailyAggregate.unknownProjectPath)
}

@ScanActor
@Test func projectAggregateRecomputerBulkPathBackfill() async throws {
    // 64+ dirty pairs should take the bulk path: one fetch + group
    // instead of N small fetches. Verify it produces the same rows
    // either way.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let baseDay = Date(timeIntervalSince1970: 1_756_800_000)
    // 70 distinct (project, date) buckets, one sample each.
    for i in 0..<70 {
        let day = baseDay.addingTimeInterval(Double(i) * 86_400)
        _ = try persister.insert(makeEntry(
            timestamp: day,
            storedCost: 0.01,
            dedup: "row-\(i)",
            sessionId: "sess-\(i)",
            projectPath: "/p\(i % 5)"))  // 5 projects, 14 days each
    }
    try persister.flush()

    let recomputer = ProjectAggregateRecomputer(container: container, context: context)
    let stats = try await recomputer.recompute(pairs: persister.dirtyProjectDates)
    #expect(stats.pairsRecomputed == 70)
    #expect(stats.aggregatesUpserted == 70)
    #expect(try context.fetchCount(FetchDescriptor<ProjectDailyAggregate>()) == 70)
}

// MARK: - SessionInfoRecomputer

@ScanActor
@Test func sessionRecomputerRollsUpPerSession() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    let later = day.addingTimeInterval(3_600)
    _ = try persister.insert(makeEntry(
        timestamp: day, model: "claude-opus-4-7",
        input: 100, output: 50, cacheRead: 10,
        storedCost: 0.10, dedup: "a:1",
        sessionId: "sess-A", projectPath: "/p1"))
    _ = try persister.insert(makeEntry(
        timestamp: later, model: "claude-sonnet-4-6",
        input: 5, output: 5, cacheRead: 0,
        storedCost: 0.02, dedup: "b:1",
        sessionId: "sess-A", projectPath: "/p1"))
    _ = try persister.insert(makeEntry(
        timestamp: day, model: "claude-opus-4-7",
        input: 1, output: 1, cacheRead: 1,
        storedCost: 0.01, dedup: "c:1",
        sessionId: "sess-B", projectPath: "/p2"))
    try persister.flush()

    let recomputer = SessionInfoRecomputer(container: container, context: context)
    let stats = try await recomputer.recompute(sessionIds: persister.dirtySessionIds)
    #expect(stats.sessionsRecomputed == 2)
    #expect(stats.sessionsUpserted == 2)

    let sessions = try context.fetch(FetchDescriptor<SessionInfo>(
        sortBy: [SortDescriptor(\.sessionId)]
    ))
    #expect(sessions.count == 2)

    let a = sessions.first { $0.sessionId == "sess-A" }!
    #expect(a.firstSeenAt == day)
    #expect(a.lastSeenAt == later)
    #expect(a.projectPath == "/p1")
    #expect(a.cumulativeInputTokens == 105)
    #expect(a.cumulativeOutputTokens == 55)
    #expect(a.cumulativeCacheReadTokens == 10)
    #expect(abs(a.cumulativeCostUSD - 0.12) < 0.0001)
    // sess-A's opus turn was 160 tokens vs sonnet's 10 — opus tops.
    #expect(a.topModel == "claude-opus-4-7")

    let b = sessions.first { $0.sessionId == "sess-B" }!
    // `totalTokens` is input + output only — cache_read is excluded
    // since it's effectively free and would dwarf the meaningful signal.
    // sess-B has input=1, output=1, cacheRead=1, so totalTokens=2.
    #expect(b.totalTokens == 2)
    #expect(b.topModel == "claude-opus-4-7")
}

@ScanActor
@Test func sessionRecomputerSkipsEntriesWithoutSessionId() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(timestamp: day, dedup: "a:1", sessionId: nil))
    _ = try persister.insert(makeEntry(timestamp: day, dedup: "b:1", sessionId: ""))
    try persister.flush()

    #expect(persister.dirtySessionIds.isEmpty)

    let recomputer = SessionInfoRecomputer(container: container, context: context)
    let stats = try await recomputer.recompute(sessionIds: persister.dirtySessionIds)
    #expect(stats.sessionsRecomputed == 0)
    #expect(try context.fetchCount(FetchDescriptor<SessionInfo>()) == 0)
}

@ScanActor
@Test func sessionRecomputerUpsertsOnSecondPass() async throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    _ = try persister.insert(makeEntry(
        timestamp: day, input: 100, dedup: "a:1",
        sessionId: "sess-A", projectPath: "/p1"))
    try persister.flush()
    let recomputer = SessionInfoRecomputer(container: container, context: context)
    _ = try await recomputer.recompute(sessionIds: persister.dirtySessionIds)

    persister.clearDirtyPairs()
    let later = day.addingTimeInterval(60)
    _ = try persister.insert(makeEntry(
        timestamp: later, input: 50, dedup: "b:1",
        sessionId: "sess-A", projectPath: "/p1"))
    try persister.flush()
    _ = try await recomputer.recompute(sessionIds: persister.dirtySessionIds)

    let sessions = try context.fetch(FetchDescriptor<SessionInfo>())
    #expect(sessions.count == 1)
    #expect(sessions[0].cumulativeInputTokens == 150)
    #expect(sessions[0].lastSeenAt == later)
}

@ScanActor
@Test func sessionRecomputerBulkPathBackfill() async throws {
    // 64+ dirty session ids should take the bulk path: one fetch +
    // group instead of N small fetches. Verify we still get all
    // SessionInfo rows back.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let persister = try SamplePersister(context: context)

    let baseDay = Date(timeIntervalSince1970: 1_756_800_000)
    for i in 0..<70 {
        _ = try persister.insert(makeEntry(
            timestamp: baseDay.addingTimeInterval(Double(i) * 60),
            storedCost: 0.01,
            dedup: "row-\(i)",
            sessionId: "sess-\(i)",
            projectPath: "/p\(i % 5)"))
    }
    try persister.flush()

    let recomputer = SessionInfoRecomputer(container: container, context: context)
    let stats = try await recomputer.recompute(sessionIds: persister.dirtySessionIds)
    #expect(stats.sessionsRecomputed == 70)
    #expect(stats.sessionsUpserted == 70)
    #expect(try context.fetchCount(FetchDescriptor<SessionInfo>()) == 70)
}

@ScanActor
@Test func samplePersisterRecoversMissingSessionIds() throws {
    // Backfill case: TokenSamples already exist with sessionIds but
    // there are no SessionInfo rows. The persister should surface
    // every distinct sessionId as missing.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    context.insert(TokenSample(from: makeEntry(
        timestamp: day, dedup: "a:1", sessionId: "sess-A", projectPath: "/p1")))
    context.insert(TokenSample(from: makeEntry(
        timestamp: day, dedup: "b:1", sessionId: "sess-A", projectPath: "/p1")))
    context.insert(TokenSample(from: makeEntry(
        timestamp: day, dedup: "c:1", sessionId: "sess-B", projectPath: "/p2")))
    // Session-less sample shouldn't show up in the recovery set.
    context.insert(TokenSample(from: makeEntry(
        timestamp: day, dedup: "d:1", sessionId: nil)))
    try context.save()

    let persister = try SamplePersister(context: context)
    let recovered = persister.consumeMissingSessionIds()
    #expect(recovered.count == 2)
    #expect(recovered.contains("sess-A"))
    #expect(recovered.contains("sess-B"))
    // One-shot drain.
    #expect(persister.consumeMissingSessionIds().isEmpty)
}

// MARK: - missing-project-aggregate recovery (existing test below)

@ScanActor
@Test func samplePersisterRecoversMissingProjectAggregatePairs() throws {
    // Backfill check: when ProjectDailyAggregate is empty but
    // TokenSamples already exist (the upgrade case), the persister
    // should surface every (project, date) pair in
    // missingProjectAggregatePairs so ScanCoordinator can rebuild.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let day = Date(timeIntervalSince1970: 1_756_800_000)
    let dayStr = TokenSample.formatDate(day)
    context.insert(TokenSample(from: makeEntry(
        timestamp: day, dedup: "a:1", projectPath: "/p1")))
    context.insert(TokenSample(from: makeEntry(
        timestamp: day, dedup: "b:1", projectPath: "/p2")))
    context.insert(TokenSample(from: makeEntry(
        timestamp: day, dedup: "c:1", projectPath: nil)))
    try context.save()

    let persister = try SamplePersister(context: context)
    let recovered = persister.consumeMissingProjectAggregatePairs()
    #expect(recovered.count == 3)
    #expect(recovered.contains(ProjectDatePair(projectPath: "/p1", date: dayStr)))
    #expect(recovered.contains(ProjectDatePair(projectPath: "/p2", date: dayStr)))
    #expect(recovered.contains(ProjectDatePair(
        projectPath: ProjectDailyAggregate.unknownProjectPath, date: dayStr)))

    // One-shot — second consume returns empty.
    #expect(persister.consumeMissingProjectAggregatePairs().isEmpty)
}
