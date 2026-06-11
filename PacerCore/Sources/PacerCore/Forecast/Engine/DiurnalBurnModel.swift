import Foundation

/// Diurnal × weekday forward-rate model for rate-limit windows — the round-2
/// flagship, and the answer to "a linear fit is OK overall but a sloped sine
/// would track the day/night oscillation across the 7-day window."
///
/// A linear projection at 11pm Friday runs the *daytime* burn rate straight
/// through an idle night and an idle weekend, over-projecting the 7-day window
/// by ~2×. This model instead learns the *shape* of the accrual rate — how fast
/// utilisation climbs as a function of (weekday, hour-of-day) — and **integrates
/// that shape forward** from now to the window reset. Remaining hours that are
/// typically idle (overnight, weekends — a 7× drop for this user) contribute
/// almost nothing, so the projection bends where a line can't.
///
/// Only the *shape* is learned (relative rates); a single per-cycle **level**
/// scalar rescales it to match the partial trajectory observed so far. That's
/// one degree of freedom fit to the data — it cannot overfit the curve — while
/// the rich shape comes from the whole history (and an optional activity-grid
/// prior the thin per-cell rates are empirical-Bayes-shrunk toward). Conforms to
/// `BurnTrajectory.Model`, so it competes in the existing burn tournament and is
/// selected only when it actually beats the simpler fits on the user's cycles.
///
/// Honest scope: the win is specific to the **7-day** window (a 5h window rarely
/// spans a day/night or weekend boundary, so there's no idle structure to
/// exploit — there it ties the simple baselines and shouldn't be selected). And
/// it rests on few completed 7-day cycles, so it ships with wide bands and firms
/// up as cycles accrue.
public struct DiurnalBurnModel: BurnTrajectory.Model {
    public let id = "diurnal-rate"
    public let complexity = 3

    /// Relative accrual-rate shape, `[weekday 0=Sun…6=Sat][hour 0…23]`. Scale is
    /// irrelevant — the per-cycle level absorbs it — only the cross-hour /
    /// cross-weekday ratios matter.
    public let rate: [[Double]]
    public let calendar: Calendar
    /// Forward-integration step (smaller = more exact, 10 min is plenty).
    public let stepSeconds: TimeInterval

    public init(rate: [[Double]], calendar: Calendar = .current, stepSeconds: TimeInterval = 600) {
        self.rate = rate
        self.calendar = calendar
        self.stepSeconds = stepSeconds
    }

    public func fit(_ cycle: BurnTrajectory.PartialCycle) -> (@Sendable (Date) -> Double)? {
        let used = cycle.usedNow
        guard used > 0 else { return nil }
        // Expected (unscaled) accrual over the observed span. If the model expects
        // ~no activity where the user actually burned, it can't explain the cycle.
        let observed = Self.integrate(table: rate, calendar: calendar,
                                      from: cycle.cycleStart, to: cycle.now, step: stepSeconds)
        guard observed > 0 else { return nil }
        let level = used / observed              // the single fitted degree of freedom
        let table = rate, cal = calendar, step = stepSeconds
        let origin = cycle.now, base = used
        return { date in
            guard date > origin else { return base }
            return base + level * Self.integrate(table: table, calendar: cal, from: origin, to: date, step: step)
        }
    }

    /// ∫ shape dt over [a, b] via fixed steps, bucketing each step by its
    /// midpoint's (weekday, hour).
    static func integrate(table: [[Double]], calendar: Calendar, from a: Date, to b: Date, step: TimeInterval) -> Double {
        guard b > a, step > 0 else { return 0 }
        var total = 0.0
        var t = a
        while t < b {
            let dt = min(step, b.timeIntervalSince(t))
            let mid = t.addingTimeInterval(dt / 2)
            let wd = calendar.component(.weekday, from: mid) - 1     // 0…6
            let h = calendar.component(.hour, from: mid)             // 0…23
            if wd >= 0, wd < 7, h >= 0, h < 24 { total += table[wd][h] * dt }
            t = t.addingTimeInterval(step)
        }
        return total
    }

    // MARK: - Building the rate table

    /// Learn the relative `[7][24]` accrual-rate shape from past cycles' sample-
    /// to-sample increments, empirical-Bayes-shrunk toward an optional activity
    /// prior (the live diurnal shape from the activity grid) so thin per-cell
    /// rates borrow the prior's shape until enough cycles accumulate.
    ///
    /// Both observed and prior shapes are normalised to unit mean before blending
    /// (they're in different units — pp/sec vs P(active)); the per-cycle level
    /// restores absolute scale at projection time. `priorPseudocount` is how many
    /// observed increments a cell needs before it trusts itself over the prior.
    public static func rateTable(
        cycles: [BurnTrajectory.Cycle],
        calendar: Calendar = .current,
        prior: [[Double]]? = nil,
        priorPseudocount: Double = 6
    ) -> [[Double]] {
        var sum = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        var cnt = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        for cycle in cycles {
            let s = cycle.samples.sorted { $0.at < $1.at }
            guard s.count >= 2 else { continue }
            for i in 1..<s.count {
                let dt = s[i].at.timeIntervalSince(s[i - 1].at)
                guard dt > 0 else { continue }
                let r = max(0, s[i].usedPercentage - s[i - 1].usedPercentage) / dt
                let mid = s[i - 1].at.addingTimeInterval(dt / 2)
                let wd = calendar.component(.weekday, from: mid) - 1
                let h = calendar.component(.hour, from: mid)
                guard wd >= 0, wd < 7, h >= 0, h < 24 else { continue }
                sum[wd][h] += r; cnt[wd][h] += 1
            }
        }

        // Observed cell means, normalised to unit mean over populated cells.
        var obs = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        var populated: [Double] = []
        for wd in 0..<7 { for h in 0..<24 where cnt[wd][h] > 0 {
            obs[wd][h] = sum[wd][h] / cnt[wd][h]; populated.append(obs[wd][h])
        }}
        let obsMean = populated.isEmpty ? 0 : populated.reduce(0, +) / Double(populated.count)
        if obsMean > 0 { for wd in 0..<7 { for h in 0..<24 { obs[wd][h] /= obsMean } } }

        // Prior shape, normalised to unit mean (uniform if absent).
        let priorShape = Self.normalizedPrior(prior)

        var table = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        for wd in 0..<7 { for h in 0..<24 {
            let n = cnt[wd][h]
            let w = n / (n + priorPseudocount)          // trust the cell as it fills in
            let cell = n > 0 ? obs[wd][h] : 0
            table[wd][h] = w * cell + (1 - w) * priorShape[wd][h]
        }}
        return table
    }

    static func normalizedPrior(_ prior: [[Double]]?) -> [[Double]] {
        guard let prior, prior.count == 7, prior.allSatisfy({ $0.count == 24 }) else {
            return [[Double]](repeating: [Double](repeating: 1, count: 24), count: 7)
        }
        let flat = prior.flatMap { $0 }
        let m = flat.reduce(0, +) / Double(flat.count)
        guard m > 0 else { return [[Double]](repeating: [Double](repeating: 1, count: 24), count: 7) }
        return prior.map { row in row.map { $0 / m } }
    }
}
