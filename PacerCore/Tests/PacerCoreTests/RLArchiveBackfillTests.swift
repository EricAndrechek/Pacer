import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The full-history record pass (`backfillRateLimitRecordIfNeeded`). It reads
/// the archive too: the live rate-limit tables are a 35-day cache, older
/// readings move (never deleted) into `AccountUsageArchive`, so "full history"
/// read from the live tables alone was the last 35 days. And it runs only when
/// the record can be missing something, a few cycles at a time.
@Suite("Rate-limit record backfill")
struct RLArchiveBackfillTests {

    static let now = Date(timeIntervalSince1970: 1_752_000_000)
    static let account = "org-a"
    static let week: TimeInterval = 7 * 86400

    /// Six archived weekly cycles 40–80 days back and one recent live one.
    static func seeded() throws -> ModelContainer {
        let container = try PacerStore.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Account(id: Self.account, organizationId: Self.account, displayName: "A", isActive: true,
                           firstSeenAt: Self.now.addingTimeInterval(-90 * 86400), lastSeenAt: Self.now))
        // Six weekly cycles 40–80 days back, only in the archive; one recent cycle live.
        for c in 0..<6 {
            let start = Self.now.addingTimeInterval(-80 * 86400 + Double(c) * Self.week)
            let reset = start.addingTimeInterval(Self.week)
            var t = start, pct = 0.0
            while t <= reset {
                ctx.insert(AccountUsageArchive(accountId: Self.account, kind: AccountUsageArchive.kindRateLimit,
                                               sampledAt: t, window: "seven_day", usedPercentage: min(90, pct),
                                               resetsAt: reset, source: "oauth"))
                t = t.addingTimeInterval(6 * 3600); pct += 3
            }
        }
        let liveStart = Self.now.addingTimeInterval(-2 * 86400)
        let liveReset = liveStart.addingTimeInterval(Self.week)
        var t = liveStart, pct = 0.0
        while t <= Self.now {
            ctx.insert(RateLimitSample(sampledAt: t, window: "seven_day", usedPercentage: pct,
                                       resetsAt: liveReset, source: "oauth", accountId: Self.account))
            t = t.addingTimeInterval(6 * 3600); pct += 3
        }
        try ctx.save()
        return container
    }

    static func engine(_ container: ModelContainer) async -> UsageIntelligenceEngine {
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.adopt(scope: .account(Self.account))
        await engine.recompute(now: Self.now)
        return engine
    }

    static func weeklyPeriods(_ container: ModelContainer, method: String = "linear-recent") throws -> Set<String> {
        let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
            .filter { $0.surface.hasPrefix(EngineSelfEval.rlSurface("seven_day")) && $0.method == method }
        return Set(rows.map(\.periodKey))
    }

    @Test func weeklyCyclesThatOnlyTheArchiveHoldsAreScored() async throws {
        let container = try Self.seeded()
        let engine = await Self.engine(container)
        #expect(try Self.weeklyPeriods(container).isEmpty)    // a refit scores only the 32 days it read
        let added = await engine.backfillRateLimitRecordIfNeeded(now: Self.now, batch: 2, pause: .zero)
        #expect(added > 0)
        #expect(try Self.weeklyPeriods(container).count == 6)  // every archived weekly cycle has a record
    }

    /// Once a pass has covered an account's history, live refits keep it
    /// current, so a later launch (a new engine on the same store) reads one
    /// meta row and stops: no archive read, nothing added.
    @Test func aCoveredRecordSkipsThePass() async throws {
        let container = try Self.seeded()
        _ = await Self.engine(container).backfillRateLimitRecordIfNeeded(now: Self.now, pause: .zero)
        let marker = try ModelContext(container).fetch(FetchDescriptor<ClaudeCodeMeta>())
            .first { $0.key == "rl_record_backfill|\(Self.account)" }
        #expect(marker?.value == UsageIntelligenceEngine.recordBackfillFingerprint)

        // Remove a cycle's rows: a pass that ran anyway would put them back.
        let ctx = ModelContext(container)
        let keep = try Self.weeklyPeriods(container).sorted().first!
        for row in try ctx.fetch(FetchDescriptor<EngineEvalOutcome>()) where row.periodKey == keep { ctx.delete(row) }
        try ctx.save()
        let again = await Self.engine(container)
        #expect(await again.backfillRateLimitRecordIfNeeded(now: Self.now, pause: .zero) == 0)
        #expect(try Self.weeklyPeriods(container).count == 5)
    }

    /// A different fingerprint (a new model, a scoring change, a pass that now
    /// reads more) means the record may be missing something: the pass runs,
    /// fills only what is missing, and records the new fingerprint.
    @Test func aStaleMarkerRunsThePassAgain() async throws {
        let container = try Self.seeded()
        _ = await Self.engine(container).backfillRateLimitRecordIfNeeded(now: Self.now, pause: .zero)
        let ctx = ModelContext(container)
        let keep = try Self.weeklyPeriods(container).sorted().first!
        for row in try ctx.fetch(FetchDescriptor<EngineEvalOutcome>()) where row.periodKey == keep { ctx.delete(row) }
        for meta in try ctx.fetch(FetchDescriptor<ClaudeCodeMeta>()) where meta.key.hasPrefix("rl_record_backfill|") {
            meta.value = "v0|older"
        }
        try ctx.save()
        let again = await Self.engine(container)
        #expect(await again.backfillRateLimitRecordIfNeeded(now: Self.now, pause: .zero) > 0)
        #expect(try Self.weeklyPeriods(container).count == 6)
    }

    @Test func theFingerprintNamesTheScoringVersionAndEveryModel() {
        let fp = UsageIntelligenceEngine.recordBackfillFingerprint
        #expect(fp.contains("|\(EngineSelfEval.rlBucketVersion)|"))
        for id in BurnTrajectory.defaultModels.map(\.id) + ["diurnal-rate"] { #expect(fp.contains(id)) }
    }

    /// Batches score exactly what one pass over every cycle would: each cycle's
    /// diurnal table still learns from every cycle before it.
    @Test func slicesScoreExactlyWhatTheWholeDoes() {
        let start = Self.now.addingTimeInterval(-60 * 86400)
        var cycles: [BurnTrajectory.Cycle] = []
        for c in 0..<7 {
            let s = start.addingTimeInterval(Double(c) * Self.week), r = s.addingTimeInterval(Self.week)
            let samples = stride(from: 0.0, through: Self.week, by: 6 * 3600).map {
                BurnTrajectory.Sample(at: s.addingTimeInterval($0), usedPercentage: min(95, $0 / 3600 * (0.4 + 0.05 * Double(c))))
            }
            cycles.append(.init(samples: samples, cycleStart: s, resetsAt: r))
        }
        let utc = Calendar(identifier: .gregorian)
        let grid = Array(repeating: Array(repeating: 1.0, count: 24), count: 7)
        func run(_ r: Range<Int>?) -> [String: Double] {
            Dictionary(EngineSelfEval.newOutcomesRL(window: "seven_day", cycles: cycles, activityGrid: grid, calendar: utc,
                                                   existingKeys: [], includeDiurnal: true, indices: r)
                .map { ("\($0.method)|\($0.bucket)|\($0.periodKey)", $0.predicted) }, uniquingKeysWith: { a, _ in a })
        }
        let whole = run(nil)
        var sliced: [String: Double] = [:]
        for lo in stride(from: 0, to: cycles.count, by: 3) { sliced.merge(run(lo..<min(lo + 3, cycles.count))) { a, _ in a } }
        #expect(!whole.isEmpty)
        #expect(sliced == whole)
    }

    @Test func mergedKeepsTheLiveCopyAndSortsByTime() {
        struct Row { let k: String; let at: Date; let live: Bool }
        let t0 = Date(timeIntervalSince1970: 0)
        let live = [Row(k: "a", at: t0.addingTimeInterval(20), live: true)]
        let archived = [Row(k: "a", at: t0.addingTimeInterval(20), live: false),
                        Row(k: "b", at: t0.addingTimeInterval(10), live: false)]
        let out = UsageIntelligenceEngine.merged(live, archived, key: { "\($0.k)|\($0.at.timeIntervalSince1970)" }, at: \.at)
        #expect(out.map(\.k) == ["b", "a"])
        #expect(out.last?.live == true)
    }
}
