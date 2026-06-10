import Foundation

/// Shared trend estimator for Pacer's projections.
///
/// Every projection Pacer shows (end-of-day cost, rate-limit ETA, monthly
/// total) historically extrapolated the *current slope* flat — a naive
/// first-derivative line that overshoots during a ramp-up and undershoots
/// during a wind-down. This estimator is the one shared replacement: a
/// **recency-weighted slope** plus a **damped, clamped acceleration**
/// (2nd-derivative) term, with forward-projection helpers.
///
/// Three design choices keep it honest, in priority order:
///
/// - **Recency weighting.** Samples are weighted by an exponential kernel
///   with a half-life, so an old spike inside the lookback window can't
///   tilt the whole line — the fit bends toward what's happening *now*.
///   This fixes the "a stale burst distorts the slope" failure of the
///   first-to-last linear model in `BurnRate`.
/// - **A linear slope, not a parabola's endpoint derivative.** `level` and
///   `slope` come from a recency-weighted *linear* fit. A least-squares
///   parabola's instantaneous slope at the most-recent sample swings wildly
///   with curvature (a "ramp then flat" series reads as *decelerating into a
///   decline*, projecting the value negative) — too fragile for a displayed
///   number. The linear slope is boundary-stable and never reverses.
/// - **Damped, clamped acceleration.** The 2nd derivative is real signal
///   during a ramp, but a raw quadratic explodes ("$40k by midnight") or, at
///   a boundary, reverses. We take the curvature from the quadratic fit but
///   feed it forward only as a *bounded bend*: the instantaneous
///   acceleration is decayed with `τ` (`accel(h) = accel₀·e^(−h/τ)`, so the
///   slope saturates instead of the value exploding), and the acceleration's
///   total slope-boost is *clamped* to `maxAccelSlopeFraction · |slope|`. So
///   a hot 2nd derivative can bend the projection up to ~2× the linear slope
///   (or flatten it), but can never run away or flip its sign. `τ` and the
///   clamp fraction are the knobs to tune against real data.
///
/// The estimator is pure and `Date`-free internally — it takes `now` as a
/// parameter and works in hours relative to it — so it unit-tests exactly
/// like `BurnRate` / `MonthlyForecast`. It is value-agnostic: `value` can be
/// cumulative used-percentage (rate-limit), cumulative cost (end-of-day /
/// monthly), or anything trending in time. Slope is reported per hour;
/// callers working in days multiply by 24, or — far cleaner — use the
/// `Date`-based projection helpers and never hand-convert.
public enum TrendEstimator {

    /// One observation: a value at a wall-clock instant. Mirrors the
    /// `BurnRate.Sample` value-type pattern so the pure math never imports
    /// SwiftData. `value` is whatever quantity the caller is trending —
    /// the estimator does not care about units.
    public struct Sample: Equatable, Sendable {
        public let at: Date
        public let value: Double

        public init(at: Date, value: Double) {
            self.at = at
            self.value = value
        }
    }

    /// Knobs, bundled so call sites don't thread positional args. Defaults
    /// are deliberately generic; each consumer (burn-rate, end-of-day,
    /// monthly) passes time-scales appropriate to its series, and tests
    /// pin their own.
    public struct Parameters: Sendable {
        /// Reference "now". Past samples sit at negative hours; future
        /// samples (clock skew) are dropped.
        public var now: Date
        /// Minimum samples required to fit. Two is enough for a slope but
        /// three excludes a single transient-spike artifact and is the
        /// floor for any acceleration signal — matches `BurnRate.minSamples`.
        public var minSamples: Int
        /// Minimum wall-clock span across the considered samples. Without
        /// it, two samples 30s apart extrapolate wild numbers from noise.
        public var minSpanSeconds: TimeInterval
        /// Optional age cutoff: samples older than this (relative to `now`)
        /// are ignored. `nil` keeps the whole series. Mirrors
        /// `BurnRate.lookbackSeconds`.
        public var lookbackSeconds: TimeInterval?
        /// Exponential recency-weight half-life. A sample this old counts
        /// half as much as one at `now`; one twice this old, a quarter; and
        /// so on. Smaller = more responsive to recent behavior, noisier;
        /// larger = smoother, slower to react. This is also the internal
        /// time-scale, so the fit stays well-conditioned whether the series
        /// spans minutes (burn-rate) or weeks (monthly).
        public var recencyHalfLifeSeconds: TimeInterval
        /// Damping time-constant `τ` (in seconds) for the acceleration term
        /// in the forward projection. The instantaneous acceleration decays
        /// as `e^(−h/τ)`, so the slope saturates rather than the value
        /// exploding. Set in the same ballpark as the projection horizon so
        /// the bend is felt early but bounded.
        public var dampingTauSeconds: TimeInterval
        /// Clamp on the acceleration's *total* slope-boost, as a fraction of
        /// `|slope|`. The asymptotic slope added by the acceleration term is
        /// limited to `maxAccelSlopeFraction · |slope|`. At `1.0` the
        /// projection's slope can at most double (for a positive
        /// acceleration) or flatten to zero (for a negative one) — it can
        /// never reverse. Set `0` to disable acceleration entirely (pure
        /// recency-weighted linear — a clean baseline). Set `.infinity` to
        /// trust the raw curvature with no clamp (diagnostics only). Values
        /// ≤ 1 keep the forward projection monotone for a positive slope,
        /// which the ETA bisection relies on.
        public var maxAccelSlopeFraction: Double

