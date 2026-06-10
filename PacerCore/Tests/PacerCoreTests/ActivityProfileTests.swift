import Foundation
import Testing
@testable import PacerCore

@Suite("ActivityProfile")
struct ActivityProfileTests {

    /// A day whose spend is concentrated in `activeHours`, `perHour` each.
    private func day(activeHours: Range<Int>, perHour: Double) -> [Double] {
        (0..<24).map { activeHours.contains($0) ? perHour : 0 }
    }

    // MARK: - Hour-of-day shape

    @Test func shapeIsMonotonicAndEndsAtOne() throws {
        // Mornings-and-afternoons worker: spend in hours 9..18.
        let days = Array(repeating: day(activeHours: 9..<18, perHour: 2), count: 10)
        let shape = try #require(ActivityProfile.hourOfDayShape(days: days))
        #expect(shape.dayCount == 10)
        for h in 1..<24 { #expect(shape.fractionByHour[h] >= shape.fractionByHour[h - 1]) }
        #expect(abs(shape.fractionByHour[23] - 1) < 1e-9)
        #expect(shape.fractionByHour[8] == 0)            // nothing before 9am
        #expect(abs(shape.fractionByHour[17] - 1) < 1e-9) // all done by 6pm
        #expect(abs(shape.fractionByHour[13] - 5.0 / 9.0) < 0.02) // 5 of 9 active hours done
    }

    @Test func shapeNilBelowMinDays() {
        let days = Array(repeating: day(activeHours: 9..<18, perHour: 2), count: 3)
        #expect(ActivityProfile.hourOfDayShape(days: days) == nil)
    }

    @Test func shapeSkipsEmptyDays() throws {
        var days = Array(repeating: day(activeHours: 9..<18, perHour: 2), count: 6)
        days.append(contentsOf: Array(repeating: [Double](repeating: 0, count: 24), count: 4))
        let shape = try #require(ActivityProfile.hourOfDayShape(days: days))
        #expect(shape.dayCount == 6)  // the 4 zero days don't count
    }

    @Test func projectionNailsTheTaperWhereNaiveOvershoots() throws {
        // Daytime worker: all spend in 9..18. By 4pm (hour 15) the profile
        // knows the day is ~85% done; the evening is quiet.
        let days = Array(repeating: day(activeHours: 9..<18, perHour: 10), count: 12)  // $90/day
        let shape = try #require(ActivityProfile.hourOfDayShape(days: days))

        // Today mirrors the pattern: $80 spent through hour 15 of a ~$90 day.
        let soFar = 80.0, throughHour = 15
        let truth = 90.0
        // Naive "× hours-left" badly overshoots: last hour $10 × 8h left.
        let naive = soFar + 10 * Double(24 - (throughHour + 1))
        let profiled = ActivityProfile.projectedEndOfDay(
            soFar: soFar, throughHour: throughHour, shape: shape, naive: naive)

        #expect(naive > 130)                                   // wild overshoot
        #expect(abs(profiled - truth) < abs(naive - truth))    // profile closer
        #expect(profiled < naive)
    }

    @Test func projectionFallsBackToNaiveEarlyInDay() throws {
        let days = Array(repeating: day(activeHours: 9..<18, perHour: 10), count: 12)
        let shape = try #require(ActivityProfile.hourOfDayShape(days: days))
        // Hour 6 (6am): fraction done is ~0 (< floor) → defer entirely to naive.
        let naive = 42.0
        let p = ActivityProfile.projectedEndOfDay(soFar: 0, throughHour: 6, shape: shape, naive: naive)
        #expect(p == naive)
    }

    // MARK: - Weekday weights

    @Test func weekdayWeightsAverageToOneAndRankWeekendLow() throws {
        // 4 weeks: weekdays (Mon–Fri, weekday 2–6) heavy, weekends (1,7) light.
        var days: [(Int, Double)] = []
        for _ in 0..<4 {
            for wd in 1...7 {
                let heavy = (2...6).contains(wd)
                days.append((wd, heavy ? 100 : 20))
            }
        }
        let w = try #require(ActivityProfile.weekdayWeights(days: days.map { (weekday: $0.0, cost: $0.1) }))
        let mean = (1...7).map { w.weight($0) }.reduce(0, +) / 7
        #expect(abs(mean - 1) < 1e-9)                 // normalized to mean 1
        #expect(w.weight(1) < w.weight(2))            // Sunday < Monday
        #expect(w.weight(7) < 0.6)                    // Saturday well below average
        #expect(w.weight(3) > 1.2)                    // Tuesday well above
    }

    @Test func weekdayWeightsNilBelowTwoWeeks() {
        let days = (0..<10).map { (weekday: ($0 % 7) + 1, cost: 50.0) }
        #expect(ActivityProfile.weekdayWeights(days: days) == nil)
    }

    @Test func weekdayWeightsIncludeZeroDays() throws {
        // Zero-cost weekends must pull weekend weight down, not be skipped.
        var days: [(weekday: Int, cost: Double)] = []
        for _ in 0..<4 {
            for wd in 1...7 { days.append((weekday: wd, cost: (2...6).contains(wd) ? 100 : 0)) }
        }
        let w = try #require(ActivityProfile.weekdayWeights(days: days))
        #expect(w.weight(1) == 0)            // dead-quiet Sundays read as zero
        #expect(w.weight(4) > 1)             // Wednesday above average
    }

    @Test func monthlyProjectionWeightsRemainingWeekends() throws {
        var days: [(weekday: Int, cost: Double)] = []
        for _ in 0..<4 {
            for wd in 1...7 { days.append((weekday: wd, cost: (2...6).contains(wd) ? 100 : 20)) }
        }
        let w = try #require(ActivityProfile.weekdayWeights(days: days))

        // Elapsed: a heavy Mon–Fri stretch (weekday 2–6), $500 so far.
        // Remaining: a light weekend (1,7) then more weekdays.
        let elapsed = [2, 3, 4, 5, 6]
        let remaining = [7, 1, 2, 3, 4, 5, 6]
        let monthSoFar = 500.0
        // Naive flat-average over-weights the coming weekend.
        let naive = monthSoFar / 5 * Double(elapsed.count + remaining.count)
        let profiled = ActivityProfile.projectedMonthTotal(
            monthSoFar: monthSoFar, elapsedWeekdays: elapsed, remainingWeekdays: remaining,
            weights: w, naive: naive)

        // The weekend (weights ~0.4 each) contributes less than two weekdays,
        // so the profile projects below the flat average.
        #expect(profiled < naive)
        #expect(profiled > monthSoFar)   // still growing
    }
}
