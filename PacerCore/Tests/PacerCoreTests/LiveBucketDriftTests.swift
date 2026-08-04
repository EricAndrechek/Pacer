import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// A rollup bucket that stopped agreeing with its own samples while it was
/// still open, and then froze that way when the hour rolled over.
///
/// The incremental fast path adds a new sample's tokens and its cost to the
/// open bucket together. Nothing re-checks the result: a bucket is only
/// recomputed when a sample lands in it, so once the hour is past, whatever
/// the bucket holds is what it holds forever.
///
/// Found on a real 191k-row store by `make verify-data`, not by the app.
/// Hour 10 of 2026-08-04 held tokens matching its 125 samples exactly — to
/// the token, in all five categories — while its cost sat $0.6971 low
/// against those same tokens, at a price vector that explained all eight
/// other hours that day and the daily row to four decimal places:
///
///      hour     stored  predicted     delta
///         9     3.8060     3.8060    0.0000
///        10    39.0625    39.7595   -0.6971   <-- frozen
///        11    17.6802    17.6802    0.0000
///
/// The specific mechanism that split tokens from cost isn't reconstructable
/// after the fact, and that's the point — several can (a cost computed
/// before pricing finished loading, an upgrade reaching one rollup and not
/// another, a cycle dying between the write and the save), and the app
/// treats the result as settled truth in every case.
///
/// So the fix isn't aimed at a cause. Open buckets get rebuilt from their
/// samples on a throttle, which closes the whole class.
@Suite struct LiveBucketDriftTests {

    /// Drift a bucket while it's open, then confirm the next due cycle
    /// rebuilds it from its samples instead of trusting its running total.
    @ScanActor
    @Test func openBucketsAreRebuiltFromTheirSamples() async throws {
        // A sample in the CURRENT hour — the bucket has to be open for this
        // to be the case under test.
        let now = Date()
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let root = try makeDriftFixtureRoot(withLines: [
            makeDriftAssistantLine(timestamp: stamp.string(from: now),
                                   storedCost: 0.25, messageId: "m1", requestId: "r1")
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeDriftContainer()
        let context = ModelContext(container)
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .display,   // no network for pricing
                                 watcherMode: .manual,
                                 probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])
        )
        _ = try await coordinator.runOnce()

        let hourly = try context.fetch(FetchDescriptor<HourlyAggregate>())
        #expect(hourly.count == 1)
        let truth = try #require(hourly.first).totalCostUSD
        #expect(truth == 0.25)

        // Drift it, exactly as the real store had drifted: tokens still
        // correct, cost no longer derived from them.
        try #require(hourly.first).totalCostUSD = 999.0
        let daily = try context.fetch(FetchDescriptor<DailyAggregate>())
        try #require(daily.first).totalCostUSD = 999.0
        try context.save()