        public init(
            now: Date = Date(),
            minSamples: Int = 3,
            minSpanSeconds: TimeInterval = 5 * 60,
            lookbackSeconds: TimeInterval? = nil,
            recencyHalfLifeSeconds: TimeInterval = 60 * 60,
            dampingTauSeconds: TimeInterval = 2 * 60 * 60,
            maxAccelSlopeFraction: Double = 1.0
        ) {
            self.now = now
            self.minSamples = minSamples
            self.minSpanSeconds = minSpanSeconds
            self.lookbackSeconds = lookbackSeconds
            self.recencyHalfLifeSeconds = recencyHalfLifeSeconds
            self.dampingTauSeconds = dampingTauSeconds
            self.maxAccelSlopeFraction = maxAccelSlopeFraction
        }
    }

    /// The fitted trend at `now`, with forward-projection helpers baked in
    /// so callers never re-derive the damping math.
    public struct Fit: Equatable, Sendable {
        /// Estimated value at `now` (the recency-weighted linear fit
        /// evaluated at t = 0). Not necessarily the last raw sample — the
        /// weighted fit smooths it.
        public let level: Double
        /// Recency-weighted slope at `now`, in value-units per hour, from
        /// the linear fit. Boundary-stable: it never reverses from
        /// curvature the way a parabola's endpoint derivative does.
        public let slopePerHour: Double
        /// Recency-weighted second derivative, in value-units per hour²,
        /// from the quadratic fit. Raw/unclamped — the clamp and damping are
        /// applied only in the forward projection. This is the value the
        /// acceleration *warning* keys off. Zero when only a linear fit was
        /// possible.
        public let accelPerHourSq: Double
        /// Samples that survived filtering and fed the fit.
        public let sampleCount: Int
        /// Wall-clock span of those samples, in seconds.
        public let spanSeconds: TimeInterval
        /// `τ` used for the damped forward model, in hours.
        public let dampingTauHours: Double
        /// Clamp fraction carried from `Parameters` so the projection is
        /// self-contained (see `Parameters.maxAccelSlopeFraction`).
        public let maxAccelSlopeFraction: Double

        /// The acceleration actually used in the forward projection after
        /// clamping its asymptotic slope-boost to `maxAccelSlopeFraction ·
        /// |slope|`. Exposed so callers can see how much of the raw
        /// curvature survived the clamp.
        public var effectiveAccelPerHourSq: Double {
            guard dampingTauHours > 0 else { return 0 }
            let maxBoost = maxAccelSlopeFraction * abs(slopePerHour)
            guard maxBoost.isFinite else { return accelPerHourSq }
            let cap = maxBoost / dampingTauHours
            return max(-cap, min(cap, accelPerHourSq))
        }

