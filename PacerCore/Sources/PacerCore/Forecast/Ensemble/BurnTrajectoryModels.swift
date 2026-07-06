import Foundation

/// The curve-fit candidates for `BurnTrajectory`. Each fits the cycle-so-far
/// and returns a closure projecting usage% at any future date. Ordered by
/// `complexity` (the selector's tie-breaker), simplest first — which matches
/// the real-data finding that plain linear is hard to beat.
extension BurnTrajectory {

    /// Least-squares line over a recent window (a fraction of the cycle).
    /// Reacts to the current rate; the 7-day window's best fit on real data.
    public struct LinearRecent: Model {
        public let id = "linear-recent"
        public let complexity = 1
        /// Recent window as a fraction of the cycle duration (from
        /// `EngineParams`, the versioned, harness-sweepable set).
        public let lookbackFraction: Double
        public init(lookbackFraction: Double = EngineParams.current.linearRecentLookbackFraction) {
            self.lookbackFraction = lookbackFraction
        }

        public func fit(_ cycle: PartialCycle) -> (@Sendable (Date) -> Double)? {
            let cutoff = cycle.nowHours - cycle.durationHours * lookbackFraction
            let pts = cycle.samples.filter { cycle.hours($0.at) >= cutoff }
            let used = pts.count >= 2 ? pts : cycle.samples
            guard used.count >= 2,
                  let line = Self.line(used.map { (cycle.hours($0.at), $0.usedPercentage) })
            else { return nil }
            let cycleStart = cycle.cycleStart
            return { date in line.slope * (date.timeIntervalSince(cycleStart) / 3600) + line.intercept }
        }

        static func line(_ points: [(Double, Double)]) -> (slope: Double, intercept: Double)? {
            let n = Double(points.count)
            let sx = points.reduce(0) { $0 + $1.0 }, sy = points.reduce(0) { $0 + $1.1 }
            let sxx = points.reduce(0) { $0 + $1.0 * $1.0 }, sxy = points.reduce(0) { $0 + $1.0 * $1.1 }
            let det = n * sxx - sx * sx
            guard abs(det) > 1e-9 else { return nil }
            return ((n * sxy - sx * sy) / det, (sy * sxx - sx * sxy) / det)
        }
    }

    /// Recency-weighted linear via `TrendEstimator` (acceleration off). Smooths
    /// out a single busy hour; the 5-hour window's best fit on real data.
    public struct RecencyWeighted: Model {
        public let id = "recency-weighted"
        public let complexity = 2
        public init() {}
        public func fit(_ cycle: PartialCycle) -> (@Sendable (Date) -> Double)? {
            guard let estimate = TrendEstimator.fit(
                samples: cycle.samples.map { .init(at: $0.at, value: $0.usedPercentage) },
                parameters: .init(
                    now: cycle.now, minSamples: 3,
                    minSpanSeconds: max(300, cycle.durationHours * 3600 * 0.05),
                    recencyHalfLifeSeconds: cycle.durationHours * 3600 * EngineParams.current.recencyHalfLifeFraction,
                    dampingTauSeconds: 3600, maxAccelSlopeFraction: 0))
            else { return nil }
            let now = cycle.now
            return { date in estimate.projectedValue(at: date, now: now) }
        }
    }

    /// Recency-weighted with a damped acceleration term — lets the projection
    /// bend when the recent curve is genuinely accelerating, bounded so it
    /// can't run away (see `TrendEstimator`).
    public struct DampedAcceleration: Model {
        public let id = "damped-acceleration"
        public let complexity = 4
        public init() {}
        public func fit(_ cycle: PartialCycle) -> (@Sendable (Date) -> Double)? {
            let remaining = max(3600, cycle.resetsAt.timeIntervalSince(cycle.now))
            guard let estimate = TrendEstimator.fit(
                samples: cycle.samples.map { .init(at: $0.at, value: $0.usedPercentage) },
                parameters: .init(
                    now: cycle.now, minSamples: 4,
                    minSpanSeconds: max(300, cycle.durationHours * 3600 * 0.05),
                    recencyHalfLifeSeconds: cycle.durationHours * 3600 * EngineParams.current.recencyHalfLifeFraction,
                    dampingTauSeconds: remaining, maxAccelSlopeFraction: 1))
            else { return nil }
            let now = cycle.now
            return { date in estimate.projectedValue(at: date, now: now) }
        }
    }

    /// Saturating exponential `L·(1 − e^(−k·s))` — captures usage that
    /// decelerates as a window fills or rolls old usage off. Fit by a grid over
    /// the ceiling `L` with a closed-form `k` per `L` (linear through the
    /// origin in `−ln(1 − y/L)` vs `s`), picking the lowest original-space SSE.
    public struct Saturating: Model {
        public let id = "saturating"
        public let complexity = 3
        public init() {}

        public func fit(_ cycle: PartialCycle) -> (@Sendable (Date) -> Double)? {
            let s = cycle.samples.map { cycle.hours($0.at) }
            let y = cycle.samples.map { $0.usedPercentage }
            guard s.count >= 3, let yMax = y.max(), yMax > 0 else { return nil }

            var best: (sse: Double, L: Double, k: Double)?
            var ceiling = 1.05
            while ceiling <= 2.5 {
                let L = max(yMax * ceiling, yMax + 1)
                var sk = 0.0, ss = 0.0
                for i in s.indices where y[i] > 0 && y[i] < L * 0.999 {
                    let z = -log(1 - y[i] / L)
                    sk += s[i] * z; ss += s[i] * s[i]
                }
                if ss > 1e-9 {
                    let k = sk / ss
                    if k > 0 {
                        var sse = 0.0
                        for i in s.indices {
                            let pred = L * (1 - exp(-k * s[i]))
                            sse += (pred - y[i]) * (pred - y[i])
                        }
                        if best == nil || sse < best!.sse { best = (sse, L, k) }
                    }
                }
                ceiling += 0.05
            }
            guard let fit = best else { return nil }
            let cycleStart = cycle.cycleStart
            return { date in
                let s = date.timeIntervalSince(cycleStart) / 3600
                return fit.L * (1 - exp(-fit.k * s))
            }
        }
    }
}
