import Foundation
import Testing
@testable import PacerCore
@testable import PacerUI

/// The summary card's strip (rounds 6 and 7): how many of a period's days or
/// hours were active, how a long period buckets into weeks, the cost behind
/// its heights, its caption and tooltips, the range it spans, and the labels
/// around it. Expressions are short with typed intermediates — long
/// mixed-literal ones time out Xcode 16's type checker on the macOS 15
/// runner.
@MainActor
struct PeriodActivityTests {

    // MARK: Active days of the period

    @Test("a period counts every day from its first through its last, and only its active ones")
    func activeDaysOfPeriod() {
        let active: Set<String> = ["2026-09-30", "2026-10-01", "2026-10-03", "2026-10-07", "2026-10-09"]
        let a = PeriodActivity.days(active: active, from: "2026-10-01", through: "2026-10-07")
        // Oct 1–7 inclusive; Sep 30 and Oct 9 fall outside it.
        #expect(a.slots == 7)
        #expect(a.active == 3)
        #expect(a.cells.count == 7)
        #expect(a.start == "2026-10-01")
        #expect(a.end == "2026-10-07")
        #expect(a.firstActive == "2026-10-01")
        #expect(a.lastActive == "2026-10-07")
        let flags: [Int] = a.cells.map(\.active)
        #expect(flags == [1, 0, 1, 0, 0, 0, 1])
    }

    // MARK: Ranges of exactly N days (#342)

    /// The dates a range's cut reads: `formatDate(since)` through today, in
    /// the calendar's time zone, as every range query compares them.
    private static func rangeDates(_ range: TimeRange, now: Date, calendar: Calendar) -> [String] {
        guard let since = range.since(now: now, calendar: calendar) else { return [] }
        let first: String = TokenSample.formatDate(since, timeZone: calendar.timeZone)
        let last: String = TokenSample.formatDate(now, timeZone: calendar.timeZone)
        return PeriodActivity.dayKeys(from: first, through: last)
    }

    @Test("7d, 30d, 90d and 1y each span exactly N dates, today the last, at any hour, across a clock change")
    func rangesSpanExactlyNDates() throws {
        let zones: [String] = ["America/New_York", "Europe/London", "Asia/Kolkata", "Pacific/Auckland", "UTC"]
        for zone in zones {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = try #require(TimeZone(identifier: zone))
            // Just after midnight, midday and just before midnight; on a
            // spring-forward and a fall-back day in North America and in
            // Europe, and an ordinary one.
            let days: [DateComponents] = [
                DateComponents(year: 2026, month: 10, day: 22),
                DateComponents(year: 2026, month: 11, day: 1),
                DateComponents(year: 2026, month: 10, day: 25),
                DateComponents(year: 2026, month: 3, day: 8),
                DateComponents(year: 2026, month: 3, day: 29),
            ]
            for day in days {
                for (hour, minute) in [(0, 0), (0, 30), (12, 0), (23, 59)] {
                    var parts: DateComponents = day
                    parts.hour = hour
                    parts.minute = minute
                    let now: Date = try #require(cal.date(from: parts))
                    let today: String = TokenSample.formatDate(now, timeZone: cal.timeZone)
                    for range in TimeRange.allCases {
                        guard let n = range.days else {
                            #expect(range.since(now: now, calendar: cal) == nil)
                            continue
                        }
                        let dates: [String] = Self.rangeDates(range, now: now, calendar: cal)
                        #expect(dates.count == n, "\(range.rawValue) at \(today) \(hour):\(minute) \(zone)")
                        #expect(dates.last == today)
                        // The cut is a day's start, so a cut on the instant
                        // (sessions' `lastSeenAt >= since`) covers the same days.
                        let since: Date = try #require(range.since(now: now, calendar: cal))
                        #expect(cal.startOfDay(for: since) == since)
                    }
                }
            }
        }
    }