        /// Damped, clamped extrapolation of the value `hours` into the
        /// future:
        /// `level + slope·h + accelₑ·τ·(h − τ·(1 − e^(−h/τ)))`
        /// where `accelₑ` is `effectiveAccelPerHourSq`.
        ///
        /// The instantaneous acceleration is `accelₑ·e^(−h/τ)`, so the slope
        /// rises from `slope` and saturates at `slope + accelₑ·τ` (itself
        /// clamped to within `±maxAccelSlopeFraction · |slope|`). The value
        /// therefore grows at most linearly far out — a hot ramp bends the
        /// projection up early without the quadratic blow-up, and a taper
        /// flattens it without diving negative. Negative `hours` (reading the
        /// recent past) is allowed but the damping is tuned for the forward
        /// direction.
        public func projectedValue(afterHours hours: Double) -> Double {
            let linear = level + slopePerHour * hours
            let accel = effectiveAccelPerHourSq
            guard dampingTauHours > 0, accel != 0 else { return linear }
            let tau = dampingTauHours
            let accelTerm = accel * tau * (hours - tau * (1 - exp(-hours / tau)))
            return linear + accelTerm
        }

        /// Damped value at a wall-clock `date`, given the `now` the fit was
        /// built against.
        public func projectedValue(at date: Date, now: Date) -> Double {
            projectedValue(afterHours: date.timeIntervalSince(now) / 3600.0)
        }

        /// Hours from `now` until the projected trajectory first reaches
        /// `target`, searched within `[0, maxHorizonHours]`. Returns `0` when
        /// the level already meets the target; `nil` when the trajectory
        /// never reaches `target` inside the horizon (flat/falling trend).
        ///
        /// Found by bisection, which is robust because the clamped projection
        /// is monotone for a positive slope (with `maxAccelSlopeFraction ≤ 1`).
        public func crossingHours(
            target: Double,
            maxHorizonHours: Double
        ) -> Double? {
            guard maxHorizonHours > 0 else { return nil }
            if projectedValue(afterHours: 0) >= target { return 0 }
            if projectedValue(afterHours: maxHorizonHours) < target { return nil }
            var lo = 0.0
            var hi = maxHorizonHours
            // 60 halvings drives the bracket below any meaningful time
            // resolution regardless of horizon.
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                if projectedValue(afterHours: mid) < target {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            return hi
        }

        /// Wall-clock date the projected trajectory first reaches `target`,
        /// or `nil` (see `crossingHours`). `maxHorizon` bounds the search.
        public func crossingDate(
            target: Double,
            now: Date,
            maxHorizon: TimeInterval
        ) -> Date? {
            guard let hours = crossingHours(
                target: target,
                maxHorizonHours: maxHorizon / 3600.0
            ) else { return nil }
            return now.addingTimeInterval(hours * 3600.0)
        }
    }

