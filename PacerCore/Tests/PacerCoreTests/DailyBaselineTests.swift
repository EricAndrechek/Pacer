import Foundation
import Testing
@testable import PacerCore

/// The "yesterday was your third-highest day in 22 weeks" statement, which has
/// to be answerable per account — the engine fits one series and cannot.
@Suite("Ranking a day against its own history")
struct DailyBaselineTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ offset: Int, from now: Date) -> String {
        TokenSample.formatDate(
            calendar.date(byAdding: .day, value: offset, to: now)!, timeZone: calendar.timeZone)
    }

    private func rows(_ costs: [Int: Double], now: Date) -> [DailyRow] {
        costs.map { offset, cost in
            DailyRow(date: day(offset, from: now), model: "m",
                     inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                     cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: cost)
        }
    }

    @Test func ranksYesterdayAgainstEveryPriorDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 10 days back; yesterday is the third-largest.
        var costs: [Int: Double] = [:]
        for i in 1...10 { costs[-i] = Double(i) }
        costs[-1] = 9          // yesterday, beaten by 10 and by... only day -10.
        let r = DailyBaseline.yesterdayRank(rows: rows(costs, now: now), now: now, calendar: calendar)
        #expect(r?.of == 10)
        #expect(r?.cost == 9)
        #expect(r?.rankFromTop == 2)   // only the $10 day is higher
    }

    /// A day with no usage is a real day you didn't spend on. Dropping it would
    /// turn "third-highest in 22 weeks" into "third of the days I happened to
    /// work", which is a different and much weaker claim.
    @Test func quietDaysCountInTheDenominator() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Usage on only three days, twenty days apart from the first.
        let r = DailyBaseline.yesterdayRank(
            rows: rows([-20: 5, -10: 1, -1: 3], now: now), now: now, calendar: calendar)
        #expect(r?.of == 20)           // every calendar day, not the three with rows
        #expect(r?.rankFromTop == 2)   // only the $5 day is higher
    }

    @Test func todayIsNeverRanked() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let r = DailyBaseline.yesterdayRank(
            rows: rows([0: 999, -1: 4, -2: 1, -3: 1, -4: 1, -5: 1, -6: 1, -7: 1], now: now),
            now: now, calendar: calendar)
        #expect(r?.cost == 4)          // yesterday, not today's 999
        #expect(r?.of == 7)
    }

    /// "Highest in one week" is noise, not a notice.
    @Test func staysQuietUnderAWeekOfHistory() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DailyBaseline.yesterdayRank(
            rows: rows([-1: 5, -2: 1, -3: 1], now: now), now: now, calendar: calendar) == nil)
    }

    /// Several rollup rows share a date — one per model.
    @Test func rowsForOneDayAreSummed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var many = rows([-2: 1, -3: 1, -4: 1, -5: 1, -6: 1, -7: 1, -8: 1], now: now)
        many += rows([-1: 2], now: now)
        many += rows([-1: 3], now: now)
        let r = DailyBaseline.yesterdayRank(rows: many, now: now, calendar: calendar)
        #expect(r?.cost == 5)
        #expect(r?.rankFromTop == 1)
    }
}
