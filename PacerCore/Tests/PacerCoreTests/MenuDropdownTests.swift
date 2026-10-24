import Foundation
import Testing
@testable import PacerCore
@testable import PacerUI

/// The menu-bar dropdown's fuel bars (#318, round 4): one row per window and
/// one caption line per account.
@Suite("Menu dropdown: fuel bars and the account caption")
struct MenuDropdownTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86400

    static func chip(_ kind: ForecastChip.Kind) -> ForecastChip {
        ForecastChip(text: "", tint: .neutral, help: "", kind: kind)
    }

    static func window(_ name: String, _ percent: Double, resetsIn: TimeInterval?,
                       _ kind: ForecastChip.Kind? = nil) -> AccountCaption.Window {
        AccountCaption.Window(name: name, percent: percent,
                              resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                              forecast: kind.map(chip))
    }

    // MARK: - The caption: at most two facts, the most urgent first

    /// The four accounts of the approved mockup.
    @Test func theMockupsAccounts() {
        // 5H idle, weekly 90% holding, Fable 2% on the same reset: the
        // binding window's reset, and the Fable cap's quiet reset is not news.
        #expect(AccountCaption.text([
            Self.window("5-hour", 0, resetsIn: nil),
            Self.window("weekly", 90, resetsIn: 2 * Self.day, .holds),
            Self.window("Fable", 2, resetsIn: 2 * Self.day, .holds),
        ], now: Self.now) == "weekly resets in 2 days")
        // Fable at 0% says nothing.
        #expect(AccountCaption.text([
            Self.window("5-hour", 0, resetsIn: nil),
            Self.window("weekly", 97, resetsIn: 4 * Self.day, .holds),
            Self.window("Fable", 0, resetsIn: 4 * Self.day),
        ], now: Self.now) == "weekly resets in 4 days")
        #expect(AccountCaption.text([
            Self.window("weekly", 97, resetsIn: 12 * Self.hour, .limitAroundReset),
            Self.window("Fable", 12, resetsIn: 12 * Self.hour, .holds),
        ], now: Self.now) == "weekly resets in 12 hr · limit around reset")
        // The signed-in account: the crossing first, then the binding
        // quiet window's reset.
        #expect(AccountCaption.text([
            Self.window("5-hour", 0.8, resetsIn: 4 * Self.hour, .atReset(4)),
            Self.window("weekly", 54.5, resetsIn: 5 * Self.day,
                        .limit(at: Self.now.addingTimeInterval(28 * Self.hour))),
            Self.window("Fable", 0, resetsIn: 5 * Self.day),
        ], now: Self.now) == "weekly limit in 28 hr · 5-hour resets in 4 hr")
    }

    @Test func urgentWindowsRankBeforeQuietOnes() {
        // At the limit beats a crossing; the sooner crossing first.
        #expect(AccountCaption.facts([
            Self.window("weekly", 60, resetsIn: 3 * Self.day,
                        .limit(at: Self.now.addingTimeInterval(30 * Self.hour))),
            Self.window("5-hour", 100, resetsIn: 2 * Self.hour, .atLimit),
            Self.window("Fable", 70, resetsIn: 3 * Self.day,
                        .limit(at: Self.now.addingTimeInterval(9 * Self.hour))),
        ], now: Self.now) == ["5-hour resets in 2 hr", "Fable limit in 9 hr"])
        // A claimed crossing beats a withheld one.
        #expect(AccountCaption.facts([
            Self.window("5-hour", 40, resetsIn: 3 * Self.hour,
                        .mayHitLimit(at: Self.now.addingTimeInterval(1 * Self.hour))),
            Self.window("weekly", 70, resetsIn: 3 * Self.day,
                        .limit(at: Self.now.addingTimeInterval(40 * Self.hour))),
        ], now: Self.now) == ["weekly limit in 40 hr", "5-hour may hit limit in 60 min"])
        // A reading at 100% is at the limit whatever the chip.
        #expect(AccountCaption.facts([
            Self.window("weekly", 30, resetsIn: 3 * Self.day),
            Self.window("5-hour", 100, resetsIn: 90 * 60),
        ], now: Self.now) == ["5-hour resets in 2 hr", "weekly resets in 3 days"])
    }

    @Test func twoFactsAtMostAndAPairShortensToFit() {
        #expect(AccountCaption.facts([
            Self.window("5-hour", 80, resetsIn: 2 * Self.hour,
                        .limit(at: Self.now.addingTimeInterval(1 * Self.hour))),
            Self.window("weekly", 95, resetsIn: 12 * Self.hour, .limitAroundReset),
            Self.window("Fable", 50, resetsIn: 12 * Self.hour),
        ], now: Self.now) == ["5-hour limit in 60 min", "weekly limit around reset"])
        #expect(AccountCaption.facts([
            Self.window("5-hour", 80, resetsIn: 2 * Self.hour,
                        .limit(at: Self.now.addingTimeInterval(1 * Self.hour))),
            Self.window("weekly", 70, resetsIn: 3 * Self.day,
                        .limit(at: Self.now.addingTimeInterval(20 * Self.hour))),
            Self.window("Fable", 60, resetsIn: 3 * Self.day,
                        .limit(at: Self.now.addingTimeInterval(30 * Self.hour))),
        ], now: Self.now).count == 2)
    }

    @Test func onlyTheBindingQuietWindowSpeaks() {
        // The most used one; the 5-hour's reset is not news at 30%.
        #expect(AccountCaption.facts([
            Self.window("5-hour", 30, resetsIn: 3 * Self.hour, .atReset(45)),
            Self.window("weekly", 62, resetsIn: 4 * Self.day, .atReset(70)),
        ], now: Self.now) == ["weekly resets in 4 days"])
        // A reset an urgent window already said is not said again.
        #expect(AccountCaption.facts([
            Self.window("weekly", 100, resetsIn: 2 * Self.day, .atLimit),
            Self.window("Fable", 40, resetsIn: 2 * Self.day, .holds),
        ], now: Self.now) == ["weekly resets in 2 days"])
    }

    @Test func idleAndEmptyWindowsSayNothing() {
        #expect(AccountCaption.facts([
            Self.window("5-hour", 0, resetsIn: nil),
            Self.window("weekly", 0, resetsIn: 6 * Self.day),
            // Past its reset.
            Self.window("Fable", 40, resetsIn: -60),
        ], now: Self.now).isEmpty)
        #expect(AccountCaption.text([], now: Self.now) == "")
    }

    @Test func theCaptionCountsDownOnTheGivenClock() {
        let windows = [Self.window("5-hour", 50, resetsIn: 47 * 60)]
        #expect(AccountCaption.text(windows, now: Self.now) == "5-hour resets in 45 min")
        #expect(AccountCaption.text(windows, now: Self.now.addingTimeInterval(20 * 60))
                == "5-hour resets in 25 min")
        #expect(AccountCaption.text(windows, now: Self.now.addingTimeInterval(48 * 60)).isEmpty)
    }

    /// The caption's forecast words are the chip's: `ForecastChip.make`
    /// marks each chip with what it says.
    @Test func theChipSaysWhatKindItIs() throws {
        let hit = Self.now.addingTimeInterval(9 * Self.hour)
        let o = UsageIntelligenceEngine.BurnOutlook(
            slopePercentPerHour: 30, projectedFullAt: hit, etaSeconds: hit.timeIntervalSince(Self.now),
            projectedFullAtEarliest: nil, projectedFullAtLatest: nil, usedPct: 70,
            resetsAt: Self.now.addingTimeInterval(3 * Self.day), anchorShift: 0, method: "test",
            cyclesObserved: 10, cyclesPeakOver90: 1, cyclesHit100: 0,
            hitClaimable: true, claimConfirmed: true)
        let end = Estimate(value: 100, interval80: nil, method: "test", confidence: .medium, support: 10)
        let chip = try #require(ForecastChip.make(outlook: o, endEstimate: end, duration: 7 * Self.day,
                                                  usedPct: 70, now: Self.now))
        #expect(chip.kind == .limit(at: hit))
        let atLimit = try #require(ForecastChip.make(outlook: o, endEstimate: end, duration: 7 * Self.day,
                                                     usedPct: 100, now: Self.now))
        #expect(atLimit.kind == .atLimit)
    }

    // MARK: - The rows

    static func item(_ key: String = RateLimitWindowName.sevenDay, used: Double?, reading: Double? = nil,
                     resetsAt: Date?, estimate: Double? = nil, restarted: Bool = false,
                     duration: TimeInterval = 7 * 86400) -> MenuBarWindowItem {
        let readAt = now.addingTimeInterval(-300)
        var readout: LiveMeterReadout?
        if let used {
            let read = MeterReading(at: readAt, percent: reading ?? used, resetsAt: resetsAt)
            let live = estimate.map { est in
                LiveMeterValue(percent: est.rounded(.down), reading: read, addedPoints: 0,
                               exactAdded: restarted ? 0 : est - (reading ?? used), spendUSD: 1,
                               rateSource: .perModel, restarted: restarted, asOf: now, exactPercent: est)
            }
            readout = LiveMeterReadout(reading: read, live: live, now: now)
        }
        return MenuBarWindowItem(key: key, displayName: key == RateLimitWindowName.sevenDay ? "7-day" : "Fable",
                                 usedPercentage: used, resetsAt: resetsAt, duration: duration, group: "",
                                 isScoped: key != RateLimitWindowName.sevenDay && key != RateLimitWindowName.fiveHour,
                                 isActive: false, readout: readout)
    }

    @Test func aRunningWindowHasItsBarTickAndNumber() throws {
        // Two days into a 7-day cycle: the tick at 2/7.
        let resets = Self.now.addingTimeInterval(5 * Self.day)
        let row = Self.item(used: 54, resetsAt: resets).fuelRow(now: Self.now)
        #expect(row.value == .percent(54, isEstimate: false))
        #expect(row.reading == 54)
        #expect(row.estimate == nil)
        #expect(abs(try #require(row.pace) - 2.0 / 7) < 1e-9)
        #expect(row.resetsAt == resets)
        // An estimate: the tail to it, its decimal in the number.
        let est = Self.item(used: 54, resetsAt: resets, estimate: 54.5).fuelRow(now: Self.now)
        #expect(est.value == .percent(54.5, isEstimate: true))
        #expect(est.reading == 54)
        #expect(est.estimate == 54.5)
    }

    @Test func idleWindowsAreIdle() {
        // No cycle, at 0%.
        #expect(Self.item(RateLimitWindowName.fiveHour, used: 0, resetsAt: nil, duration: 5 * 3600)
            .fuelRow(now: Self.now).value == .idle)
        // Past its reset: the old cycle's 80% is not this window's.
        let past = Self.item(used: 80, resetsAt: Self.now.addingTimeInterval(-60)).fuelRow(now: Self.now)
        #expect(past.value == .idle)
        #expect(past.reading == nil)
        #expect(past.pace == nil)
        // No reading at all is not idle, and not 0%.
        #expect(Self.item(used: nil, resetsAt: nil).fuelRow(now: Self.now).value == .noReading)
    }

    @Test func aRestartedEstimateIsDrawnAloneWithNoTick() {
        let past = Self.now.addingTimeInterval(-60)
        let row = Self.item(used: 3.2, reading: 80, resetsAt: past, estimate: 3.2, restarted: true)
            .fuelRow(now: Self.now)
        #expect(row.value == .percent(3.2, isEstimate: true))
        #expect(row.pace == nil)
        #expect(row.resetsAt == nil)
        // The bar: an estimate under its reading draws from 0.
        let bar = PacerFuelBar.stretches(reading: row.reading, estimate: row.estimate)
        #expect(bar.solid == 0)
        #expect(abs(bar.tail - 0.032) < 1e-6)
    }

    @Test func theBarsStretchesAndTick() {
        let bar = PacerFuelBar.stretches(reading: 54, estimate: 54.5)
        #expect(abs(bar.solid - 0.54) < 1e-6)
        #expect(abs(bar.tail - 0.545) < 1e-6)
        let none = PacerFuelBar.stretches(reading: nil, estimate: 5)
        #expect(none.solid == 0 && none.tail == 0)
        #expect(PacerFuelBar.stretches(reading: 120, estimate: nil).solid == 1)
        // The tick stays inside the bar at either end.
        #expect(PacerFuelBar.tickOffset(0, width: 200) == 0)
        #expect(PacerFuelBar.tickOffset(1, width: 200) == 198)
        #expect(PacerFuelBar.tickOffset(0.5, width: 200) == 99)
        // A sliver still shows.
        #expect(PacerFuelBar.drawn(0.004, of: 200) == 2)
    }

    @Test func rowsAreNamedShortAndCaptionsLong() {
        let five = MenuBarWindowItem(key: RateLimitWindowName.fiveHour, displayName: "5-hour", usedPercentage: 1,
                                     resetsAt: nil, duration: 5 * 3600, group: "", isScoped: false, isActive: false)
        #expect(five.barLabel == "5H")
        #expect(five.captionName == "5-hour")
        let week = Self.item(used: 1, resetsAt: nil)
        #expect(week.barLabel == "7D")
        #expect(week.captionName == "weekly")
        let fable = Self.item("fable|weekly", used: 1, resetsAt: nil)
        #expect(fable.barLabel == "FABLE")
        #expect(fable.captionName == "Fable")
    }
}
