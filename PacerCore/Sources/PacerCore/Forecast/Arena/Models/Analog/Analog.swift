import Foundation

// `research/arena/models/g1-10-fable-analog/analog.py`, the meter half:
// kernel-weighted analog ensembles cut from the account's own complete past
// cycles. The hourly spend/token, split and next-start analogs have no meter
// target and are not ported.
//
// The forecast distribution of "what happens to this meter by its reset" is
// read off the account's own past: every past moment that looked like now
// (same phase of the window, same local time of day and weekday type, a
// similar recent rise, the same account, not too long ago) contributes the
// trajectory that followed it, with a kernel weight. Nothing is parametric
// except the kernels; bandwidths widen until the effective sample size is
// adequate.
//
// Names and order of operations follow the Python, so the two read side by
// side. Floating-point expressions are written in the Python's order (a
// product of separate kernels, not one exp of a sum) so the weights agree
// with numpy's to the last bit where both call the same libm `exp`.

enum Analog {
    static let MIN = ArenaTime.minute
    static let HOUR = ArenaTime.hour
    static let DAY = ArenaTime.day

    // MARK: - Small helpers

    /// `searchsorted(t, q, side="right")`: how many of the ascending `t` are
    /// at or before `q`.
    @inline(__always)
    static func upper(_ t: [Millis], _ q: Millis) -> Int {
        var lo = 0, hi = t.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if t[mid] <= q { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// `step_at`: the step function through `(t, u)` at `q` (the last
    /// reading at or before it), `before` when `q` precedes the first.
    @inline(__always)
    static func stepAt(_ t: [Millis], _ u: [Double], _ q: Millis, before: Double = 0) -> Double {
        let i = upper(t, q) - 1
        return i >= 0 ? u[i] : before
    }

    /// `local_hour`: numpy's float64 `(t + tz) % DAY / HOUR` (a remainder
    /// with the divisor's sign, so never negative).
    @inline(__always)
    static func localHour(_ t: Millis, _ tz: Millis) -> Double {
        let x = Double(t) + Double(tz)
        var m = fmod(x, Double(DAY))
        if m != 0, m < 0 { m += Double(DAY) }
        return m / Double(HOUR)
    }

    /// `local_dow`: 0 = Monday … 6 = Sunday (1970-01-01 was a Thursday),
    /// with Python's floor division and modulo.
    @inline(__always)
    static func localDow(_ t: Millis, _ tz: Millis) -> Int {
        let d = KitSpend.floorDiv(t + tz, DAY) + 3
        return Int(((d % 7) + 7) % 7)
    }

    @inline(__always)
    static func circDiff(_ a: Double, _ b: Double, period: Double = 24) -> Double {
        let d = fmod(abs(a - b), period)
        return min(d, period - d)
    }

    /// `gauss`: `exp(-0.5 * (x / bw) ** 2)` (numpy squares by multiplying).
    @inline(__always)
    static func gauss(_ x: Double, _ bw: Double) -> Double {
        let z = x / bw
        return exp(-0.5 * (z * z))
    }

    /// The effective sample size `(Σw)² / Σw²`, 0 when nothing weighs.
    static func ess(_ w: [Double]) -> Double {
        var s = 0.0, s2 = 0.0
        for x in w { s += x; s2 += x * x }
        return s > 0 ? s * s / s2 : 0
    }

    /// `widen_until`: `makeW(scale)` with growing bandwidth scales until the
    /// weights' effective sample size reaches `targetEss`.
    static func widenUntil(_ makeW: (Double) -> [Double], targetEss: Double, maxRounds: Int = 6,
                           factor: Double = 1.5) -> (w: [Double], scale: Double, ess: Double) {
        var scale = 1.0
        var w = makeW(scale)
        var e = ess(w)
        var rounds = 0
        while e < targetEss && rounds < maxRounds {
            scale *= factor
            w = makeW(scale)
            e = ess(w)
            rounds += 1
        }
        return (w, scale, e)
    }

    /// `sample_idx`: `n` indices drawn with replacement with probability
    /// `w / Σw` (numpy's `choice(p=…)`: the cumulative weights, normalized,
    /// searched to the right of a uniform).
    static func sampleIdx(_ rng: inout ArenaRNG, _ w: [Double], _ n: Int) -> [Int] {
        var cdf = [Double](repeating: 0, count: w.count)
        var s = 0.0
        for (i, x) in w.enumerated() { s += x; cdf[i] = s }
        guard s > 0 else { return [Int](repeating: 0, count: n) }
        return (0..<n).map { _ in
            let u = rng.uniform() * s
            var lo = 0, hi = cdf.count
            while lo < hi { let mid = (lo + hi) >> 1; if cdf[mid] <= u { lo = mid + 1 } else { hi = mid } }
            return min(lo, cdf.count - 1)
        }
    }

    /// `tz_ms`: the history's UTC offset in ms (the kit's `tz_offset_ms`).
    static func tzMs(_ history: ArenaHistory, _ account: String?) -> Millis {
        KitSpend.tzOffsetMs(history, account: account)
    }

    // MARK: - Meters: analogs cut from complete past cycles

    /// `meter_lags`: the rate features' lags.
    static func meterLags(_ kind: String) -> [Millis] {
        kind == "five_hour" ? [15 * MIN, 60 * MIN] : [HOUR, 6 * HOUR, 24 * HOUR]
    }

    /// The cuts of one complete past cycle: a block of `MeterTable` rows,
    /// in `e` order. `rates` is `[count][lags]` and `D` `[count][M]`, flat.
    struct CycleCuts: Sendable, Equatable {
        let account: String
        /// The cycle's reset (`t_ref`, for recency).
        let reset: Millis
        let count: Int
        let e: [Millis]
        let u0: [Double]
        let rates: [Double]
        let hour: [Double]
        let dow: [Int]
        /// The increment at fractions k/M of the time left, k = 1…M.
        let D: [Double]
    }

    /// `MeterTable`: every row of every usable past cycle, as blocks (one
    /// per cycle, in the Python's row order: accounts in order, each
    /// account's cycles oldest first, each cycle's cuts in `e` order).
    struct MeterTable: Sendable {
        let kind: String
        let W: Millis
        let lags: [Millis]
        let M: Int
        let blocks: [CycleCuts]
        let count: Int
        /// Cycles that contributed rows.
        var nCycles: Int { blocks.count }

        init(kind: String, W: Millis, lags: [Millis], M: Int, blocks: [CycleCuts]) {
            self.kind = kind; self.W = W; self.lags = lags; self.M = M
            self.blocks = blocks
            self.count = blocks.reduce(0) { $0 + $1.count }
        }
    }

    /// One past cycle's rows (`build_meter_table`'s loop body), or nil when
    /// the cycle is not usable: polling must have reached near the reset
    /// (the step function holds the last reading over any final gap), and a
    /// cut needs a reading at or before it.
    static func cycleCuts(account: String, reset: Millis, start: Millis, t: [Millis], util: [Double],
                          tz: Millis, step: Millis, M: Int, lags: [Millis]) -> CycleCuts? {
        guard let tLast = t.last else { return nil }
        let Wc = reset - start
        // `c.t[-1] >= c.reset - max(HOUR, 0.2 * W_c)`, compared in float64 as numpy does.
        guard Double(tLast) >= Double(reset) - max(Double(HOUR), 0.2 * Double(Wc)) else { return nil }
        let firstE = t[0] - start
        var es: [Millis] = []
        var e = step
        while e < Wc - 5 * MIN {
            if e >= firstE { es.append(e) }
            e += step
        }
        guard !es.isEmpty else { return nil }
        let n = t.count
        let L = lags.count
        var u0s = [Double](), rates = [Double](), hours = [Double](), dows = [Int](), D = [Double]()
        u0s.reserveCapacity(es.count); rates.reserveCapacity(es.count * L)
        hours.reserveCapacity(es.count); dows.reserveCapacity(es.count); D.reserveCapacity(es.count * M)
        let fr = (1...M).map { Double($0) / Double(M) }
        for e in es {
            let x = start + e
            var i = upper(t, x) - 1
            let u0 = i >= 0 ? util[i] : 0
            u0s.append(u0)
            for lag in lags { rates.append(u0 - stepAt(t, util, x - lag)) }
            hours.append(localHour(x, tz))
            dows.append(localDow(x, tz))
            // `Q = q + (fr * rem).astype(int64)`: non-decreasing in k, so the
            // last reading at or before each Q is found by walking forward.
            let rem = Double(reset - x)
            for k in 0..<M {
                let Q = x + Millis(fr[k] * rem)
                while i + 1 < n && t[i + 1] <= Q { i += 1 }
                D.append((i >= 0 ? util[i] : 0) - u0)
            }
        }
        return CycleCuts(account: account, reset: reset, count: es.count, e: es, u0: u0s, rates: rates,
                         hour: hours, dow: dows, D: D)
    }

    /// `build_meter_table`: every usable cycle among each account's latest
    /// `maxCycles` past cycles, cut every `step`.
    static func buildMeterTable(_ history: ArenaHistory, accounts: [String], kind: String, cap: String?,
                                tz: Millis, step: Millis, M: Int, maxCycles: Int = 400) -> MeterTable {
        let W = KitSpend.windowMs(kind)
        let lags = meterLags(kind)
        var blocks: [CycleCuts] = []
        for acct in accounts {
            let cycles = KitSpend.pastCycles(history, account: acct, windowKind: kind, scopeModel: cap)
            for c in cycles.suffix(maxCycles) {
                if let b = cycleCuts(account: acct, reset: c.reset, start: c.start, t: c.t, util: c.util,
                                     tz: tz, step: step, M: M, lags: lags) {
                    blocks.append(b)
                }
            }
        }
        return MeterTable(kind: kind, W: W, lags: lags, M: M, blocks: blocks)
    }

    /// `MeterQuery`: the meter now, in the table's features.
    struct MeterQuery: Sendable {
        /// Elapsed ms at now.
        var e: Double
        /// ms to the reset.
        var remaining: Double
        /// The latest reading.
        var u: Double
        /// Rise over each lag before now.
        var rates: [Double]
        var hour: Double
        var dow: Int
        var acct: String
        var now: Millis
    }

    /// `meter_weights`: each row's kernel weight against the query, widened
    /// until the effective sample size is adequate. Weights are in table row
    /// order.
    static func meterWeights(_ T: MeterTable, _ q: MeterQuery, _ cfg: ArenaConfig)
        -> (w: [Double], scale: Double, ess: Double) {
        let bwPhase = cfg.double("bw_phase_frac", 0.08) * Double(T.W)
        let bwHour = cfg.double("bw_hour", 1.5)
        let bwRate = cfg.double("bw_rate", 0.7)
        let tau = cfg.double("recency_days", 45) * Double(DAY)
        let otherAcct = cfg.double("other_account", 0.3)
        let weekendMis = cfg.double("weekend_mismatch", 0.5)
        let bwLevel = cfg.double("bw_level", 0)
        let L = T.lags.count
        let lq = q.rates.map { log1p(max($0, 0)) }
        let wkQ = q.dow >= 5
        let n = T.count
        // Everything that does not depend on the bandwidth scale, per row.
        var base = [Double](), de = [Double](), dh = [Double](), dl = [Double](), dlev = [Double]()
        base.reserveCapacity(n); de.reserveCapacity(n); dh.reserveCapacity(n); dl.reserveCapacity(n * L)
        if bwLevel > 0 { dlev.reserveCapacity(n) }
        let lu = log1p(q.u)
        for b in T.blocks {
            let acctW = b.account == q.acct ? 1.0 : otherAcct
            let rec = exp(Double(-(q.now - b.reset)) / tau)
            for r in 0..<b.count {
                base.append(acctW * rec * ((b.dow[r] >= 5) == wkQ ? 1.0 : weekendMis))
                de.append(Double(b.e[r]) - q.e)
                dh.append(circDiff(b.hour[r], q.hour))
                for j in 0..<L { dl.append(log1p(max(b.rates[r * L + j], 0)) - lq[j]) }
                if bwLevel > 0 { dlev.append(log1p(b.u0[r]) - lu) }
            }
        }
        func make(_ scale: Double) -> [Double] {
            let bp = bwPhase * scale, bh = bwHour * scale, br = bwRate * scale, bl = bwLevel * scale
            var w = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var x = base[i] * gauss(de[i], bp) * gauss(dh[i], bh)
                for j in 0..<L { x = x * gauss(dl[i * L + j], br) }
                if bwLevel > 0 { x = x * gauss(dlev[i], bl) }
                w[i] = x
            }
            return w
        }
        return widenUntil(make, targetEss: cfg.double("target_ess", 30))
    }

    // MARK: - Trajectories on the grid

    /// Where each grid time falls among a cut's M fractions of the time
    /// left (`analog_trajectories`' `fr`, `pos`, `a`).
    struct GridPositions {
        let pos: [Int]
        let a: [Double]
    }

    static func gridPositions(_ grid: [Millis], _ q: MeterQuery, M: Int) -> GridPositions {
        let fk = (0...M).map { $0 == 0 ? 0.0 : Double($0) / Double(M) }
        var pos = [Int](), a = [Double]()
        for g in grid {
            let fr = min(max((Double(g) - Double(q.now)) / max(q.remaining, 1.0), 0), 1)
            // searchsorted(fk, fr, side="right") - 1, clipped to [0, M-1].
            var lo = 0, hi = fk.count
            while lo < hi { let mid = (lo + hi) >> 1; if fk[mid] <= fr { lo = mid + 1 } else { hi = mid } }
            let p = min(max(lo - 1, 0), M - 1)
            pos.append(p)
            a.append((fr - fk[p]) / max(fk[p + 1] - fk[p], 1e-12))
        }
        return GridPositions(pos: pos, a: a)
    }

    /// The pace scaling of one row (`scale_alpha`; off in every shipped
    /// config, ported for parity): an analog that was burning slower than
    /// now is scaled up, and vice versa, by a damped ratio of paces.
    struct PaceScaling {
        let alpha: Double, c: Double, lo: Double, hi: Double, paceQ: Double, j: Int, L: Double
        init?(_ T: MeterTable, _ q: MeterQuery, _ cfg: ArenaConfig) {
            alpha = cfg.double("scale_alpha", 0)
            guard alpha > 0 else { return nil }
            j = T.lags.count - 1                       // the longest lag
            L = Double(T.lags[j])
            c = cfg.double("scale_floor", 2.0)
            lo = cfg.double("scale_min", 0.3); hi = cfg.double("scale_max", 3.0)
            paceQ = 0.5 * max(q.rates[j], 0) + 0.5 * q.u / max(q.e, L) * L
        }
        func s(_ b: CycleCuts, _ r: Int, nLags: Int) -> Double {
            let paceA = 0.5 * max(b.rates[r * nLags + j], 0) + 0.5 * b.u0[r] / max(Double(b.e[r]), L) * L
            return min(max(pow((paceQ + c) / (paceA + c), alpha), lo), hi)
        }
    }

    /// One row's whole-point increment at one grid time: its trajectory
    /// (`D' = [0, D…]`) read linearly between the fractions around the grid
    /// time, then kept whole like a reading (rounded toward zero, with a
    /// 1e-9 guard either way).
    @inline(__always)
    static func wholeIncrement(_ b: CycleCuts, _ r: Int, M: Int, pos: Int, a: Double, s: Double) -> Double {
        let base = r * M
        let d0 = (pos == 0 ? 0.0 : b.D[base + pos - 1]) * s
        let d1 = b.D[base + pos] * s
        let inc = d0 * (1 - a) + d1 * a
        return inc >= 0 ? (inc + 1e-9).rounded(.down) : (inc - 1e-9).rounded(.up)
    }

    /// `clip(u + inc, 0, 100)`.
    @inline(__always)
    static func level(_ u: Double, _ inc: Double) -> Double { min(max(u + inc, 0), 100) }

    /// The paths of the given rows (`meter_paths_from_table` after the draw):
    /// `[rows.count][grid.count]`. `rows` index the table in row order.
    static func trajectories(_ T: MeterTable, _ q: MeterQuery, _ grid: [Millis], rows: [Int],
                             _ cfg: ArenaConfig) -> [[Double]] {
        let gp = gridPositions(grid, q, M: T.M)
        let scaling = PaceScaling(T, q, cfg)
        // Row index → (block, row within it).
        var starts: [Int] = []
        var acc = 0
        for b in T.blocks { starts.append(acc); acc += b.count }
        return rows.map { i in
            var lo = 0, hi = starts.count
            while lo < hi { let mid = (lo + hi) >> 1; if starts[mid] <= i { lo = mid + 1 } else { hi = mid } }
            let b = T.blocks[lo - 1], r = i - starts[lo - 1]
            let s = scaling?.s(b, r, nLags: T.lags.count) ?? 1
            return (0..<grid.count).map { j in
                level(q.u, wholeIncrement(b, r, M: T.M, pos: gp.pos[j], a: gp.a[j], s: s))
            }
        }
    }

    // MARK: - Deterministic quantiles (`kit/detq.analog_quantiles`)

    /// `weighted_type1(analog_trajectories(…), w, levels)`: per grid time,
    /// the smallest path value whose cumulative normalized weight (values
    /// ascending) reaches the level, within 1e-9. `[levels.count][grid]`.
    ///
    /// Every path value is `clip(u + inc)` with `inc` a whole number, which
    /// is non-decreasing in `inc`; so the quantile is read off a weight
    /// histogram of the increments, one pass over the rows per grid time,
    /// rather than a sort. The cumulative weights are the same sums in a
    /// different order: they can differ from numpy's in the last bit, which
    /// moves a level only when its cumulative weight lands within ~1e-16 of
    /// a jump (port-spec open question 5).
    static func weightedType1(_ T: MeterTable, _ q: MeterQuery, _ grid: [Millis], w: [Double],
                              levels: [Double], _ cfg: ArenaConfig) -> [[Double]] {
        let n = T.count
        precondition(w.count == n)
        var total = 0.0
        for x in w { total += x }
        let p = w.map { $0 / total }
        let gp = gridPositions(grid, q, M: T.M)
        let scaling = PaceScaling(T, q, cfg)
        let L = T.lags.count
        var scales: [Double]? = nil
        if let scaling {
            var s: [Double] = []
            s.reserveCapacity(n)
            for b in T.blocks { for r in 0..<b.count { s.append(scaling.s(b, r, nLags: L)) } }
            scales = s
        }
        let order = levels.indices.sorted { levels[$0] < levels[$1] }
        var out = [[Double]](repeating: [Double](repeating: 0, count: grid.count), count: levels.count)
        var inc = [Int](repeating: 0, count: n)
        var hist: [Double] = []
        var present: [Bool] = []
        for j in 0..<grid.count {
            let pos = gp.pos[j], a = gp.a[j]
            var lo = Int.max, hi = Int.min
            var i = 0
            for b in T.blocks {
                for r in 0..<b.count {
                    let v = Int(wholeIncrement(b, r, M: T.M, pos: pos, a: a, s: scales?[i] ?? 1))
                    inc[i] = v
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                    i += 1
                }
            }
            let nb = hi - lo + 1
            if hist.count < nb { hist = [Double](repeating: 0, count: nb); present = [Bool](repeating: false, count: nb) }
            for k in 0..<nb { hist[k] = 0; present[k] = false }
            for i in 0..<n { hist[inc[i] - lo] += p[i]; present[inc[i] - lo] = true }
            // The largest value is the answer when no cumulative weight
            // reaches a level (`min(searchsorted(...), n - 1)`).
            var last = nb - 1
            while last > 0 && !present[last] { last -= 1 }
            var k = 0
            var cum = hist[0]
            for li in order {
                let target = levels[li] - KitDetQ.type1Tol
                while cum < target && k < last { k += 1; cum += hist[k] }
                out[li][j] = level(q.u, Double(lo + k))
            }
        }
        return out
    }

    /// The exact five-hour forecast: the weighted type-1 quantiles, then the
    /// dispersion shrink toward the weighted median (monotone, so it commutes
    /// with taking quantiles), in whole points. Returns the quantiles at
    /// `levels` and the median the shrink used.
    static func analogQuantiles(_ T: MeterTable, _ q: MeterQuery, _ grid: [Millis], w: [Double],
                                levels: [Double], _ cfg: ArenaConfig) -> (q: [[Double]], shrinkMedian: [Double]?) {
        var Q = weightedType1(T, q, grid, w: w, levels: levels, cfg)
        let shrink = cfg.double("shrink", 1.0)
        guard shrink < 1.0 else { return (Q, nil) }
        let med = levels.firstIndex(of: 0.5).map { Q[$0] }
            ?? weightedType1(T, q, grid, w: w, levels: [0.5], cfg)[0]
        for li in Q.indices {
            for j in Q[li].indices {
                Q[li][j] = min(max((med[j] + shrink * (Q[li][j] - med[j])).rounded(.toNearestOrEven), 0), 100)
            }
        }
        return (Q, med)
    }

    /// `meter_paths_from_table` from the draw on: `nPaths` rows drawn with
    /// probability `w / Σw`, their paths on the grid.
    static func meterPathsFromTable(_ T: MeterTable, _ q: MeterQuery, _ grid: [Millis], nPaths: Int,
                                    rng: inout ArenaRNG, _ cfg: ArenaConfig, w: [Double]) -> [[Double]] {
        let idx = sampleIdx(&rng, w, nPaths)
        return trajectories(T, q, grid, rows: idx, cfg)
    }

    /// `meter_paths_pace`: the cold-start fallback, a burst at a random rate
    /// for a random while. Unreachable with the shipped config (the day
    /// model always answers first, `block_method` is not "bootstrap"), kept
    /// so the model's branches read as the Python's.
    static func meterPathsPace(_ q: MeterQuery, _ grid: [Millis], nPaths: Int, rng: inout ArenaRNG,
                               kind: String) -> [[Double]] {
        let lags = meterLags(kind)
        let rRecent = lags.indices.map { q.rates[$0] / (Double(lags[$0]) / Double(HOUR)) }.max() ?? 0
        let rCycle = q.u / max(q.e / Double(HOUR), 0.25)
        var r = 0.6 * rRecent + 0.4 * rCycle
        if r <= 0 { r = kind == "five_hour" ? 2.0 : 0.5 }
        let pIdle = rRecent <= 0 ? 0.5 : 0.15
        let meanT = kind == "five_hour" ? 1.5 * Double(HOUR) : 12 * Double(HOUR)
        let tau = grid.map { Double($0) - Double(q.now) }
        let rate = (0..<nPaths).map { _ in r * exp(0.7 * rng.normal()) }
        let dur = (0..<nPaths).map { _ in -meanT * log(1 - rng.uniform()) }
        let idle = (0..<nPaths).map { _ in rng.uniform() < pIdle }
        return (0..<nPaths).map { p in
            tau.map { t in
                let inc = idle[p] ? 0 : (rate[p] * min(t, dur[p]) / Double(HOUR)).rounded(.down)
                return level(q.u, inc)
            }
        }
    }
}
