import Foundation

// `research/arena/kit/detq.py`, in Swift: a model's forecast as exact
// quantiles, before any path is drawn. Sample paths cannot be matched across
// languages (different random streams); these can, and in Pacer they are
// the forecast itself: a port answers with the exact quantiles of the
// distribution the Python's draws sample.
//
// Here: the shared pieces (`weighted_type1`, `read_sorted`, the levels) and
// spend-decay's (`spend_decay_parts`, `spend_decay_quantiles`). The
// calibration layer's entry point (`calib_quantiles`) is in `Calib.swift`.

/// A memo cell, so a derivation that answers nil is memoized too (a nil
/// stored in `ArenaMemo`'s `[String: Any]` would read back as absent).
public struct KitBox<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

public enum KitDetQ {
    /// `LEVELS_OUT`: the fixtures' levels.
    public static let levelsOut: [Double] = [0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95]
    /// `CURVE_LEVELS`: (i + 0.5) / 200, the comonotone curves the
    /// calibration layer applies to.
    public static let curveLevels: [Double] = (0..<200).map { (Double($0) + 0.5) / 200 }
    /// The levels a deterministic port answers at: the 200 curve levels
    /// (exactly what the calibration layer reads from its child) and the
    /// fixtures' seven (so the median and the 5–95 % range a surface reads
    /// are the exact type-1 values, not an interpolation between curve
    /// levels). None of the seven is a curve level, so this is strictly
    /// increasing.
    public static let forecastLevels: [Double] = (curveLevels + levelsOut).sorted()
    public static let type1Tol = 1e-9

    /// `weighted_type1`: per column of `values` (`[n][G]`, one row per
    /// path), the smallest value whose cumulative normalized weight (values
    /// sorted ascending, ties in row order) reaches the level, within
    /// `type1Tol`. `[levels][G]`.
    public static func weightedType1(_ values: [[Double]], weights: [Double], levels: [Double]) -> [[Double]] {
        let n = values.count
        guard n > 0, let g = values.first?.count else { return levels.map { _ in [] } }
        let total = weights.reduce(0, +)
        let p = weights.map { $0 / total }
        var out = [[Double]](repeating: [Double](repeating: 0, count: g), count: levels.count)
        var order = Array(0..<n)
        var cw = [Double](repeating: 0, count: n)
        for j in 0..<g {
            // np.argsort(kind="stable").
            order.sort { values[$0][j] != values[$1][j] ? values[$0][j] < values[$1][j] : $0 < $1 }
            var s = 0.0
            for (i, o) in order.enumerated() { s += p[o]; cw[i] = s }
            for (li, lv) in levels.enumerated() {
                // np.searchsorted(cw, lv - tol, "left"), capped at n − 1.
                let x = lv - type1Tol
                var lo = 0, hi = n
                while lo < hi { let mid = (lo + hi) >> 1; if cw[mid] < x { lo = mid + 1 } else { hi = mid } }
                out[li][j] = values[order[min(lo, n - 1)]][j]
            }
        }
        return out
    }

    /// `read_sorted` on one sorted column: the value at `level`, position
    /// level · n − 0.5, linear between order statistics, clamped to the ends.
    @inline(__always)
    public static func readSorted(_ s: [Double], _ level: Double) -> Double {
        let n = s.count
        let pos = min(max(level * Double(n) - 0.5, 0), Double(n - 1))
        let i0 = Int(pos.rounded(.down))
        let i1 = min(i0 + 1, n - 1)
        let a = pos - Double(i0)
        return s[i0] * (1.0 - a) + s[i1] * a
    }

    /// `np.interp`, as numpy computes it: `slope · (x − x_j) + y_j`, the
    /// knot's own value on a knot, flat beyond the ends.
    public static func npInterp(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        let n = xs.count
        if x > xs[n - 1] { return ys[n - 1] }
        if x < xs[0] { return ys[0] }
        if x == xs[n - 1] { return ys[n - 1] }
        var lo = 0, hi = n - 1
        while hi - lo > 1 { let mid = (lo + hi) >> 1; if xs[mid] <= x { lo = mid } else { hi = mid } }
        if xs[lo] == x { return ys[lo] }
        let slope = (ys[lo + 1] - ys[lo]) / (xs[lo + 1] - xs[lo])
        return slope * (x - xs[lo]) + ys[lo]
    }

    /// `np.median`: the middle value, or the mean of the two middle ones.
    public static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        guard n > 0 else { return .nan }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// `np.nanargmin`: the first minimum, NaN ignored.
    public static func nanArgmin(_ xs: [Double]) -> Int {
        var best = -1
        for (i, x) in xs.enumerated() where !x.isNaN && (best < 0 || x < xs[best]) { best = i }
        return max(best, 0)
    }

