import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Round-trip every schema model through an in-memory `ModelContainer`
/// to catch:
///   - Missing default values that crash on insert
///   - `@Attribute(.unique)` collisions vs. expectations
///   - Predicate mis-types
/// These tests don't validate semantics (that's per-feature) — they
/// guard the wire shape so a schema typo can't slip through.

private func makeInMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: Heartbeat.self,
        TokenSample.self,
        DailyAggregate.self,
        ProjectDailyAggregate.self,
        RateLimitSample.self,
        SessionInfo.self,
        ClaudeCodeMeta.self,
        ProjectPathAlias.self,
        ProjectCollection.self,
        ProjectMeta.self,
        configurations: config
    )
}

@MainActor
@Test func tokenSampleRoundTrip() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    let now = Date()
    let sample = TokenSample(
        sampledAt: now,
        date: "2026-05-06",
        model: "claude-opus-4-7",
        inputTokens: 1234,
        outputTokens: 5678,
        cacheReadTokens: 90_000,
        cacheCreation5mTokens: 5_000,
        cacheCreation1hTokens: 2_000,
        sourceCostUSD: 0.42,
        dedupKey: "msg_abc:req_def",
        sessionId: "session_1",
        projectPath: "/Users/example/project",
        ccVersion: "2.1.132"
    )
    context.insert(sample)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<TokenSample>())
    #expect(fetched.count == 1)
    #expect(fetched[0].dedupKey == "msg_abc:req_def")
    #expect(fetched[0].cacheCreation1hTokens == 2_000)
}

@MainActor
@Test func tokenSampleAcceptsMultipleNilDedupKeys() throws {
    // The ccusage rule: dedup key requires both messageId AND requestId.
    // Many older lines lack one or both, so dedupKey is nil. SwiftData
    // must accept arbitrarily many null dedupKeys without rejecting on
    // a uniqueness constraint — which is exactly why we DON'T mark
    // dedupKey @Attribute(.unique). This test guards that decision.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    for i in 0..<5 {
        let s = TokenSample(
            sampledAt: Date(timeIntervalSince1970: Double(i)),
            date: "2026-05-06",
            model: "claude-opus-4-7",
            inputTokens: Int64(i),
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            dedupKey: nil
        )
        context.insert(s)
    }
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<TokenSample>()) == 5)
}

@MainActor
@Test func dailyAggregateUniqueOnDateModelKey() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let a = DailyAggregate(date: "2026-05-06", model: "claude-opus-4-7", inputTokens: 100)
    context.insert(a)
    try context.save()

    // Insert again with same (date, model) — SwiftData should treat as
    // an upsert via the @Attribute(.unique) on dateModelKey.
    let b = DailyAggregate(date: "2026-05-06", model: "claude-opus-4-7", inputTokens: 200)
    context.insert(b)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<DailyAggregate>())
    #expect(fetched.count == 1)
    // Last write wins under SwiftData's unique-upsert semantics.
    #expect(fetched[0].inputTokens == 200)
}

@MainActor
@Test func dailyAggregateKeyShape() {
    #expect(DailyAggregate.makeKey(date: "2026-05-06", model: "claude-opus-4-7")
        == "2026-05-06|claude-opus-4-7")
}

@MainActor
@Test func sessionInfoUniqueOnSessionId() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    let now = Date()
    let s = SessionInfo(
        sessionId: "sess_1",
        firstSeenAt: now,
        lastSeenAt: now,
        projectPath: "/example"
    )
    context.insert(s)
    try context.save()

    // Same sessionId → upsert.
    let s2 = SessionInfo(
        sessionId: "sess_1",
        firstSeenAt: now,
        lastSeenAt: now.addingTimeInterval(60),
        projectPath: "/example",
        cumulativeInputTokens: 999
    )
    context.insert(s2)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<SessionInfo>())
    #expect(fetched.count == 1)
    #expect(fetched[0].cumulativeInputTokens == 999)
}

@MainActor
@Test func rateLimitSampleAppendOnly() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    for i in 0..<3 {
        context.insert(RateLimitSample(
            sampledAt: Date(timeIntervalSince1970: Double(i * 60)),
            window: "five_hour",
            usedPercentage: Double(i * 10),
            resetsAt: Date(timeIntervalSince1970: Double(i * 60 + 18000)),
            source: "oauth"
        ))
    }
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<RateLimitSample>()) == 3)
}

@MainActor
@Test func rateLimitSampleRoundTripsNullableResetsAt() throws {
    // Server occasionally returns `resets_at: null`; the model field
    // is `Date?` so the row preserves nil rather than synthesizing a
    // sentinel date. This test guards against accidental migration
    // back to a non-optional column or a defaulting-init.
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)
    context.insert(RateLimitSample(
        sampledAt: Date(timeIntervalSince1970: 1_750_000_000),
        window: "seven_day",
        usedPercentage: 5.5,
        resetsAt: nil,
        source: "oauth"
    ))
    try context.save()

    let row = try context.fetch(FetchDescriptor<RateLimitSample>()).first
    #expect(row != nil)
    #expect(row?.resetsAt == nil)
    #expect(row?.usedPercentage == 5.5)
}

@MainActor
@Test func claudeCodeMetaUniqueOnKey() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    context.insert(ClaudeCodeMeta(key: ClaudeCodeMetaKey.scanVersion, value: "1"))
    try context.save()

    // Upsert: same key, new value.
    context.insert(ClaudeCodeMeta(key: ClaudeCodeMetaKey.scanVersion, value: "2"))
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<ClaudeCodeMeta>())
    #expect(fetched.count == 1)
    #expect(fetched[0].value == "2")
}

@MainActor
@Test func projectPathAliasUniqueOnSourcePath() throws {
    let container = try makeInMemoryContainer()
    let context = ModelContext(container)

    context.insert(ProjectPathAlias(
        sourcePath: "/old/path",
        canonicalPath: "/new/path"
    ))
    try context.save()

    // Upsert: same sourcePath → new canonical replaces old.
    context.insert(ProjectPathAlias(
        sourcePath: "/old/path",
        canonicalPath: "/different/path"
    ))
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<ProjectPathAlias>())
    #expect(fetched.count == 1)
    #expect(fetched[0].canonicalPath == "/different/path")
}

@MainActor
@Test func tokenSampleFromParsedEntry() {
    let entry = ParsedUsageEntry(
        timestamp: Date(timeIntervalSince1970: 1_756_800_000),
        model: "claude-opus-4-7",
        breakdown: TokenBreakdown(
            inputTokens: 100,
            outputTokens: 200,
            cacheReadTokens: 300,
            cacheCreation5mTokens: 400,
            cacheCreation1hTokens: 500
        ),
        storedCostUSD: 0.99,
        dedupKey: "msg:req",
        sessionId: "s1",
        projectPath: "/p",
        claudeCodeVersion: "2.1.132",
        isApiErrorMessage: false
    )
    let sample = TokenSample(from: entry)
    #expect(sample.model == "claude-opus-4-7")
    #expect(sample.cacheCreation5mTokens == 400)
    #expect(sample.cacheCreation1hTokens == 500)
    #expect(sample.dedupKey == "msg:req")
    #expect(sample.sourceCostUSD == 0.99)
    // Date string format check — not asserting the exact day to avoid
    // TZ flakiness, just that it's well-shaped YYYY-MM-DD.
    #expect(sample.date.count == 10)
    #expect(sample.date.contains("-"))
}
