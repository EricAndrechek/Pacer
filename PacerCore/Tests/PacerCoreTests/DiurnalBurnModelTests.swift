import Foundation
import Testing
@testable import PacerCore

@Suite("Diurnal burn model")
struct DiurnalBurnModelTests {

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func at(_ ymd: String, _ h: Int = 0) -> Date {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        var dc = DateComponents(); dc.year = p[0]; dc.month = p[1]; dc.day = p[2]; dc.hour = h
        return utc.date(from: dc)!
    }

    /// A shape table: weekdays (Mon–Fri) burn during hours 9–16, everything else
    /// (nights, weekends) idle.
    private func workdayTable() -> [[Double]] {
        var t = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        for wd in 1...5 { for h in 9...16 { t[wd][h] = 1 } }   // 0=Sun..6=Sat → 1..5 = Mon..Fri
        return t
    }

    @Test func idleHoursAndWeekendsDoNotAccrue() throws {
        let model = DiurnalBurnModel(rate: workdayTable(), calendar: utc)
        // Observe one working day (May 4 09:00→17:00, $40 used), reset a week out.
        let start = at("2026-05-04", 9)
        let cycle = BurnTrajectory.PartialCycle(
            samples: [.init(at: start, usedPercentage: 0), .init(at: at("2026-05-04", 17), usedPercentage: 40)],
            now: at("2026-05-04", 17), cycleStart: start, resetsAt: at("2026-05-11", 9))
        let project = try #require(model.fit(cycle))

        // A few hours into the night: nothing accrues.
        #expect(abs(project(at("2026-05-04", 23)) - 40) < 1e-6)
        // Across the whole remaining week the model adds the future *working*
        // hours only — far less than a flat extrapolation of the daytime rate.
        let diurnalFinal = project(at("2026-05-11", 9))
        let linear = BurnTrajectory.LinearRecent().fit(cycle)!(at("2026-05-11", 9))
        #expect(diurnalFinal > 40)                 // it does keep climbing on weekdays
        #expect(diurnalFinal < linear * 0.5)       // but ~nothing like the line's runaway
    }

    @Test func fitDeclinesWithoutSignal() {
        let model = DiurnalBurnModel(rate: workdayTable(), calendar: utc)
        // No usage yet.
        let zero = BurnTrajectory.PartialCycle(
            samples: [.init(at: at("2026-05-04", 9), usedPercentage: 0)],
            now: at("2026-05-04", 9), cycleStart: at("2026-05-04", 9), resetsAt: at("2026-05-11", 9))
        #expect(model.fit(zero) == nil)
        // Observed only during idle (night) hours where the model expects nothing
        // → it can't explain the burn, so it declines rather than divide by ~0.
        let nightOnly = BurnTrajectory.PartialCycle(
            samples: [.init(at: at("2026-05-04", 1), usedPercentage: 0), .init(at: at("2026-05-04", 5), usedPercentage: 10)],
            now: at("2026-05-04", 5), cycleStart: at("2026-05-04", 1), resetsAt: at("2026-05-11", 1))
        #expect(model.fit(nightOnly) == nil)
    }

    @Test func rateTableLearnsTheActivePatternAndShrinksThinCells() {
        // Build cycles that only ever accrue Mon–Fri during hours 10–15.
        func cycle(_ startYMD: String) -> BurnTrajectory.Cycle {
            var samples: [BurnTrajectory.Sample] = []
            var used = 0.0
            var t = at(startYMD, 0)
            let reset = at(startYMD, 0).addingTimeInterval(7 * 86400)
            while t <= reset {
                samples.append(.init(at: t, usedPercentage: used))
                let h = utc.component(.hour, from: t), wd = utc.component(.weekday, from: t)
                if (10...15).contains(h) && (2...6).contains(wd) { used += 1 }
                t = t.addingTimeInterval(3600)
            }
            return .init(samples: samples, cycleStart: at(startYMD, 0), resetsAt: reset)
        }
        let table = DiurnalBurnModel.rateTable(cycles: [cycle("2026-05-04"), cycle("2026-05-11")], calendar: utc)
        // Active weekday hours carry clearly more rate than nights/weekends.
        let activeWeekday = table[2][12]    // Tue noon
        let nightWeekday = table[2][3]      // Tue 3am
        let weekendNoon = table[0][12]      // Sun noon
        #expect(activeWeekday > nightWeekday)
        #expect(activeWeekday > weekendNoon)
    }

    @Test func priorShapesEmptyCells() {
        // No cycles at all → table falls back entirely to the (normalized) prior.
        var prior = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        for wd in 0..<7 { prior[wd][12] = 10 }   // a noon-heavy prior
        let table = DiurnalBurnModel.rateTable(cycles: [], calendar: utc, prior: prior)
        #expect(table[3][12] > table[3][3])      // noon > 3am, inherited from the prior
    }

    @Test func competesInTheBurnTournament() {
        // It's a BurnTrajectory.Model, so it can sit in the roster and be scored /
        // selected like any other curve fit.
        func cycle(_ startYMD: String) -> BurnTrajectory.Cycle {
            var samples: [BurnTrajectory.Sample] = []; var used = 0.0
            var t = at(startYMD, 0); let reset = at(startYMD, 0).addingTimeInterval(7 * 86400)
            while t <= reset {
                samples.append(.init(at: t, usedPercentage: min(100, used)))
                let h = utc.component(.hour, from: t), wd = utc.component(.weekday, from: t)
                if (9...16).contains(h) && (2...6).contains(wd) { used += 0.7 }
                t = t.addingTimeInterval(3600)
            }
            return .init(samples: samples, cycleStart: at(startYMD, 0), resetsAt: reset)
        }
        let history = [cycle("2026-04-06"), cycle("2026-04-13"), cycle("2026-04-20")]
        let table = DiurnalBurnModel.rateTable(cycles: history, calendar: utc)
        let models: [any BurnTrajectory.Model] = [
            DiurnalBurnModel(rate: table, calendar: utc), BurnTrajectory.LinearRecent()]
        let scores = BurnTrajectory.score(models: models, cycles: history)
        #expect(scores.contains { $0.id == "diurnal-rate" })
    }
}