        // Age the throttle so the rebuild is due — the same thing ten
        // minutes of wall clock would do.
        // Upsert rather than require, so that a build without the rebuild
        // fails on the healing assertions below — the actual behaviour under
        // test — instead of on the throttle's bookkeeping.
        let key = ClaudeCodeMetaKey.lastLiveBucketRebuildAt
        let stale = String(Date().timeIntervalSince1970 - 3_600)
        let meta = try context.fetch(FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }))
        if let existing = meta.first { existing.value = stale }
        else { context.insert(ClaudeCodeMeta(key: key, value: stale)) }
        try context.save()

        _ = try await coordinator.runOnce()

        // Rebuilt from the sample, not carried forward. Without the live
        // rebuild both of these stay at 999.0: no new sample lands in the
        // bucket, so nothing ever marks it dirty.
        let healedHour = try context.fetch(FetchDescriptor<HourlyAggregate>())
        #expect(healedHour.count == 1)
        #expect(try #require(healedHour.first).totalCostUSD == truth)
        #expect(try #require(healedHour.first).outputTokens == 200)

        let healedDay = try context.fetch(FetchDescriptor<DailyAggregate>())
        #expect(try #require(healedDay.first).totalCostUSD == truth)
    }

    /// Every rollup slices the same samples, so every rollup must arrive at
    /// the same total spend. They didn't.
    ///
    /// The recomputers price from `SampleCostCache`, which is empty until
    /// something awaits `reload()` — and the app only warms it in an
    /// un-awaited `Task` at launch, which the first scan cycle beats. A
    /// bucket recomputed in that window prices every sample lacking a stored
    /// cost at **$0**, and a rollup cannot tell a real zero from an unpriced
    /// one, so it never recomputes.
    ///
    /// On the real store that showed up as project rollups $663 below the
    /// daily rollup for the same day — the whole `claude-fable-5` share of
    /// it — while the daily and hourly rollups, whose from-scratch path
    /// reads `PricingTable` directly instead of the cache, stayed correct.
    /// The asymmetry is what made it survive: had all four read the cache,
    /// they'd have agreed with each other and been wrong together.
    @ScanActor
    @Test func everyRollupPricesTheSameSamplesIdentically() async throws {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // No `costUSD` on the line: cost has to come from tokens x pricing,
        // which is the path that silently yields $0 on a cold cache.
        let line = """
        {"type":"assistant","timestamp":"\(stamp.string(from: Date()))",\
        "requestId":"r1","cwd":"/tmp/acme","sessionId":"drift-session",\
        "message":{"model":"claude-opus-4-1","id":"m1","usage":{\
        "input_tokens":100000,"output_tokens":50000,\
        "cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,\
        "ephemeral_1h_input_tokens":0}}}}
        """.replacingOccurrences(of: "\n", with: "")
        let root = try makeDriftFixtureRoot(withLines: [line])
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeDriftContainer()
        let context = ModelContext(container)
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .calculate,   // tokens x pricing
                                 watcherMode: .manual,
                                 probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])
        )
        _ = try await coordinator.runOnce()

        let daily = try context.fetch(FetchDescriptor<DailyAggregate>())
            .reduce(0) { $0 + $1.totalCostUSD }
        #expect(daily > 0, "pricing never warmed — the whole point")

        let hourly = try context.fetch(FetchDescriptor<HourlyAggregate>())
            .reduce(0) { $0 + $1.totalCostUSD }
        let project = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
            .reduce(0) { $0 + $1.totalCostUSD }
        let sessions = try context.fetch(FetchDescriptor<SessionInfo>())
        #expect(sessions.count == 1, "no SessionInfo row would make the check vacuous")
        let session = sessions.reduce(0) { $0 + $1.cumulativeCostUSD }

        #expect(abs(hourly - daily) < 0.000_001, "hourly \(hourly) vs daily \(daily)")
        #expect(abs(project - daily) < 0.000_001, "project \(project) vs daily \(daily)")
        #expect(abs(session - daily) < 0.000_001, "session \(session) vs daily \(daily)")
    }

    /// A model that arrives before its price does gets its history rebuilt
    /// when the price shows up — without a release.
    ///
    /// Every model launch has hit this: `costRecomputeVersion` "3" was Fable
    /// 5 and Mythos 5 aggregating at $0 because LiteLLM had no entry on
    /// their launch day, "4" was Mythos Preview. Each needed a human to
    /// notice and ship a bump. Pricing self-heals; the rollups built from it
    /// did not.
    @ScanActor
    @Test func historyIsRebuiltWhenAModelGainsPricing() async throws {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let root = try makeDriftFixtureRoot(withLines: [
            makeDriftAssistantLine(timestamp: stamp.string(from: Date()),
                                   storedCost: 0.25, messageId: "m1", requestId: "r1")
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeDriftContainer()
        let context = ModelContext(container)
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .calculate, watcherMode: .manual,
                                 probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])
        )
        _ = try await coordinator.runOnce()

        let model = try #require(
            try context.fetch(FetchDescriptor<DailyAggregate>()).first).model

        // Rewrite history as it would look had this model been unpriced when
        // its samples were first aggregated: $0 cost, and recorded as
        // unpriced so the next cycle can see it has since gained a price.
        for row in try context.fetch(FetchDescriptor<DailyAggregate>()) { row.totalCostUSD = 0 }
        for row in try context.fetch(FetchDescriptor<HourlyAggregate>()) { row.totalCostUSD = 0 }
        let key = ClaudeCodeMetaKey.unpricedModels
        let json = String(data: try JSONEncoder().encode(Set([model])), encoding: .utf8)!
        let existing = try context.fetch(FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }))
        if let row = existing.first { row.value = json }
        else { context.insert(ClaudeCodeMeta(key: key, value: json)) }
        try context.save()

        _ = try await coordinator.runOnce()

        // The model is priced now, so it left the unpriced set, so its
        // history was rebuilt — no version bump, no release.
        let daily = try context.fetch(FetchDescriptor<DailyAggregate>())
            .reduce(0) { $0 + $1.totalCostUSD }
        #expect(daily > 0, "history stayed at $0 after the model gained a price")
    }

    /// The same billable turn stored twice gets collapsed to one.
    ///
    /// A `dedupKey` identifies one turn, so two rows carrying it means it was
    /// counted twice. Found on a real store as 126 byte-identical pairs from
    /// 2026-05-06/07 — reported by `make verify-data`, invisible to the app.
    ///
    /// This is the only place Pacer removes raw rows, so the test pins BOTH
    /// halves: the extra copy goes, and the surviving row is the one with the
    /// most output (a partial streamed copy must never win over its finished
    /// twin).
    @ScanActor
    @Test func duplicateTurnsAreCollapsedKeepingTheFullestCopy() async throws {
        let container = try makeDriftContainer()
        let context = ModelContext(container)

        let at = Date(timeIntervalSince1970: 1_780_000_000)
        let date = TokenSample.formatDate(at)
        for output in [50, 900, 300] as [Int64] {
            let sample = TokenSample(
                sampledAt: at, date: date, model: "claude-opus-4-8",
                inputTokens: 10, outputTokens: output, cacheReadTokens: 0,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
            sample.dedupKey = "msg_dupe:req_dupe"
            context.insert(sample)
        }
        // A turn that is NOT duplicated must survive untouched.
        let solo = TokenSample(
            sampledAt: at, date: date, model: "claude-opus-4-8",
            inputTokens: 10, outputTokens: 7, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
        solo.dedupKey = "msg_solo:req_solo"
        context.insert(solo)
        try context.save()

        let persister = try SamplePersister(context: context)
        #expect(try persister.repairDuplicateSamples() == 2)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<TokenSample>())
        #expect(rows.count == 2, "one per distinct turn")
        let kept = rows.first { $0.dedupKey == "msg_dupe:req_dupe" }
        #expect(try #require(kept).outputTokens == 900,
                "kept the fullest copy, not the first or last seen")
        #expect(rows.contains { $0.dedupKey == "msg_solo:req_solo" })

        // Idempotent — a second run has nothing left to do.
        #expect(try persister.repairDuplicateSamples() == 0)
    }

    /// The throttle has to actually throttle — otherwise this trades a
    /// correctness bug for the cost of rebuilding the day's buckets on every
    /// cycle, which is the fast path's whole reason for existing.
    @ScanActor
    @Test func rebuildIsSkippedWhenNotDue() async throws {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let root = try makeDriftFixtureRoot(withLines: [
            makeDriftAssistantLine(timestamp: stamp.string(from: Date()),
                                   storedCost: 0.25, messageId: "m1", requestId: "r1")
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeDriftContainer()
        let context = ModelContext(container)
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .display, watcherMode: .manual,
                                 probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path])
        )
        _ = try await coordinator.runOnce()

        let hourly = try context.fetch(FetchDescriptor<HourlyAggregate>())
        try #require(hourly.first).totalCostUSD = 999.0
        try context.save()

        // No throttle ageing this time.
        _ = try await coordinator.runOnce()

        let after = try context.fetch(FetchDescriptor<HourlyAggregate>())
        #expect(try #require(after.first).totalCostUSD == 999.0,
                "a rebuild that fires every cycle would defeat the fast path")
    }
}

