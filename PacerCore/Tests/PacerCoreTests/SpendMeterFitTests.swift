import Foundation
import SwiftData
import Testing
@testable import PacerCore

// MARK: - NNLS

@Suite("NNLS (Lawson–Hanson)")
struct NNLSTests {

    @Test("a consistent system with a positive answer is solved exactly")
    func exactPositive() {
        let truth = [0.5, 2.0, 1.25]
        let rows: [[Double]] = (0..<20).map { i in
            [Double(i % 7), Double((i * 3) % 5), 1]
        }
        let b = rows.map { r in zip(r, truth).reduce(0) { $0 + $1.0 * $1.1 } }
        let s = NNLS.solve(rows: rows, b: b)
        #expect(s.converged)
        for j in 0..<3 { #expect(abs(s.x[j] - truth[j]) < 1e-9) }
        #expect(s.residualNorm < 1e-9)
    }

    @Test("matches scipy.optimize.nnls where constraints bind")
    func matchesScipy() {
        // `nnls(A, b)` in scipy 1.x gives x = [0.4727, 0, 1.3689, 0, 0] and
        // a residual of 6.3057; plain least squares puts -0.758 on column 1.
        let a: [[Double]] = [
            [3, 0, 1, 2, 1], [1, 4, 0, 0, 1], [0, 2, 5, 1, 1], [2, 2, 2, 0, 1],
            [4, 1, 0, 3, 1], [0, 0, 3, 1, 1], [1, 3, 1, 4, 1], [5, 0, 2, 0, 1],
            [2, 1, 4, 2, 1], [0, 5, 0, 1, 1], [3, 3, 3, 3, 1], [1, 0, 0, 5, 1],
        ]
        let b: [Double] = [4, -2, 7, 1, 3, 5, -1, 6, 8, -3, 4, 0]
        let s = NNLS.solve(rows: a, b: b)
        let expected = [0.47267683772538127, 0.0, 1.368932038834952, 0.0, 0.0]
        #expect(s.converged)
        for j in 0..<5 { #expect(abs(s.x[j] - expected[j]) < 1e-9, "x[\(j)] = \(s.x[j])") }
        #expect(abs(s.residualNorm - 6.3056894812196775) < 1e-9)
    }

    @Test("a slope that would go negative is held at zero")
    func clampsNegativeSlope() {
        // Falling data: least squares wants slope -1, intercept 4. NNLS
        // holds the slope at 0 and the intercept takes the mean.
        let s = NNLS.solve(rows: [[1, 1], [2, 1], [3, 1]], b: [3, 2, 1])
        #expect(s.x[0] == 0)
        #expect(abs(s.x[1] - 2) < 1e-12)
    }

    @Test("zero and duplicate columns do not break it")
    func degenerateColumns() {
        // Column 1 is all zeros, column 2 duplicates column 0.
        let rows: [[Double]] = (0..<10).map { i in [Double(i), 0, Double(i), 1] }
        let b = rows.map { 2 * $0[0] + 3 }
        let s = NNLS.solve(rows: rows, b: b)
        #expect(s.converged)
        #expect(s.x[1] == 0)
        #expect(abs(s.x[0] + s.x[2] - 2) < 1e-9)
        #expect(abs(s.x[3] - 3) < 1e-9)
    }

    @Test("random problems satisfy the optimality conditions")
    func kktOnRandomProblems() {
        var rng = SplitMix(seed: 7)
        for _ in 0..<50 {
            let m = 30 + Int(rng.next() % 40)
            let n = 2 + Int(rng.next() % 10)
            let rows = (0..<m).map { _ in (0..<n).map { _ in rng.uniform() * 10 - 3 } }
            let b = (0..<m).map { _ in rng.uniform() * 20 - 5 }
            let s = NNLS.solve(rows: rows, b: b)
            #expect(s.converged)
            // Feasible; the gradient Aᵀ(b − Ax) is ≤ 0 everywhere and ≈ 0
            // where the coefficient is positive.
            var r = b
            for i in 0..<m { for j in 0..<n { r[i] -= rows[i][j] * s.x[j] } }
            for j in 0..<n {
                #expect(s.x[j] >= 0)
                let w = (0..<m).reduce(0.0) { $0 + rows[$1][j] * r[$1] }
                #expect(w < 1e-7)
                if s.x[j] > 1e-9 { #expect(abs(w) < 1e-7) }
            }
        }
    }
}

// MARK: - Synthetic meter

/// Deterministic generator, so the golden tests are exact and repeatable.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// A meter driven by known per-model rates plus a constant intercept, read
/// every five minutes, resetting every `duration`. Each hour's rise is spread
/// over exactly the pairs the fitter will count in that hour, so the hourly
/// sums satisfy the model exactly and a correct fit recovers it to rounding.
/// Each reading's `resetsAt` jitters by a few hundred milliseconds, as the
/// server's does.
private struct SyntheticMeter {
    var readings: [MeterReading] = []
    var spend: [HourlySpend] = []
    var span: DateInterval

    init(start: Date, hours: Int, timeZone: TimeZone, duration: TimeInterval,
         rates: [String: Double], intercept: Double,
         spendFor: (Int, String) -> Double) {
        span = DateInterval(start: start, duration: Double(hours) * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let step: TimeInterval = 300
        let count = hours * 12 + 1
        let times = (0..<count).map { start.addingTimeInterval(Double($0) * step) }
        let cycle = times.map { Int($0.timeIntervalSince(start) / duration) }

        // The pair ending at reading k spans [k−1, k] five-minute steps, all
        // inside hour (k − 1) / 12, so no pair crosses an hour boundary. A
        // pair across a reset is not counted, so that hour is watched for
        // 55 minutes and the intercept accrues for 55.
        var counted = Array(repeating: 0, count: hours)
        for k in 1..<count where cycle[k] == cycle[k - 1] {
            counted[(k - 1) / 12] += 1
        }
        var rise = Array(repeating: 0.0, count: hours)
        for i in 0..<hours {
            let at = start.addingTimeInterval(Double(i) * 3600)
            var total = intercept * Double(counted[i]) / 12
            for (model, rate) in rates.sorted(by: { $0.key < $1.key }) {
                let cost = spendFor(i, model)
                guard cost > 0 else { continue }
                total += rate * cost
                spend.append(HourlySpend(
                    date: TokenSample.formatDate(at, timeZone: timeZone),
                    hour: calendar.component(.hour, from: at), model: model, costUSD: cost))
            }
            rise[i] = total
        }
        var value = 0.0
        for k in 0..<count {
            if k > 0 {
                let i = (k - 1) / 12
                value = cycle[k] == cycle[k - 1] ? value + rise[i] / Double(counted[i]) : 0
            }
            let jitter = Double(k % 7 - 3) * 0.1
            let reset = start.addingTimeInterval(Double(cycle[k] + 1) * duration + jitter)
            readings.append(MeterReading(at: times[k], percent: value, resetsAt: reset))
        }
    }
}

private let utc = TimeZone(identifier: "UTC")!
/// 2026-10-01 00:00 UTC.
private let spanStart = Date(timeIntervalSince1970: 1_790_812_800)

private let opus = "claude-opus-5-5"
private let fable = "claude-fable-5-1"
private let sonnet = "claude-sonnet-5-5"

/// Busy, idle and mixed hours: Opus in most working hours, Fable and Sonnet
/// in some of them, so the columns overlap without being collinear.
private func workday(_ rng: inout SplitMix, hours: Int) -> [Int: [String: Double]] {
    var out: [Int: [String: Double]] = [:]
    for i in 0..<hours {
        let hourOfDay = i % 24
        guard hourOfDay >= 8 && hourOfDay < 23, rng.uniform() > 0.2 else { continue }
        var row: [String: Double] = [opus: 5 + rng.uniform() * 30]
        if rng.uniform() < 0.35 { row[fable] = 2 + rng.uniform() * 12 }
        if rng.uniform() < 0.3 { row[sonnet] = 1 + rng.uniform() * 15 }
        out[i] = row
    }
    return out
}

/// Pairs that cross a reset, which the fit does not count.
private func resets(_ readings: [MeterReading], duration: TimeInterval) -> Int {
    zip(readings, readings.dropFirst()).filter { a, b in
        !RateLimitCycle.contains(sampleReset: b.resetsAt, resets: a.resetsAt!, duration: duration)
    }.count
}

// MARK: - Fitter

@Suite("Spend → meter fit")
struct SpendMeterFitterTests {

    @Test("golden: known per-model rates and intercept are recovered")
    func goldenRecovery() throws {
        var rng = SplitMix(seed: 42)
        let hours = 14 * 24
        let plan = workday(&rng, hours: hours)
        let rates = [opus: 0.16, fable: 0.40, sonnet: 0.10]
        let meter = SyntheticMeter(
            start: spanStart, hours: hours, timeZone: utc, duration: 5 * 3600,
            rates: rates, intercept: 0.05) { plan[$0]?[$1] ?? 0 }

        let outcome = SpendMeterFitter.fit(
            accountId: "acct", window: "five_hour", duration: 5 * 3600,
            readings: meter.readings, spend: meter.spend, span: meter.span, timeZone: utc)
        guard case .fitted(let r) = outcome else { Issue.record("not fitted: \(outcome)"); return }

        for (model, rate) in rates {
            let got = try #require(r.modelRates[model])
            #expect(abs(got - rate) / rate < 1e-6, "\(model): \(got) vs \(rate)")
        }
        #expect(abs(r.interceptPerHour - 0.05) < 1e-6)
        #expect(r.hours == hours)
        #expect(r.r2 > 0.999_999)
        #expect(r.rmse < 1e-6)
        let spent = meter.spend.reduce(0) { $0 + $1.costUSD }
        #expect(abs(r.totalSpendUSD - spent) < 1e-6)
        #expect(abs(r.pooledRate - r.totalRise / spent) < 1e-12)
        let watched = Double(meter.readings.count - 1 - resets(meter.readings, duration: 5 * 3600)) / 12
        #expect(abs(r.interceptShare - 0.05 * watched / r.totalRise) < 1e-6)
        #expect(r.method == "nnls-hourly-v1")
    }

    @Test("golden, rounded like the server: rates still within 5%")
    func goldenRoundedMeter() throws {
        var rng = SplitMix(seed: 99)
        let hours = 14 * 24
        let plan = workday(&rng, hours: hours)
        let rates = [opus: 0.16, fable: 0.40, sonnet: 0.10]
        let exact = SyntheticMeter(
            start: spanStart, hours: hours, timeZone: utc, duration: 5 * 3600,
            rates: rates, intercept: 0) { plan[$0]?[$1] ?? 0 }
        // The server reports whole points.
        let rounded = exact.readings.map {
            MeterReading(at: $0.at, percent: $0.percent.rounded(.down), resetsAt: $0.resetsAt)
        }
        let outcome = SpendMeterFitter.fit(
            accountId: "acct", window: "five_hour", duration: 5 * 3600,
            readings: rounded, spend: exact.spend, span: exact.span, timeZone: utc)
        guard case .fitted(let r) = outcome else { Issue.record("not fitted: \(outcome)"); return }
        for (model, rate) in rates {
            let got = r.modelRates[model] ?? 0
            #expect(abs(got - rate) / rate < 0.05, "\(model): \(got) vs \(rate)")
        }
    }

    @Test("scoped cap: only the cap's model moves it")
    func scopedCapOnlyItsModel() throws {
        var rng = SplitMix(seed: 5)
        let hours = 14 * 24
        let plan = workday(&rng, hours: hours)
        // A Fable weekly cap: Opus and Sonnet spend land in the same hours
        // but never move it.
        let meter = SyntheticMeter(
            start: spanStart, hours: hours, timeZone: utc, duration: 7 * 86_400,
            rates: [fable: 0.9], intercept: 0) { plan[$0]?[$1] ?? 0 }
        let otherSpend = plan.flatMap { i, row in
            row.filter { $0.key != fable }.map { model, cost in
                HourlySpend(date: TokenSample.formatDate(spanStart.addingTimeInterval(Double(i) * 3600), timeZone: utc),
                            hour: i % 24, model: model, costUSD: cost)
            }
        }
        let outcome = SpendMeterFitter.fit(
            accountId: "acct", window: "weekly_scoped|Fable|", duration: 7 * 86_400,
            readings: meter.readings, spend: meter.spend + otherSpend, span: meter.span, timeZone: utc)
        guard case .fitted(let r) = outcome else { Issue.record("not fitted: \(outcome)"); return }
        #expect(abs((r.modelRates[fable] ?? 0) - 0.9) < 1e-6)
        #expect((r.modelRates[opus] ?? 0) < 1e-9)
        #expect((r.modelRates[sonnet] ?? 0) < 1e-9)
        #expect(r.interceptPerHour < 1e-9)
    }

    @Test("a model under 1% of spend gets no column, and its spend is reported")
    func tinyModelLeftOut() throws {
        var rng = SplitMix(seed: 11)
        let hours = 14 * 24
        let plan = workday(&rng, hours: hours)
        let haiku = "claude-haiku-4-5"
        let meter = SyntheticMeter(
            start: spanStart, hours: hours, timeZone: utc, duration: 5 * 3600,
            rates: [opus: 0.16, haiku: 0.05], intercept: 0) { i, model in
                model == haiku ? (i % 50 == 10 ? 0.5 : 0) : (plan[i]?[opus] ?? 0)
            }
        let outcome = SpendMeterFitter.fit(
            accountId: "acct", window: "five_hour", duration: 5 * 3600,
            readings: meter.readings, spend: meter.spend, span: meter.span, timeZone: utc)
        guard case .fitted(let r) = outcome else { Issue.record("not fitted: \(outcome)"); return }
        #expect(r.modelRates[haiku] == nil)
        #expect(r.modelRates[opus] != nil)
        let haikuSpend = meter.spend.filter { $0.model == haiku }.reduce(0) { $0 + $1.costUSD }
        #expect(abs(r.unfittedSpendUSD - haikuSpend) < 1e-9)
    }

    @Test("too little data is not fitted")
    func insufficientData() {
        let few = SyntheticMeter(
            start: spanStart, hours: 10, timeZone: utc, duration: 5 * 3600,
            rates: [opus: 0.16], intercept: 0) { _, _ in 10 }
        let outcome = SpendMeterFitter.fit(
            accountId: "acct", window: "five_hour", duration: 5 * 3600,
            readings: few.readings, spend: few.spend, span: few.span, timeZone: utc)
        guard case .skipped = outcome else { Issue.record("fitted 10 hours"); return }

        let idle = SyntheticMeter(
            start: spanStart, hours: 48, timeZone: utc, duration: 5 * 3600,
            rates: [opus: 0.16], intercept: 0) { _, _ in 0 }
        let none = SpendMeterFitter.fit(
            accountId: "acct", window: "five_hour", duration: 5 * 3600,
            readings: idle.readings, spend: idle.spend, span: idle.span, timeZone: utc)
        guard case .skipped = none else { Issue.record("fitted an idle meter"); return }
    }

    @Test("no-spend share counts the rise in hours with nothing spent here")
    func noSpendShare() throws {
        // Two days; 10 points rise in an idle hour, the rest is spend.
        let hours = 48
        let meter = SyntheticMeter(
            start: spanStart, hours: hours, timeZone: utc, duration: 7 * 86_400,
            rates: [opus: 0.2], intercept: 0) { i, _ in i % 24 >= 9 && i % 24 < 17 ? 20 : 0 }
        // Add 10 points across the 03:00 hour of the first day.
        let bumped = meter.readings.map { r -> MeterReading in
            let hour = Int(r.at.timeIntervalSince(spanStart) / 3600)
            let into = r.at.timeIntervalSince(spanStart) - 3 * 3600
            let extra = hour < 3 ? 0 : (into >= 3600 || hour > 3 ? 10 : 10 * into / 3600)
            return MeterReading(at: r.at, percent: r.percent + extra, resetsAt: r.resetsAt)
        }
        let outcome = SpendMeterFitter.fit(
            accountId: "acct", window: "seven_day", duration: 7 * 86_400,
            readings: bumped, spend: meter.spend, span: meter.span, timeZone: utc)
        guard case .fitted(let r) = outcome else { Issue.record("not fitted: \(outcome)"); return }
        let spendRise = 0.2 * 20 * 16
        #expect(abs(r.totalRise - (spendRise + 10)) < 1e-9)
        #expect(abs(r.noSpendRiseShare - 10 / (spendRise + 10)) < 1e-9)
    }
}

// MARK: - Bucketing

@Suite("Spend → meter fit: hourly rise")
struct SpendMeterBucketingTests {

    private func at(_ minutes: Double) -> Date { spanStart.addingTimeInterval(minutes * 60) }
    private let wide = DateInterval(start: spanStart.addingTimeInterval(-86_400), duration: 10 * 86_400)
    private let fiveHours: TimeInterval = 5 * 3600

    private func rise(_ readings: [MeterReading], tz: TimeZone = utc) -> [LocalHour: Double] {
        SpendMeterFitter.hourlyRise(readings: readings, duration: fiveHours, span: wide, timeZone: tz)
            .mapValues(\.rise)
    }

    @Test("a reset is never a rise, even when the new cycle reads higher")
    func resetBoundary() {
        let oldReset = at(120)
        let newReset = at(125 + 5 * 60)
        let readings = [
            MeterReading(at: at(100), percent: 10, resetsAt: oldReset),
            MeterReading(at: at(115), percent: 20, resetsAt: oldReset.addingTimeInterval(0.4)),
            // The old cycle ended at 2:00. Ten minutes later the new one
            // already reads higher, but 20 → 35 spans the reset.
            MeterReading(at: at(125), percent: 35, resetsAt: newReset),
            MeterReading(at: at(130), percent: 40, resetsAt: newReset.addingTimeInterval(-0.3)),
        ]
        let r = rise(readings)
        #expect(r[LocalHour(date: "2026-10-01", hour: 1)] == 10)
        #expect(r[LocalHour(date: "2026-10-01", hour: 2)] == 5)
        #expect(r.values.reduce(0, +) == 15)
    }

    @Test("the null-reset 0% reading after a reset starts the next cycle")
    func nullResetAfterReset() {
        let oldReset = at(30)
        let newReset = at(60 + 5 * 60)
        let readings = [
            MeterReading(at: at(20), percent: 40, resetsAt: oldReset),
            MeterReading(at: at(35), percent: 0, resetsAt: nil),
            MeterReading(at: at(65), percent: 3, resetsAt: newReset),
            MeterReading(at: at(70), percent: 4, resetsAt: newReset),
        ]
        let r = rise(readings)
        // 0 → 3 runs 00:35–01:05: split 25:5 between the hours.
        #expect(r[LocalHour(date: "2026-10-01", hour: 0)] == 2.5)
        #expect(r[LocalHour(date: "2026-10-01", hour: 1)] == 1.5)
    }

    @Test("a drop within a cycle is skipped, and so is an hour-long gap")
    func negativeAndGap() {
        let reset = at(4 * 60)
        let readings = [
            MeterReading(at: at(0), percent: 20, resetsAt: reset),
            MeterReading(at: at(5), percent: 18, resetsAt: reset),
            MeterReading(at: at(10), percent: 21, resetsAt: reset),
            // 70 minutes later: not a pair.
            MeterReading(at: at(80), percent: 30, resetsAt: reset),
            MeterReading(at: at(85), percent: 31, resetsAt: reset),
        ]
        let r = rise(readings)
        #expect(r[LocalHour(date: "2026-10-01", hour: 0)] == 3)
        #expect(r[LocalHour(date: "2026-10-01", hour: 1)] == 1)
    }

    @Test("a pair across an hour boundary is split between local hours by time")
    func localHourAttribution() throws {
        // India is UTC+5:30, so local hours start on UTC half hours — the
        // quarter-hour memo must not leak one hour into the next.
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let reset = at(4 * 60)
        let readings = [
            MeterReading(at: at(25), percent: 1, resetsAt: reset),   // 05:55 local
            MeterReading(at: at(29), percent: 2, resetsAt: reset),   // 05:59 local
            MeterReading(at: at(31), percent: 5, resetsAt: reset),   // 06:01 local
            MeterReading(at: at(44), percent: 6, resetsAt: reset),   // 06:14 local
            MeterReading(at: at(46), percent: 8, resetsAt: reset),   // 06:16 local
        ]
        let r = rise(readings.shuffled(), tz: kolkata)
        // 2 → 5 runs 05:59–06:01: half each side.
        #expect(r[LocalHour(date: "2026-10-01", hour: 5)] == 2.5)
        #expect(r[LocalHour(date: "2026-10-01", hour: 6)] == 4.5)
        #expect(r.count == 2)
    }

    @Test("only the part of a pair inside the span counts")
    func spanEdges() {
        let reset = at(4 * 60)
        let readings = [
            MeterReading(at: at(-5), percent: 1, resetsAt: reset),
            MeterReading(at: at(5), percent: 3, resetsAt: reset),
            MeterReading(at: at(50), percent: 8, resetsAt: reset),
            MeterReading(at: at(70), percent: 10, resetsAt: reset),
        ]
        let span = DateInterval(start: spanStart, duration: 3600)
        let r = SpendMeterFitter.hourlyRise(readings: readings, duration: fiveHours, span: span, timeZone: utc)
        // Half of +2 (23:55–00:05), all of +5, half of +2 (00:50–01:10).
        #expect(r.count == 1)
        #expect(r[LocalHour(date: "2026-10-01", hour: 0)] == HourObservation(rise: 7, watchedSeconds: 3600))
    }
}

// MARK: - Worker

@Suite("Spend → meter fit: daily job")
struct SpendMeterFitWorkerTests {

    /// Two weeks of a synthetic account in a store: the 5-hour and 7-day
    /// meters, a Fable weekly cap, the account-wide scoped rows that
    /// duplicate the fixed windows, and the hourly spend behind them.
    private func seed(_ context: ModelContext, account: String = "acct-a") throws {
        var rng = SplitMix(seed: 3)
        let hours = 15 * 24
        let start = spanStart
        let plan = workday(&rng, hours: hours)
        context.insert(Account(id: account, organizationId: account, displayName: "A",
                               isActive: true, firstSeenAt: start, lastSeenAt: start))
        let five = SyntheticMeter(start: start, hours: hours, timeZone: utc, duration: 5 * 3600,
                                  rates: [opus: 0.16, fable: 0.4, sonnet: 0.1], intercept: 0.02) { plan[$0]?[$1] ?? 0 }
        let week = SyntheticMeter(start: start, hours: hours, timeZone: utc, duration: 7 * 86_400,
                                  rates: [opus: 0.045, fable: 0.11, sonnet: 0.03], intercept: 0) { plan[$0]?[$1] ?? 0 }
        let cap = SyntheticMeter(start: start, hours: hours, timeZone: utc, duration: 7 * 86_400,
                                 rates: [fable: 0.9], intercept: 0) { plan[$0]?[$1] ?? 0 }
        for r in five.readings {
            context.insert(RateLimitSample(sampledAt: r.at, window: "five_hour", usedPercentage: r.percent,
                                           resetsAt: r.resetsAt, source: "oauth", accountId: account))
        }
        for r in week.readings {
            context.insert(RateLimitSample(sampledAt: r.at, window: "seven_day", usedPercentage: r.percent,
                                           resetsAt: r.resetsAt, source: "oauth", accountId: account))
            context.insert(UsageLimitSample(
                sampledAt: r.at, identity: "weekly_all||", kind: "weekly_all", group: "weekly",
                label: "All models", percent: r.percent, resetsAt: r.resetsAt, severity: "normal",
                isActive: false, source: "oauth", accountId: account))
        }
        for r in cap.readings {
            context.insert(UsageLimitSample(
                sampledAt: r.at, identity: "weekly_scoped|Fable|", kind: "weekly_scoped", group: "weekly",
                label: "Fable", percent: r.percent, resetsAt: r.resetsAt, severity: "normal",
                isActive: false, modelDisplayName: "Fable", source: "oauth", accountId: account))
        }
        for s in five.spend {
            context.insert(AccountHourlyAggregate(
                accountId: account, date: s.date, hour: s.hour, model: s.model,
                inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: s.costUSD))
        }
        try context.save()
    }

    /// The fit made on 2026-10-15 covers 10-01 through 10-14.
    private let fitDay = spanStart.addingTimeInterval(14 * 86_400 + 9 * 3600)

    private func check(_ report: SpendMeterFitWorker.Report) throws {
        #expect(report.fittedDay == "2026-10-15")
        #expect(report.span == DateInterval(start: spanStart, duration: 14 * 86_400))
        #expect(Set(report.entries.map(\.window)) == ["five_hour", "seven_day", "weekly_scoped|Fable|"])
        let byWindow = Dictionary(uniqueKeysWithValues: report.fitted.map { ($0.window, $0) })
        let five = try #require(byWindow["five_hour"])
        #expect(abs((five.modelRates[opus] ?? 0) - 0.16) < 1e-6)
        #expect(abs((five.modelRates[fable] ?? 0) - 0.4) < 1e-6)
        #expect(abs(five.interceptPerHour - 0.02) < 1e-6)
        let week = try #require(byWindow["seven_day"])
        #expect(abs((week.modelRates[opus] ?? 0) - 0.045) < 1e-6)
        let cap = try #require(byWindow["weekly_scoped|Fable|"])
        #expect(abs((cap.modelRates[fable] ?? 0) - 0.9) < 1e-6)
        #expect((cap.modelRates[opus] ?? 0) < 1e-9)
    }

    @Test("fits every window, stores one row each, and a same-day refit replaces them")
    func upsertIsIdempotent() async throws {
        let container = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try seed(ModelContext(container))
        let worker = SpendMeterFitWorker(modelContainer: container)

        let first = try #require(try await worker.runIfDue(now: fitDay, timeZone: utc))
        try check(first)
        let rows = try ModelContext(container).fetch(FetchDescriptor<SpendMeterFit>(sortBy: [SortDescriptor(\.fitKey)]))
        #expect(rows.count == 3)
        func values(_ rows: [SpendMeterFit]) -> [String] {
            rows.map { "\($0.fitKey) \($0.modelRatesJSON) \($0.pooledRate) \($0.r2) \($0.interceptPerHour)" }
        }
        let snapshot = values(rows)

        // Already fitted today: nothing to do.
        #expect(try await worker.runIfDue(now: fitDay.addingTimeInterval(3600), timeZone: utc) == nil)

        // Forced refit, same day: same rows, same values.
        _ = try await worker.refit(now: fitDay.addingTimeInterval(7200), timeZone: utc)
        let again = try ModelContext(container).fetch(FetchDescriptor<SpendMeterFit>(sortBy: [SortDescriptor(\.fitKey)]))
        #expect(again.count == 3)
        #expect(values(again) == snapshot)
        let stored = try #require(again.first { $0.window == "five_hour" })
        #expect(stored.fittedDay == "2026-10-15")
        #expect(stored.method == "nnls-hourly-v1")
        #expect(abs((stored.modelRates[opus] ?? 0) - 0.16) < 1e-6)

        // The next day adds rows: history is kept.
        _ = try await worker.runIfDue(now: fitDay.addingTimeInterval(86_400), timeZone: utc)
        let history = try ModelContext(container).fetch(FetchDescriptor<SpendMeterFit>())
        #expect(history.count == 6)
    }

    @Test("an on-disk store reads the limit tables through sqlite and gets the same fit")
    func rawReadMatchesSwiftData() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spend-fit-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let disk = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                      configurations: ModelConfiguration(url: url))
        try seed(ModelContext(disk))
        let memory = try ModelContainer(for: Schema(PacerStore.allModelTypes),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try seed(ModelContext(memory))

        let onDisk = try await SpendMeterFitWorker(modelContainer: disk).refit(now: fitDay, timeZone: utc, persist: false)
        let inMemory = try await SpendMeterFitWorker(modelContainer: memory).refit(now: fitDay, timeZone: utc, persist: false)
        try check(onDisk)
        #expect(onDisk.readingRows == inMemory.readingRows)
        #expect(onDisk.entries == inMemory.entries)
    }
}
