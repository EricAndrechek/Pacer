import Foundation
import SwiftData
import Testing
@testable import PacerCore
@testable import PacerUI

/// The live meter on every surface (#318 part B): the carry, weak fits, the
/// shared readout and board, the engine's live input, the chart's live
/// stretch, today's agreement, and the edge cases the issue lists.
@Suite("Live meter, part B")
struct LiveMeterPartBTests {

    typealias T = LiveMeterTests
    static let t0 = LiveMeterTests.t0
    static let five = RateLimitWindowName.fiveHour
    static let reset = t0.addingTimeInterval(3 * 3600)

    static func reading(_ pct: Double, at seconds: TimeInterval = 0, resets: Date? = reset) -> MeterReading {
        MeterReading(at: t0.addingTimeInterval(seconds), percent: pct, resetsAt: resets)
    }

    static func rateRow(_ context: ModelContext, _ pct: Double, at seconds: TimeInterval,
                        account: String = "acct", window: String = five, resets: Date? = reset) {
        context.insert(RateLimitSample(sampledAt: t0.addingTimeInterval(seconds), window: window,
                                       usedPercentage: pct, resetsAt: resets,
                                       source: RateLimitSource.oauth, accountId: account))
    }

    static func fit(_ context: ModelContext, account: String = "acct", window: String = five,
                    rates: [String: Double] = ["claude-opus-5-5": 0.2], r2: Double = 0.9,
                    rise: Double = 100, day: String = "2026-10-22") {
        let base = T.fitResult(account: account, window: window, rates: rates)
        let result = SpendMeterFitResult(
            accountId: base.accountId, window: base.window, spanStart: base.spanStart, spanEnd: base.spanEnd,
            modelRates: base.modelRates, interceptPerHour: 0, pooledRate: base.pooledRate,
            r2: r2, rmse: 1, pooledR2: r2, hours: 100, activeHours: 50,
            totalSpendUSD: 1000, totalRise: rise, unfittedSpendUSD: 0,
            interceptShare: 0, noSpendRiseShare: 0, method: SpendMeterFitter.method)
        context.insert(SpendMeterFit(result: result, fittedDay: day, fittedAt: t0))
    }

    static func source(_ context: ModelContext) -> LiveMeterSource {
        LiveMeterSource(context: context, mode: .auto, pricing: T.storedCosts)
    }

    static func spend(_ seconds: TimeInterval, usd: Double, model: String = "claude-opus-5-5") -> LiveSpend {
        LiveSpend(at: t0.addingTimeInterval(seconds), model: model, costUSD: usd)
    }

    // MARK: - The carry

