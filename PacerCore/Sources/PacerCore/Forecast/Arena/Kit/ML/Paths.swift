import Foundation

// `research/arena/kit/ml/paths.py`, in Swift: quantiles, paths and scores
// shared by the learned models and the combiners.
//
// - `tidyRiseQuantiles`: make a [levels × leads] table of meter rises a
//   proper cumulative forecast: no crossing across levels, never falling
//   with lead, within [0, headroom].
// - `risePaths`: such a table, read at anchor leads, to sample paths on a
//   request grid (comonotone: a path high early stays high, as a meter
//   does). `riseQuantiles` is the same table on the grid before any path is
//   drawn, for a port that answers with quantiles.
// - `sortedSamples` / `crpsSorted`: the empirical CRPS of a sample set,
//   exact for the samples, from their sorted values (the combiners store
//   each child's forecast as m sorted values per grid time).
//
// Layout as in the Python: a table is `[rows][columns]`, rows = levels (or
// samples, or paths), columns = leads (or grid times). `q[i][j]` is numpy's
// `q[i, j]`.

public enum KitMLPaths {
    /// `tidy_rise_quantiles`: `q` `[levels][leads]` (levels ascending, leads
    /// ascending) clipped to [0, headroom], sorted across levels per lead,
    /// then a running maximum along the leads per level.
    public static func tidyRiseQuantiles(_ q: [[Double]], headroom: Double) -> [[Double]] {
        let hi = max(headroom, 0.0)
        var out = q.map { row in row.map { min(max($0, 0.0), hi) } }
        sortColumns(&out)
        for i in out.indices { runningMax(&out[i]) }
        return out
    }

    /// `with_tails`: the table extended to levels 0 and 1 by half the outer
    /// gaps (bounded by 0 and the headroom), so sampled paths are not cut at
    /// the outermost fitted levels. Needs at least two levels.
    public static func withTails(_ levels: [Double], _ q: [[Double]], headroom: Double)
        -> (levels: [Double], q: [[Double]]) {
        precondition(q.count >= 2, "with_tails needs two levels")
        let n = q.count
        let hiCap = max(headroom, 0.0)
        let cols = q[0].indices
        let lo = cols.map { j in max(q[0][j] - 0.5 * (q[1][j] - q[0][j]), 0.0) }
        let hi = cols.map { j in max(min(q[n - 1][j] + 0.5 * (q[n - 1][j] - q[n - 2][j]), hiCap), q[n - 1][j]) }
        return ([0.0] + levels + [1.0], [lo] + q + [hi])
    }

    /// The deterministic half of `rise_paths`: the rise table, tidied and
    /// tailed, read at the grid's lead fractions (rise 0 at lead 0).
    /// `(levels, Q [levels][grid])`, rises (add `used` for the meter).
    public static func riseQuantiles(levels: [Double], q: [[Double]], anchorFracs: [Double], gridFracs: [Double],
                                     used: Double) -> (levels: [Double], q: [[Double]]) {
        let head = max(100.0 - used, 0.0)
        let tidy = tidyRiseQuantiles(q, headroom: head)
        let tailed = withTails(levels, tidy, headroom: head)
        var t = tailed.q
        sortColumns(&t)
        for i in t.indices { runningMax(&t[i]) }
        let fa = [0.0] + anchorFracs
        let g = gridFracs.map { min(max($0, 0.0), 1.0) }
        let Q = t.map { row -> [Double] in
            let ys = [0.0] + row
            return g.map { KitDetQ.npInterp($0, xs: fa, ys: ys) }
        }
        return (tailed.levels, Q)
    }

    /// `rise_paths`: paths of the meter (used + rise) on a grid, from rise
    /// quantiles at anchor lead fractions, drawn comonotone
    /// (`TargetForecast.from_quantiles`), clipped to [used, 100].
    public static func risePaths(levels: [Double], q: [[Double]], anchorFracs: [Double], gridFracs: [Double],
                                 used: Double, nPaths: Int, rng: inout ArenaRNG) -> ArenaTargetForecast {
        let (lv, Q) = riseQuantiles(levels: levels, q: q, anchorFracs: anchorFracs, gridFracs: gridFracs,
                                    used: used)
        let paths = fromQuantiles(lv, Q, nPaths: nPaths, rng: &rng)
        return ArenaTargetForecast(paths: paths.map { row in row.map { min(max(used + $0, used), 100.0) } })
    }

    /// `rise_paths` before the draw, as a quantile forecast of the meter:
    /// clipping is monotone, so the clipped quantiles are the quantiles of
    /// the clipped paths. What a deterministic port answers with.
    public static func riseForecast(levels: [Double], q: [[Double]], anchorFracs: [Double], gridFracs: [Double],
                                    used: Double) -> ArenaTargetForecast {
        let (lv, Q) = riseQuantiles(levels: levels, q: q, anchorFracs: anchorFracs, gridFracs: gridFracs,
                                    used: used)
        return ArenaTargetForecast(levels: lv, quantiles: Q.map { row in row.map { min(max(used + $0, used), 100.0) } })
    }

    /// `sample_rise_paths`: whole sampled rise trajectories at anchor
    /// fractions (`[n][k]`) to meter paths on the grid.
    public static func sampleRisePaths(_ samples: [[Double]], anchorFracs: [Double], gridFracs: [Double],
                                       used: Double) -> [[Double]] {
        let head = max(100.0 - used, 0.0)
        let fa = [0.0] + anchorFracs
        let g = gridFracs.map { min(max($0, 0.0), 1.0) }
        return samples.map { s -> [Double] in
            var row = s.map { min(max($0, 0.0), head) }
            runningMax(&row)
            let ys = [0.0] + row
            return g.map { min(max(used + KitDetQ.npInterp($0, xs: fa, ys: ys), used), 100.0) }
        }
    }