    /// `scipy.special.ndtri`: the standard normal quantile. Acklam's
    /// rational approximation, then one Halley step on `erfc`, which brings
    /// it to full double precision (scipy's Cephes value to a few ulps).
    public static func ndtri(_ p: Double) -> Double {
        if p <= 0 { return -.infinity }
        if p >= 1 { return .infinity }
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let pLow = 0.02425
        var x: Double
        if p < pLow {
            let q = (-2 * log(p)).squareRoot()
            x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= 1 - pLow {
            let q = p - 0.5, r = q * q
            x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
                / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = (-2 * log(1 - p)).squareRoot()
            x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        for _ in 0..<2 {
            let e = 0.5 * erfc(-x / 2.0.squareRoot()) - p
            let u = e * (2 * Double.pi).squareRoot() * exp(x * x / 2)
            x -= u / (1 + x * u / 2)
        }
        return x
    }

    // MARK: - spend-decay

    /// `spend_decay_parts`' dict.
    public struct SpendDecayParts: Sendable {
        public enum Mode: String, Sendable { case flat, lognormal, cases }
        public var kind: String
        public var latest: Double
        public var latestT: Millis
        public var start: Millis
        public var reset: Millis
        public var mode: Mode = .flat
        public var rates: [Double] = []
        public var weak = false
        public var r2 = 0.0
        public var state: SpendDecayModel.State?
        public var uNow = 0.0
        public var tauH = 0.0
        public var centre: [Double] = []
        public var nCases = 0
        public var picked = 0
        /// The picked cuts' error trajectories on the grid, `[picked][G]`.
        public var errors: [[Double]] = []

        public init(kind: String, latest: Double, latestT: Millis, start: Millis, reset: Millis) {
            self.kind = kind; self.latest = latest; self.latestT = latestT; self.start = start; self.reset = reset
        }
    }

    /// `spend_decay_quantiles`, for one target: exact. The model draws each
    /// path's error trajectory uniformly from the picked past cuts, so its
    /// distribution is those cuts' paths with equal weight, each kept within
    /// [the reading, 100] and made non-decreasing: their equal-weight type-1
    /// quantiles. The fallback with too few cuts scales the predicted rise
    /// by exp(N(0, 0.6²)): every path is a monotone function of that one
    /// factor, so the quantile at α is the path at the factor's α-quantile.
    /// With no conversion, the reading, flat. `[levels][G]`.
    public static func spendDecayQuantiles(_ p: SpendDecayParts, gridCount g: Int, levels: [Double]) -> [[Double]] {
        let latest = p.latest
        switch p.mode {
        case .flat:
            return levels.map { _ in [Double](repeating: latest, count: g) }
        case .lognormal:
            return levels.map { lv in
                let mult = exp(0.6 * ndtri(lv))
                return runningMax(p.centre.map { min(max(latest + ($0 - latest) * mult, latest), 100.0) })
            }
        case .cases:
            let paths = p.errors.map { e in
                runningMax((0..<g).map { min(max(p.centre[$0] + e[$0], latest), 100.0) })
            }
            return weightedType1(paths, weights: [Double](repeating: 1, count: paths.count), levels: levels)
        }
    }

    /// The model's answer: a point when flat, else the exact quantiles at
    /// `forecastLevels`.
    public static func spendDecayForecast(_ p: SpendDecayParts, gridCount g: Int) -> ArenaTargetForecast {
        if p.mode == .flat { return .point([Double](repeating: p.latest, count: g)) }
        return ArenaTargetForecast(levels: forecastLevels,
                                   quantiles: spendDecayQuantiles(p, gridCount: g, levels: forecastLevels))
    }

    /// `tf.quantile(level)` for many levels at once, `[levels][G]`: the
    /// same values (linear between the model's levels, flat beyond; numpy's
    /// type 7 over paths), without re-gathering a column per level.
    public static func quantileRows(_ tf: ArenaTargetForecast, levels: [Double]) -> [[Double]] {
        let g = tf.gridCount
        if let lv = tf.levels, let q = tf.quantiles, let first = lv.first, let last = lv.last {
            return levels.map { x -> [Double] in
                if x <= first { return q[0] }
                if x >= last { return q[q.count - 1] }
                var lo = 0, hi = lv.count - 1
                while hi - lo > 1 { let mid = (lo + hi) >> 1; if lv[mid] <= x { lo = mid } else { hi = mid } }
                let span = lv[hi] - lv[lo]
                if span == 0 { return q[lo] }
                let a = (x - lv[lo]) / span
                if a == 0 { return q[lo] }
                return (0..<g).map { j in q[lo][j] + a * (q[hi][j] - q[lo][j]) }
            }
        }
        guard let paths = tf.paths, !paths.isEmpty else { return levels.map { _ in [] } }
        var cols = [[Double]](repeating: [], count: g)
        for j in 0..<g { cols[j] = paths.map { $0[j] }.sorted() }
        return levels.map { x in (0..<g).map { ArenaMath.quantile(cols[$0], x) } }
    }

    /// `np.maximum.accumulate` along a path.
    @inline(__always)
    public static func runningMax(_ xs: [Double]) -> [Double] {
        var out = xs
        for i in out.indices.dropFirst() where out[i] < out[i - 1] { out[i] = out[i - 1] }
        return out
    }
}