    /// A reading that ticks up after spend that should have moved it well
    /// past the point has only just crossed into it; one that holds still
    /// while spend piles up is near the top of its point.
    @Test func theCarryNarrowsWhereTheMeterSitsInsideItsPoint() {
        // 40 → 41 with $10 at 0.2 between: 2 points predicted, 1 half-weighted.
        let ticked = LiveMeter.carry(
            readings: [Self.reading(40), Self.reading(41, at: 300)], duration: T.fiveHours,
            rates: T.rates, spend: [Self.spend(100, usd: 10)])
        // 41 → 41 with $4 at 0.2: 0.8 predicted, 0.4 half-weighted.
        let held = LiveMeter.carry(
            readings: [Self.reading(41), Self.reading(41, at: 300)], duration: T.fiveHours,
            rates: T.rates, spend: [Self.spend(100, usd: 4)])
        let lone = LiveMeter.carry(readings: [Self.reading(41)], duration: T.fiveHours, rates: T.rates, spend: [])
        #expect(abs(lone - 0.25) < 1e-9)                // nothing known: a quarter up
        #expect(abs(held - (0.4 + 0.25 * 0.6)) < 1e-9)  // [41.4, 42): a quarter up it
        #expect(abs(ticked - 0.25) < 1e-9)               // moved a point: just into 41, a quarter up
        // The carry lifts the value across the point it sat near the top of.
        let v = LiveMeter.value(reading: Self.reading(41, at: 300), duration: T.fiveHours, rates: T.rates,
                                spend: [Self.spend(400, usd: 2.5)], carry: held, now: Self.t0.addingTimeInterval(500))
        #expect(v?.percent == 42)   // 0.55 + 0.5 crosses; floored alone it read 41
        #expect(LiveMeter.value(reading: Self.reading(41, at: 300), duration: T.fiveHours, rates: T.rates,
                                spend: [Self.spend(400, usd: 2.5)], now: Self.t0.addingTimeInterval(500))?.percent == 41)
    }

    // MARK: - Edge cases (#318)

    /// 1. Usage on another device moves the meter with no spend here: the
    /// live value cannot see it, and the next reading brings it in whole.
    @Test func otherDevicesAreInvisibleUntilTheNextReading() {
        let before = LiveMeter.value(reading: Self.reading(40), duration: T.fiveHours, rates: T.rates,
                                     spend: [], now: Self.t0.addingTimeInterval(200))
        #expect(before?.percent == 40)
        // The phone's 5 points arrive with the reading, and the carry starts
        // over at the bottom of that point rather than inventing a fraction.
        let next = Self.reading(45, at: 300)
        let readout = LiveMeterReadout(reading: next, live: before, now: Self.t0.addingTimeInterval(310))
        #expect(readout.percent == 45)
        #expect(readout.live == nil)
        #expect(abs(LiveMeter.carry(readings: [Self.reading(40), next], duration: T.fiveHours,
                                    rates: T.rates, spend: []) - 0.25) < 1e-9)
    }

    /// 2 and 13. Claude Desktop's agent sessions and subagent transcripts are
    /// turns like any other: the source counts every turn the account billed,
    /// whatever session or project it came from.
    @Test func desktopAndSubagentTurnsAreCounted() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        Self.fit(context)
        Self.rateRow(context, 30, at: 0)
        for (i, (session, project)) in [("desktop-session", "/Desktop/agent"),
                                        ("parent", "/repo"), ("parent", "/repo/.claude/agents")].enumerated() {
            let at = Self.t0.addingTimeInterval(Double(60 + i * 10))
            let s = TokenSample(sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5-5",
                                inputTokens: 10, outputTokens: 10, cacheReadTokens: 0,
                                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, sourceCostUSD: 5,
                                dedupKey: "m\(i):r\(i)", sessionId: session, projectPath: project)
            s.accountId = "acct"
            context.insert(s)
        }
        try context.save()
        let v = try #require(Self.source(context).value(account: "acct", window: Self.five,
                                                        now: Self.t0.addingTimeInterval(200)))
        #expect(abs(v.spendUSD - 15) < 1e-12)
        #expect(v.percent == 33)   // 30 + floor(0.25 + 3)
    }

    /// 3. After `cswap` moves the login, the new account bills the turns: the
    /// account it moved off stops climbing.
    @Test func anAccountSwitchedOffStopsClimbing() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        Self.fit(context, account: "a")
        Self.fit(context, account: "b")
        Self.rateRow(context, 50, at: 0, account: "a")
        Self.rateRow(context, 10, at: 0, account: "b")
        T.turn(context, account: "a", at: 30, usd: 5)     // before the switch
        T.turn(context, account: "b", at: 90, usd: 50)    // after it
        try context.save()
        let s = Self.source(context)
        let now = Self.t0.addingTimeInterval(200)
        #expect(s.value(account: "a", window: Self.five, now: now)?.percent == 51)
        #expect(s.value(account: "b", window: Self.five, now: now)?.percent == 20)
    }

    /// 4. Several accounts in use at once: the board holds a value for each,
    /// each from its own spend and its own fit.
    @Test func severalAccountsAtOnceEachCountTheirOwnSpend() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        let now = Date()
        for (id, pct, usd) in [("a", 20.0, 10.0), ("b", 60.0, 30.0)] {
            context.insert(Account(id: id, organizationId: id, displayName: id, isActive: id == "a",
                                   firstSeenAt: now.addingTimeInterval(-86_400), lastSeenAt: now))
            let base = T.fitResult(account: id)
            context.insert(SpendMeterFit(result: base, fittedDay: TokenSample.formatDate(now), fittedAt: now))
            context.insert(RateLimitSample(sampledAt: now.addingTimeInterval(-240), window: Self.five,
                                           usedPercentage: pct, resetsAt: now.addingTimeInterval(3600),
                                           source: RateLimitSource.oauth, accountId: id))
            let at = now.addingTimeInterval(-60)
            let s = TokenSample(sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5-5",
                                inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, sourceCostUSD: usd)
            s.accountId = id
            context.insert(s)
        }
        try context.save()
        let board = LiveMeterBoard.build(container: container, now: now)
        #expect(board["a"]?[Self.five]?.percent == 22)   // 20 + floor(0.25 + 2)
        #expect(board["b"]?[Self.five]?.percent == 66)   // 60 + floor(0.25 + 6)
    }

    /// 5. Past the reading's reset the value restarts at 0 plus the spend
    /// after it, with no carry from the window that ended.
    @Test func aResetRestartsFromZeroAndDropsTheCarry() throws {
        let r = Self.reading(80, resets: Self.t0.addingTimeInterval(120))
        let v = try #require(LiveMeter.value(reading: r, duration: T.fiveHours, rates: T.rates,
                                             spend: [Self.spend(60, usd: 50), Self.spend(180, usd: 10)],
                                             carry: 0.9, now: Self.t0.addingTimeInterval(240)))
        #expect(v.restarted)
        #expect(v.percent == 2)
        #expect(v.carry == 0)
        // And the readout keeps a restarted value past the reset it crossed.
        #expect(LiveMeterReadout(reading: r, live: v, now: Self.t0.addingTimeInterval(240)).percent == 2)
    }

    /// 6. A window not started (0%, no reset) begins with the first turn, and
    /// the first anchored reading after it starts a new carry.
    @Test func aWindowNotStartedBeginsWithTheFirstTurn() throws {
        let idle = Self.reading(0, resets: nil)
        let v = try #require(LiveMeter.value(reading: idle, duration: T.fiveHours, rates: T.rates,
                                             spend: [Self.spend(60, usd: 10)], now: Self.t0.addingTimeInterval(120)))
        #expect(v.percent == 2)
        #expect(!LiveMeter.sameCycle(idle, Self.reading(2, at: 300), duration: T.fiveHours))
        #expect(LiveMeter.sameCycle(idle, Self.reading(0, at: 300, resets: nil), duration: T.fiveHours))
    }

    /// 7. Capped at 100, carry or not.
    @Test func theCarryNeverPushesPastOneHundred() {
        let v = LiveMeter.value(reading: Self.reading(99), duration: T.fiveHours, rates: T.rates,
                                spend: [Self.spend(60, usd: 20)], carry: 0.99, now: Self.t0.addingTimeInterval(120))
        #expect(v?.percent == 100)
    }

    /// 8. Readings stop (the poller paused, the token expired): the value keeps
    /// adding spend for an hour from its reading, then the reading stands
    /// alone; the board wakes itself at that instant to say so.
    @Test func readingsStoppedLiveRunsAnHourThenTheReading() throws {
        let r = Self.reading(40)
        let v = try #require(LiveMeter.value(reading: r, duration: T.fiveHours, rates: T.rates,
                                             spend: [Self.spend(600, usd: 10)], now: Self.t0.addingTimeInterval(3000)))
        #expect(LiveMeterReadout(reading: r, live: v, now: Self.t0.addingTimeInterval(3500)).percent == 42)
        let late = LiveMeterReadout(reading: r, live: v, now: Self.t0.addingTimeInterval(3700))
        #expect(late.percent == 40)
        #expect(late.live == nil)
        #expect(LiveMeter.value(reading: r, duration: T.fiveHours, rates: T.rates,
                                spend: [Self.spend(600, usd: 10)], now: Self.t0.addingTimeInterval(3700)) == nil)
        let expiry = LiveMeterBoard.nextExpiry(["acct": [Self.five: v]], after: Self.t0.addingTimeInterval(3000))
        #expect(expiry == Self.t0.addingTimeInterval(3600))
    }

    /// 9. A model with no rate of its own (a new release) goes at the
    /// account's pooled rate: `LiveMeterTests.aModelWithoutItsOwnRateUsesThePooledOne`.
    /// Through the board's path too.
    @Test func aNewModelUsesTheAccountsPooledRate() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        Self.fit(context, rates: ["claude-opus-5-5": 0.2])   // pooled 0.1
        Self.rateRow(context, 10, at: 0)
        T.turn(context, account: "acct", at: 60, model: "claude-opus-6", usd: 30)
        try context.save()
        let v = try #require(Self.source(context).value(account: "acct", window: Self.five,
                                                        now: Self.t0.addingTimeInterval(120)))
        #expect(v.rateSource == .pooled)
        #expect(v.percent == 13)   // floor(0.25 + 3)
    }

    /// 10. Spend is priced the way the fit's rollup priced it: through
    /// `CostCalculator.sampleCost`, under the same mode and price ledger.
    /// (On the owner's store, 162,393 turns: $22,090.32 against the rollup's
    /// $22,090.32, `LiveMeterProbe.costBasis`.)
    @Test func spendIsPricedOnTheFitsBasis() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        T.turn(context, account: "acct", at: 60, usd: 7.5)
        try context.save()
        let sample = try #require(try context.fetch(FetchDescriptor<TokenSample>()).first)
        for mode in CostMode.allCases {
            let s = LiveMeterSource(context: context, mode: mode, pricing: T.storedCosts)
            let priced = try #require(s.spend(account: "acct", after: Self.t0, through: Self.t0.addingTimeInterval(120)))
            #expect(priced.map(\.costUSD) == [CostCalculator.sampleCost(sample, mode: mode, snapshot: T.storedCosts).total])
        }
    }

    /// 11. An allowance change moves points per dollar: the next daily fit
    /// carries the new rate, the source reads the newest fit, and until then
    /// the drift log shows the gap at each reading.
    @Test func anAllowanceChangeFollowsTheDailyRefit() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        Self.fit(context, rates: ["claude-opus-5-5": 0.2], day: "2026-10-21")
        Self.rateRow(context, 30, at: 0)
        T.turn(context, account: "acct", at: 60, usd: 20)
        Self.rateRow(context, 38, at: 300)   // the allowance halved: $20 moved 8 points, not 4
        try context.save()
        let s = Self.source(context)
        let prior = try #require(s.latestReading(account: "acct", window: Self.five, before: Self.t0.addingTimeInterval(300)))
        let old = try #require(s.values(account: "acct", windows: [prior], now: Self.t0.addingTimeInterval(300))[Self.five])
        let line = LiveMeterDrift.line(account: "acct", window: Self.five, read: 38, live: old)
        #expect(line.hasSuffix("· -4"))
        // The refit the next morning has the new rate, and the source takes it.
        Self.fit(context, rates: ["claude-opus-5-5": 0.4], day: "2026-10-22")
        try context.save()
        let new = try #require(s.values(account: "acct", windows: [prior], now: Self.t0.addingTimeInterval(300))[Self.five])
        #expect(new.percent == 38)
    }

    /// 12. A long streamed turn lands when Claude Code writes its last copy,
    /// and counts from then: not before, and never twice.
    @Test func aLongStreamedTurnCountsWhenItLands() {
        let turn = [Self.spend(400, usd: 20)]
        let r = Self.reading(30)
        #expect(LiveMeter.value(reading: r, duration: T.fiveHours, rates: T.rates, spend: turn,
                                now: Self.t0.addingTimeInterval(300))?.percent == 30)
        #expect(LiveMeter.value(reading: r, duration: T.fiveHours, rates: T.rates, spend: turn,
                                now: Self.t0.addingTimeInterval(450))?.percent == 34)
        // A reading after it already has it: from there it is history.
        #expect(LiveMeter.value(reading: Self.reading(34, at: 500), duration: T.fiveHours, rates: T.rates,
                                spend: turn, now: Self.t0.addingTimeInterval(600))?.percent == 34)
    }

    /// 14. A weak fit shows the reading: under 20 points of rise or R² 0.5.
    @Test func aWeakFitShowsTheReading() throws {
        let spend = [Self.spend(60, usd: 20)]
        func shown(r2: Double, rise: Double) -> Double? {
            LiveMeter.value(reading: Self.reading(5), duration: T.fiveHours,
                            rates: LiveMeterRates(modelRates: ["claude-opus-5-5": 0.3], pooledRate: 0.3,
                                                  r2: r2, totalRise: rise),
                            spend: spend, now: Self.t0.addingTimeInterval(120))?.percent
        }
        #expect(shown(r2: 0.15, rise: 8) == nil)     // the Fable weekly's fits
        #expect(shown(r2: 0.75, rise: 12) == nil)
        #expect(shown(r2: 0.39, rise: 40) == nil)
        #expect(shown(r2: 0.5, rise: 20) == 11)
        // Through the source: a weak stored fit costs the probe and no more.
        let container = try T.makeContainer()
        let context = ModelContext(container)
        Self.fit(context, r2: 0.3, rise: 12)
        Self.rateRow(context, 5, at: 0)
        T.turn(context, account: "acct", at: 60, usd: 20)
        try context.save()
        #expect(Self.source(context).value(account: "acct", window: Self.five,
                                           now: Self.t0.addingTimeInterval(120)) == nil)
    }

    /// 15. Under $5 of spend in the fortnight there is no fit, so the reading
    /// is all there is.
    @Test func underFiveDollarsHasNoFit() {
        let utc = TimeZone(identifier: "UTC")!
        let span = DateInterval(start: Self.t0.addingTimeInterval(-14 * 86_400), end: Self.t0)
        let resets = span.start.addingTimeInterval(3 * 86_400)
        // Fifty watched hours, a point every hour, five cents an hour: plenty
        // of hours and rise, $2.50 of spend.
        let readings = (0..<100).map {
            MeterReading(at: span.start.addingTimeInterval(Double($0) * 1800), percent: Double($0 / 2), resetsAt: resets)
        }
        let spend = (0..<50).map { h -> HourlySpend in
            let at = span.start.addingTimeInterval(Double(h) * 3600)
            return HourlySpend(date: TokenSample.formatDate(at, timeZone: utc), hour: Calendar.utc.component(.hour, from: at),
                               model: "claude-opus-5-5", costUSD: 0.05)
        }
        let outcome = SpendMeterFitter.fit(accountId: "acct", window: Self.five, duration: T.fiveHours,
                                           readings: readings, spend: spend, span: span, timeZone: utc)
        guard case .skipped(let reason) = outcome else {
            Issue.record("a fortnight under $5 was fitted: \(outcome)")
            return
        }
        #expect(reason.contains("spent"))
    }

    /// 16. Daylight saving: the hourly buckets the fit reads are local hours,
    /// so the repeated 1 AM of the fall-back and the missing 2 AM of the
    /// spring-forward neither lose a rise nor count one twice. (The live value
    /// itself adds turns by instant and has no buckets.)
    @Test func daylightSavingDaysKeepEveryPointOfRise() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        func hours(from start: String) throws -> [LocalHour: HourObservation] {
            let begin = try #require(ISO8601DateFormatter().date(from: start))
            let readings = (0...9).map {
                MeterReading(at: begin.addingTimeInterval(Double($0) * 1200), percent: Double($0),
                             resetsAt: begin.addingTimeInterval(4 * 3600))
            }
            let span = DateInterval(start: begin.addingTimeInterval(-86_400), end: begin.addingTimeInterval(86_400))
            return SpendMeterFitter.hourlyRise(readings: readings, duration: T.fiveHours, span: span, timeZone: ny)
        }
        // Fall back, 2026-11-01: 1 AM happens twice and is one bucket, as it
        // is in the hourly spend rollup, with both hours' rise in it.
        let fall = try hours(from: "2026-11-01T04:40:00Z")
        #expect(abs(fall.values.reduce(0) { $0 + $1.rise } - 9) < 1e-9)
        let oneAM = try #require(fall[LocalHour(date: "2026-11-01", hour: 1)])
        #expect(abs(oneAM.rise - 6) < 1e-9)
        #expect(abs(oneAM.watchedSeconds - 7200) < 1e-6)
        // Spring forward, 2027-03-14: there is no 2 AM, and nothing is lost.
        let spring = try hours(from: "2027-03-14T05:40:00Z")
        #expect(abs(spring.values.reduce(0) { $0 + $1.rise } - 9) < 1e-9)
        #expect(spring[LocalHour(date: "2027-03-14", hour: 2)] == nil)
    }

    /// 17. A reading lowered mid-window (the server corrected itself) takes
    /// the number down with it: the newer reading wins over the estimate
    /// built on the older one, and the carry starts over.
    @Test func aLoweredReadingTakesTheLiveValueDown() throws {
        let built = try #require(LiveMeter.value(reading: Self.reading(45), duration: T.fiveHours, rates: T.rates,
                                                 spend: [Self.spend(60, usd: 10)], now: Self.t0.addingTimeInterval(200)))
        #expect(built.percent == 47)
        let lowered = Self.reading(40, at: 300)
        #expect(LiveMeterReadout(reading: lowered, live: built, now: Self.t0.addingTimeInterval(310)).percent == 40)
        #expect(abs(LiveMeter.carry(readings: [Self.reading(45), lowered], duration: T.fiveHours, rates: T.rates,
                                    spend: [Self.spend(60, usd: 10)]) - 0.25) < 1e-9)
    }

    // MARK: - The readout every surface reads

    @Test func theReadoutTakesTheNewerOfTheReadingAndTheLiveValue() throws {
        let built = try #require(LiveMeter.value(reading: Self.reading(42, at: 300), duration: T.fiveHours,
                                                 rates: T.rates, spend: [Self.spend(400, usd: 15)],
                                                 now: Self.t0.addingTimeInterval(500)))
        // The surface still holds the reading before: the live one is newer.
        let r = LiveMeterReadout(reading: Self.reading(40), live: built, now: Self.t0.addingTimeInterval(500))
        #expect(r.percent == 45)
        #expect(r.reading.percent == 42)
        #expect(r.help(now: Self.t0.addingTimeInterval(500)) == "read 42% 3 min ago · live 45%")
        // A value equal to its reading says nothing extra.
        let same = try #require(LiveMeter.value(reading: Self.reading(42, at: 300), duration: T.fiveHours,
                                                rates: T.rates, spend: [], now: Self.t0.addingTimeInterval(320)))
        let quiet = LiveMeterReadout(reading: Self.reading(42, at: 300), live: same, now: Self.t0.addingTimeInterval(320))
        #expect(quiet.help(now: Self.t0.addingTimeInterval(320)) == nil)
        #expect(!quiet.differsFromReading)
        // Its window reset since it was built, and it was not restarted: stand down.
        let old = try #require(LiveMeter.value(reading: Self.reading(90, resets: Self.t0.addingTimeInterval(600)),
                                               duration: T.fiveHours, rates: T.rates,
                                               spend: [Self.spend(100, usd: 10)], now: Self.t0.addingTimeInterval(500)))
        #expect(LiveMeterReadout(reading: Self.reading(90, resets: Self.t0.addingTimeInterval(600)), live: old,
                                 now: Self.t0.addingTimeInterval(700)).live == nil)
    }

    /// The board republishes only when a number, or the reading under it,
    /// moved: a rebuild that only advanced `asOf` must not redraw the menu
    /// bar's status item.
    @Test func theBoardPublishesOnlyWhatASurfaceCanShow() throws {
        let a = try #require(LiveMeter.value(reading: Self.reading(40), duration: T.fiveHours, rates: T.rates,
                                             spend: [Self.spend(60, usd: 5)], now: Self.t0.addingTimeInterval(100)))
        let b = try #require(LiveMeter.value(reading: Self.reading(40), duration: T.fiveHours, rates: T.rates,
                                             spend: [Self.spend(60, usd: 6)], now: Self.t0.addingTimeInterval(200)))
        let c = try #require(LiveMeter.value(reading: Self.reading(40), duration: T.fiveHours, rates: T.rates,
                                             spend: [Self.spend(60, usd: 10)], now: Self.t0.addingTimeInterval(200)))
        #expect(LiveMeterBoard.sameOnScreen(["x": [Self.five: a]], ["x": [Self.five: b]]))
        #expect(!LiveMeterBoard.sameOnScreen(["x": [Self.five: a]], ["x": [Self.five: c]]))
        #expect(!LiveMeterBoard.sameOnScreen(["x": [Self.five: a]], [:]))
    }

    /// The menu bar's items carry the live number, and the reading under it.
    @Test func menuBarItemsShowTheLiveNumber() throws {
        let built = try #require(LiveMeter.value(reading: Self.reading(42), duration: T.fiveHours, rates: T.rates,
                                                 spend: [Self.spend(60, usd: 15)], now: Self.t0.addingTimeInterval(200)))
        let readout = LiveMeterReadout(reading: Self.reading(42), live: built, now: Self.t0.addingTimeInterval(200))
        let item = MenuBarWindowItem(key: Self.five, displayName: "5-hour", usedPercentage: 42,
                                     resetsAt: Self.reset, duration: T.fiveHours, group: "",
                                     isScoped: false, isActive: false, readout: readout)
        #expect(item.usedPercentage == 45)
        #expect(item.readout?.reading.percent == 42)
    }

    // MARK: - The engine's live input

    /// With no live value the engine's answers are the golden ones, byte for
    /// byte, through the new `live:` parameters as well as the old calls.
    @Test func withNoLiveValueTheEngineIsByteIdentical() {
        #expect(EngineWindowGoldenTests.serialize() == EngineWindowGoldenTests.golden)
        let f = EngineWindowGoldenTests.fixtureFeatures()
        let fit = UsageIntelligenceEngine.makeFit(f)
        let a = UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: "five_hour")
        let b = UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: "five_hour", live: nil)
        #expect(a == b)
    }

    /// Forecasts start from the live value: the outlook's "used now", the
    /// shown end-of-window floor, and every trajectory's first point.
    @Test func forecastsStartFromTheLiveValue() throws {
        let f = EngineWindowGoldenTests.fixtureFeatures()
        let fit = UsageIntelligenceEngine.makeFit(f)
        let samples = try #require(f.rateLimit["five_hour"])
        let last = try #require(samples.max { $0.at < $1.at })
        let live = LiveMeterValue(percent: 61, reading: MeterReading(at: last.at, percent: last.usedPercentage,
                                                                     resetsAt: last.resetsAt),
                                  addedPoints: 61 - last.usedPercentage, exactAdded: 6, spendUSD: 30,
                                  rateSource: .perModel, restarted: false, asOf: f.now)
        let o = try #require(UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: "five_hour", live: live))
        #expect(o.usedPct == 61)
        let est = UsageIntelligenceEngine.rateLimitOutlook(f, fit, windowKey: "five_hour", live: live)
        #expect(est.value >= 61)
        let traj = UsageIntelligenceEngine.rateLimitTrajectories(f, fit, windowKey: "five_hour", accuracy: nil, live: live)
        #expect(traj.filter(\.canProject).allSatisfy { $0.trajectory.points.first?.usedPercentage == 61 })
        // The fit itself did not see it: a sample is never appended.
        let current = try #require(BurnTrajectory.segment(samples: samples, duration: 5 * 3600, now: f.now).current)
        #expect(current.withLive(live, duration: 5 * 3600).samples == current.samples)
    }

    /// A live value from another cycle, an older reading, or past its reset
    /// says nothing about this cycle's "used now".
    @Test func aLiveValueThatIsNotThisCyclesIsIgnored() throws {
        let f = EngineWindowGoldenTests.fixtureFeatures()
        let samples = try #require(f.rateLimit["five_hour"])
        let current = try #require(BurnTrajectory.segment(samples: samples, duration: 5 * 3600, now: f.now).current)
        let last = try #require(current.samples.last)
        func live(at: Date, resets: Date?, restarted: Bool = false) -> LiveMeterValue {
            LiveMeterValue(percent: 99, reading: MeterReading(at: at, percent: 50, resetsAt: resets),
                           addedPoints: 49, exactAdded: 49, spendUSD: 1, rateSource: .pooled,
                           restarted: restarted, asOf: f.now)
        }
        let duration: TimeInterval = 5 * 3600
        #expect(current.withLive(live(at: last.at, resets: current.resetsAt.addingTimeInterval(duration)),
                                 duration: duration).liveUsed == nil)
        #expect(current.withLive(live(at: last.at.addingTimeInterval(-600), resets: current.resetsAt),
                                 duration: duration).liveUsed == nil)
        #expect(current.withLive(live(at: last.at, resets: current.resetsAt, restarted: true),
                                 duration: duration).liveUsed == nil)
        #expect(current.withLive(live(at: last.at, resets: current.resetsAt), duration: duration).liveUsed == 99)
    }

    // MARK: - The chart

    @Test func theChartDrawsTheLiveStretchPastTheLastReading() throws {
        let now = Self.t0.addingTimeInterval(500)
        let points = [LimitSamplePoint(sampledAt: Self.t0, window: Self.five, usedPercentage: 30, resetsAt: Self.reset),
                      LimitSamplePoint(sampledAt: Self.t0.addingTimeInterval(300), window: Self.five,
                                       usedPercentage: 33, resetsAt: Self.reset)]
        let base = try #require(PaceChartView.Data.cycle(fixed: points, duration: T.fiveHours, now: now))
        #expect(base.points.last?.time == now)          // the flat tail at the reading
        #expect(base.live == nil)
        let built = try #require(LiveMeter.value(reading: Self.reading(33, at: 300), duration: T.fiveHours,
                                                 rates: T.rates, spend: [Self.spend(400, usd: 15)], now: now))
        let readout = LiveMeterReadout(reading: Self.reading(33, at: 300), live: built, now: now)
        let lived = base.withLive(readout, now: now)
        #expect(lived.points.last?.time == Self.t0.addingTimeInterval(300))   // readings only
        #expect(lived.live == PaceChartView.Data.Point(time: now, value: 36))
        #expect(lived.tip == lived.live)
        // The forecast keeps the live point under it.
        let projected = lived.withProjection([.init(time: now, value: 36), .init(time: Self.reset, value: 80)],
                                             crossesFullAt: nil, claimed: false)
        #expect(projected.live == lived.live)
        // No live value, or one equal to the reading: the chart is unchanged.
        #expect(base.withLive(LiveMeterReadout(reading: Self.reading(33, at: 300), live: nil, now: now), now: now) == base)
    }

    // MARK: - How close it has been

    /// Today's agreement scores every reading against the live value built
    /// on the one before, as the drift log does, and stores nothing.
    @Test func todaysAgreementCountsReadingsWithinAPoint() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        Self.fit(context)
        let resets = Self.t0.addingTimeInterval(4 * 3600)
        // $5 per 5 minutes at 0.2: one point each, and the meter keeps up,
        // except the last pair, where another device added four more.
        var pct = 10.0
        for i in 0...8 {
            Self.rateRow(context, pct, at: Double(i * 300), resets: resets)
            T.turn(context, account: "acct", at: Double(i * 300 + 100), usd: 5)
            pct += i == 7 ? 5 : 1
        }
        try context.save()
        let a = try #require(LiveMeterDrift.agreement(context: context, account: "acct", window: Self.five,
                                                      since: Self.t0, now: Self.t0.addingTimeInterval(9 * 300)))
        #expect(a.pairs == 8)
        #expect(a.withinOne == 7)
        #expect(try context.fetchCount(FetchDescriptor<RateLimitSample>()) == 9)
        // Too few readings: nothing to say.
        #expect(LiveMeterDrift.agreement(context: context, account: "acct", window: Self.five,
                                         since: Self.t0.addingTimeInterval(7 * 300),
                                         now: Self.t0.addingTimeInterval(9 * 300)) == nil)
    }
}

private extension Calendar {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}
