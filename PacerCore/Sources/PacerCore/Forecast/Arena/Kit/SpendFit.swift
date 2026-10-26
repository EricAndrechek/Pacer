import Foundation

// `kit/spend.py`, the conversion (SpendMeterFit, the lab's interval form):
// `Conversion`, `FitDetails`, `hourly_r2`, `_span_rows`, `fit_on_day`,
// `fit_details`, `fit_conversion`.
//
// This is NOT the app's `SpendMeterFitter` (`LiveMeter/`), which fits per
// model per local hour with an intercept. The arena's forecasters were
// scored on this one: per family, per reading interval, no intercept
// (port-spec § "On the app's code"); parity with the fixtures needs it.

extension KitSpend {
    /// Meter points per API-equivalent dollar, per model family, for one
    /// account and window.
    public struct Conversion: Sendable {
        public let pointsPerUSD: [String: Double]
        /// Rise < 20 points or R² < 0.5: the app shows no live value.
        public let weak: Bool
        public let r2: Double
        public let fittedThrough: Millis

        public func convert(_ spendByFamily: [String: Double]) -> Double {
            spendByFamily.reduce(0) { $0 + (pointsPerUSD[$1.key] ?? 0) * $1.value }
        }
    }

    /// A conversion with what it was fitted on.
    ///
    /// The Python keeps the fit's rows, fitted values and residuals here. A
    /// cut memoizes one fit per local day it touches (spend-decay's past cuts
    /// touch up to 120), so keeping 14 days of interval rows per fit would
    /// hold tens of MB per cut; they are re-derived on demand instead
    /// (`fitRows`), which only `port-live-meter` asks for.
    public struct FitDetails: Sendable {
        public let conversion: Conversion
        /// Points per USD per family, in `families` order.
        public let rates: [Double]
        /// Σ rise ÷ Σ counted spend over the fit's rows.
        public let pooled: Double
        /// Fitted on the account's own intervals alone.
        public let own: Bool
        /// Σ rise.
        public let rise: Double
        public let weakReason: String?
        /// The NNLS coefficients before the weak / small-family fallbacks.
        public let nnls: [Double]
        /// Σ counted spend per family over the rows.
        public let spent: [Double]
        public let r2Interval: Double
        public let nRows: Int
        public let dayStart: Millis
    }

    /// `hourly_r2`: the fit's R² the way the app scores it
    /// (`SpendMeterFitter.fit`): rise and prediction summed per account and
    /// local hour (an interval counts in the hour its later reading falls
    /// in), over the active hours (any rise or any counted spend). Per
    /// interval the meter's whole-point steps make R² meaningless at a poll
    /// every few seconds.
    public static func hourlyR2(_ rows: Intervals, rowSpend: [Double], predicted: [Double], offsetMs: Millis = 0) -> Double {
        let n = rows.count
        if n == 0 { return 0 }
        // Groups in (account, hour) order, as np.unique sorts them; each
        // group's sums in row order, as np.bincount adds them.
        struct Key: Hashable { let a: String; let h: Millis }
        var index: [Key: Int] = [:]
        var keys: [Key] = []
        var y: [Double] = [], p: [Double] = [], s: [Double] = []
        let labels = rows.account
        for i in 0..<n {
            let k = Key(a: labels[i], h: floorDiv(rows.t1[i] + offsetMs, hourMs))
            let g: Int
            if let j = index[k] { g = j } else {
                g = keys.count; index[k] = g; keys.append(k); y.append(0); p.append(0); s.append(0)
            }
            y[g] += rows.rise[i]; p[g] += predicted[i]; s[g] += rowSpend[i]
        }
        let order = keys.indices.sorted { keys[$0].a != keys[$1].a ? keys[$0].a < keys[$1].a : keys[$0].h < keys[$1].h }
        var ya: [Double] = [], pa: [Double] = []
        for g in order where y[g] > 0 || s[g] > 0 { ya.append(y[g]); pa.append(p[g]) }
        if ya.isEmpty { return 0 }
        let mean = KitMath.sum(ya) / Double(ya.count)
        let ss = KitMath.sum(ya.map { ($0 - mean) * ($0 - mean) })
        guard ss > 0 else { return 0 }
        return 1 - KitMath.sum(zip(ya, pa).map { ($0 - $1) * ($0 - $1) }) / ss
    }