    /// `grid_fracs`: each grid time's share of the span from now to the reset.
    public static func gridFracs(_ grid: [Millis], now: Millis, reset: Millis) -> [Double] {
        let span = Double(max(reset - now, 1))
        return grid.map { (Double($0) - Double(now)) / span }
    }

    /// `sorted_samples`: `[m][G]`, the paths' quantiles at levels
    /// (i + 0.5) / m per grid time (all of them, sorted, when there are
    /// exactly m). Kept as the Python computes it, including its
    /// extrapolation below the lowest path when m > n (the weight is taken
    /// from the clipped index), which no caller here reaches.
    public static func sortedSamples(_ paths: [[Double]], m: Int) -> [[Double]] {
        var P = paths
        sortColumns(&P)
        let n = P.count
        if n == m || n == 0 { return P }
        let g = P[0].count
        var out = [[Double]](repeating: [Double](repeating: 0, count: g), count: m)
        for i in 0..<m {
            let lv = (Double(i) + 0.5) / Double(m)
            let pos = lv * Double(n) - 0.5
            let lo = min(max(Int(pos.rounded(.down)), 0), n - 1)
            let hi = min(max(lo + 1, 0), n - 1)
            let w = pos - Double(lo)
            for j in 0..<g { out[i][j] = (1 - w) * P[lo][j] + w * P[hi][j] }
        }
        return out
    }

    /// `sorted_samples` of a forecast: its own paths as the Python reads
    /// them; for a port that answers with quantiles (the Swift ports of the
    /// arena's sampling models: spend-decay, Timestral), the quantile
    /// function itself read at (i + 0.5) / m, which is what the Python's
    /// sorted samples estimate from its draws (`KitCalib.curves` reads a
    /// quantile child the same way).
    public static func sortedSamples(_ tf: ArenaTargetForecast, m: Int) -> [[Double]] {
        if let p = tf.paths { return sortedSamples(p, m: m) }
        return KitDetQ.quantileRows(tf, levels: levelGrid(m))
    }

    /// (i + 0.5) / m, i < m.
    public static func levelGrid(_ m: Int) -> [Double] { (0..<m).map { (Double($0) + 0.5) / Double(m) } }

    /// `crps_sorted`: the CRPS of the empirical distribution of each
    /// column's samples. `x` `[m][E]` sorted ascending along the rows; `y`
    /// `[E]`. E|X − y| − E|X − X'| / 2, the second term from the sorted
    /// values (Gini) instead of every pair.
    public static func crpsSorted(_ x: [[Double]], _ y: [Double]) -> [Double] {
        let m = x.count
        guard m > 0 else { return y.map { _ in .nan } }
        var a = [Double](repeating: 0, count: y.count)
        var b = [Double](repeating: 0, count: y.count)
        for i in 0..<m {
            let w = Double(2 * (i + 1) - m - 1)
            let row = x[i]
            for e in y.indices {
                a[e] += abs(row[e] - y[e])
                b[e] += w * row[e]
            }
        }
        let mm = Double(m * m), md = Double(m)
        return y.indices.map { a[$0] / md - b[$0] / mm }
    }

    /// `crps_paths`: ensemble CRPS per column, paths `[n][E]` read at the
    /// truth times.
    public static func crpsPaths(_ paths: [[Double]], _ y: [Double]) -> [Double] {
        var p = paths
        sortColumns(&p)
        return crpsSorted(p, y)
    }

    /// `TargetForecast.from_quantiles` (comonotone): one uniform per path
    /// on [lowest level, highest level], sorted, read at that level at every
    /// grid time. `ArenaRNG`, not numpy's stream: paths match within
    /// Monte-Carlo bounds only.
    public static func fromQuantiles(_ levels: [Double], _ q: [[Double]], nPaths: Int,
                                     rng: inout ArenaRNG) -> [[Double]] {
        guard let lo = levels.min(), let hi = levels.max(), let g = q.first?.count else { return [] }
        let us = (0..<nPaths).map { _ in lo + (hi - lo) * rng.uniform() }.sorted()
        var col = [Double](repeating: 0, count: q.count)
        var out = [[Double]](repeating: [Double](repeating: 0, count: g), count: nPaths)
        for j in 0..<g {
            for i in q.indices { col[i] = q[i][j] }
            for (p, u) in us.enumerated() { out[p][j] = KitDetQ.npInterp(u, xs: levels, ys: col) }
        }
        return out
    }

    // MARK: - small numerics

    /// `np.sort(a, axis=0)`: each column sorted ascending, in place.
    public static func sortColumns(_ a: inout [[Double]]) {
        guard let g = a.first?.count, a.count > 1 else { return }
        var col = [Double](repeating: 0, count: a.count)
        for j in 0..<g {
            var sorted = true
            for i in a.indices {
                col[i] = a[i][j]
                if i > 0 && !(col[i] >= col[i - 1]) { sorted = false }
            }
            if sorted { continue }
            col.sort()
            for i in a.indices { a[i][j] = col[i] }
        }
    }

    /// `np.maximum.accumulate` along one row, in place.
    @inline(__always)
    public static func runningMax(_ row: inout [Double]) {
        guard row.count > 1 else { return }
        for i in 1..<row.count where row[i] < row[i - 1] { row[i] = row[i - 1] }
    }
}