    @Test("the strip over a range's cut has exactly N days")
    func stripOverARangeHasNDays() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now: Date = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 15)))
        let expected: [(TimeRange, Int)] = [(.sevenDays, 7), (.thirtyDays, 30), (.ninetyDays, 90), (.oneYear, 365)]
        for (range, n) in expected {
            let dates: [String] = Self.rangeDates(range, now: now, calendar: cal)
            let first: String = try #require(dates.first)
            let last: String = try #require(dates.last)
            let a = PeriodActivity.days(active: [last], from: first, through: last)
            #expect(a.slots == n)
        }
    }

    @Test("days step across a month end, a year end and a clock change once each")
    func dayKeysStepCalendarDays() {
        let keys: [String] = PeriodActivity.dayKeys(from: "2025-12-30", through: "2026-01-02")
        #expect(keys == ["2025-12-30", "2025-12-31", "2026-01-01", "2026-01-02"])
        // Clocks change in early November in North America, late October in Europe.
        let autumn: [String] = PeriodActivity.dayKeys(from: "2026-10-24", through: "2026-11-03")
        #expect(autumn.count == 11)
        #expect(Set(autumn).count == 11)
        #expect(PeriodActivity.dayKeys(from: "2026-10-02", through: "2026-10-01").isEmpty)
        #expect(PeriodActivity.dayKeys(from: "nope", through: "2026-10-01").isEmpty)
    }

    @Test("a period with no days is empty, not a crash")
    func emptyPeriod() {
        let a = PeriodActivity.days(active: ["2026-10-01"], from: "2026-10-05", through: "2026-10-01")
        #expect(a == .empty)
        #expect(a.slots == 0)
    }

    // MARK: Bucketing

    @Test("a cell a day up to 92 days; whole weeks past that, ending on the last day")
    func bucketSizes() {
        #expect(PeriodActivity.dayBucket(slots: 2, maxCells: 92) == 1)
        #expect(PeriodActivity.dayBucket(slots: 91, maxCells: 92) == 1)
        #expect(PeriodActivity.dayBucket(slots: 92, maxCells: 92) == 1)
        #expect(PeriodActivity.dayBucket(slots: 93, maxCells: 92) == 7)
        #expect(PeriodActivity.dayBucket(slots: 366, maxCells: 92) == 7)
        #expect(PeriodActivity.dayBucket(slots: 644, maxCells: 92) == 7)
        #expect(PeriodActivity.dayBucket(slots: 645, maxCells: 92) == 14)
        #expect(PeriodActivity.dayBucket(slots: 781, maxCells: 92) == 14)
    }

    @Test("a year buckets into weeks: the newest whole, the oldest short, costs and means per cell")
    func yearBucketsIntoWeeks() {
        let keys: [String] = PeriodActivity.dayKeys(from: "2025-10-23", through: "2026-10-22")
        #expect(keys.count == 365)
        // Every other day active, each costing $4.
        var active = Set<String>()
        var cost: [String: Double] = [:]
        for (i, k) in keys.enumerated() where i % 2 == 0 {
            active.insert(k)
            cost[k] = 4
        }
        let a = PeriodActivity.days(active: active, cost: cost, from: keys[0], through: keys[keys.count - 1])
        #expect(a.slotsPerCell == 7)
        // 365 = 52 weeks + 1 day: the oldest cell is that one day.
        #expect(a.cells.count == 53)
        let oldest: PeriodActivity.Cell = a.cells[0]
        #expect(oldest.span == 1)
        #expect(oldest.first == "2025-10-23")
        let newest: PeriodActivity.Cell = a.cells[a.cells.count - 1]
        #expect(newest.span == 7)
        #expect(newest.last == "2026-10-22")
        #expect(newest.first == "2026-10-16")
        let spans: Int = a.cells.reduce(0) { $0 + $1.span }
        #expect(spans == 365)
        let actives: Int = a.cells.reduce(0) { $0 + $1.active }
        #expect(actives == a.active)
        #expect(a.active == 183)
        // A week of alternate days: 3 or 4 of 7 active, $4 each; its height
        // is its cost a day, $4 × that share.
        let share: Double = newest.activeShare
        let expectedTotal: Double = 4 * Double(newest.active)
        let expectedPerDay: Double = 4 * share
        #expect(abs(newest.cost - expectedTotal) < 1e-9)
        #expect(abs(newest.costPerSlot - expectedPerDay) < 1e-9)
        #expect(newest.active == 3 || newest.active == 4)
        let totals: Double = a.cells.reduce(0) { $0 + $1.cost }
        #expect(abs(totals - 4 * 183) < 1e-9)
    }

    @Test("a cell's height is its cost per day over its days, so a short oldest week compares")
    func heightsAreCostPerSlot() {
        let cost: [String: Double] = ["2026-10-01": 6, "2026-10-02": 2]
        let a = PeriodActivity.days(active: Set(cost.keys), cost: cost,
                                    from: "2026-10-01", through: "2026-10-02", maxCells: 1)
        #expect(a.slotsPerCell == 7)
        #expect(a.cells.count == 1)
        #expect(a.cells[0].span == 2)
        #expect(a.cells[0].cost == 8)
        #expect(a.cells[0].costPerSlot == 4)
        #expect(a.cells[0].activeShare == 1)
    }

    // MARK: Hours

    @Test("a day is 24 hours, one cell each, with its first and last active hour and each one's cost")
    func hours() {
        let a = PeriodActivity.hours(active: [9, 14, 23], cost: [9: 1.5, 14: 3, 23: 0.5])
        #expect(a.unit == .hour)
        #expect(a.slots == 24)
        #expect(a.cells.count == 24)
        #expect(a.active == 3)
        #expect(a.firstActive == "9")
        #expect(a.lastActive == "23")
        #expect(a.cells[14].cost == 3)
        #expect(a.cells[14].costPerSlot == 3)
        #expect(a.cells[13].active == 0)
        #expect(pacerActivityCaption(a) == "cost per hour")
    }

    // MARK: The strip's metric and bucketing

    @Test("7 days: a column a day, each one's height its cost against the dearest day, captioned cost per day")
    func weekStripIsCostPerDay() {
        let cost: [String: Double] = ["2026-10-16": 30, "2026-10-17": 120, "2026-10-19": 60]
        let active: Set<String> = Set(cost.keys).union(["2026-10-21"])
        let a = PeriodActivity.days(active: active, cost: cost, from: "2026-10-16", through: "2026-10-22")
        #expect(a.slots == 7)
        #expect(a.cells.count == 7)
        #expect(a.slotsPerCell == 1)
        #expect(pacerActivityCaption(a) == "cost per day")
        let fills: [CGFloat] = PacerActivityStripLayout.fills(a)
        #expect(fills[0] == 0.25)
        #expect(fills[1] == 1)
        #expect(fills[2] == 0)
        #expect(fills[3] == 0.5)
        // Active at $0 (every model unpriced): a stub, not a gap.
        #expect(fills[5] > 0 && fills[5] < 0.01)
        #expect(fills[6] == 0)
        let help: [String] = pacerActivityCellHelp(a, currentYear: 2026)
        #expect(help[1] == "\(pacerFactDayExact("2026-10-17")) · \(pacerCostExact(120))")
        #expect(help[2] == "\(pacerFactDayExact("2026-10-18")) · no use")
    }

    @Test("1 year: 365 days in weeks, each column its cost a day, captioned by week")
    func yearStripIsCostPerDayByWeek() {
        let keys: [String] = PeriodActivity.dayKeys(from: "2025-10-23", through: "2026-10-22")
        var cost: [String: Double] = [:]
        for k in keys.suffix(7) { cost[k] = 70 }
        for k in keys.suffix(14).prefix(7) { cost[k] = 14 }
        let a = PeriodActivity.days(active: Set(cost.keys), cost: cost, from: keys[0], through: keys[keys.count - 1])
        #expect(a.slots == 365)
        #expect(a.slotsPerCell == 7)
        #expect(a.cells.count == 53)
        #expect(pacerActivityCaption(a) == "cost per day, by week")
        let fills: [CGFloat] = PacerActivityStripLayout.fills(a)
        #expect(fills[52] == 1)
        #expect(abs(fills[51] - 0.2) < 1e-9)
        #expect(fills[50] == 0)
        let help: [String] = pacerActivityCellHelp(a, currentYear: 2026)
        let from: String = pacerFactDay("2026-10-16", currentYear: 2026)
        let to: String = pacerFactDay("2026-10-22", currentYear: 2026)
        let perDay: String = pacerCostExact(70)
        let total: String = pacerCostExact(490)
        #expect(help[52] == "\(from) – \(to) · \(perDay) a day, \(total) in all · 7 of 7 days active")
        // Two years buckets in two-week cells, and says so.
        let long = PeriodActivity.days(active: [], from: "2024-09-02", through: "2026-10-22")
        #expect(long.slotsPerCell == 14)
        #expect(pacerActivityCaption(long) == "cost per day, by 2 weeks")
    }

    // MARK: Layout

    @Test("cells always fill the strip's width; the gap follows the cells' size")
    func stripLayoutFillsTheWidth() {
        let widths: [CGFloat] = [520, 612, 744]
        for width in widths {
            for count in [1, 2, 7, 24, 30, 53, 90] {
                let layout = PacerActivityStripLayout(count: count, width: width)
                #expect(abs(layout.used - width) < 0.01, "\(count) cells at \(width)")
                let lastEnd: CGFloat = layout.x(of: count - 1) + layout.cell
                #expect(abs(lastEnd - width) < 0.01)
            }
        }
        // Round 6 drew a week as eight 24 pt columns in the left third.
        let week = PacerActivityStripLayout(count: 7, width: 680)
        #expect(week.gap == 4)
        #expect(week.cell > 90)
        let hours = PacerActivityStripLayout(count: 24, width: 612)
        #expect(hours.gap == 3)
        let quarter = PacerActivityStripLayout(count: 90, width: 520)
        #expect(quarter.gap == 1)
        let x: CGFloat = quarter.x(of: 2)
        let expectedX: CGFloat = 2 * (quarter.cell + 1)
        #expect(x == expectedX)
    }

    @Test("heights: cost against the dearest day; an active day at $0 is a stub; idle is 0")
    func fills() {
        let cost: [String: Double] = ["2026-10-01": 2, "2026-10-02": 8]
        let active: Set<String> = ["2026-10-01", "2026-10-02", "2026-10-03"]
        let a = PeriodActivity.days(active: active, cost: cost, from: "2026-10-01", through: "2026-10-04")
        let fills: [CGFloat] = PacerActivityStripLayout.fills(a)
        #expect(fills[0] == 0.25)
        #expect(fills[1] == 1)
        #expect(fills[2] > 0 && fills[2] < 0.01)
        #expect(fills[3] == 0)
    }

    // MARK: Labels

    @Test("the axis: the first day and Today; one label under a short strip; a past end by date")
    func dayAxis() {
        let month = PeriodActivity.days(active: [], from: "2026-09-22", through: "2026-10-22")
        let labels: [PacerActivityStrip.AxisLabel] = pacerDayAxis(month, today: "2026-10-22", currentYear: 2026)
        #expect(labels.map(\.cell) == [0, 30])
        #expect(labels.last?.text == "Today")
        let first: String = pacerFactDay("2026-09-22", currentYear: 2026)
        #expect(labels.first?.text == first)
        let two = PeriodActivity.days(active: [], from: "2026-10-21", through: "2026-10-22")
        let short: [PacerActivityStrip.AxisLabel] = pacerDayAxis(two, today: "2026-10-22", currentYear: 2026)
        #expect(short.count == 1)
        #expect(short.first?.text == "\(pacerFactDay("2026-10-21", currentYear: 2026)) – Today")
        let one = PeriodActivity.days(active: [], from: "2026-10-22", through: "2026-10-22")
        #expect(pacerDayAxis(one, today: "2026-10-22", currentYear: 2026).map(\.text) == ["Today"])
        let past: [PacerActivityStrip.AxisLabel] = pacerDayAxis(month, today: "2026-10-23", currentYear: 2026)
        #expect(past.last?.text == pacerFactDay("2026-10-22", currentYear: 2026))
        #expect(pacerDayAxis(PeriodActivity.hours(active: []), today: "2026-10-22", currentYear: 2026).isEmpty)
    }

    @Test("the span leaves out an end the axis already prints")
    func span() {
        let format: (String) -> String = { $0 }
        let both = PeriodActivity.days(active: ["2026-10-02", "2026-10-05"], from: "2026-10-01", through: "2026-10-07")
        #expect(pacerActivitySpan(both, format: format) == "2026-10-02 – 2026-10-05")
        let fromStart = PeriodActivity.days(active: ["2026-10-01", "2026-10-05"], from: "2026-10-01", through: "2026-10-07")
        #expect(pacerActivitySpan(fromStart, format: format) == "last active 2026-10-05")
        let toEnd = PeriodActivity.days(active: ["2026-10-03", "2026-10-07"], from: "2026-10-01", through: "2026-10-07")
        #expect(pacerActivitySpan(toEnd, format: format) == "first active 2026-10-03")
        let whole = PeriodActivity.days(active: ["2026-10-01", "2026-10-07"], from: "2026-10-01", through: "2026-10-07")
        #expect(pacerActivitySpan(whole, format: format) == nil)
        let none = PeriodActivity.days(active: [], from: "2026-10-01", through: "2026-10-07")
        #expect(pacerActivitySpan(none, format: format) == nil)
        // A day's hours: both ends, always.
        let day = PeriodActivity.hours(active: [0, 9, 23])
        #expect(pacerActivitySpan(day, format: format) == "0 – 23")
    }

    @Test("tooltips: the day and its exact cost, no use, an hour's cost, a week's cost a day and active days")
    func cellHelp() {
        let a = PeriodActivity.days(active: ["2026-10-01"], cost: ["2026-10-01": 12.4],
                                    from: "2026-10-01", through: "2026-10-02")
        let help: [String] = pacerActivityCellHelp(a, currentYear: 2026)
        #expect(help.count == 2)
        #expect(help[0] == "\(pacerFactDayExact("2026-10-01")) · \(pacerCostExact(12.4))")
        #expect(help[1] == "\(pacerFactDayExact("2026-10-02")) · no use")
        let day = PeriodActivity.hours(active: [9], cost: [9: 4.2])
        let hours: [String] = pacerActivityCellHelp(day, currentYear: 2026)
        #expect(hours[9] == "\(pacerHourLabel(9)) – \(pacerHourLabel(10)) · \(pacerCostExact(4.2))")
        #expect(hours[10].hasSuffix(" · no use"))
        let long = PeriodActivity.days(active: ["2026-10-22"], from: "2026-01-01", through: "2026-10-22")
        let weeks: [String] = pacerActivityCellHelp(long, currentYear: 2026)
        #expect(weeks.last?.hasSuffix("1 of 7 days active") == true)
        #expect(weeks.first?.hasSuffix(" · no use") == true)
    }

    // MARK: Input and output beside the cache hit rate

    @Test("Input / Output reads as two labelled percents, rounded as the legend rounds output")
    func inOutAgreesWithLegend() throws {
        // Output 12.55% of the cost. Rounded alone it is 13; rounded with the
        // other four parts (largest remainder) it is 12, which the legend
        // prints: reads (.7) and 5m writes (.65) take the two spare points.
        let cost = CostComponents(input: 0, output: 12.55, cacheRead: 56.7, cacheWrite5m: 10.65, cacheWrite1h: 20.1)
        let legend: [CostBreakdown.Part] = CostBreakdown(cost: cost).parts
        let out: CostBreakdown.Part = try #require(legend.first { $0.component == .output })
        #expect(out.percent == 12)
        let shares = try #require(pacerInOutShares(cost))
        #expect(shares.input == 88)
        #expect(shares.output == 12)
        #expect(pacerInOutText(cost) == "Input 88% · Output 12%")
        #expect(pacerInOutText(CostComponents(input: 94, output: 6)) == "Input 94% · Output 6%")
        #expect(pacerInOutText(CostComponents(output: 5)) == "Input 0% · Output 100%")
        #expect(pacerInOutText(.zero) == nil)
        #expect(pacerInOutShares(.zero) == nil)
    }
}
