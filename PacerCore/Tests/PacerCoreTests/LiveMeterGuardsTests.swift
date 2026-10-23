import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The live meter's two guards (#318): a reading that holds still while the
/// spend says the meter moved is stale (the server-lag guard), and an
/// estimate that runs high three readings in a row is suspended until the
/// next daily fit (the runaway guard).
@Suite("Live meter: the lag and runaway guards")
struct LiveMeterGuardsTests {

    typealias T = LiveMeterTests
    typealias B = LiveMeterPartBTests
    static let t0 = LiveMeterTests.t0
    static let five = RateLimitWindowName.fiveHour

    static func r(_ pct: Double, _ seconds: TimeInterval) -> MeterReading { B.reading(pct, at: seconds) }

    // MARK: - Server lag

    /// 39 → 40 at 0 is the tick. 40 held at 120 with $11 at 0.2 between:
    /// 2.2 points implied while the reading held. Stale: the estimate keeps
    /// building on the tick instead of starting over at the held reading.
    @Test func aReadingThatHoldsWhileSpendImpliesTwoPointsIsStale() throws {
        let readings = [Self.r(39, -300), Self.r(40, 0), Self.r(40, 120)]
        let spend = [B.spend(60, usd: 11), B.spend(150, usd: 1)]
        let held = try #require(LiveMeter.heldTick(readings: readings, duration: T.fiveHours, rates: T.rates,
                                                   spend: spend))
        #expect(held.tick == Self.r(40, 0))
        #expect(abs(held.implied - 2.2) < 1e-9)
        let v = try #require(LiveMeter.estimate(history: readings, duration: T.fiveHours, rates: T.rates,
                                                spend: spend, now: Self.t0.addingTimeInterval(180)))
        // Built on the tick with all the spend since: 40 + carry + 2.4.
        #expect(v.anchor == Self.r(40, 0))
        #expect(v.reading == Self.r(40, 120))
        #expect(v.percent >= 42)
        #expect(abs((v.heldImplied ?? 0) - 2.2) < 1e-9)
        // Without the guard it would have started over at the held reading.
        let plain = try #require(LiveMeter.value(reading: Self.r(40, 120), duration: T.fiveHours, rates: T.rates,
                                                 spend: spend, carry: 0.9, now: Self.t0.addingTimeInterval(180)))
        #expect(plain.percent == 41)
    }

    /// What the owner's data shows today: a plateau's spend under 2 points is
    /// ordinary, and the reading is believed.
    @Test func aPlateauUnderTwoPointsIsBelieved() {
        let readings = [Self.r(39, -300), Self.r(40, 0), Self.r(40, 120)]
        #expect(LiveMeter.heldTick(readings: readings, duration: T.fiveHours, rates: T.rates,
                                   spend: [B.spend(60, usd: 7)]) == nil)    // 1.4 points
        // A reading that moved is never stale.
        #expect(LiveMeter.heldTick(readings: [Self.r(40, 0), Self.r(41, 120)], duration: T.fiveHours,
                                   rates: T.rates, spend: [B.spend(60, usd: 20)]) == nil)
        // At 100 there is nothing to climb to.
        #expect(LiveMeter.heldTick(readings: [Self.r(100, 0), Self.r(100, 120)], duration: T.fiveHours,
                                   rates: T.rates, spend: [B.spend(60, usd: 20)]) == nil)
    }

    /// Past `maxServerLag` since the tick a held reading is believed again,
    /// whatever the spend says: that is the runaway guard's to judge.
    @Test func aHoldPastTheLagAllowanceIsBelieved() {
        let late = LiveMeter.maxServerLag + 60
        let readings = [Self.r(39, -300), Self.r(40, 0), Self.r(40, late)]
        #expect(LiveMeter.heldTick(readings: readings, duration: T.fiveHours, rates: T.rates,
                                   spend: [B.spend(60, usd: 20)]) == nil)
    }

    /// The source applies it, and says so for the drift log.
    @Test func theSourceBuildsOnTheTickAndReportsTheHold() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        B.fit(context)
        B.rateRow(context, 39, at: -300)
        B.rateRow(context, 40, at: 0)
        B.rateRow(context, 40, at: 120)
        T.turn(context, account: "acct", at: 60, usd: 11)
        try context.save()
        let s = B.source(context)
        let held = try #require(s.held(account: "acct", window: Self.five, through: Self.t0.addingTimeInterval(120)))
        #expect(abs(held.implied - 2.2) < 1e-9)
        let v = try #require(s.value(account: "acct", window: Self.five, now: Self.t0.addingTimeInterval(130)))
        #expect(v.anchor.at == Self.t0)
        #expect(v.percent >= 42)
        // The surfaces hold the latest reading, and the readout keeps the value.
        let readout = LiveMeterReadout(reading: Self.r(40, 120), live: v, now: Self.t0.addingTimeInterval(130))
        #expect(readout.live != nil)
        #expect(readout.wholePercent >= 42)
    }

    // MARK: - Runaway

    /// Three readings in a row with the estimate 2+ points over: suspended,
    /// for that account and window, until a new daily fit.
    @Test func threeHighReadingsInARowSuspendTheWindowUntilTheNextFit() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        B.fit(context, day: "2026-10-22")
        B.rateRow(context, 40, at: 0)
        T.turn(context, account: "acct", at: 60, usd: 20)
        try context.save()
        let guardian = LiveMeterRunaway()
        func judge(_ shown: Double, _ reading: Double, stale: Bool = false) -> LiveMeterRunaway.Verdict {
            guardian.judge(context: context, account: "acct", window: Self.five, fittedDay: "2026-10-22",
                           shown: shown, reading: reading, readingIsStale: stale)
        }
        #expect(judge(43, 41) == .high(1))
        #expect(judge(42, 41) == .fine)          // within 2: the count starts over
        #expect(judge(44, 41) == .high(1))
        #expect(judge(45, 41, stale: true) == .skipped)   // a stale reading is no answer
        #expect(judge(45, 42) == .high(2))
        #expect(judge(46, 43) == .suspendedNow)
        #expect(judge(40, 43) == .suspended)
        // The source shows the reading for that window, and only that one.
        let s = B.source(context)
        let now = Self.t0.addingTimeInterval(120)
        #expect(s.value(account: "acct", window: Self.five, now: now) == nil)
        var ignoring = s
        ignoring.ignoresRunaway = true
        #expect(ignoring.value(account: "acct", window: Self.five, now: now) != nil)
        // The next daily fit lifts it.
        B.fit(context, day: "2026-10-23")
        try context.save()
        #expect(s.value(account: "acct", window: Self.five, now: now) != nil)
        #expect(guardian.judge(context: context, account: "acct", window: Self.five, fittedDay: "2026-10-23",
                               shown: 43, reading: 41, readingIsStale: false) == .high(1))
    }

    /// Another account's or window's misses are their own.
    @Test func theRunawayCountIsPerAccountAndWindow() throws {
        let container = try T.makeContainer()
        let context = ModelContext(container)
        let guardian = LiveMeterRunaway()
        for _ in 0..<2 {
            _ = guardian.judge(context: context, account: "a", window: Self.five, fittedDay: "d",
                               shown: 50, reading: 40, readingIsStale: false)
        }
        #expect(guardian.judge(context: context, account: "b", window: Self.five, fittedDay: "d",
                               shown: 50, reading: 40, readingIsStale: false) == .high(1))
        #expect(guardian.judge(context: context, account: "a", window: "seven_day", fittedDay: "d",
                               shown: 50, reading: 40, readingIsStale: false) == .high(1))
        #expect(guardian.judge(context: context, account: "a", window: Self.five, fittedDay: "d",
                               shown: 50, reading: 40, readingIsStale: false) == .suspendedNow)
        #expect(LiveMeterRunaway.suspendedDays(context: context, account: "a") == [Self.five: "d"])
        #expect(LiveMeterRunaway.suspendedDays(context: context, account: "b").isEmpty)
    }
}