// MARK: - Fixtures

private func makeDriftContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Heartbeat.self, TokenSample.self, DailyAggregate.self,
        HourlyAggregate.self, ProjectDailyAggregate.self, RateLimitSample.self,
        SessionInfo.self, ClaudeCodeMeta.self, ProjectPathAlias.self,
        ProjectPathProbe.self, ProjectBudget.self, ProjectMeta.self,
        ProjectCollection.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private func makeDriftFixtureRoot(withLines lines: [String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-drift-\(UUID().uuidString)")
    let projectsDir = root.appendingPathComponent("projects/-tmp-fixture")
    try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n")
        .write(to: projectsDir.appendingPathComponent("drift-session.jsonl"),
               atomically: true, encoding: .utf8)
    return root
}

private func makeDriftAssistantLine(
    timestamp: String, storedCost: Double, messageId: String, requestId: String
) -> String {
    let fields: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "requestId": requestId,
        "costUSD": storedCost,
        "message": [
            "model": "claude-opus-4-8",
            "id": messageId,
            "usage": [
                "input_tokens": 100,
                "output_tokens": 200,
                "cache_read_input_tokens": 0,
                "cache_creation": [
                    "ephemeral_5m_input_tokens": 0,
                    "ephemeral_1h_input_tokens": 0,
                ],
            ],
        ] as [String: Any]
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
}