    /// `_span_rows`: the intervals that ended in the 14 days before
    /// `dayStart`; the account's own when it has 100, else every visible
    /// account's (its own, however few, when nobody else is visible).
    static func spanRows(_ history: ArenaHistory, account: String, windowKind: String, scopeModel: String?,
                         dayStart: Millis) -> (rows: Intervals, own: Bool) {
        let lo = dayStart - spanDays * dayMs
        func inSpan(_ iv: Intervals) -> Intervals {
            // (t1 <= dayStart) & (t1 > lo): a range, since t1 ascends.
            let a = lowerIndex(iv.t1) { $0 > lo }
            let b = lowerIndex(iv.t1) { $0 > dayStart }
            return a < b ? iv.slice(a..<b) : .empty
        }
        let own = inSpan(intervals(history, account: account, windowKind: windowKind, scopeModel: scopeModel))
        if own.count >= minOwn { return (own, true) }
        let others = history.accounts.filter { $0 != account }
            .map { inSpan(intervals(history, account: $0, windowKind: windowKind, scopeModel: scopeModel)) }
        if !others.contains(where: { $0.count > 0 }) { return (own, true) }
        var out = Intervals.empty
        for part in [own] + others where part.count > 0 { out.append(part) }
        return (out, false)
    }

    /// First index whose value satisfies `pred` (monotone false → true).
    @inline(__always)
    static func lowerIndex(_ xs: [Millis], _ pred: (Millis) -> Bool) -> Int {
        var lo = 0, hi = xs.count
        while lo < hi { let mid = (lo + hi) >> 1; if pred(xs[mid]) { hi = mid } else { lo = mid + 1 } }
        return lo
    }

    /// `fit_on_day`: the fit the app would have made for the local day
    /// starting at `dayStart`: intervals that ended in the 14 days before
    /// it. `dayStart` may be any earlier day (walk-forward backtests); a day
    /// after now's day began is refused (its span would end after now).
    public static func fitOnDay(_ history: ArenaHistory, account: String, windowKind: String, scopeModel: String?,
                                dayStart: Millis) -> FitDetails? {
        // The Python raises here; a forecaster running in the app's
        // background must not trap, and "refused" reads as no conversion.
        guard dayStart <= localDayStart(history, account: account) else { return nil }
        return history.memo.value("kit.spend.fit|\(account)|\(windowKind)|\(scopeModel ?? "")|\(dayStart)") {
            let off = tzOffsetMs(history, account: account)
            // A local midnight is a whole number of hours from the epoch in
            // local time, so its span is whole hour buckets: the fast path.
            if floorDiv(dayStart + off, hourMs) * hourMs == dayStart + off {
                return KitBox(fitFromHours(history, account: account, windowKind: windowKind, scopeModel: scopeModel,
                                           dayStart: dayStart, offsetMs: off))
            }
            return KitBox(fitOnDayByRows(history, account: account, windowKind: windowKind, scopeModel: scopeModel,
                                         dayStart: dayStart))
        }.value
    }

    /// `fit_on_day` row by row, as the Python computes it: the reference
    /// the hour-bucket fit is checked against, and the path for a
    /// `dayStart` that is not on a local hour.
    static func fitOnDayByRows(_ history: ArenaHistory, account: String, windowKind: String, scopeModel: String?,
                               dayStart: Millis) -> FitDetails? {
        let (rows, own) = spanRows(history, account: account, windowKind: windowKind, scopeModel: scopeModel,
                                   dayStart: dayStart)
        return fit(rows, own: own, scopeModel: scopeModel, dayStart: dayStart,
                   offsetMs: tzOffsetMs(history, account: account)).details
    }

