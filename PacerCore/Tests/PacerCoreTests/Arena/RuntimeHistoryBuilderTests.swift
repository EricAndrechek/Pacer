import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The arena's history from the store (`ArenaHistoryBuilder`): the meters the
/// exporter writes, thinned the way the port fixtures are, and spend as one
/// priced row per family per five minutes.
@Suite("Arena runtime: history from the store")
struct RuntimeHistoryBuilderTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let account = "acct-test"

    static func reading(_ minutes: Int, _ util: Double?, reset: Millis? = 99, active: Bool = true) -> ArenaReading {
        let t = Millis(minutes) * ArenaTime.minute
        return ArenaReading(tEvent: t, tKnown: t, utilPct: util, resetsAt: active ? reset : nil, active: active)
    }

    // MARK: Thinning

    @Test func thinKeepsChangesKeepalivesAndBothEnds() {
        // Three hours of one-minute readings, flat at 10% except a rise to 12%
        // at minute 50 and an idle row at minute 100.
        var rows: [ArenaReading] = []
        for m in 0...180 {
            if m == 100 { rows.append(Self.reading(m, 12, active: false)); continue }
            rows.append(Self.reading(m, m >= 50 ? 12 : 10))
        }
        let kept = ArenaHistoryBuilder.thin(rows).map { $0.tEvent / ArenaTime.minute }
        // first; the change at 50; the idle row at 100 and the return at 101;
        // an hourly keepalive after 101 (161); the last.
        #expect(kept == [0, 50, 100, 101, 161, 180])
    }

    @Test func thinTreatsAMovedResetAsANewCycle() {
        let rows = [Self.reading(0, 5, reset: 0), Self.reading(1, 5, reset: 10 * ArenaTime.minute),
                    Self.reading(2, 5, reset: 40 * ArenaTime.minute), Self.reading(3, 5, reset: 40 * ArenaTime.minute),
                    Self.reading(4, 5, reset: 40 * ArenaTime.minute)]
        // 10 min apart: same cycle (jitter); 30 min apart: a new one.
        #expect(ArenaHistoryBuilder.thin(rows).map { $0.tEvent / ArenaTime.minute } == [0, 2, 4])
    }

    /// Thinning only looks back, so thinning then cutting is cutting then
    /// thinning (plus the cut's own last row): a cut sees no row the full
    /// series kept because of something later.
    @Test func thinningIsCausal() {
        var rows: [ArenaReading] = []
        var u = 0.0
        for m in 0..<600 { if m % 37 == 0 { u += 1 }; rows.append(Self.reading(m, u)) }
        let full = ArenaHistoryBuilder.thin(rows)
        for cut in [100, 250, 433] {
            let prefix = ArenaHistoryBuilder.thin(Array(rows.prefix(cut + 1)))
            let fromFull = full.filter { $0.tEvent <= Millis(cut) * ArenaTime.minute }
            #expect(Array(prefix.dropLast()) == Array(fromFull.prefix(prefix.count - 1)))
        }
    }

    // MARK: Naming

    @Test func scopedCapsAreNamedAsTheExporterNamesThem() {
        #expect(ArenaHistoryBuilder.scopeModel(identity: "weekly_scoped|claude-fable|", display: "Fable") == "Fable")
        #expect(ArenaHistoryBuilder.scopeModel(identity: "weekly_scoped|claude-fable|", display: nil) == "claude-fable")
        #expect(ArenaHistoryBuilder.scopeModel(identity: "weekly_scoped|claude-fable|", display: "") == "claude-fable")
        #expect(ArenaHistoryBuilder.scopeModel(identity: "session||", display: nil) == nil)
        #expect(ArenaHistoryBuilder.family("claude-opus-5-5") == "opus")
        #expect(ArenaHistoryBuilder.family("Claude-Haiku-4") == "haiku")
        #expect(ArenaHistoryBuilder.family("gpt-x") == "other")
        #expect(ArenaHistoryBuilder.family(nil) == "other")
    }

    // MARK: From the store

    static func container() throws -> ModelContainer { try PacerStore.makeInMemoryContainer() }

    static func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3600) }

    @Test func metersUnionTheArchiveWithTheLiveRowWinning() throws {
        let c = try Self.container()
        let ctx = ModelContext(c)
        let reset = Self.at(-2)
        // Live: two readings. Archive: one older row, and a copy of a live row
        // with a different value (caught between archive insert and live
        // delete) that must lose.
        ctx.insert(RateLimitSample(sampledAt: Self.at(3), window: "five_hour", usedPercentage: 20,
                                   resetsAt: reset, source: "oauth", accountId: Self.account))
        ctx.insert(RateLimitSample(sampledAt: Self.at(1), window: "five_hour", usedPercentage: 30,
                                   resetsAt: reset, source: "oauth", accountId: Self.account))
        ctx.insert(AccountUsageArchive(accountId: Self.account, kind: AccountUsageArchive.kindRateLimit,
                                       sampledAt: Self.at(1), window: "five_hour", usedPercentage: 99,
                                       resetsAt: reset, source: "oauth"))
        ctx.insert(AccountUsageArchive(accountId: Self.account, kind: AccountUsageArchive.kindRateLimit,
                                       sampledAt: Self.at(24 * 50), window: "five_hour", usedPercentage: 7,
                                       resetsAt: Self.at(24 * 50 - 2), source: "oauth"))
        // Another account's row never shows up.
        ctx.insert(RateLimitSample(sampledAt: Self.at(2), window: "five_hour", usedPercentage: 55,
                                   resetsAt: reset, source: "oauth", accountId: "someone-else"))
        // Older than the depth: dropped.
        ctx.insert(AccountUsageArchive(accountId: Self.account, kind: AccountUsageArchive.kindRateLimit,
                                       sampledAt: Self.at(24 * 130), window: "five_hour", usedPercentage: 3,
                                       resetsAt: Self.at(24 * 130 - 2), source: "oauth"))
        try ctx.save()

        let built = ArenaHistoryBuilder.build(container: c, account: Self.account, now: Self.now,
                                              pricing: .init(pricingByModel: [:], ledger: .empty))
        let h = ArenaHistory(store: built.store, now: ArenaTime.millis(Self.now), accounts: [Self.account])
        let five = h.readings(account: Self.account, windowKind: "five_hour")
        #expect(five.map(\.utilPct) == [7, 20, 30])
        #expect(five.allSatisfy { $0.tKnown == $0.tEvent })
        #expect(built.store.dataStart == ArenaTime.millis(Self.now) - 120 * ArenaTime.day)
    }

    @Test func scopedReadingsBecomeScopedMeters() throws {
        let c = try Self.container()
        let ctx = ModelContext(c)
        let reset = Self.at(-24 * 3)
        for (i, pct) in [10.0, 12, 15].enumerated() {
            ctx.insert(UsageLimitSample(sampledAt: Self.at(Double(10 - i)), identity: "weekly_scoped|claude-fable|",
                                        kind: "weekly_scoped", group: "weekly", label: "Fable", percent: pct,
                                        resetsAt: reset, severity: "ok", isActive: false,
                                        modelId: "claude-fable", modelDisplayName: "Fable", source: "oauth",
                                        accountId: Self.account))
            // The account-wide twin of the weekly window: not a scoped meter.
            ctx.insert(UsageLimitSample(sampledAt: Self.at(Double(10 - i)), identity: "weekly_all||",
                                        kind: "weekly_all", group: "weekly", label: "All models", percent: 40,
                                        resetsAt: reset, severity: "ok", isActive: true, source: "oauth",
                                        accountId: Self.account))
        }
        try ctx.save()
        let built = ArenaHistoryBuilder.build(container: c, account: Self.account, now: Self.now,
                                              pricing: .init(pricingByModel: [:], ledger: .empty))
        let ids = built.store.meters.keys.map { "\($0.windowKind)|\($0.scopeModel ?? "")" }.sorted()
        #expect(ids == ["weekly_scoped|Fable"])
        let rows = built.store.meters[ArenaMeterID(account: Self.account, windowKind: "weekly_scoped", scopeModel: "Fable")]
        #expect(rows?.map(\.utilPct) == [10, 12, 15])
    }

    static let catalog: [String: LiteLLMModelPricing] = [
        "claude-opus-5-5": LiteLLMModelPricing(
            inputCostPerToken: 5e-06, outputCostPerToken: 25e-06,
            cacheCreationInputTokenCost: 6.25e-06, cacheCreationInputTokenCostAbove1hr: 1e-05,
            cacheReadInputTokenCost: 5e-07,
            inputCostPerTokenAbove200kTokens: nil, outputCostPerTokenAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove200kTokens: nil, cacheReadInputTokenCostAbove200kTokens: nil,
            cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
            maxInputTokens: 1_000_000, maxOutputTokens: 128_000),
    ]

    static func turn(_ ctx: ModelContext, at: Date, model: String, input: Int64 = 1000, output: Int64 = 500,
                     account: String? = account) {
        let s = TokenSample(sampledAt: at, date: TokenSample.formatDate(at), model: model,
                            inputTokens: input, outputTokens: output, cacheReadTokens: 100,
                            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
        s.accountId = account
        ctx.insert(s)
    }

    @Test func spendIsOneRowPerFamilyPerFiveMinutesAndUnpricedStaysNil() throws {
        let c = try Self.container()
        let ctx = ModelContext(c)
        // Bucket boundaries on whole five-minute marks from the epoch.
        let base = Date(timeIntervalSince1970: (Self.at(5).timeIntervalSince1970 / 300).rounded(.down) * 300)
        Self.turn(ctx, at: base.addingTimeInterval(10), model: "claude-opus-5-5")
        Self.turn(ctx, at: base.addingTimeInterval(200), model: "claude-opus-5-5")
        Self.turn(ctx, at: base.addingTimeInterval(250), model: "<synthetic>")          // skipped
        Self.turn(ctx, at: base.addingTimeInterval(260), model: "mystery-model-x")       // unpriced: other
        Self.turn(ctx, at: base.addingTimeInterval(320), model: "claude-opus-5-5")       // next bucket
        Self.turn(ctx, at: base.addingTimeInterval(330), model: "claude-opus-5-5", account: "someone-else")
        try ctx.save()

        let pricing = PricingTable.Snapshot(pricingByModel: Self.catalog)
        let built = ArenaHistoryBuilder.build(container: c, account: Self.account, now: Self.now,
                                              mode: .calculate, pricing: pricing)
        let rows = try #require(built.store.spend[Self.account])
        #expect(rows.count == 3)
        let one = pricing.ledger.cost(model: "claude-opus-5-5", at: base, breakdown: TokenBreakdown(
            inputTokens: 1000, outputTokens: 500, cacheReadTokens: 100, cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0)).total
        #expect(one > 0)
        let opus = rows.filter { $0.family == "opus" }
        #expect(opus.count == 2)
        #expect(opus[0].turns == 2 && opus[0].tokens == 3200)
        #expect(abs((opus[0].costUSD ?? 0) - 2 * one) < 1e-12)
        #expect(opus[0].tEvent == ArenaTime.millis(base.addingTimeInterval(200)))   // the bucket's last turn
        #expect(opus[1].turns == 1)
        let other = try #require(rows.first { $0.family == "other" })
        #expect(other.costUSD == nil)                 // unpriced is unknown, never $0
        #expect(other.turns == 1 && other.tokens == 1600)
    }

    @Test func extendingAppendsNewRowsAndRereadsTheOpenBucket() throws {
        let c = try Self.container()
        let ctx = ModelContext(c)
        let reset = Self.at(-3)
        ctx.insert(RateLimitSample(sampledAt: Self.at(2), window: "five_hour", usedPercentage: 10,
                                   resetsAt: reset, source: "oauth", accountId: Self.account))
        let bucket = Date(timeIntervalSince1970: (Self.now.timeIntervalSince1970 / 300).rounded(.down) * 300)
        Self.turn(ctx, at: bucket.addingTimeInterval(-30), model: "claude-opus-5-5")
        try ctx.save()
        let pricing = PricingTable.Snapshot(pricingByModel: Self.catalog)
        let built = ArenaHistoryBuilder.build(container: c, account: Self.account, now: Self.now,
                                              mode: .calculate, pricing: pricing)

        // Ten minutes on: a new reading, a turn in the bucket that was open,
        // and one in a new bucket.
        let later = Self.now.addingTimeInterval(600)
        ctx.insert(RateLimitSample(sampledAt: Self.now.addingTimeInterval(300), window: "five_hour",
                                   usedPercentage: 14, resetsAt: reset, source: "oauth", accountId: Self.account))
        Self.turn(ctx, at: Self.now.addingTimeInterval(1), model: "claude-opus-5-5")
        Self.turn(ctx, at: Self.now.addingTimeInterval(400), model: "claude-opus-5-5")
        try ctx.save()
        let next = ArenaHistoryBuilder.extend(built, container: c, account: Self.account, now: later,
                                              mode: .calculate, pricing: pricing)
        let fresh = ArenaHistoryBuilder.build(container: c, account: Self.account, now: later,
                                              mode: .calculate, pricing: pricing)
        #expect(next.store.meters == fresh.store.meters)
        #expect(next.store.spend == fresh.store.spend)
        #expect(next.builtThrough == later)
    }
}
