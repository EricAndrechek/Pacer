import Foundation
import Testing
@testable import PacerCore
@testable import PacerUI

/// Real against estimated (#318): a reading is written whole, an estimate
/// with its decimal, and the whole points the gate and alerts judge are the
/// estimate's floor.
@Suite("Live meter: the shown value")
struct LiveMeterShownValueTests {

    typealias T = LiveMeterTests
    typealias B = LiveMeterPartBTests
    static let t0 = LiveMeterTests.t0

    static func value(_ reading: Double, carry: Double = 0, usd: Double, at seconds: TimeInterval = 100,
                      resets: Date? = B.reset, now: TimeInterval = 200) -> LiveMeterValue? {
        LiveMeter.value(reading: B.reading(reading, resets: resets), duration: T.fiveHours, rates: T.rates,
                        spend: usd > 0 ? [B.spend(seconds, usd: usd)] : [], carry: carry,
                        now: t0.addingTimeInterval(now))
    }

    @Test func theFormatWritesAReadingWholeAndAnEstimateWithItsDecimal() {
        #expect(PacerMeterFormat.percent(42, isEstimate: false) == "42%")
        #expect(PacerMeterFormat.percent(42.6, isEstimate: true) == "42.6%")
        // An estimate on a whole number keeps its decimal: no exception to learn.
        #expect(PacerMeterFormat.percent(43, isEstimate: true) == "43.0%")
        // Cut, never rounded up: 42.96 is not yet 43.
        #expect(PacerMeterFormat.number(42.96, isEstimate: true) == "42.9")
        // A float sum a hair under a tenth keeps it.
        #expect(PacerMeterFormat.tenths(42.599999999) == 42.6)
        #expect(PacerMeterFormat.parts(42.6, isEstimate: true) == ("42", ".6"))
        #expect(PacerMeterFormat.parts(42, isEstimate: false) == ("42", nil))
    }

