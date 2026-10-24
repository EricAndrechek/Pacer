import Foundation
import Testing
@testable import PacerCore
@testable import PacerUI

/// Round 3 of the live meter's display (#318): the estimate as the number
/// with the reading in a caption, one colour rule for the forecast chip, the
/// burn-rate chip, and one minute schedule for every age.
@Suite("Live meter: what every surface says")
struct LiveMeterDisplayTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let fiveHours: TimeInterval = 5 * 3600

    static func outlook(slope: Double, used: Double = 50, hitAt: Date? = nil, earliest: Date? = nil,
                        latest: Date? = nil, claimable: Bool = false, confirmed: Bool = false)
        -> UsageIntelligenceEngine.BurnOutlook {
        UsageIntelligenceEngine.BurnOutlook(
            slopePercentPerHour: slope, projectedFullAt: hitAt,
            etaSeconds: hitAt.map { $0.timeIntervalSince(now) },
            projectedFullAtEarliest: earliest, projectedFullAtLatest: latest,
            usedPct: used, resetsAt: now.addingTimeInterval(2 * 3600), anchorShift: 0, method: "test",
            cyclesObserved: 10, cyclesPeakOver90: 1, cyclesHit100: 0,
            hitClaimable: claimable, claimConfirmed: confirmed)
    }

    static func end(_ value: Double, band: ClosedRange<Double>? = nil) -> Estimate {
        Estimate(value: value, interval80: band, method: "test", confidence: .medium, support: 10)
    }

    static func chip(_ o: UsageIntelligenceEngine.BurnOutlook, end: Estimate?, used: Double = 50,
                     duration: TimeInterval = fiveHours) -> ForecastChip? {
        ForecastChip.make(outlook: o, endEstimate: end, duration: duration, usedPct: used, now: now)
    }

    // MARK: - The forecast chip: colour is where the window ends up

    @Test func theAtResetChipIsColouredByWhereTheWindowEndsUp() throws {
        // 10%/hr on a 5-hour window is half the pace that lands at 100%.
        let moving = Self.outlook(slope: 10)
        let green = try #require(Self.chip(moving, end: Self.end(39.4)))
        #expect(green.text == "≈39% at reset")
        #expect(green.tint == .band(.green))
        let yellow = try #require(Self.chip(moving, end: Self.end(65)))
        #expect(yellow.text == "≈65% at reset")
        #expect(yellow.tint == .band(.yellow))
        let orange = try #require(Self.chip(moving, end: Self.end(84.2)))
        #expect(orange.text == "≈84% at reset")
        #expect(orange.tint == .band(.orange))
        // A slow climb to a high end is still that end's colour: the speed
        // no longer tints it.
        let slow = try #require(Self.chip(Self.outlook(slope: 2), end: Self.end(84.2)))
        #expect(slow.tint == .band(.orange))
        // The calibrated range stays in the hover.
        let ranged = try #require(Self.chip(moving, end: Self.end(65, band: 58...72)))
        #expect(ranged.help.contains("Calibrated range at reset: 58–72%."))
    }

    /// "≈100% at reset" said the limit as a number that rounds to it.
    @Test func endingAtTheLimitWithoutCrossingSaysLimitAroundReset() throws {
        let moving = Self.outlook(slope: 10)
        let limit = try #require(Self.chip(moving, end: Self.end(99.8)))
        #expect(limit.text == "limit around reset")
        #expect(limit.tint == .band(.red))
        #expect(try #require(Self.chip(moving, end: Self.end(99.5))).text == "limit around reset")
        let under = try #require(Self.chip(moving, end: Self.end(99.4)))
        #expect(under.text == "≈99% at reset")
        #expect(under.tint == .band(.red))
        // An idle window whose rhythm still climbs to the limit says the same.
        let idle = try #require(Self.chip(Self.outlook(slope: 0), end: Self.end(99.7), used: 80))
        #expect(idle.text == "limit around reset")
        #expect(idle.tint == .band(.red))
    }

    @Test func aCrossingIsRedWhetherClaimedOrNot() throws {
        let hit = Self.now.addingTimeInterval(9 * 3600)
        let claimed = try #require(Self.chip(
            Self.outlook(slope: 30, used: 70, hitAt: hit, claimable: true, confirmed: true),
            end: Self.end(100), used: 70, duration: 7 * 86400))
        #expect(claimed.text == "limit in 9 hr")
        #expect(claimed.tint == .band(.red))
        // Withheld: the same outcome, so the same colour; "may" carries the doubt
        // and the hover says why.
        let unconfirmed = try #require(Self.chip(
            Self.outlook(slope: 30, used: 70, hitAt: hit, claimable: true, confirmed: false),
            end: Self.end(100), used: 70, duration: 7 * 86400))
        #expect(unconfirmed.text == "may hit limit in 9 hr")
        #expect(unconfirmed.tint == .band(.red))
        #expect(unconfirmed.help.contains("Called once it holds on the next update."))
        let early = try #require(Self.chip(
            Self.outlook(slope: 30, used: 30, hitAt: hit), end: Self.end(100), used: 30, duration: 7 * 86400))
        #expect(early.text == "may hit limit in 9 hr")
        #expect(early.tint == .band(.red))
    }

    @Test func idleHoldsGreyAndTheLimitIsTheLimit() throws {
        let holds = try #require(Self.chip(Self.outlook(slope: 0), end: Self.end(50), used: 50))
        #expect(holds.text == "holds until reset")
        #expect(holds.tint == .neutral)
        // Nothing to hold at 0%.
        #expect(Self.chip(Self.outlook(slope: 0), end: nil, used: 0) == nil)
        let at = try #require(Self.chip(Self.outlook(slope: 5), end: nil, used: 100))
        #expect(at.text == "at the limit")
        #expect(at.tint == .band(.red))
        // An estimate of 99.6% has not reached the limit.
        #expect(Self.chip(Self.outlook(slope: 10), end: Self.end(99.9), used: 99.6)?.text
                == "limit around reset")
        // Moving with no forecast of where it ends: the burn-rate chip says
        // the speed, and this one has nothing to add.
        #expect(Self.chip(Self.outlook(slope: 10), end: nil) == nil)
    }

    @Test func theCrossingCountsDownAgainstTheGivenClock() {
        let hit = Self.now.addingTimeInterval(47 * 60)
        #expect(ForecastChip.relativeCrossing(hit, now: Self.now) == "in 45 min")
        #expect(ForecastChip.relativeCrossing(hit, now: Self.now.addingTimeInterval(20 * 60)) == "in 25 min")
        #expect(ForecastChip.relativeCrossing(Self.now.addingTimeInterval(9 * 3600), now: Self.now) == "in 9 hr")
        #expect(ForecastChip.relativeCrossing(Self.now.addingTimeInterval(3 * 86400), now: Self.now) == "in 3 days")
        #expect(ForecastChip.relativeCrossing(nil, now: Self.now) == nil)
    }

    // MARK: - The burn-rate chip

    @Test func theBurnRateChipIsTheReportsNowRate() {
        let resets = Self.now.addingTimeInterval(3600)
        let readings: [RecentBurn.Reading] = [
            .init(at: Self.now.addingTimeInterval(-1800), percent: 40, resetsAt: resets),
            .init(at: Self.now.addingTimeInterval(-900), percent: 44, resetsAt: resets),
            .init(at: Self.now, percent: 48, resetsAt: resets),
        ]
        let rate = RecentBurn.percentPerHour(readings: readings, now: Self.now, duration: Self.fiveHours)
        #expect(rate == 16)
        #expect(RecentBurn.chipText(rate) == "+16%/hr")
        #expect(RecentBurn.chipText(0.2) == "+0.2%/hr")
        #expect(RecentBurn.chipText(9.97) == "+10%/hr")
        // Not moving: no burn chip (round 4). A reading that went down is
        // not moving up either. Too few readings for a rate: no chip.
        #expect(RecentBurn.chipText(0) == nil)
        #expect(RecentBurn.chipText(0.04) == nil)
        #expect(RecentBurn.chipText(-2) == nil)
        #expect(RecentBurn.chipText(nil) == nil)
    }

    /// The owner's round-4 rules for the card's chip row.
    @Test func theChipRowDropsIdleAndSaysNothingAtZero() {
        // Moving: the burn rate and the forecast.
        #expect(RecentBurn.chipRow(percentPerHour: 16, shownPercent: 48)
                == .init(burn: "+16%/hr", showsForecast: true))
        // Idle above 0%: "holds until reset" alone, no grey "idle" beside it.
        #expect(RecentBurn.chipRow(percentPerHour: 0, shownPercent: 62)
                == .init(burn: nil, showsForecast: true))
        #expect(RecentBurn.chipRow(percentPerHour: 0.04, shownPercent: 0.3)
                == .init(burn: nil, showsForecast: true))
        // Idle at 0%, as written ("0%", "0.0%"): no chip at all.
        #expect(RecentBurn.chipRow(percentPerHour: 0, shownPercent: 0)
                == .init(burn: nil, showsForecast: false))
        #expect(RecentBurn.chipRow(percentPerHour: -1, shownPercent: 0.04)
                == .init(burn: nil, showsForecast: false))
        // No rate yet: nothing claims it is idle, so the forecast stays.
        #expect(RecentBurn.chipRow(percentPerHour: nil, shownPercent: 0)
                == .init(burn: nil, showsForecast: true))
        // And at 0% the forecast chip itself has nothing to hold.
        #expect(Self.chip(Self.outlook(slope: 0), end: nil, used: 0) == nil)
    }

    // MARK: - The estimate and the reading

    /// Design B: the estimate is the number, with its decimal; the caption
    /// always says what Anthropic last read.
    @Test func theCaptionSaysWhatAnthropicLastRead() throws {
        let reading = MeterReading(at: Self.now.addingTimeInterval(-180), percent: 50, resetsAt: nil)
        let live = LiveMeterValue(percent: 51, reading: reading, addedPoints: 1, exactAdded: 1.3, spendUSD: 6,
                                  rateSource: .perModel, restarted: false, asOf: Self.now, exactPercent: 51.3)
        let estimate = LiveMeterReadout(reading: reading, live: live, now: Self.now)
        #expect(estimate.text == "51.3%")
        #expect(estimate.readPercentText == "read 50%")
        #expect(estimate.caption(age: "3m ago") == "estimate · Anthropic read 50% 3m ago")
        #expect(estimate.help(age: "3m ago") == "read 50% 3m ago · estimate 51.3%")
        let bare = LiveMeterReadout(reading: reading, live: nil, now: Self.now)
        #expect(bare.text == "50%")
        #expect(bare.caption(age: "3m ago") == "read 3m ago")
        // Through the shared formatter, the caption's age and the hover's agree.
        let age = PacerReadAge.string(reading.at, now: Self.now, locale: Locale(identifier: "en_US"))
        #expect(age == "3m ago")
    }

    /// An estimate that crosses into a new whole number: every digit of it is
    /// the estimate's, and it is written as one.
    @Test func anEstimateCrossingAWholeNumberIsWrittenAsTheEstimate() throws {
        let reading = MeterReading(at: Self.now.addingTimeInterval(-120), percent: 50, resetsAt: nil)
        let crossed = LiveMeterValue(percent: 51, reading: reading, addedPoints: 1, exactAdded: 1.04,
                                     spendUSD: 5, rateSource: .perModel, restarted: false, asOf: Self.now,
                                     exactPercent: 51.04)
        let r = LiveMeterReadout(reading: reading, live: crossed, now: Self.now)
        #expect(r.isEstimate)
        #expect(r.text == "51.0%")
        #expect(r.wholePercent == 51)
        #expect(r.readPercentText == "read 50%")
        // A hair under the next whole number is not yet it.
        let under = LiveMeterValue(percent: 50, reading: reading, addedPoints: 0, exactAdded: 0.97,
                                   spendUSD: 5, rateSource: .perModel, restarted: false, asOf: Self.now,
                                   exactPercent: 50.97)
        let u = LiveMeterReadout(reading: reading, live: under, now: Self.now)
        #expect(u.text == "50.9%")
        #expect(u.wholePercent == 50)
        // The drawn number is the formatter's, every digit alike.
        #expect(PacerMeterFormat.number(51.04, isEstimate: true) == "51.0")
        #expect(PacerMeterFormat.number(51, isEstimate: false) == "51")
    }

    // MARK: - The shared schedule

    /// Every age label and its hover are drawn on the wall clock's whole
    /// minutes: first the moment the view appears, then each minute on the
    /// minute, so every age on screen changes at the same instant.
    @Test func theScheduleFiresOnTheWallClocksWholeMinutes() {
        let start = Date(timeIntervalSince1970: 1_790_000_037.4)
        var entries = PacerReadAge.Schedule().entries(from: start, mode: .normal)
        var dates: [Date] = []
        for _ in 0..<5 { if let d = entries.next() { dates.append(d) } }
        #expect(dates.first == start)
        #expect(dates.dropFirst().map(\.timeIntervalSince1970) == [1_790_000_040, 1_790_000_100,
                                                                    1_790_000_160, 1_790_000_220])
        // On a minute exactly, the next change is the next minute.
        #expect(PacerReadAge.nextChange(after: Date(timeIntervalSince1970: 1_790_000_040))
                == Date(timeIntervalSince1970: 1_790_000_100))
    }

    /// Minutes, rounded, no seconds: the words a label shows at one of the
    /// schedule's instants.
    @Test func theAgeIsShortRoundedMinutes() {
        let en = Locale(identifier: "en_US")
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func age(_ seconds: TimeInterval) -> String {
            PacerReadAge.string(at, now: at.addingTimeInterval(seconds), locale: en)
        }
        #expect(age(0) == "just now")
        #expect(age(29) == "just now")
        // A reading stamped a moment after this Mac's clock is fresh.
        #expect(age(-20) == "just now")
        #expect(age(31) == "1m ago")
        #expect(age(150) == "3m ago")
        #expect(age(59 * 60) == "59m ago")
        #expect(age(2 * 3600 + 60) == "2h ago")
        #expect(age(3 * 86400) == "3d ago")
    }

    /// Two labels about readings a few seconds apart change on the same
    /// instant: the schedule is the clock's, not the reading's.
    @Test func labelsAboutDifferentReadingsChangeTogether() {
        let en = Locale(identifier: "en_US")
        let a = Date(timeIntervalSince1970: 1_790_000_011)
        let b = Date(timeIntervalSince1970: 1_790_000_024)
        var entries = PacerReadAge.Schedule().entries(from: Date(timeIntervalSince1970: 1_790_000_030), mode: .normal)
        var pairs: [(String, String)] = []
        for _ in 0..<6 {
            guard let d = entries.next() else { break }
            pairs.append((PacerReadAge.string(a, now: d, locale: en), PacerReadAge.string(b, now: d, locale: en)))
        }
        #expect(pairs.map(\.0) == pairs.map(\.1))
        #expect(pairs.map(\.0) == ["just now", "just now", "1m ago", "2m ago", "3m ago", "4m ago"])
    }

    // MARK: - Widgets read the widget clock

    /// The README screenshots pin the widget extension's clock (`PacerClock`,
    /// #154): a widget that reads `Date()` draws whenever it was run, and a
    /// PR with no UI change gets a screenshot commit.
    @Test func widgetsReadPacerClockNotDate() throws {
        let widgets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Widgets")
        let files = try FileManager.default.contentsOfDirectory(at: widgets, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                #expect(!code.contains("Date()"), "\(file.lastPathComponent):\(n + 1) reads Date()")
            }
        }
    }
}
