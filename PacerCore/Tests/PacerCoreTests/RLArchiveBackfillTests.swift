import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The record backfill reads the archive too. The live rate-limit tables are a
/// 35-day cache; older readings are moved (never deleted) into
/// `AccountUsageArchive`, so "full history" read from the live tables alone
/// was the last 35 days.
@Suite("Rate-limit record backfill reads the archive")
struct RLArchiveBackfillTests {

    static let now = Date(timeIntervalSince1970: 1_752_000_000)
    static let account = "org-a"
    static let week: TimeInterval = 7 * 86400

    @Test func weeklyCyclesThatOnlyTheArchiveHoldsAreScored() async throws {
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

        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.adopt(scope: .account(Self.account))
        await engine.recompute(now: Self.now)
        await engine.recompute(now: Self.now)      // the backfill runs on the second refit

        let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
            .filter { $0.surface.hasPrefix(EngineSelfEval.rlSurface("seven_day")) && $0.method == "linear-recent" }
        #expect(Set(rows.map(\.periodKey)).count == 6)    // every archived weekly cycle has a record
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
