import Foundation

// `research/arena/kit/fm/paths.py`: from a pretrained model's quantiles (or
// samples) to the sample paths the arena scores.
//
// Quantiles are `levels` [Q] and `q` [T][Q]: one quantile curve per level
// over T times (row = time, as numpy's `(..., T, Q)`). Paths are
// `[nPaths][T]`.
//
// - `fixCrossing`: sort along the level axis (some heads cross).
// - `extendTails`: a head trained on 0.1…0.9 says nothing about the outer
//   20 %; the tails are extrapolated linearly in the normal-score scale from
//   the two outermost levels (a Gaussian tail), never inward.
// - `toPaths`: one uniform per path and time read through each time's
//   quantile function; `comonotone` (one uniform per path for every time),
//   `ar1` (a Gaussian copula with AR(1) correlation `rho` per step) or
//   `independent`.
// - `monotoneMeter`: at least the latest reading, at most 100, never falling.
// - `isotonicPaths`: each sampled path's closest non-decreasing path.
//
// The random draws use `ArenaRNG`, not numpy's PCG64: paths match the
// arena's within Monte-Carlo bounds only, never draw for draw. Everything
// deterministic (quantiles, tails, burn, clipping) matches exactly.

public enum FMPaths {
    public enum Dependence: String, Sendable { case comonotone, ar1, independent }

    public static func fixCrossing(_ q: [[Double]]) -> [[Double]] {
        q.map { $0.sorted() }
    }

    /// Add levels `lo` and `hi` when the head stops short of them.
    public static func extendTails(_ levels: [Double], _ q: [[Double]], lo: Double = 0.01,
                                   hi: Double = 0.99) -> (levels: [Double], q: [[Double]]) {
        var lv = levels
        var q = fixCrossing(q)
        if let first = lv.first, first > lo + 1e-9, lv.count >= 2 {
            let z0 = ndtri(lv[0]), z1 = ndtri(lv[1])
            q = q.map { row in
                let slope = (row[1] - row[0]) / (z1 - z0)
                return [row[0] - max(slope, 0.0) * (z0 - ndtri(lo))] + row
            }
            lv.insert(lo, at: 0)
        }
        if let last = lv.last, last < hi - 1e-9, lv.count >= 2 {
            let n = lv.count
            let z0 = ndtri(lv[n - 2]), z1 = ndtri(lv[n - 1])
            q = q.map { row in
                let slope = (row[n - 1] - row[n - 2]) / (z1 - z0)
                return row + [row[n - 1] + max(slope, 0.0) * (ndtri(hi) - z1)]
            }
            lv.append(hi)
        }
        return (lv, q)
    }

    /// [nPaths][nTimes] uniforms with the requested dependence across times.
    public static func uniforms(_ nPaths: Int, _ nTimes: Int, _ dependence: Dependence = .comonotone,
                                rho: Double = 0.8, rng: inout ArenaRNG) -> [[Double]] {
        switch dependence {
        case .comonotone:
            // Stratified: path i sits at the (i + 0.5)/n quantile everywhere
            // (a random permutation keeps path order uninformative).
            var u = (0..<nPaths).map { (Double($0) + 0.5) / Double(nPaths) }
            shuffle(&u, rng: &rng)
            return u.map { [Double](repeating: $0, count: nTimes) }
        case .independent:
            return (0..<nPaths).map { _ in (0..<nTimes).map { _ in rng.uniform() } }
        case .ar1:
            let r = min(max(rho, -0.999), 0.999)
            let s = (1.0 - r * r).squareRoot()
            return (0..<nPaths).map { _ in
                var z = rng.normal()
                var row = [ndtr(z)]
                row.reserveCapacity(nTimes)
                for _ in 1..<max(nTimes, 1) {
                    z = r * z + s * rng.normal()
                    row.append(ndtr(z))
                }
                return Array(row.prefix(nTimes))
            }
        }
    }

    /// Quantiles `q` [T][Q] at `levels` -> paths [nPaths][T]. A uniform
    /// beyond the outermost level reads that level (no further extrapolation).
    public static func toPaths(_ levels: [Double], _ q: [[Double]], nPaths: Int,
                               _ dependence: Dependence = .comonotone, rho: Double = 0.8,
                               rng: inout ArenaRNG) -> [[Double]] {
        let q = fixCrossing(q)
        let u = uniforms(nPaths, q.count, dependence, rho: rho, rng: &rng)
        return u.map { row in row.indices.map { j in ArenaMath.interp(row[j], xs: levels, ys: q[j]) } }
    }

    /// Linear interpolation of `v` [tFrom.count][K] (along the first axis) at
    /// `tTo`, flat beyond the ends.
    public static func interpTimes(_ tFrom: [Double], _ tTo: [Double], _ v: [[Double]]) -> [[Double]] {
        guard let k = v.first?.count else { return [] }
        var out = [[Double]](repeating: [Double](repeating: 0, count: k), count: tTo.count)
        for (i, x) in tTo.enumerated() {
            // np.interp per column, sharing the bracket search across columns.
            if x <= tFrom[0] { out[i] = v[0]; continue }
            if x >= tFrom[tFrom.count - 1] { out[i] = v[tFrom.count - 1]; continue }
            var lo = 0, hi = tFrom.count - 1
            while hi - lo > 1 { let mid = (lo + hi) / 2; if tFrom[mid] <= x { lo = mid } else { hi = mid } }
            let span = tFrom[hi] - tFrom[lo]
            if span == 0 { out[i] = v[lo]; continue }
            let w = (x - tFrom[lo]) / span
            for c in 0..<k { out[i][c] = v[lo][c] + w * (v[hi][c] - v[lo][c]) }
        }
        return out
    }

