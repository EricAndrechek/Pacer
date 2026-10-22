import Foundation
import Testing
@testable import PacerCore

/// When the dashboard's nested windows would print the same numbers twice.
/// Typed intermediates throughout: long mixed-literal expressions time out
/// Xcode 16's type checker on the macOS 15 runner.
struct PeriodWindowsTests {

    private func noon(_ month: Int, _ day: Int) -> Date {
        let c = DateComponents(year: 2026, month: month, day: day, hour: 12)
        return Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    private func key(_ month: Int, _ day: Int) -> String {
        TokenSample.formatDate(noon(month, day))
    }

    @Test func boundsAreTodayAWeekAndTheFirst() {
        let w = PeriodWindows(now: noon(10, 22))
        #expect(w.today == key(10, 22))
        #expect(w.weekStart == key(10, 16))
        #expect(w.monthStart == key(10, 1))
    }

    @Test func weekAndMonthPickTheirDays() {
        let w = PeriodWindows(now: noon(10, 3))
        let active: Set<String> = [key(9, 26), key(9, 28), key(10, 1), key(10, 3)]
        let week: Set<String> = w.week(active)
        #expect(week == [key(9, 28), key(10, 1), key(10, 3)])
        let month: Set<String> = w.month(active)
        #expect(month == [key(10, 1), key(10, 3)])
    }

    @Test func onTheFirstTheMonthIsToday() {
        let w = PeriodWindows(now: noon(10, 1))
        let active: Set<String> = [key(9, 29), key(9, 30), key(10, 1)]
        let month: Set<String> = w.month(active)
        #expect(w.repeatsTodayOrWeek(month, in: active))
    }

    @Test func onTheSeventhTheMonthCanBeTheWeek() {
        let w = PeriodWindows(now: noon(10, 7))
        let days: [Int] = [2, 4, 7]
        let active: Set<String> = Set(days.map { key(10, $0) })
        let month: Set<String> = w.month(active)
        #expect(w.repeatsTodayOrWeek(month, in: active))
    }

    @Test func aMonthWithEarlierDaysRepeatsNothing() {
        let w = PeriodWindows(now: noon(10, 22))
        let active: Set<String> = [key(10, 2), key(10, 20), key(10, 22)]
        let month: Set<String> = w.month(active)
        #expect(!w.repeatsTodayOrWeek(month, in: active))
    }

    @Test func midWeekAMonthStartRepeatsNothingWhileLastMonthIsInTheWeek() {
        let w = PeriodWindows(now: noon(10, 3))
        let active: Set<String> = [key(9, 30), key(10, 2), key(10, 3)]
        let month: Set<String> = w.month(active)
        #expect(!w.repeatsTodayOrWeek(month, in: active))
    }

    @Test func thirtyDaysThatAreAllThisWeekRepeatIt() {
        let w = PeriodWindows(now: noon(10, 3))
        // A new install on the 29th: every active day is in the last seven.
        let active: Set<String> = [key(9, 29), key(10, 1), key(10, 3)]
        #expect(w.repeatsTodayOrWeek(active, in: active))
    }

    @Test func anEmptyWindowRepeatsNothing() {
        let w = PeriodWindows(now: noon(10, 3))
        let none: Set<String> = []
        #expect(!w.repeatsTodayOrWeek(none, in: none))
    }
}
