import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The live meter (#318): last reading + floor(Σ rate × spend since it).
@Suite("Live meter")
struct LiveMeterTests {

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let fiveHours: TimeInterval = 5 * 3600
    static let rates = LiveMeterRates(modelRates: ["claude-opus-5-5": 0.2, "claude-fable-5-1": 0.5],
                                      pooledRate: 0.1)

    static func reading(_ percent: Double, at: Date = t0, resets: Date? = t0.addingTimeInterval(3 * 3600)) -> MeterReading {
        MeterReading(at: at, percent: percent, resetsAt: resets)
    }

    static func spend(_ seconds: TimeInterval, _ model: String = "claude-opus-5-5", usd: Double) -> LiveSpend {
        LiveSpend(at: t0.addingTimeInterval(seconds), model: model, costUSD: usd)
    }

    static func value(_ r: MeterReading, _ spend: [LiveSpend], rates: LiveMeterRates? = rates,
                      counts: (@Sendable (String) -> Bool)? = nil, at seconds: TimeInterval = 240) -> LiveMeterValue? {
        LiveMeter.value(reading: r, duration: fiveHours, rates: rates, spend: spend, counts: counts,
                        now: t0.addingTimeInterval(seconds))
    }

    // MARK: - The arithmetic

    @Test func noSpendEqualsTheReading() throws {
        let v = try #require(Self.value(Self.reading(42), []))
        #expect(v.percent == 42)
        #expect(v.addedPoints == 0)
        #expect(v.rateSource == .none)
        #expect(v.reading == Self.reading(42))
        #expect(v.asOf == Self.t0.addingTimeInterval(240))
    }

    @Test func pointsAreFlooredNotRounded() throws {
        // $14.5 at 0.2 = 2.9 points: shown as 2, never 3.
        let v = try #require(Self.value(Self.reading(40), [Self.spend(60, usd: 10), Self.spend(120, usd: 4.5)]))
        #expect(v.percent == 42)
        #expect(v.addedPoints == 2)
        #expect(abs(v.exactAdded - 2.9) < 1e-12)
        #expect(abs(v.spendUSD - 14.5) < 1e-12)
        // A sum that lands a hair under a whole point still counts it.
        // Ten turns of 0.1 points sum to 0.9999999999999999 in floating point.
        let tenths = (1...10).map { Self.spend(Double($0), usd: 0.5) }
        #expect(Self.value(Self.reading(40), tenths)?.percent == 41)
    }

    @Test func spendAtOrBeforeTheReadingAndAfterNowIsNotCounted() throws {
        let v = try #require(Self.value(Self.reading(10), [
            Self.spend(-30, usd: 50),   // before the reading: already in it
            Self.spend(0, usd: 50),     // at the reading: already in it
            Self.spend(100, usd: 10),   // counted: 2 points
            Self.spend(300, usd: 50),   // after now
        ]))
        #expect(v.percent == 12)
    }

    @Test func cappedAtOneHundredAndNeverBelowTheReading() throws {
        #expect(Self.value(Self.reading(97), [Self.spend(60, usd: 100)])?.percent == 100)
        // A reading at or over 100 stays as the server said.
        #expect(Self.value(Self.reading(100), [Self.spend(60, usd: 100)])?.percent == 100)
        #expect(Self.value(Self.reading(101), [])?.percent == 101)
        // Negative or zero costs never pull it down.
        #expect(Self.value(Self.reading(30), [Self.spend(60, usd: -50)])?.percent == 30)
    }

    @Test func aResetRestartsFromZeroPlusTheSpendAfterIt() throws {
        // Reading 80% two minutes before its reset; spend either side of it.
        let r = Self.reading(80, resets: Self.t0.addingTimeInterval(120))
        let v = try #require(Self.value(r, [Self.spend(60, usd: 50), Self.spend(180, usd: 10)]))
        #expect(v.restarted)
        #expect(v.percent == 2)        // 0 + $10 × 0.2, not 80 + anything
        #expect(v.addedPoints == 2)
        // Before the reset it is the ordinary fill.
        let before = try #require(Self.value(r, [Self.spend(60, usd: 50)], at: 100))
        #expect(!before.restarted)
        #expect(before.percent == 90)
        // Reset instants are compared as instants: a jittered one a few
        // hundred ms later is the same reset.
        let jitter = Self.reading(80, resets: Self.t0.addingTimeInterval(120.4))
        #expect(Self.value(jitter, [Self.spend(180, usd: 10)])?.percent == 2)
    }

    @Test func moreThanOneCycleLaterThereIsNoValue() {
        let r = Self.reading(50, resets: Self.t0.addingTimeInterval(60))
        #expect(LiveMeter.value(reading: r, duration: 600, rates: Self.rates, spend: [],
                                now: Self.t0.addingTimeInterval(60 + 601)) == nil)
    }

    @Test func aNullResetAtZeroOpensANewWindowWithTheFirstTurn() throws {
        let v = try #require(Self.value(Self.reading(0, resets: nil), [Self.spend(30, usd: 15)]))
        #expect(v.percent == 3)
        #expect(!v.restarted)
    }

    @Test func theInterceptIsNeverAdded() throws {
        // A fit with a large intercept: nothing spent, nothing added, however
        // long since the reading.
        let fit = SpendMeterFit(result: Self.fitResult(intercept: 25), fittedDay: "2026-10-22", fittedAt: Self.t0)
        let rates = LiveMeterRates(fit)
        #expect(Self.value(Self.reading(20), [], rates: rates, at: 3500)?.percent == 20)
        // And with spend, only rate × spend.
        #expect(Self.value(Self.reading(20), [Self.spend(60, usd: 10)], rates: rates)?.percent == 22)
    }

    @Test func aScopedCapCountsOnlyItsOwnModel() throws {
        let counts = SpendMeterFitter.capCounts(modelId: nil, displayName: "Fable")
        let v = try #require(Self.value(Self.reading(5), [
            Self.spend(60, "claude-opus-5-5", usd: 500),
            Self.spend(90, "claude-fable-5-1", usd: 4),
        ], counts: counts))
        #expect(v.percent == 7)   // $4 × 0.5; the Opus $500 moves nothing
        #expect(abs(v.spendUSD - 4) < 1e-12)
    }

    @Test func aModelWithoutItsOwnRateUsesThePooledOne() throws {
        let pooled = try #require(Self.value(Self.reading(10), [Self.spend(60, "claude-haiku-5", usd: 30)]))
        #expect(pooled.percent == 13)            // $30 × 0.1
        #expect(pooled.rateSource == .pooled)
        let mixed = try #require(Self.value(Self.reading(10), [
            Self.spend(60, "claude-haiku-5", usd: 30), Self.spend(70, "claude-opus-5-5", usd: 10)]))
        #expect(mixed.percent == 15)
        #expect(mixed.rateSource == .mixed)
        let own = try #require(Self.value(Self.reading(10), [Self.spend(70, "claude-opus-5-5", usd: 10)]))
        #expect(own.rateSource == .perModel)
        // A model's own zero is the fit's answer, not a gap to fill.
        let zero = LiveMeterRates(modelRates: ["claude-haiku-5": 0], pooledRate: 0.1)
        #expect(Self.value(Self.reading(10), [Self.spend(60, "claude-haiku-5", usd: 30)], rates: zero)?.percent == 10)
    }

    @Test func syntheticTurnsAreNeverCounted() {
        #expect(Self.value(Self.reading(10), [Self.spend(60, "<synthetic>", usd: 100)])?.percent == 10)
    }

    @Test func noFitNoValue() {
        #expect(Self.value(Self.reading(42), [Self.spend(60, usd: 10)], rates: nil) == nil)
    }

    @Test func aReadingOlderThanAnHourHasNoValue() {
        #expect(Self.value(Self.reading(42), [], at: LiveMeter.maxReadingAge) != nil)
        #expect(Self.value(Self.reading(42), [], at: LiveMeter.maxReadingAge + 1) == nil)
    }

    // MARK: - The source

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(PacerStore.allModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    static func fitResult(account: String = "acct", window: String = RateLimitWindowName.fiveHour,
                          rates: [String: Double] = ["claude-opus-5-5": 0.2],
                          pooled: Double = 0.1, intercept: Double = 0) -> SpendMeterFitResult {
        SpendMeterFitResult(
            accountId: account, window: window,
            spanStart: t0.addingTimeInterval(-14 * 86_400), spanEnd: t0,
            modelRates: rates, interceptPerHour: intercept, pooledRate: pooled,
            r2: 0.9, rmse: 1, pooledR2: 0.9, hours: 100, activeHours: 50,
            totalSpendUSD: 1000, totalRise: 100, unfittedSpendUSD: 0,
            interceptShare: 0, noSpendRiseShare: 0, method: SpendMeterFitter.method)
    }

    static func turn(_ context: ModelContext, account: String?, at seconds: TimeInterval,
                     model: String = "claude-opus-5-5", usd: Double) {
        let at = t0.addingTimeInterval(seconds)
        let s = TokenSample(sampledAt: at, date: TokenSample.formatDate(at), model: model,
                            inputTokens: 10, outputTokens: 10, cacheReadTokens: 0,
                            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, sourceCostUSD: usd)
        s.accountId = account
        context.insert(s)
    }

    /// Stored costs only, no ledger: a sample's cost is its `costUSD`, so the
    /// test pins the arithmetic and not a price list.
    static let storedCosts = PricingTable.Snapshot(pricingByModel: [:], ledger: .empty)

    @Test func theSourceReadsTheLatestFitAndOnlyThatAccountsTurns() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(SpendMeterFit(result: Self.fitResult(rates: ["claude-opus-5-5": 0.5]),
                                     fittedDay: "2026-10-20", fittedAt: Self.t0))
        context.insert(SpendMeterFit(result: Self.fitResult(rates: ["claude-opus-5-5": 0.2]),
                                     fittedDay: "2026-10-22", fittedAt: Self.t0))
        context.insert(RateLimitSample(sampledAt: Self.t0, window: RateLimitWindowName.fiveHour,
                                       usedPercentage: 30, resetsAt: Self.t0.addingTimeInterval(7200),
                                       source: RateLimitSource.oauth, accountId: "acct"))
        Self.turn(context, account: "acct", at: 60, usd: 10)
        Self.turn(context, account: "acct", at: 90, model: "<synthetic>", usd: 100)
        Self.turn(context, account: "other", at: 60, usd: 1000)
        Self.turn(context, account: nil, at: 60, usd: 1000)   // unattributed: never counted
        try context.save()

        let source = LiveMeterSource(context: ModelContext(container), mode: .auto, pricing: Self.storedCosts)
        let v = try #require(source.value(account: "acct", window: RateLimitWindowName.fiveHour,
                                          now: Self.t0.addingTimeInterval(120)))
        #expect(v.percent == 32)          // the 10-22 fit: $10 × 0.2
        #expect(abs(v.spendUSD - 10) < 1e-12)
        #expect(v.reading.percent == 30)
    }

    @Test func aNewReadingReplacesTheEstimate() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(SpendMeterFit(result: Self.fitResult(), fittedDay: "2026-10-22", fittedAt: Self.t0))
        let reset = Self.t0.addingTimeInterval(7200)
        context.insert(RateLimitSample(sampledAt: Self.t0, window: RateLimitWindowName.fiveHour,
                                       usedPercentage: 30, resetsAt: reset,
                                       source: RateLimitSource.oauth, accountId: "acct"))
        Self.turn(context, account: "acct", at: 60, usd: 20)
        try context.save()
        let source = LiveMeterSource(context: context, mode: .auto, pricing: Self.storedCosts)
        let now = Self.t0.addingTimeInterval(400)
        #expect(source.value(account: "acct", window: RateLimitWindowName.fiveHour, now: now)?.percent == 34)

        // The server's next reading lands: it already counts that spend.
        context.insert(RateLimitSample(sampledAt: Self.t0.addingTimeInterval(300),
                                       window: RateLimitWindowName.fiveHour,
                                       usedPercentage: 33, resetsAt: reset,
                                       source: RateLimitSource.oauth, accountId: "acct"))
        try context.save()
        let v = try #require(source.value(account: "acct", window: RateLimitWindowName.fiveHour, now: now))
        #expect(v.percent == 33)
        #expect(v.addedPoints == 0)
    }

    @Test func theSourceHasNoValueWithoutAFit() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(RateLimitSample(sampledAt: Self.t0, window: RateLimitWindowName.fiveHour,
                                       usedPercentage: 30, resetsAt: Self.t0.addingTimeInterval(7200),
                                       source: RateLimitSource.oauth, accountId: "acct"))
        Self.turn(context, account: "acct", at: 60, usd: 20)
        try context.save()
        let source = LiveMeterSource(context: context, mode: .auto, pricing: Self.storedCosts)
        #expect(source.value(account: "acct", window: RateLimitWindowName.fiveHour,
                             now: Self.t0.addingTimeInterval(120)) == nil)
    }

    @Test func aScopedCapThroughTheSourceCountsOnlyItsModel() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let identity = "weekly_scoped|Fable|"
        context.insert(SpendMeterFit(result: Self.fitResult(window: identity, rates: ["claude-fable-5-1": 0.5],
                                                            pooled: 0.5),
                                     fittedDay: "2026-10-22", fittedAt: Self.t0))
        context.insert(UsageLimitSample(
            sampledAt: Self.t0, identity: identity, kind: "weekly_scoped", group: "weekly",
            label: "Fable", percent: 4, resetsAt: Self.t0.addingTimeInterval(86_400), severity: "normal",
            isActive: false, modelId: nil, modelDisplayName: "Fable", surface: nil,
            source: RateLimitSource.oauth, accountId: "acct"))
        Self.turn(context, account: "acct", at: 60, model: "claude-opus-5-5", usd: 400)
        Self.turn(context, account: "acct", at: 70, model: "claude-fable-5-1", usd: 6)
        try context.save()
        let source = LiveMeterSource(context: context, mode: .auto, pricing: Self.storedCosts)
        let v = try #require(source.value(account: "acct", window: identity, now: Self.t0.addingTimeInterval(120)))
        #expect(v.percent == 7)   // $6 × 0.5
    }

    @Test func pastTheBackstopThereIsNoValueRatherThanALowOne() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        for i in 0..<5 { Self.turn(context, account: "acct", at: Double(10 + i), usd: 1) }
        try context.save()
        let source = LiveMeterSource(context: context, mode: .auto, pricing: Self.storedCosts)
        #expect(source.spend(account: "acct", after: Self.t0, through: Self.t0.addingTimeInterval(60),
                             limit: 4) == nil)
        #expect(source.spend(account: "acct", after: Self.t0, through: Self.t0.addingTimeInterval(60),
                             limit: 5)?.count == 5)
    }

    // MARK: - The drift log

    /// At a new reading, the line compares it with what the live meter showed
    /// the moment before: built on the previous reading, never the new one.
    @Test func theDriftLineComparesTheNewReadingWithTheEstimateBeforeIt() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(SpendMeterFit(result: Self.fitResult(), fittedDay: "2026-10-22", fittedAt: Self.t0))
        let reset = Self.t0.addingTimeInterval(7200)
        context.insert(RateLimitSample(sampledAt: Self.t0, window: RateLimitWindowName.fiveHour,
                                       usedPercentage: 30, resetsAt: reset,
                                       source: RateLimitSource.oauth, accountId: "acct"))
        Self.turn(context, account: "acct", at: 60, usd: 20)
        let readAt = Self.t0.addingTimeInterval(300)
        context.insert(RateLimitSample(sampledAt: readAt, window: RateLimitWindowName.fiveHour,
                                       usedPercentage: 33, resetsAt: reset,
                                       source: RateLimitSource.oauth, accountId: "acct"))
        try context.save()

        let source = LiveMeterSource(context: context, mode: .auto, pricing: Self.storedCosts)
        let prior = try #require(source.latestReading(account: "acct", window: RateLimitWindowName.fiveHour,
                                                      before: readAt))
        #expect(prior.reading.percent == 30)
        let v = try #require(source.values(account: "acct", windows: [prior], now: readAt)[RateLimitWindowName.fiveHour])
        #expect(v.percent == 34)
        let line = LiveMeterDrift.line(account: "org-acct", window: RateLimitWindowName.fiveHour, read: 33, live: v)
        #expect(line == "acct five_hour: read 33% · live showed 34% (30% 5m ago +4, $20.00 per-model) · +1")
    }
}