    /// Fit the trend to a `(time, value)` series.
    ///
    /// - Parameters:
    ///   - samples: observations of one quantity. Order doesn't matter
    ///     (sorted internally). Future samples and (if `lookbackSeconds` is
    ///     set) over-age samples are dropped.
    ///   - parameters: knobs (see `Parameters`).
    /// - Returns: a `Fit`, or `nil` when there isn't enough signal —
    ///   fewer than `minSamples` after filtering, a span shorter than
    ///   `minSpanSeconds`, or a degenerate (collinear-in-time) design.
    public static func fit(
        samples: [Sample],
        parameters: Parameters
    ) -> Fit? {
        let now = parameters.now
        let halfLifeHours = parameters.recencyHalfLifeSeconds / 3600.0
        guard halfLifeHours > 0 else { return nil }

        let cutoff = parameters.lookbackSeconds
            .map { now.addingTimeInterval(-$0) }
        let recent = samples
            .filter { sample in
                sample.at <= now && cutoff.map { sample.at >= $0 } ?? true
            }
            .sorted { $0.at < $1.at }

        guard recent.count >= parameters.minSamples,
              let first = recent.first,
              let last = recent.last
        else { return nil }

        let spanSeconds = last.at.timeIntervalSince(first.at)
        guard spanSeconds >= parameters.minSpanSeconds else { return nil }

        // Work in half-life units (u = t / halfLife) so the design matrix
        // stays well-conditioned whether the series spans minutes or weeks.
        // t is hours-relative-to-now and ≤ 0 for past samples; u ≤ 0 too.
        // Weight = 0.5^(age / halfLife) = 2^u, which is 1 at now and decays
        // into the past.
        struct Row { let u: Double; let v: Double; let w: Double }
        let rows: [Row] = recent.map { s in
            let tHours = s.at.timeIntervalSince(now) / 3600.0
            let u = tHours / halfLifeHours
            return Row(u: u, v: s.value, w: pow(2.0, u))
        }

        // Weighted power sums for the normal equations of v = A + B·u (+ C·u²).
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var t0 = 0.0, t1 = 0.0, t2 = 0.0
        for r in rows {
            let w = r.w, u = r.u, u2 = r.u * r.u
            s0 += w
            s1 += w * u
            s2 += w * u2
            s3 += w * u2 * u
            s4 += w * u2 * u2
            t0 += w * r.v
            t1 += w * r.v * u
            t2 += w * r.v * u2
        }

        // Level + slope from the boundary-stable linear fit. Required — a
        // failure here (degenerate time design) means no usable trend.
        guard let lin = solveLinear(s0: s0, s1: s1, s2: s2, t0: t0, t1: t1) else {
            return nil
        }
        let level = lin.a
        let slopePerHour = lin.b / halfLifeHours

        // Acceleration from the quadratic curvature, when there's enough
        // distinct-time signal for it; otherwise zero (pure linear).
        var accelPerHourSq = 0.0
        let distinctTimes = Set(rows.map { $0.u }).count
        if distinctTimes >= 3,
           let q = solveQuadratic(s0: s0, s1: s1, s2: s2, s3: s3, s4: s4,
                                  t0: t0, t1: t1, t2: t2) {
            accelPerHourSq = 2 * q.c / (halfLifeHours * halfLifeHours)
        }

        return Fit(
            level: level,
            slopePerHour: slopePerHour,
            accelPerHourSq: accelPerHourSq,
            sampleCount: recent.count,
            spanSeconds: spanSeconds,
            dampingTauHours: parameters.dampingTauSeconds / 3600.0,
            maxAccelSlopeFraction: parameters.maxAccelSlopeFraction
        )
    }

    // MARK: - Small dense solvers

    /// Solve the 3×3 weighted normal equations for a quadratic via Cramer's
    /// rule. Returns nil when the system is near-singular (ill-conditioned
    /// design) so the caller can fall back to linear-only.
    private static func solveQuadratic(
        s0: Double, s1: Double, s2: Double, s3: Double, s4: Double,
        t0: Double, t1: Double, t2: Double
    ) -> (a: Double, b: Double, c: Double)? {
        // [ s0 s1 s2 ][a]   [t0]
        // [ s1 s2 s3 ][b] = [t1]
        // [ s2 s3 s4 ][c]   [t2]
        let det = det3(s0, s1, s2, s1, s2, s3, s2, s3, s4)
        guard abs(det) > epsilon(of: [s0, s2, s4]) else { return nil }
        let a = det3(t0, s1, s2, t1, s2, s3, t2, s3, s4) / det
        let b = det3(s0, t0, s2, s1, t1, s3, s2, t2, s4) / det
        let c = det3(s0, s1, t0, s1, s2, t1, s2, s3, t2) / det
        return (a, b, c)
    }

    /// Solve the 2×2 weighted normal equations for a line.
    private static func solveLinear(
        s0: Double, s1: Double, s2: Double,
        t0: Double, t1: Double
    ) -> (a: Double, b: Double)? {
        // [ s0 s1 ][a]   [t0]
        // [ s1 s2 ][b] = [t1]
        let det = s0 * s2 - s1 * s1
        guard abs(det) > epsilon(of: [s0, s2]) else { return nil }
        let a = (t0 * s2 - t1 * s1) / det
        let b = (s0 * t1 - s1 * t0) / det
        return (a, b)
    }

    private static func det3(
        _ a: Double, _ b: Double, _ c: Double,
        _ d: Double, _ e: Double, _ f: Double,
        _ g: Double, _ h: Double, _ i: Double
    ) -> Double {
        a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    }

    /// Relative singularity threshold: scale the floor by the magnitude of
    /// the design's diagonal so the test is stable across value/time scales.
    private static func epsilon(of diagonals: [Double]) -> Double {
        let scale = diagonals.reduce(0) { $0 + abs($1) }
        return 1e-12 * max(1, scale * scale)
    }
}