    /// The fit itself, on given rows: the details plus the per-row fitted
    /// values (what `fitRows` hands back).
    static func fit(_ rows: Intervals, own: Bool, scopeModel: String?, dayStart: Millis, offsetMs: Millis)
        -> (details: FitDetails?, fitted: [Double]) {
        let n = rows.count
        if n == 0 { return (nil, []) }
        let counted = counted(scopeModel)
        // X = where(counted, spend, 0), row-major [n × 5].
        var X = rows.spend
        for f in 0..<5 where !counted[f] { for i in 0..<n { X[i * 5 + f] = 0 } }
        let y = rows.rise
        let total = KitMath.sum(X)
        if total <= minPooledSpend { return (nil, []) }
        let ySum = KitMath.sum(y)
        let pooled = ySum / total
        let cols = (0..<5).filter { counted[$0] }
        var coef = [Double](repeating: 0, count: 5)
        let sol = KitMath.nnls(X, rows: n, columns: cols, y: y)
        for (k, j) in cols.enumerated() { coef[j] = sol[k] }
        let pred = (0..<n).map { i in KitMath.dot5(X, i, coef) }
        let mean = ySum / Double(n)
        let ss = KitMath.sum(y.map { ($0 - mean) * ($0 - mean) })
        let r2Interval = ss > 0 ? 1 - KitMath.sum((0..<n).map { (y[$0] - pred[$0]) * (y[$0] - pred[$0]) }) / ss : 0
        let rowSpend = (0..<n).map { i in X[i * 5] + X[i * 5 + 1] + X[i * 5 + 2] + X[i * 5 + 3] + X[i * 5 + 4] }
        let r2 = hourlyR2(rows, rowSpend: rowSpend, predicted: pred, offsetMs: offsetMs)
        let rise = ySum
        var reason: String?
        if rise < minRise {
            reason = String(format: "rise %.1f < %.0f", rise, minRise)
        } else if r2 < minR2 {
            reason = String(format: "R² %.2f < %g", r2, minR2)
        }
        let weak = reason != nil
        var spent = [Double](repeating: 0, count: 5)
        for i in 0..<n { for f in 0..<5 { spent[f] += X[i * 5 + f] } }
        let rates: [Double] = (0..<5).map { f in
            guard counted[f] else { return 0 }
            // Weak: the forecasters' fallback (the lab's tokc factor), one
            // pooled rate for every counted family; the live meter shows
            // nothing then.
            if weak { return pooled }
            return spent[f] > minFamilySpend ? coef[f] : pooled
        }
        let conv = Conversion(pointsPerUSD: Dictionary(uniqueKeysWithValues: zip(families, rates)), weak: weak,
                              r2: r2, fittedThrough: dayStart)
        let fitted = (0..<n).map { i in KitMath.dot5(X, i, rates) }
        let d = FitDetails(conversion: conv, rates: rates, pooled: pooled, own: own, rise: rise, weakReason: reason,
                           nnls: coef, spent: spent, r2Interval: r2Interval, nRows: n, dayStart: dayStart)
        return (d, fitted)
    }

    /// The rows behind `fitOnDay`, with the fit's fitted values and
    /// residuals (the Python's `FitDetails.rows`, `.fitted`, `.residuals`),
    /// re-derived on demand.
    public static func fitRows(_ history: ArenaHistory, account: String, windowKind: String, scopeModel: String?,
                               dayStart: Millis) -> (rows: Intervals, fitted: [Double], residuals: [Double])? {
        let (rows, own) = spanRows(history, account: account, windowKind: windowKind, scopeModel: scopeModel,
                                   dayStart: dayStart)
        let r = fit(rows, own: own, scopeModel: scopeModel, dayStart: dayStart,
                    offsetMs: tzOffsetMs(history, account: account))
        guard r.details != nil else { return nil }
        return (rows, r.fitted, zip(rows.rise, r.fitted).map { $0 - $1 })
    }

    /// `fit_details`: `fit_conversion` with what is behind it.
    public static func fitDetails(_ history: ArenaHistory, account: String, windowKind: String,
                                  scopeModel: String? = nil) -> FitDetails? {
        fitOnDay(history, account: account, windowKind: windowKind, scopeModel: scopeModel,
                 dayStart: localDayStart(history, account: account))
    }

