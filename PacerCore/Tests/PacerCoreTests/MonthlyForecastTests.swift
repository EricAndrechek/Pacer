import Foundation
import Testing
@testable import PacerCore

@Suite("MonthlyForecast.compute")
struct MonthlyForecastTests {

    /// UTC calendar so day boundaries are deterministic across timezones.
    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ ymd: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        c.timeZone = cal.timeZone
        return cal.date(from: c)!
    }

    @Test func returnsNilWithFewerThanThreeActiveDays() {
        let projection = MonthlyForecast.compute(
            dailyCosts: [
                "2026-05-01": 10,
                "2026-05-02": 5,
            ],
            now: date("2026-05-03"),
            calendar: utc
        )
        #expect(projection == nil)
    }

    @Test func threeActiveDaysPublishesProjection() throws {
        // 3 active days, each $10. May has 31 days. Today is day 10.
        // monthSoFar = $30. avg = $10. daysRemaining = 21.
        // Projected = 30 + 10 × 21 = $240.
        let projection = try #require(MonthlyForecast.compute(
            dailyCosts: [
                "2026-05-01": 10,
                "2026-05-02": 10,
                "2026-05-03": 10,
            ],
            now: date("2026-05-10"),
            calendar: utc
        ))
        #expect(projection.daysWithData == 3)
        #expect(abs(projection.averageDailyCost - 10) < 1e-9)
        #expect(projection.daysInMonth == 31)
        #expect(projection.dayOfMonth == 10)
        #expect(abs(projection.monthSoFar - 30) < 1e-9)
        #expect(abs(projection.projectedMonthTotal - 240) < 1e-9)
    }

    @Test func vacationDaysDoNotDiluteAverage() throws {
        // 3 spending days ($20 avg) + 7 zero days. Average should be
        // $20, NOT $20×3/10 = $6.
        var costs: [String: Double] = [
            "2026-05-01": 20,
            "2026-05-02": 20,
            "2026-05-03": 20,
        ]
        for day in 4...10 {
            let key = String(format: "2026-05-%02d", day)
            costs[key] = 0
        }
        let projection = try #require(MonthlyForecast.compute(
            dailyCosts: costs,
            now: date("2026-05-15"),
            calendar: utc
        ))
        #expect(abs(projection.averageDailyCost - 20) < 1e-9)
    }

    @Test func ignoresEntriesOutsideCurrentMonth() throws {
        // April values should be ignored entirely; only the May rows
        // count toward the projection.
        let projection = try #require(MonthlyForecast.compute(
            dailyCosts: [
                "2026-04-01": 1000,
                "2026-04-15": 1000,
                "2026-04-30": 1000,
                "2026-05-01": 5,
                "2026-05-02": 5,
                "2026-05-03": 5,
            ],
            now: date("2026-05-10"),
            calendar: utc
        ))
        #expect(projection.daysWithData == 3)
        #expect(abs(projection.averageDailyCost - 5) < 1e-9)
        #expect(abs(projection.monthSoFar - 15) < 1e-9)
    }

    @Test func projectsZeroRemainingOnLastDayOfMonth() throws {
        // May 31 is the last day. Projection collapses to monthSoFar.
        var costs: [String: Double] = [:]
        for day in 1...31 {
            let key = String(format: "2026-05-%02d", day)
            costs[key] = 10
        }
        let projection = try #require(MonthlyForecast.compute(
            dailyCosts: costs,
            now: date("2026-05-31"),
            calendar: utc
        ))
        #expect(projection.dayOfMonth == 31)
        #expect(abs(projection.projectedMonthTotal - projection.monthSoFar) < 1e-9)
    }

    @Test func handlesFebruaryAcrossLeapAndCommonYears() throws {
        // 2026 is not a leap year; February has 28 days.
        let p2026 = try #require(MonthlyForecast.compute(
            dailyCosts: [
                "2026-02-01": 10,
                "2026-02-02": 10,
                "2026-02-03": 10,
            ],
            now: date("2026-02-10"),
            calendar: utc
        ))
        #expect(p2026.daysInMonth == 28)

        // 2024 is a leap year; February has 29 days.
        let p2024 = try #require(MonthlyForecast.compute(
            dailyCosts: [
                "2024-02-01": 10,
                "2024-02-02": 10,
                "2024-02-03": 10,
            ],
            now: date("2024-02-10"),
            calendar: utc
        ))
        #expect(p2024.daysInMonth == 29)
    }

    @Test func weekdayWeightsReshapeTheProjection() throws {
        // 10 equal active days so the flat baseline is clean.
        var costs: [String: Double] = [:]
        for d in 1...10 { costs[String(format: "2026-05-%02d", d)] = 10 }
        // Heavy weekdays (Mon–Fri = 2…6), light weekends (1, 7).
        let weights = ActivityProfile.WeekdayWeights(
            weightByWeekday: [1: 0.3, 2: 1.4, 3: 1.4, 4: 1.4, 5: 1.4, 6: 1.4, 7: 0.3],
            dayCount: 30
        )
        let shaped = try #require(MonthlyForecast.compute(
            dailyCosts: costs, now: date("2026-05-10"), calendar: utc, weekdayWeights: weights))

        // Exact: monthSoFar × (Σ weights over all days) / (Σ over elapsed days).
        func w(_ d: Int) -> Double {
            weights.weight(utc.component(.weekday, from: date(String(format: "2026-05-%02d", d))))
        }
        let wElapsed = (1...10).reduce(0.0) { $0 + w($1) }
        let wAll = (1...31).reduce(0.0) { $0 + w($1) }
        #expect(abs(shaped.projectedMonthTotal - 100.0 * wAll / wElapsed) < 1e-6)

        // And it actually moves off the flat-average baseline.
        let flat = try #require(MonthlyForecast.compute(
            dailyCosts: costs, now: date("2026-05-10"), calendar: utc))
        #expect(abs(shaped.projectedMonthTotal - flat.projectedMonthTotal) > 1e-6)
        // Other fields (month-so-far, days) are untouched by the shaping.
        #expect(abs(shaped.monthSoFar - flat.monthSoFar) < 1e-9)
        #expect(shaped.daysInMonth == flat.daysInMonth)
    }

    @Test func uniformWeekdayWeightsLeaveAllEqualDaysProjectionUnchanged() throws {
        // Every day active and equal → the flat baseline equals the linear
        // pace, so uniform weights must reproduce it exactly.
        var costs: [String: Double] = [:]
        for d in 1...10 { costs[String(format: "2026-05-%02d", d)] = 10 }
        let uniform = ActivityProfile.WeekdayWeights(
            weightByWeekday: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, 1.0) }), dayCount: 30)
        let shaped = try #require(MonthlyForecast.compute(
            dailyCosts: costs, now: date("2026-05-10"), calendar: utc, weekdayWeights: uniform))
        let flat = try #require(MonthlyForecast.compute(
            dailyCosts: costs, now: date("2026-05-10"), calendar: utc))
        #expect(abs(shaped.projectedMonthTotal - flat.projectedMonthTotal) < 1e-6)
    }
}
