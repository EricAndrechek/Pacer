import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// Tests for the engine integration layer: the feature builder (cumulative
/// series, diurnal activity grid, idle gate) and the typed question→Estimate
/// answers. Everything but the actor smoke test runs on the pure statics, so
/// no `ModelContainer` is needed.
@Suite("Usage intelligence engine")
struct UsageIntelligenceEngineTests {

    // A fixed clock + UTC Gregorian calendar so date keys are deterministic.
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static let now = utc.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 20, minute: 30))!

    func key(_ date: Date) -> String { TokenSample.formatDate(date, timeZone: Self.utc.timeZone) }
    func dayBack(_ i: Int) -> Date {
        Self.utc.date(byAdding: .day, value: -i, to: Self.utc.startOfDay(for: Self.now))!
    }

    // MARK: - Feature builder

    @Test func cumulativePointsRoundTripThroughHourlyCosts() {
        var hours = [Double](repeating: 0, count: 24)
        hours[9] = 4; hours[13] = 6; hours[17] = 2     // $12 total, three active hours
        let start = Self.utc.startOfDay(for: Self.now)
        let pts = EngineFeatures.cumulativePoints(hours, dayStart: start, cap: nil)
        #expect(pts != nil)
        // The shape forecaster must reconstruct the per-hour costs exactly.
        let recovered = HourOfDayShapeForecaster.hourlyCosts(points: pts!, start: start, calendar: Self.utc)
        #expect(recovered != nil)
        #expect(abs(recovered![9] - 4) < 1e-9)
        #expect(abs(recovered![13] - 6) < 1e-9)
        #expect(abs(recovered![17] - 2) < 1e-9)
        #expect(abs((recovered!.reduce(0, +)) - 12) < 1e-9)
    }

    @Test func activityGridIsPActiveAndCountsIdleDays() {
        // 14 consecutive complete days, each active only at hour 9.
        var hourly: [EngineFeatures.HourlyRow] = []
        var daily: [EngineFeatures.DailyRow] = []
        for i in 1...14 {
            let k = key(dayBack(i))
            hourly.append(.init(date: k, hour: 9, cost: 10, sampleCount: 1))
            daily.append(.init(date: k, cost: 10))
        }
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: daily,
                                     hourly: hourly, rate: [], lastArrivalAt: nil)
        // Every weekday that appears was active at hour 9 on all its days → P = 1.
        var sawFull = false
        for wd in 0..<7 {
            let total = f.activityGrid[wd].reduce(0, +)
            if total > 0 {
                #expect(abs(f.activityGrid[wd][9] - 1.0) < 1e-9)
                #expect(f.activityGrid[wd][10] == 0)
                sawFull = true
            }
            // P(active) is a probability — never exceeds 1.
            #expect(f.activityGrid[wd].allSatisfy { $0 <= 1.0 + 1e-9 })
        }
        #expect(sawFull)

        // Remaining-activity share: everything is at hour 9, so nothing is left
        // after hour 9, but it's all still ahead after hour 8.
        let presentWd = (0..<7).first { f.activityGrid[$0].reduce(0, +) > 0 }!
        #expect(EngineFeatures.remainingActivityShare(f.activityGrid, weekday: presentWd, afterHour: 9) == 0)
        #expect(abs(EngineFeatures.remainingActivityShare(f.activityGrid, weekday: presentWd, afterHour: 8) - 1.0) < 1e-9)
        // Unknown weekday (no data) → safe default 1 (never gate on nothing).
        let emptyGrid = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        #expect(EngineFeatures.remainingActivityShare(emptyGrid, weekday: 0, afterHour: 12) == 1)
    }

    // MARK: - Idle / done gate

    /// Build features where activity is concentrated at hour 9 (so the rest of
    /// the day is typically idle) with a small spend today.
    private func quietDayFeatures(lastArrival: Date?) -> EngineFeatures {
        var hourly: [EngineFeatures.HourlyRow] = []
        var daily: [EngineFeatures.DailyRow] = []
        for i in 1...21 {
            let k = key(dayBack(i))
            hourly.append(.init(date: k, hour: 9, cost: 10, sampleCount: 1))
            daily.append(.init(date: k, cost: 10))
        }
        // Today: a small early spend, now is hour 20.
        let todayKey = key(Self.now)
        hourly.append(.init(date: todayKey, hour: 9, cost: 5, sampleCount: 1))
        daily.append(.init(date: todayKey, cost: 5))
        return EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: daily,
                                    hourly: hourly, rate: [], lastArrivalAt: lastArrival)
    }

    @Test func idleGateHoldsAQuietDoneDay() {
        // Last arrival was this morning — long idle, rest of day typically dead.
        let morning = Self.utc.date(bySettingHour: 9, minute: 0, second: 0, of: Self.now)!
        let f = quietDayFeatures(lastArrival: morning)
        let fit = UsageIntelligenceEngine.makeFit(f)
        let e = UsageIntelligenceEngine.projectedCostToday(f, fit)
        #expect(e.method == "eod-done-gate")
        #expect(abs(e.value - 5) < 1e-9)               // held at spend so far
        #expect(e.interval80?.lowerBound == 5)         // can't un-spend
        #expect((e.interval80?.upperBound ?? 0) >= 5)
    }

    @Test func idleGateYieldsToRecentActivity() {
        // A token arrived 10 minutes ago — the day is still live, don't hold.
        let f = quietDayFeatures(lastArrival: Self.now.addingTimeInterval(-600))
        let fit = UsageIntelligenceEngine.makeFit(f)
        let e = UsageIntelligenceEngine.projectedCostToday(f, fit)
        #expect(e.method != "eod-done-gate")
    }

    // MARK: - Synthetic rich history for the cost/norm questions

    /// ~55 prior active days spanning >2 calendar months, weekdays heavier than
    /// weekends, each day's cost spread across active hours.
    private func richHistory() -> EngineFeatures {
        var hourly: [EngineFeatures.HourlyRow] = []
        var daily: [EngineFeatures.DailyRow] = []
        for i in 1...55 {
            let day = dayBack(i)
            let k = key(day)
            let wd = Self.utc.component(.weekday, from: day)
            let weekend = (wd == 1 || wd == 7)
            let total = weekend ? Double(6 + i % 3) : Double(40 + (i % 5) * 4)
            let hoursActive = weekend ? [11, 12] : [9, 11, 13, 15, 17]
            let per = total / Double(hoursActive.count)
            for h in hoursActive {
                hourly.append(.init(date: k, hour: h, cost: per, sampleCount: 1))
            }
            daily.append(.init(date: k, cost: total))
        }
        // A little spend today too.
        let todayKey = key(Self.now)
        hourly.append(.init(date: todayKey, hour: 9, cost: 12, sampleCount: 1))
        hourly.append(.init(date: todayKey, hour: 13, cost: 18, sampleCount: 1))
        daily.append(.init(date: todayKey, cost: 30))
        return EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: daily,
                                    hourly: hourly, rate: [], lastArrivalAt: Self.now.addingTimeInterval(-300))
    }

    @Test func monthlyProjectionIsEligibleOnRichHistory() {
        let f = richHistory()
        let fit = UsageIntelligenceEngine.makeFit(f)
        let e = UsageIntelligenceEngine.answer(.projectedCost(.thisMonth), features: f, fit: fit)
        #expect(!e.isInsufficient)
        #expect(e.value > 0)
        #expect(e.method == "monthly-daily-sum")       // seasonal model, not the flat fallback
    }

    @Test func typicalUsageAndPaceAndShortHorizon() {
        let f = richHistory()
        let fit = UsageIntelligenceEngine.makeFit(f)

        let typical = UsageIntelligenceEngine.answer(.typicalUsage, features: f, fit: fit)
        #expect(!typical.isInsufficient)
        #expect(typical.value > 0)
        #expect(typical.interval80 != nil)

        let pace = UsageIntelligenceEngine.answer(.pace, features: f, fit: fit)
        #expect(!pace.isInsufficient)
        #expect(pace.value >= 0 && pace.value <= 1)

        let next = UsageIntelligenceEngine.answer(.shortHorizon, features: f, fit: fit)
        #expect(!next.isInsufficient)
        #expect(next.confidence == .low)               // honest: next-day is wide
    }

    @Test func anomalyNeedsAtLeastTwoWeeksOfBaseline() {
        // Only 10 prior days → can't judge what's normal yet.
        var hourly: [EngineFeatures.HourlyRow] = []
        var daily: [EngineFeatures.DailyRow] = []
        for i in 1...10 {
            let k = key(dayBack(i))
            hourly.append(.init(date: k, hour: 10, cost: 20, sampleCount: 1))
            daily.append(.init(date: k, cost: 20))
        }
        let thin = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: daily,
                                        hourly: hourly, rate: [], lastArrivalAt: nil)
        #expect(UsageIntelligenceEngine.makeFit(thin).anomaly.isInsufficient)

        // With a long baseline and a dead final day, the verdict is a lull.
        var hourly2: [EngineFeatures.HourlyRow] = []
        var daily2: [EngineFeatures.DailyRow] = []
        for i in 2...30 {                               // days 2..30 are busy
            let k = key(dayBack(i))
            hourly2.append(.init(date: k, hour: 10, cost: 50, sampleCount: 1))
            daily2.append(.init(date: k, cost: 50))
        }
        // day 1 (most recent complete day) has no spend → $0 lull.
        let rich = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: daily2,
                                        hourly: hourly2, rate: [], lastArrivalAt: nil)
        let anomaly = UsageIntelligenceEngine.makeFit(rich).anomaly
        #expect(!anomaly.isInsufficient)
        #expect(anomaly.note == "lull — unusually quiet")
        #expect(anomaly.value < 0)                      // negative z = below normal
    }

    // MARK: - Rate-limit outlook

    @Test func rateLimitOutlookProjectsWithinBounds() {
        let duration: TimeInterval = 7 * 24 * 3600
        var rate: [EngineFeatures.RateRow] = []
        // Three complete cycles + one live one, each ramping 0 → ~60%.
        for c in 0..<4 {
            // cycle c starts (3 - c) cycles ago; the last one is live (reset future).
            let cycleStart = Self.now.addingTimeInterval(-Double(3 - c) * duration - 2 * 86400)
            let resetsAt = cycleStart.addingTimeInterval(duration)
            var t = cycleStart
            var pct = 0.0
            while t <= min(resetsAt, Self.now) {
                rate.append(.init(window: "seven_day", at: t, usedPercentage: min(60, pct), resetsAt: resetsAt))
                t = t.addingTimeInterval(6 * 3600)
                pct += 2.2
            }
        }
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [],
                                     hourly: [], rate: rate, lastArrivalAt: nil)
        let fit = UsageIntelligenceEngine.makeFit(f)
        let e = UsageIntelligenceEngine.answer(.rateLimitOutlook(.sevenDay), features: f, fit: fit)
        #expect(!e.isInsufficient)
        #expect(e.value >= 0 && e.value <= 100)
        #expect(e.method.hasPrefix("rl-"))
    }

    // MARK: - Insufficient / cold-start guards

    @Test func emptyFeaturesAnswerInsufficientNotZero() {
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [],
                                     hourly: [], rate: [], lastArrivalAt: nil)
        let fit = UsageIntelligenceEngine.makeFit(f)
        for q: EngineQuestion in [.projectedCost(.today), .projectedCost(.thisMonth),
                                  .rateLimitOutlook(.fiveHour), .rateLimitOutlook(.sevenDay),
                                  .pace, .typicalUsage, .isAnomalous, .shortHorizon] {
            #expect(UsageIntelligenceEngine.answer(q, features: f, fit: fit).isInsufficient)
        }
    }

    // MARK: - Actor smoke test (exercises the @ModelActor + store fetches)

    @Test func actorRecomputeOnEmptyStoreIsSafe() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.recompute(now: Self.now, calendar: Self.utc)
        #expect(await engine.trainingDayCount() == 0)
        let e = await engine.ask(.projectedCost(.today))
        #expect(e.isInsufficient)
    }
}