    /// `fit_conversion`: NNLS of each reading interval's rise on what each
    /// family spent in it, no intercept, over the 14 days ending at the
    /// start of now's day (refit daily, no peeking); the account's own
    /// intervals when it has 100, else every visible account's. Nil when
    /// there is nothing to fit. Weak fits come back too, with `weak` set and
    /// one pooled rate for every counted family.
    public static func fitConversion(_ history: ArenaHistory, account: String, windowKind: String,
                                     scopeModel: String? = nil) -> Conversion? {
        fitDetails(history, account: account, windowKind: windowKind, scopeModel: scopeModel)?.conversion
    }
}

/// Small numerics the kit shares, written to reproduce numpy where it
/// matters for parity.
public enum KitMath {
    /// `np.sum` of a float64 array: numpy's pairwise summation (blocks of 8
    /// accumulated in 8 lanes, halves above 128 elements), so sums that
    /// gate a decision (the fit's "spent at least $1") round as the
    /// Python's do.
    public static func sum(_ a: [Double]) -> Double {
        a.withUnsafeBufferPointer { pairwise($0.baseAddress!, a.count) }
    }

    static func pairwise(_ a: UnsafePointer<Double>, _ n: Int) -> Double {
        if n < 8 {
            var res = -0.0
            for i in 0..<n { res += a[i] }
            return res
        } else if n <= 128 {
            var r = (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
            var i = 8
            while i < n - (n % 8) {
                r.0 += a[i]; r.1 += a[i + 1]; r.2 += a[i + 2]; r.3 += a[i + 3]
                r.4 += a[i + 4]; r.5 += a[i + 5]; r.6 += a[i + 6]; r.7 += a[i + 7]
                i += 8
            }
            var res = ((r.0 + r.1) + (r.2 + r.3)) + ((r.4 + r.5) + (r.6 + r.7))
            while i < n { res += a[i]; i += 1 }
            return res
        } else {
            var n2 = n / 2
            n2 -= n2 % 8
            return pairwise(a, n2) + pairwise(a + n2, n - n2)
        }
    }

    /// Row `i` of a row-major `[n × 5]` matrix dotted with `k`.
    @inline(__always)
    static func dot5(_ X: [Double], _ i: Int, _ k: [Double]) -> Double {
        let b = i * 5
        return X[b] * k[0] + X[b + 1] * k[1] + X[b + 2] * k[2] + X[b + 3] * k[3] + X[b + 4] * k[4]
    }

    /// Non-negative least squares of `y` on the listed columns of a
    /// row-major `[rows × 5]` matrix: Lawson–Hanson's active set (scipy's
    /// `nnls`), on the columns' Gram matrix rather than a QR of the rows.
    /// With at most five columns the Gram matrix is all the solve needs,
    /// and building it is one pass over the rows: no per-row arrays, which
    /// is what keeps a cut's dozens of daily fits cheap. Columns are scaled
    /// to unit length first (the scale does not change the non-negative
    /// solution, and it puts the tolerance on one footing).
    public static func nnls(_ X: [Double], rows n: Int, columns cols: [Int], y: [Double]) -> [Double] {
        let k = cols.count
        guard n > 0, k > 0 else { return Array(repeating: 0, count: k) }
        var G = [Double](repeating: 0, count: k * k)
        var c = [Double](repeating: 0, count: k)
        for i in 0..<n {
            let b = i * 5
            for a in 0..<k {
                let xa = X[b + cols[a]]
                if xa == 0 { continue }
                c[a] += xa * y[i]
                for bb in a..<k { G[a * k + bb] += xa * X[b + cols[bb]] }
            }
        }
        for a in 0..<k { for bb in 0..<a { G[a * k + bb] = G[bb * k + a] } }
        return nnlsGram(G, c, rows: n)
    }

    /// `nnls` from the Gram matrix `G` (`k × k`, symmetric, row-major) and
    /// `c = Xᵀy` of `rows` rows.
    public static func nnlsGram(_ G0: [Double], _ c0: [Double], rows n: Int) -> [Double] {
        let k = c0.count
        guard n > 0, k > 0 else { return Array(repeating: 0, count: k) }
        var G = G0, c = c0
        let scale = (0..<k).map { G[$0 * k + $0].squareRoot() }
        for a in 0..<k {
            c[a] = scale[a] > 0 ? c[a] / scale[a] : 0
            for bb in 0..<k {
                G[a * k + bb] = scale[a] > 0 && scale[bb] > 0 ? G[a * k + bb] / (scale[a] * scale[bb]) : 0
            }
        }
        let tol = 10 * Double.ulpOfOne * Double(max(n, k)) * Double(n).squareRoot()
        var x = [Double](repeating: 0, count: k)
        var passive = [Bool](repeating: false, count: k)
        var iterations = 0
        let cap = 3 * k
        func gradient() -> [Double] {
            (0..<k).map { a in c[a] - (0..<k).reduce(0.0) { $0 + G[a * k + $1] * x[$1] } }
        }
        outer: while true {
            var w = gradient()
            var rejected = [Bool](repeating: false, count: k)
            var added = false
            while !added {
                var best = -1, bestW = tol
                for j in 0..<k where !passive[j] && !rejected[j] && scale[j] > 0 && w[j] > bestW {
                    best = j; bestW = w[j]
                }
                guard best >= 0 else { break outer }
                passive[best] = true
                var firstSolve = true
                while true {
                    iterations += 1
                    if iterations > cap { break outer }
                    let p = (0..<k).filter { passive[$0] }
                    let zp = solveSPD(G, k, p, c)
                    var z = [Double](repeating: 0, count: k)
                    for (i, j) in p.enumerated() { z[j] = zp[i] }
                    if firstSolve && z[best] <= 0 {
                        passive[best] = false; rejected[best] = true; w[best] = 0
                        break
                    }
                    firstSolve = false
                    if p.allSatisfy({ z[$0] > 0 }) { x = z; added = true; break }
                    var alpha = Double.infinity
                    for j in p where z[j] <= 0 {
                        let d = x[j] - z[j]
                        if d > 0 { alpha = min(alpha, x[j] / d) }
                    }
                    if !alpha.isFinite { alpha = 0 }
                    for j in 0..<k { x[j] += alpha * (z[j] - x[j]) }
                    for j in p where x[j] <= tol { x[j] = 0; passive[j] = false }
                }
            }
        }
        return (0..<k).map { scale[$0] > 0 ? max(0, x[$0]) / scale[$0] : 0 }
    }

    /// Solve G[p, p] z = c[p] (symmetric, positive semi-definite) by
    /// Gaussian elimination with partial pivoting; a numerically dependent
    /// column gets 0, which the caller then drops from the passive set.
    static func solveSPD(_ G: [Double], _ k: Int, _ p: [Int], _ c: [Double]) -> [Double] {
        let m = p.count
        var A = [Double](repeating: 0, count: m * m)
        var b = p.map { c[$0] }
        for i in 0..<m { for j in 0..<m { A[i * m + j] = G[p[i] * k + p[j]] } }
        var perm = Array(0..<m)
        var dead = [Bool](repeating: false, count: m)
        for col in 0..<m {
            var piv = col
            for r in col..<m where abs(A[r * m + col]) > abs(A[piv * m + col]) { piv = r }
            if abs(A[piv * m + col]) < 1e-13 { dead[col] = true; continue }
            if piv != col {
                for j in 0..<m { A.swapAt(col * m + j, piv * m + j) }
                b.swapAt(col, piv); perm.swapAt(col, piv)
            }
            for r in (col + 1)..<m {
                let f = A[r * m + col] / A[col * m + col]
                if f == 0 { continue }
                for j in col..<m { A[r * m + j] -= f * A[col * m + j] }
                b[r] -= f * b[col]
            }
        }
        var z = [Double](repeating: 0, count: m)
        for i in stride(from: m - 1, through: 0, by: -1) {
            if dead[i] { z[i] = 0; continue }
            var s = b[i]
            for j in (i + 1)..<m { s -= A[i * m + j] * z[j] }
            z[i] = s / A[i * m + i]
        }
        return z
    }
}
