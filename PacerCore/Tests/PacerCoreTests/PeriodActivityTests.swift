import Foundation
import Testing
@testable import PacerCore
@testable import PacerUI

/// The summary card's strip (round 6): how many of a period's days or hours
/// were active, how a long period buckets into weeks, the sessions a day
/// behind its heights, and the labels around it. Expressions are short with
/// typed intermediates — long mixed-literal ones time out Xcode 16's type
/// checker on the macOS 15 runner.
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
        #expect(a.hasTrend == false)
    }

    @Test("History's 30-day range is the 31 days its query reads, today included")
    func thirtyDayRangeIncludesItsCutoffDay() {
        let a = PeriodActivity.days(active: ["2026-10-22"], from: "2026-09-22", through: "2026-10-22")
        #expect(a.slots == 31)
        #expect(a.active == 1)
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

    @Test("a year buckets into weeks: the newest whole, the oldest short, shares and means per cell")
    func yearBucketsIntoWeeks() {
        let keys: [String] = PeriodActivity.dayKeys(from: "2025-10-23", through: "2026-10-22")
        #expect(keys.count == 365)
        // Every other day active, each with 4 sessions.
        var active = Set<String>()
        var trend: [String: Double] = [:]
        for (i, k) in keys.enumerated() where i % 2 == 0 {
            active.insert(k)
            trend[k] = 4
        }
        let a = PeriodActivity.days(active: active, trend: trend, from: keys[0], through: keys[keys.count - 1])
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
        // A week of alternate days: 3 or 4 of 7 active, a mean of 4 × that share.
        let share: Double = newest.activeShare
        let expectedValue: Double = 4 * share
        #expect(abs(newest.value - expectedValue) < 1e-9)
        #expect(newest.active == 3 || newest.active == 4)
    }

    @Test("a cell's value is its sessions' mean over its days, so a short oldest week compares")
    func valuesAreMeansPerSlot() {
        let trend: [String: Double] = ["2026-10-01": 6, "2026-10-02": 2]
        let a = PeriodActivity.days(active: Set(trend.keys), trend: trend,
                                    from: "2026-10-01", through: "2026-10-02", maxCells: 1)
        #expect(a.slotsPerCell == 7)
        #expect(a.cells.count == 1)
        #expect(a.cells[0].span == 2)
        #expect(a.cells[0].value == 4)
        #expect(a.cells[0].activeShare == 1)
    }

    // MARK: Hours

    @Test("a day is 24 hours, one cell each, with its first and last active hour")
    func hours() {
        let a = PeriodActivity.hours(active: [9, 14, 23], trend: [9: 1.5, 14: 3, 23: 0.5])
        #expect(a.unit == .hour)
        #expect(a.slots == 24)
        #expect(a.cells.count == 24)
        #expect(a.active == 3)
        #expect(a.firstActive == "9")
        #expect(a.lastActive == "23")
        #expect(a.cells[14].value == 3)
        #expect(a.cells[13].active == 0)
        #expect(a.hasTrend)
    }

    // MARK: Sessions a day

    @Test("a session counts on every day from its first turn to its last, from the range's first day")
    func sessionsByDayCountsOverlap() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "UTC"))
        func at(_ day: Int, _ hour: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)) ?? Date()
        }
        let spans: [(first: Date, last: Date)] = [
            (at(1, 9), at(1, 17)),   // one day
            (at(1, 22), at(3, 1)),   // overnight, twice: Oct 1, 2 and 3
            (at(3, 10), at(3, 11)),
            (at(5, 10), at(4, 10)),  // last before first: ignored
        ]
        let all: [String: Int] = RangeActivityCounts.sessionsByDay(spans, from: nil, calendar: cal)
        #expect(all == ["2026-10-01": 2, "2026-10-02": 1, "2026-10-03": 2])
        // From the 2nd: the overnight session counts from there on.
        let start: Date = cal.startOfDay(for: at(2, 12))
        let ranged: [String: Int] = RangeActivityCounts.sessionsByDay(spans, from: start, calendar: cal)
        #expect(ranged == ["2026-10-02": 1, "2026-10-03": 2])
    }

    // MARK: Layout

    @Test("cells share the width up to their cap; gaps shrink to 1 pt when cells are narrow")
    func stripLayout() {
        let month = PacerActivityStripLayout(count: 31, width: 680, maxCell: 24)
        #expect(month.gap == 2)
        #expect(month.cell < 24)
        #expect(abs(month.used - 680) < 0.01)
        let week = PacerActivityStripLayout(count: 8, width: 680, maxCell: 24)
        #expect(week.cell == 24)
        let weekUsed: CGFloat = 8 * 24 + 7 * 2
        #expect(week.used == weekUsed)
        let quarter = PacerActivityStripLayout(count: 91, width: 520, maxCell: 24)
        #expect(quarter.gap == 1)
        #expect(quarter.used <= 520.01)
        let x: CGFloat = quarter.x(of: 2)
        let expectedX: CGFloat = 2 * (quarter.cell + 1)
        #expect(x == expectedX)
    }

    @Test("heights: sessions against the busiest day; an active day with none yet is a stub; idle is 0")
    func fills() {
        let trend: [String: Double] = ["2026-10-01": 2, "2026-10-02": 8]
        let active: Set<String> = ["2026-10-01", "2026-10-02", "2026-10-03"]
        let a = PeriodActivity.days(active: active, trend: trend, from: "2026-10-01", through: "2026-10-04")
        let fills: [CGFloat] = PacerActivityStripLayout.fills(a)
        #expect(fills[0] == 0.25)
        #expect(fills[1] == 1)
        #expect(fills[2] > 0 && fills[2] < 0.01)
        #expect(fills[3] == 0)
        // Without a trend, a cell's height is the share of its days active.
        let presence = PeriodActivity.days(active: active, from: "2026-10-01", through: "2026-10-04")
        let shares: [CGFloat] = PacerActivityStripLayout.fills(presence)
        #expect(shares == [1, 1, 1, 0])
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

    @Test("tooltips: the day and its sessions, no use, a week's active days")
    func cellHelp() {
        let a = PeriodActivity.days(active: ["2026-10-01"], trend: ["2026-10-01": 3],
                                    from: "2026-10-01", through: "2026-10-02")
        let help: [String] = pacerActivityCellHelp(a, currentYear: 2026) { _ in "3 sessions" }
        #expect(help.count == 2)
        #expect(help[0] == "\(pacerFactDayExact("2026-10-01")) · 3 sessions")
        #expect(help[1] == "\(pacerFactDayExact("2026-10-02")) · no use")
        let long = PeriodActivity.days(active: ["2026-10-22"], from: "2026-01-01", through: "2026-10-22")
        let weeks: [String] = pacerActivityCellHelp(long, currentYear: 2026)
        #expect(weeks.last?.hasSuffix("1 of 7 days active") == true)
    }

    // MARK: In / Out beside the cache hit rate

    @Test("In / Out rounds output as the legend does, so the two never disagree")
    func inOutAgreesWithLegend() throws {
        // Output 12.55% of the cost. Rounded alone it is 13; rounded with the
        // other four parts (largest remainder) it is 12, which the legend
        // prints: reads (.7) and 5m writes (.65) take the two spare points.
        let cost = CostComponents(input: 0, output: 12.55, cacheRead: 56.7, cacheWrite5m: 10.65, cacheWrite1h: 20.1)
        let legend: [CostBreakdown.Part] = CostBreakdown(cost: cost).parts
        let out: CostBreakdown.Part = try #require(legend.first { $0.component == .output })
        #expect(out.percent == 12)
        #expect(pacerInOutText(cost) == "88 / 12")
        #expect(pacerInOutText(CostComponents(input: 87, output: 13)) == "87 / 13")
        #expect(pacerInOutText(.zero) == nil)
    }
}