    /// The decimal is the reading, plus the carry, plus the unfloored spend,
    /// cut to a tenth; its whole part is the floored value.
    @Test func theEstimatesDecimalIsTheReadingPlusTheCarryPlusTheExactSpend() throws {
        // 42 + 0.3 carry + $2 × 0.2 = 42.7.
        let v = try #require(Self.value(42, carry: 0.3, usd: 2))
        #expect(v.isEstimate)
        #expect(v.percent == 42)
        #expect(abs(v.shownPercent - 42.7) < 1e-9)
        // 42 + 0.25 + $3.48 × 0.2 = 42.946: shown 42.9, counted 42.
        let near = try #require(Self.value(42, carry: 0.25, usd: 3.48))
        #expect(near.percent == 42)
        #expect(abs(near.shownPercent - 42.9) < 1e-9)
        // Capped at 100, never below the reading.
        let top = try #require(Self.value(99, carry: 0.5, usd: 10))
        #expect(top.percent == 100)
        #expect(top.shownPercent == 100)
        let over = try #require(Self.value(100, carry: 0.5, usd: 10))
        #expect(over.shownPercent == 100)
        // After a reset: 0 plus the spend after it, no carry.
        let restarted = try #require(Self.value(97, carry: 0.6, usd: 16, at: 400,
                                                resets: Self.t0.addingTimeInterval(300), now: 500))
        #expect(restarted.restarted)
        #expect(restarted.isEstimate)
        #expect(abs(restarted.shownPercent - 3.2) < 1e-9)
        #expect(restarted.percent == 3)
    }

    /// Nothing counted since the reading: the number is the reading, whole,
    /// whatever the carry says. A model whose own fitted rate is zero moved
    /// nothing either.
    @Test func withNothingCountedTheNumberIsTheReading() throws {
        let quiet = try #require(Self.value(42, carry: 0.7, usd: 0))
        #expect(!quiet.isEstimate)
        #expect(quiet.shownPercent == 42)
        let rates = LiveMeterRates(modelRates: ["claude-haiku-5": 0], pooledRate: 0.2)
        let zero = try #require(LiveMeter.value(
            reading: B.reading(42), duration: T.fiveHours, rates: rates,
            spend: [B.spend(100, usd: 5, model: "claude-haiku-5")], carry: 0.7,
            now: Self.t0.addingTimeInterval(200)))
        #expect(zero.spendUSD == 5)
        #expect(!zero.isEstimate)
        #expect(zero.shownPercent == 42)
    }

    /// The readout every surface reads: the estimate's decimal or the reading,
    /// the whole points for alerts, and the text and hover built from them.
    @Test func theReadoutCarriesTheShownNumberAndItsWholePoints() throws {
        let v = try #require(Self.value(42, carry: 0.3, usd: 2))
        let r = LiveMeterReadout(reading: B.reading(42), live: v, now: Self.t0.addingTimeInterval(200))
        #expect(r.isEstimate)
        #expect(abs(r.percent - 42.7) < 1e-9)
        #expect(r.wholePercent == 42)
        #expect(r.text == "42.7%")
        #expect(r.readText(age: "3 min. ago") == "read 42% 3 min. ago")
        #expect(r.readText(age: nil) == "read 42%")
        #expect(r.help(age: "3 min. ago") == "read 42% 3 min. ago · estimate 42.7%")
        // No live value at all: the reading, and the hover still says so.
        let bare = LiveMeterReadout(reading: B.reading(42), live: nil, now: Self.t0.addingTimeInterval(200))
        #expect(!bare.isEstimate)
        #expect(bare.text == "42%")
        #expect(bare.help(age: "3 min. ago") == "read 42% 3 min. ago")
        // After a reset the hover says the reading is from the window before.
        let restarted = try #require(Self.value(97, usd: 16, at: 400, resets: Self.t0.addingTimeInterval(300),
                                                now: 500))
        let after = LiveMeterReadout(reading: B.reading(97, resets: Self.t0.addingTimeInterval(300)),
                                     live: restarted, now: Self.t0.addingTimeInterval(500))
        #expect(after.help(age: "8 min. ago") == "read 97% 8 min. ago, reset since · estimate 3.2%")
    }

    /// The menu bar's items say which they are, and the engine starts its
    /// forecasts from the number shown.
    @Test func surfacesAndTheEngineTakeTheShownNumber() throws {
        let v = try #require(Self.value(42, carry: 0.3, usd: 2))
        let readout = LiveMeterReadout(reading: B.reading(42), live: v, now: Self.t0.addingTimeInterval(200))
        let item = MenuBarWindowItem(key: B.five, displayName: "5-hour", usedPercentage: 42, resetsAt: B.reset,
                                     duration: T.fiveHours, group: "", isScoped: false, isActive: false,
                                     readout: readout)
        #expect(item.isEstimate)
        #expect(abs((item.usedPercentage ?? 0) - 42.7) < 1e-9)
        let f = EngineWindowGoldenTests.fixtureFeatures()
        let samples = try #require(f.rateLimit["five_hour"])
        let current = try #require(BurnTrajectory.segment(samples: samples, duration: 5 * 3600, now: f.now).current)
        let last = try #require(current.samples.last)
        let live = LiveMeterValue(percent: 56, reading: MeterReading(at: last.at, percent: 55,
                                                                     resetsAt: current.resetsAt),
                                  addedPoints: 1, exactAdded: 1.4, spendUSD: 7, rateSource: .perModel,
                                  restarted: false, asOf: f.now, exactPercent: 56.4)
        #expect(current.withLive(live, duration: 5 * 3600).liveUsed == 56.4)
    }
}

/// One reading, one clock, one formatter (#318): a hover or tooltip built
/// beside a "read … ago" label says the same words, on the same instants
/// (`LiveMeterDisplayTests` has the schedule).
@Suite("Live meter: the reading's age")
struct LiveMeterReadAgeTests {

    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theHoverAndTheLabelUseOneFormatter() {
        let now = Self.at.addingTimeInterval(150)
        let words = PacerReadAge.string(Self.at, now: now)
        let readout = LiveMeterReadout(reading: MeterReading(at: Self.at, percent: 42, resetsAt: nil),
                                       live: nil, now: now)
        #expect(pacerMeterHelp(readout, now: now) == "read 42% \(words)")
        #expect(pacerMeterReadText(readout, now: now) == "read 42% \(words)")
        #expect(readout.caption(age: words) == "read \(words)")
    }
}