    /// Clip to [floor, cap] and make each path non-decreasing in time.
    public static func monotoneMeter(_ paths: [[Double]], floor: Double, cap: Double = 100.0) -> [[Double]] {
        paths.map { row in
            var m = -Double.infinity
            return row.map { x in m = max(m, min(max(x, floor), cap)); return m }
        }
    }

    /// Cumulative-burn quantile curves [H][Q] -> burn since now, per level
    /// non-decreasing in time and never negative, with no crossing.
    public static func burnQuantiles(_ qCum: [[Double]], cLast: Double) -> [[Double]] {
        guard let nq = qCum.first?.count else { return [] }
        var running = [Double](repeating: -.infinity, count: nq)
        let b = qCum.map { row in
            (0..<nq).map { k -> Double in running[k] = max(running[k], max(row[k] - cLast, 0.0)); return running[k] }
        }
        return fixCrossing(b)
    }

    /// Each path's closest non-decreasing path (least squares, pool adjacent
    /// violators). A running max would ratchet every upward wiggle of a noisy
    /// sample into the level; this keeps the path's average course.
    public static func isotonicPaths(_ paths: [[Double]]) -> [[Double]] {
        paths.map(isotonic)
    }

    static func isotonic(_ y: [Double]) -> [Double] {
        var means: [Double] = [], weights: [Double] = [], counts: [Int] = []
        means.reserveCapacity(y.count); weights.reserveCapacity(y.count); counts.reserveCapacity(y.count)
        for x in y {
            means.append(x); weights.append(1); counts.append(1)
            while means.count > 1 && means[means.count - 2] > means[means.count - 1] {
                let w = weights[weights.count - 2] + weights[weights.count - 1]
                let m = (means[means.count - 2] * weights[weights.count - 2]
                         + means[means.count - 1] * weights[weights.count - 1]) / w
                let c = counts[counts.count - 2] + counts[counts.count - 1]
                means.removeLast(); weights.removeLast(); counts.removeLast()
                means[means.count - 1] = m; weights[weights.count - 1] = w; counts[counts.count - 1] = c
            }
        }
        var out: [Double] = []
        out.reserveCapacity(y.count)
        for (m, c) in zip(means, counts) { out.append(contentsOf: repeatElement(m, count: c)) }
        return out
    }

    /// A model's own sample paths [S][T] -> [n][T]: all of them when S is at
    /// most the request's count, else a random subset (kept in order).
    public static func samplesToPaths(_ samples: [[Double]], nPaths: Int, rng: inout ArenaRNG) -> [[Double]] {
        guard samples.count > nPaths else { return samples }
        var idx = Array(samples.indices)
        shuffle(&idx, rng: &rng)
        return idx.prefix(nPaths).sorted().map { samples[$0] }
    }

    static func shuffle<T>(_ a: inout [T], rng: inout ArenaRNG) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = Int(rng.uniform() * Double(i + 1))
            a.swapAt(i, min(j, i))
        }
    }

    // MARK: - The normal distribution (scipy.special.ndtr / ndtri)

    /// Standard normal CDF.
    public static func ndtr(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }

    /// Inverse standard normal CDF (Wichura's AS 241, PPND16: about 1e-16
    /// relative, the same accuracy class as scipy's `ndtri`).
    public static func ndtri(_ p: Double) -> Double {
        if p <= 0 { return -.infinity }
        if p >= 1 { return .infinity }
        let q = p - 0.5
        if abs(q) <= 0.425 {
            let r = 0.180625 - q * q
            let num = (((((((r * 2509.0809287301226727 + 33430.575583588128105) * r + 67265.770927008700853) * r
                + 45921.953931549871457) * r + 13731.693765509461125) * r + 1971.5909503065514427) * r
                + 133.14166789178437745) * r + 3.387132872796366608)
            let den = (((((((r * 5226.495278852545925 + 28729.085735721942674) * r + 39307.89580009271061) * r
                + 21213.794301586595867) * r + 5394.1960214247511077) * r + 687.1870074920579083) * r
                + 42.313330701600911252) * r + 1.0)
            return q * num / den
        }
        var r = q < 0 ? p : 1 - p
        r = (-log(r)).squareRoot()
        var val: Double
        if r <= 5 {
            r -= 1.6
            let num = (((((((r * 7.7454501427834140764e-4 + 0.0227238449892691845833) * r + 0.24178072517745061177) * r
                + 1.27045825245236838258) * r + 3.64784832476320460504) * r + 5.7694972214606914055) * r
                + 4.6303378461565452959) * r + 1.42343711074968357734)
            let den = (((((((r * 1.05075007164441684324e-9 + 5.475938084995344946e-4) * r + 0.0151986665636164571966) * r
                + 0.14810397642748007459) * r + 0.68976733498510000455) * r + 1.6763848301838038494) * r
                + 2.05319162663775882187) * r + 1.0)
            val = num / den
        } else {
            r -= 5
            let num = (((((((r * 2.01033439929228813265e-7 + 2.71155556874348757815e-5) * r + 0.0012426609473880784386) * r
                + 0.026532189526576123093) * r + 0.29656057182850489123) * r + 1.7848265399172913358) * r
                + 5.4637849111641143699) * r + 6.6579046435011037772)
            let den = (((((((r * 2.04426310338993978564e-15 + 1.4215117583164458887e-7) * r + 1.8463183175100546818e-5) * r
                + 7.868691311456132591e-4) * r + 0.0148753612908506148525) * r + 0.13692988092273580531) * r
                + 0.59983220655588793769) * r + 1.0)
            val = num / den
        }
        return q < 0 ? -val : val
    }
}
