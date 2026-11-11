import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The record of what the live meter showed just before each reading (#352):
/// measured before the poll's save, one row per window with a value, in the
/// same save as the reading.
@Suite("Live meter outcomes")
struct LiveMeterOutcomeTests {

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let reset = t0.addingTimeInterval(7200)
    static let fiveHour = RateLimitWindowName.fiveHour

    static func reading(_ percent: Double, at seconds: TimeInterval, resetsAt: Date? = reset) -> MeterReading {
        MeterReading(at: t0.addingTimeInterval(seconds), percent: percent, resetsAt: resetsAt)
    }

    /// A reading as the store holds it: written by an earlier poll.
    static func store(_ r: MeterReading, _ context: ModelContext, account: String = "acct") {
        context.insert(RateLimitSample(sampledAt: r.at, window: fiveHour, usedPercentage: r.percent,
                                       resetsAt: r.resetsAt, source: RateLimitSource.oauth, accountId: account))
    }

    static func fit(_ context: ModelContext, account: String = "acct", day: String = "2026-10-22",
                    totalRise: Double = 100) {
        let r = LiveMeterTests.fitResult(account: account)
        context.insert(SpendMeterFit(result: SpendMeterFitResult(
            accountId: r.accountId, window: r.window, spanStart: r.spanStart, spanEnd: r.spanEnd,
            modelRates: r.modelRates, interceptPerHour: r.interceptPerHour, pooledRate: r.pooledRate,
            r2: r.r2, rmse: r.rmse, pooledR2: r.pooledR2, hours: r.hours, activeHours: r.activeHours,
            totalSpendUSD: r.totalSpendUSD, totalRise: totalRise, unfittedSpendUSD: r.unfittedSpendUSD,
            interceptShare: r.interceptShare, noSpendRiseShare: r.noSpendRiseShare, method: r.method),
            fittedDay: day, fittedAt: t0))
    }

    /// Stored costs, no catalog: a turn costs exactly its `sourceCostUSD`.
    static func measure(_ context: ModelContext, _ new: MeterReading,
                        runaway: LiveMeterRunaway = LiveMeterRunaway()) -> [LiveMeterDrift.Measurement] {
        let source = LiveMeterSource(context: context, mode: .auto, pricing: LiveMeterTests.storedCosts)
        return LiveMeterDrift.measure(source: source, account: "acct", at: new.at,
                                      readings: [(fiveHour, new)], runaway: runaway)
    }

    static func rows(_ measured: [LiveMeterDrift.Measurement]) -> [LiveMeterOutcome] {
        LiveMeterOutcome.rows(account: "acct", measurements: measured)
    }

    // MARK: - One row, holding what was shown

    /// 30% read, $20 spent at 0.2 points a dollar: the meter showed 34.2
    /// (34 whole) when the next reading landed at 33.
    @Test func aReadingLandsWithOneRowHoldingWhatWasShown() throws {
        let context = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(context)
        Self.store(Self.reading(30, at: 0), context)
        LiveMeterTests.turn(context, account: "acct", at: 60, usd: 20)
        try context.save()

        let new = Self.reading(33, at: 300)
        let rows = Self.rows(Self.measure(context, new))
        try #require(rows.count == 1)
        let row = rows[0]
        #expect(row.accountId == "acct")
        #expect(row.window == Self.fiveHour)
        #expect(row.readingAt == new.at)
        #expect(row.readingPercent == 33)
        #expect(row.readingResetsAt == Self.reset)
        #expect(row.previousAt == Self.t0)
        #expect(row.previousPercent == 30)
        // 30 + carry 0.25 + $20 × 0.2: floored for the gate, cut to a tenth
        // for the surfaces.
        #expect(row.livePercent == 34)
        #expect(row.shownPercent == 34.2)
        #expect(abs(row.exactPercent - 34.25) < 1e-6)
        #expect(abs(row.exactAdded - 4) < 1e-9)
        #expect(abs(row.carry - 0.25) < 1e-9)
        #expect(abs(row.spendUSD - 20) < 1e-12)
        #expect(row.rateSource == "per-model")
        #expect(row.fitDay == "2026-10-22")
        #expect(row.sameCycle)
        #expect(!row.restarted)
        #expect(row.heldImplied == nil && row.heldAt == nil && row.readingHeldImplied == nil)
        #expect(row.runaway == "fine")
    }

    /// The fit recorded is the one whose rates built the value: the newest,
    /// not any other day's.
    @Test func theFitIdIsTheFitThatBuiltTheValue() throws {
        let context = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(context, day: "2026-10-20")
        Self.fit(context, day: "2026-10-22")
        Self.store(Self.reading(30, at: 0), context)
        try context.save()
        #expect(Self.rows(Self.measure(context, Self.reading(30, at: 300))).map(\.fitDay) == ["2026-10-22"])
    }

    // MARK: - No value, no row

    @Test func noRowWithoutALiveValue() throws {
        // No fit at all.
        let bare = ModelContext(try LiveMeterTests.makeContainer())
        Self.store(Self.reading(30, at: 0), bare)
        LiveMeterTests.turn(bare, account: "acct", at: 60, usd: 20)
        try bare.save()
        let none = Self.measure(bare, Self.reading(33, at: 300))
        #expect(none.count == 1 && none[0].value == nil)
        #expect(Self.rows(none).isEmpty)

        // A weak fit: under `LiveMeter.minFitRise` of rise.
        let weak = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(weak, totalRise: LiveMeter.minFitRise - 1)
        Self.store(Self.reading(30, at: 0), weak)
        try weak.save()
        #expect(Self.rows(Self.measure(weak, Self.reading(33, at: 300))).isEmpty)

        // The window's first reading: nothing before it to build on.
        let first = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(first)
        try first.save()
        #expect(Self.rows(Self.measure(first, Self.reading(33, at: 300))).isEmpty)

        // The reading before is over an hour old.
        let old = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(old)
        Self.store(Self.reading(30, at: 0), old)
        try old.save()
        #expect(Self.rows(Self.measure(old, Self.reading(33, at: LiveMeter.maxReadingAge + 1))).isEmpty)
    }

    // MARK: - The guards

    /// The previous reading held at 30 while $15 (3 points) was spent since
    /// it last moved: the shown value was built on that tick, and the row
    /// says so.
    @Test func theLagGuardOnTheShownValueIsRecorded() throws {
        let context = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(context)
        Self.store(Self.reading(29, at: -60), context)
        Self.store(Self.reading(30, at: 0), context)       // the tick
        LiveMeterTests.turn(context, account: "acct", at: 60, usd: 15)
        Self.store(Self.reading(30, at: 120), context)     // held
        try context.save()

        let row = try #require(Self.rows(Self.measure(context, Self.reading(34, at: 240))).first)
        #expect(row.previousAt == Self.t0.addingTimeInterval(120))
        #expect(row.previousPercent == 30)
        #expect(row.heldAt == Self.t0)
        #expect(abs((row.heldImplied ?? 0) - 3) < 1e-9)
        #expect(row.livePercent == 33)
        #expect(row.readingHeldImplied == nil)
        #expect(row.runaway == "fine")
    }

    /// The new reading holds at the tick's value while the spend since
    /// implied 3 points: the lag guard calls it stale, and the runaway guard
    /// does not judge it.
    @Test func theLagGuardOnTheNewReadingIsRecorded() throws {
        let context = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(context)
        Self.store(Self.reading(29, at: -60), context)
        Self.store(Self.reading(30, at: 0), context)
        LiveMeterTests.turn(context, account: "acct", at: 60, usd: 15)
        try context.save()

        let measured = Self.measure(context, Self.reading(30, at: 120))
        #expect(measured.first?.runaway == .skipped)
        let row = try #require(Self.rows(measured).first)
        #expect(abs((row.readingHeldImplied ?? 0) - 3) < 1e-9)
        #expect(row.heldImplied == nil)
        #expect(row.livePercent == 33)
        #expect(row.runaway == "skipped")
    }

    /// Three readings in a row each 2+ points under what the meter showed
    /// suspend the window on that fit; the fourth finds it suspended. Every
    /// verdict is on its reading's row.
    @Test func theRunawayGuardsVerdictsAreRecorded() throws {
        let context = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(context)
        let runaway = LiveMeterRunaway()
        var verdicts: [String] = []
        Self.store(Self.reading(30, at: 0), context)
        for i in 1...4 {
            // $20 (4 points) between readings that rise by one.
            LiveMeterTests.turn(context, account: "acct", at: Double(i) * 300 - 200, usd: 20)
            try context.save()
            let new = Self.reading(30 + Double(i), at: Double(i) * 300)
            let row = try #require(Self.rows(Self.measure(context, new, runaway: runaway)).first)
            verdicts.append(row.runaway)
            Self.store(new, context)
        }
        #expect(verdicts == ["high-1", "high-2", "suspended-now", "suspended"])
    }

    // MARK: - Cycles (AGENTS.md rule 9)

    /// The server re-serializes `resets_at` on every response and it jitters
    /// in the milliseconds: a reading 300 ms off the previous one's reset is
    /// the same cycle. Equality would call it a new one.
    @Test func cycleMembershipToleratesResetJitter() throws {
        let context = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(context)
        Self.store(Self.reading(30, at: 0), context)
        try context.save()

        let jittered = Self.reading(31, at: 300, resetsAt: Self.reset.addingTimeInterval(0.3))
        let row = try #require(Self.rows(Self.measure(context, jittered)).first)
        #expect(row.sameCycle)
        #expect(!row.restarted)
        #expect(row.readingResetsAt != Self.reset)
    }

    /// A reading after the previous reading's reset is a new cycle, and the
    /// value it replaced had restarted at 0 plus the spend after the reset.
    @Test func aReadingPastTheResetIsANewCycle() throws {
        let context = ModelContext(try LiveMeterTests.makeContainer())
        Self.fit(context)
        let before = 7200.0 - 600
        Self.store(Self.reading(80, at: before), context)
        LiveMeterTests.turn(context, account: "acct", at: 7200 + 60, usd: 10)
        try context.save()

        let next = Self.reading(2, at: 7200 + 300, resetsAt: Self.reset.addingTimeInterval(5 * 3600))
        let row = try #require(Self.rows(Self.measure(context, next)).first)
        #expect(!row.sameCycle)
        #expect(row.restarted)
        #expect(row.livePercent == 2)     // 0 + $10 × 0.2
        #expect(row.previousPercent == 80)
    }

    // MARK: - Through the poller

    private static func client(body: String, token: String = "tok") -> OAuthClient {
        let blob = try! JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": token,
                "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
            ] as [String: Any],
        ])
        let kc = KeychainOAuth(rawReader: { .success(blob) })
        return OAuthClient(keychain: kc, transport: { _ in try HTTPOutcome.success(jsonBody: body).materialize() },
                           desktopEnabled: { false })
    }

    struct StoredOutcome: Sendable {
        let window: String, readingAt: Date, readingPercent: Double, previousPercent: Double
        let shownPercent: Double, livePercent: Double, spendUSD: Double, fitDay: String
    }

    /// A poll writes the outcome in the same save as its readings: after
    /// `runOnce` the row is there, beside the five-hour reading it describes,
    /// carrying what the source computed for that moment. No row for the
    /// seven-day window, which has no fit.
    @Test func aPolledReadingWritesItsOutcomeInTheSameSave() async throws {
        let container = try LiveMeterTests.makeContainer()
        let now = Date()
        let reset = now.addingTimeInterval(7200)
        // No org header: the poll's account is `Account.defaultKey`.
        let account = Account.defaultKey
        let expected: LiveMeterValue = try await MainActor.run {
            let context = ModelContext(container)
            Self.fit(context, account: account)
            context.insert(RateLimitSample(sampledAt: now.addingTimeInterval(-300), window: Self.fiveHour,
                                           usedPercentage: 30, resetsAt: reset,
                                           source: RateLimitSource.oauth, accountId: account))
            let at = now.addingTimeInterval(-200)
            let s = TokenSample(sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5-5",
                                inputTokens: 10, outputTokens: 10, cacheReadTokens: 0,
                                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, sourceCostUSD: 20)
            s.accountId = account
            context.insert(s)
            try context.save()
            // What the poller's own source (the user's cost mode, the
            // process's prices) builds for the reading before, at any moment
            // after the turn: the poll's instant is not known in advance.
            return try #require(LiveMeterSource(context: context).value(account: account, window: Self.fiveHour,
                                                                        now: Date()))
        }

        let iso = ISO8601DateFormatter()
        let poller = OAuthPoller(client: Self.client(body: """
            {"five_hour":{"utilization":33.0,"resets_at":"\(iso.string(from: reset))"},
             "seven_day":{"utilization":10.0,"resets_at":"\(iso.string(from: now.addingTimeInterval(3 * 86_400)))"}}
            """), container: container, configuration: .init(), clock: TestClock())
        _ = await poller.runOnce()

        let (outcomes, fiveHourAt): ([StoredOutcome], Date?) = try await MainActor.run {
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<LiveMeterOutcome>()).map {
                StoredOutcome(window: $0.window, readingAt: $0.readingAt, readingPercent: $0.readingPercent,
                              previousPercent: $0.previousPercent, shownPercent: $0.shownPercent,
                              livePercent: $0.livePercent, spendUSD: $0.spendUSD, fitDay: $0.fitDay)
            }
            let window = Self.fiveHour
            var d = FetchDescriptor<RateLimitSample>(
                predicate: #Predicate { $0.window == window && $0.usedPercentage == 33 })
            d.fetchLimit = 1
            return (rows, try context.fetch(d).first?.sampledAt)
        }
        try #require(outcomes.count == 1)
        let row = outcomes[0]
        #expect(row.window == Self.fiveHour)
        #expect(row.readingAt == fiveHourAt)
        #expect(row.readingPercent == 33)
        #expect(row.previousPercent == 30)
        #expect(row.fitDay == "2026-10-22")
        #expect(row.livePercent == expected.percent)
        #expect(row.shownPercent == expected.shownPercent)
        #expect(abs(row.spendUSD - expected.spendUSD) < 1e-9)
    }
}
