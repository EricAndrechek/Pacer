import CryptoKit
import Foundation

// `research/arena/models/g1-08-opus-fm/fmcal.py` (identical in
// g2-06-opus-fmgate2): recalibrated pretrained meter forecasts. The
// forecaster's quantiles of the meter's cumulative burn, remapped by what the
// same forecaster got wrong on this user's own past, in meter space.
//
// **Self-backtest.** The cumulative burn series (`FMSeries.meterSeries`:
// burn summed across cycles, never reset) is the same object at every moment
// of the history, so the forecaster is run at past cut points `c` exactly as
// it runs now (`SelfBacktest`). At each cut the meter read `usedC` in a cycle
// resetting at `resetC`; the forecast meter at lead L is
// `clip(usedC + burnQ(L), usedC, 100)`, the transformation the live forecast
// uses. Every lead that ended before now and inside that cycle gives the PIT
// of the meter as then read (randomised over ties: an idle stretch reads
// exactly `usedC`, a capped one exactly 100).
//
// **Quantile recalibration** (Kuleshov et al. 2018), conditional. The PITs
// are weighted by how alike their cut is to now (meter level, cycle phase,
// age, whether the meter was moving); per lead, the weighted empirical
// quantile function of the PITs, shrunk toward a prior by the effective
// number of PITs (`n / (n + n0)`), maps a nominal level `a` to the
// forecaster's level `Q_L(a)`: the calibrated quantile is `F^-1(Q_L(a))`.
// Leads in between interpolate the maps in log-lead.
//
// `EnsembleBackend` (several backends averaged) is not ported: neither
// model's config names an ensemble.

public enum FMCal {
    /// `LEADS_MIN`: the backtest leads, minutes, per window kind.
    public static let leadsMin: [String: [Double]] = [
        "five_hour": [0.5, 1, 2, 3, 5, 10, 20, 30, 60, 90, 120, 180, 240, 300],
        "seven_day": [1, 5, 15, 30, 60, 120, 240, 480, 720, 1440, 2160, 2880, 4320, 5760, 7200, 10080],
        "weekly_scoped": [1, 5, 15, 30, 60, 120, 240, 480, 720, 1440, 2160, 2880, 4320, 5760, 7200, 10080],
    ]

    /// `ALPHA`: the output levels, one per stratified path, (i + 0.5) / 200.
    public static let alpha: [Double] = (0..<200).map { (Double($0) + 0.5) / 200 }

    /// `ext_levels`: burn quantiles `[rows][Q]` at `levels` -> with anchors at
    /// level 0 (burn 0) and level 1 (the top tail continued), so every PIT
    /// lands inside.
    public static func extLevels(_ levels: [Double], _ q: [[Double]]) -> (lv: [Double], q: [[Double]]) {
        let ext = FMPaths.extendTails(levels, q)
        let lv = [0.0] + ext.levels + [1.0]
        let rows = ext.q.map { row -> [Double] in
            // np.maximum(fix_crossing(q), 0.0)
            let r = row.sorted().map { max($0, 0.0) }
            let n = r.count
            let top = r[n - 1] + (r[n - 1] - r[n - 2]) * 1.5 + 1e-6
            return [0.0] + r + [top]
        }
        return (lv, rows)
    }

    /// The context the network is handed: the cumulative burn relative to
    /// its latest value (rounded to 1e-9 points), so a cut's context, and the
    /// memo below, no longer depend on where the history's view starts (the
    /// app's slides forward as old cycles leave it).
    ///
    /// The Python hands the network the raw cumulative burn. Timestral
    /// normalizes each patch by the causal mean and std of what it has seen
    /// and adds the mean back, and its non-negative clip (at cumulative 0)
    /// only touches quantiles below the latest value, where the burn is 0
    /// anyway, so the network's answer moves with the offset. What does not
    /// is its float32 output: the Python reads quantiles near a cumulative
    /// value of thousands, where float32 resolves only 1e-4 to 1e-3 points,
    /// and a low quantile a hair above the latest value reads as exactly no
    /// burn. Those exact zeros are ties the PIT spreads over, so they shape
    /// the calibration (a tie-free version moved its quantiles by up to a
    /// point on the fixtures). `pythonBurn` puts that rounding back: each
    /// relative quantile is rounded as float32 at the raw magnitude, as the
    /// Python's is.
    public static func relativeContext(_ v: [Double]) -> [Double] {
        guard let last = v.last, last.isFinite else { return v }
        return v.map { $0.isFinite ? (($0 - last) * 1e9).rounded() / 1e9 : $0 }
    }

    /// The network's relative answer `[H][Q]` -> running max over time per
    /// level, rows sorted: `burn_quantiles` before its `max(·, 0)`. The
    /// rounding `pythonBurn` applies is monotone, so it commutes with both,
    /// and this part can be memoized whatever the raw magnitude.
    public static func runningSorted(_ r: [[Double]]) -> [[Double]] {
        guard let nq = r.first?.count else { return [] }
        var running = [Double](repeating: -.infinity, count: nq)
        return r.map { row in
            (0..<nq).map { k -> Double in running[k] = max(running[k], row[k]); return running[k] }.sorted()
        }
    }

    /// One row of `runningSorted` as the Python's burn: the quantile it
    /// would have read (`cLast + b` in float32, as the network returns it),
    /// minus the latest value, never negative.
    @inline(__always)
    public static func pythonBurn<F: BinaryFloatingPoint>(_ row: [F], cLast: Double) -> [Double] {
        row.map { max(Double(Float(cLast + Double($0))) - cLast, 0.0) }
    }

    /// A row of `runningSorted` as burn: from a relative answer
    /// (`pythonBurn`), or from a raw one (`burn_quantiles` exactly: minus the
    /// latest value, never negative).
    @inline(__always)
    static func burn<F: BinaryFloatingPoint>(_ row: [F], cLast: Double, relative: Bool) -> [Double] {
        relative ? pythonBurn(row, cLast: cLast) : row.map { max(Double($0) - cLast, 0.0) }
    }

    /// `pit`: the randomised PIT of `r` against one non-decreasing quantile
    /// row at `lv`. A value sitting on tied levels spreads over the tie's
    /// mass (up to the neighbours' midpoints), read at `u01`.
    public static func pit(_ lv: [Double], _ qrow: [Double], _ r: Double, _ u01: Double) -> Double {
        let n = qrow.count
        if r < qrow[0] { return 0.0 }
        if r > qrow[n - 1] { return 1.0 }
        // np.searchsorted left (first q >= r) and right (first q > r).
        var a = 0, b = n
        while a < b { let m = (a + b) >> 1; if qrow[m] < r { a = m + 1 } else { b = m } }
        let loI = a
        a = loI; b = n
        while a < b { let m = (a + b) >> 1; if qrow[m] <= r { a = m + 1 } else { b = m } }
        let hiI = a
        if hiI > loI {
            var lo = loI > 0 ? lv[loI - 1] : 0.0
            var hi = hiI < lv.count ? lv[hiI] : 1.0
            lo = loI > 0 ? 0.5 * (lo + lv[loI]) : 0.0
            hi = hiI < lv.count ? 0.5 * (hi + lv[hiI - 1]) : 1.0
            return lo + u01 * (hi - lo)
        }
        let j = loI
        let x0 = qrow[j - 1], x1 = qrow[j]
        return lv[j - 1] + (lv[j] - lv[j - 1]) * (r - x0) / max(x1 - x0, 1e-12)
    }

    /// `wquantile`: the weighted empirical quantile function, at the
    /// midpoints of each value's weight, read by `np.interp`.
    ///
    /// The sort is STABLE (ties keep record order). numpy's default argsort
    /// is not, so where tied PITs carry different weights the Python's order,
    /// and with it the map just past the tie, is arbitrary; the parity
    /// fixtures were made with a stable sort for that reason.
    public static func wquantile(_ x: [Double], _ w: [Double], _ q: [Double]) -> [Double] {
        let order = x.indices.sorted { x[$0] != x[$1] ? x[$0] < x[$1] : $0 < $1 }
        let xs = order.map { x[$0] }
        var c = [Double](repeating: 0, count: order.count)
        var s = 0.0
        for (i, o) in order.enumerated() { s += w[o]; c[i] = s }
        let total = s
        for (i, o) in order.enumerated() { c[i] = (c[i] - 0.5 * w[o]) / total }
        return q.map { KitDetQ.npInterp($0, xs: c, ys: xs) }
    }

    // MARK: - Self-backtest

    /// One past cut of the series, forecast as the live forecast would have
    /// been: its meta and the forecaster's extended burn quantiles at the
    /// rows the PIT records read (float32, as the Python keeps them).
    public struct Cut: Sendable {
        public let c: Millis
        public let cLast: Double
        public let usedC: Double
        public let resetC: Millis
        public let phase: Double
        public let act: Double
        public let lv: [Double]
        /// `bq[row]` for each of `SelfBacktest.rows`, aligned with them.
        public let bq: [[Float]]
    }

    /// `SelfBacktest`: the forecaster's quantiles at past cuts of one
    /// meter's series. The Python keeps its cuts on the instance across
    /// refreshes; a Swift model instance lives for one forecast, so the
    /// network calls are memoized by content instead (`FMCalCutCache`), and
    /// the assembled table on the history cut (every model asked on one cut
    /// shares it).
    public final class SelfBacktest {
        public let wk: String
        public let step: Millis
        public let ctxN: Int
        public let stale: Millis
        public let every: Millis
        public let maxCuts: Int
        public let duration: Millis
        public let leads: [Double]
        public let H: Int
        /// The burn rows the records read: `floor(L / step)` and the next,
        /// capped at `H`, for every lead.
        public let rows: [Int]
        let rowIndex: [Int: Int]
        /// The network's rows behind `rows` (burn row r is network row r - 1;
        /// row 0 is the zero row at now).
        let netRows: [Int]
        /// Every candidate cut, newest first (the Python dict's insertion
        /// order on a fresh instance); nil where the meter was idle or stale.
        public private(set) var cuts: [(c: Millis, cut: Cut?)] = []

        public init(wk: String, step: Millis, ctxN: Int, stale: Millis, every: Millis, maxCuts: Int, duration: Millis) {
            self.wk = wk; self.step = step; self.ctxN = ctxN; self.stale = stale
            self.every = every; self.maxCuts = maxCuts; self.duration = duration
            leads = FMCal.leadsMin[wk] ?? FMCal.leadsMin["seven_day"]!
            let maxLeadMs = (leads.max() ?? 0) * Double(FMSeries.minMs)
            H = Int((maxLeadMs / Double(step)).rounded(.up))
            var rs = Set<Int>()
            for L in leads {
                let pos = L * Double(FMSeries.minMs) / Double(step)
                let j0 = min(Int(pos.rounded(.down)), H)
                rs.insert(j0); rs.insert(min(j0 + 1, H))
            }
            rows = rs.sorted()
            rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1, $0) })
            netRows = rows.filter { $0 >= 1 }.map { $0 - 1 }
        }

        /// A cut's burn table at `rows` from its memoized relative rows:
        /// rounded as the Python reads them at this cut's magnitude, the zero
        /// row at now, then `ext_levels`, kept in float32 as the Python keeps
        /// them.
        func table(_ net: [[Float]], levels: [Double], cLast: Double, relative: Bool) -> (lv: [Double], bq: [[Float]]) {
            var burn: [[Double]] = []
            burn.reserveCapacity(rows.count)
            var k = 0
            for r in rows {
                if r == 0 { burn.append([Double](repeating: 0, count: levels.count)) } else {
                    burn.append(FMCal.burn(net[k], cLast: cLast, relative: relative)); k += 1
                }
            }
            let (lv, bq) = FMCal.extLevels(levels, burn)
            return (lv, bq.map { $0.map(Float.init) })
        }

        /// The cut times, newest first, on a fixed lattice (multiples of
        /// `every`) so successive forecasts share them.
        public func candidates(_ series: FMSeries.MeterSeries, now: Millis) -> [Millis] {
            let t0 = series.times.first ?? now
            let last = now - Millis(leads[0] * Double(FMSeries.minMs))
            let hi = FMSeries.floorDiv(last, every) * every
            // np.arange(hi, t0 + step * 12, -every)[:max_cuts]
            var out: [Millis] = []
            var c = hi
            let stop = t0 + step * 12
            while c > stop && out.count < maxCuts { out.append(c); c -= every }
            return out
        }

        /// `refresh` for a fresh instance: every candidate cut, its network
        /// call answered by `cache` when an identical context was forecast
        /// before (any cut, any forecast, this process).
        ///
        /// `relative`: hand the network each cut's context relative to its
        /// latest value (`FMCal.relativeContext`, the default in the app) or
        /// raw, as the Python does.
        public func refresh(_ fc: TimestralForecaster, weightsID: String, series s: FMSeries.MeterSeries, now: Millis,
                            cache: FMCalCutCache = .shared, relative: Bool = true,
                            checkCancelled: () throws -> Void = {}) throws {
            let cand = candidates(s, now: now)
            let k30 = max(1, Int((30.0 * Double(FMSeries.minMs) / Double(step)).rounded(.toNearestOrEven)))
            var pending: [(slot: Int, c: Millis, ctx: [Double], key: FMCalCutCache.Key,
                           meta: (cLast: Double, used: Double, reset: Millis, phase: Double, act: Double))] = []
            cuts = []
            cuts.reserveCapacity(cand.count)
            let tag = "\(weightsID)|\(wk)|\(step)|\(ctxN)|\(H)|\(relative ? "rel" : "raw")|"
                + netRows.map(String.init).joined(separator: ",")
            for c in cand {
                // j = searchsorted(times, c, "right") - 1
                let j = Self.lastAtOrBefore(s.times, c)
                if j < 0 || c - s.times[j] > stale || !s.active[j] || s.reset[j] <= c {
                    cuts.append((c, nil)); continue
                }
                let v = FMSeries.resampleLast(times: s.times, values: s.cum,
                                              grid: FMSeries.regularGrid(now: c, stepMs: step, n: ctxN), staleMs: stale)
                guard let vLast = v.last, vLast.isFinite else { cuts.append((c, nil)); continue }
                let resetC = s.reset[j]
                let phase = 1.0 - Double(resetC - c) / Double(duration)
                let back = v[v.count - 1 - k30]
                let act = back.isFinite ? vLast - back : 0.0
                let meta = (cLast: vLast, used: s.cycleUtil[j], reset: resetC, phase: phase, act: act)
                let rel = relative ? FMCal.relativeContext(v) : v
                let key = FMCalCutCache.Key(tag: tag, context: rel)
                if let hit = cache.get(key) {
                    let (lv, bq) = table(hit.rows, levels: hit.lv, cLast: meta.cLast, relative: relative)
                    cuts.append((c, Cut(c: c, cLast: meta.cLast, usedC: meta.used, resetC: resetC, phase: phase,
                                        act: act, lv: lv, bq: bq)))
                } else {
                    cuts.append((c, nil))
                    pending.append((cuts.count - 1, c, rel, key, meta))
                }
            }
            // The missing cuts in batches of 32, as the Python's. A series'
            // answer does not depend on its batch-mates (checked bit for bit:
            // CombinedTimingTests.batchedRowsAreBitIdentical), which the memo
            // relies on.
            var b = 0
            while b < pending.count {
                try checkCancelled()
                let batch = pending[b..<min(b + 32, pending.count)]
                let out = try FMBackends.quantiles(fc, context: batch.map { [$0.ctx] }, horizon: H)
                for (k, p) in batch.enumerated() {
                    // Network values are float32, so Float keeps them exactly.
                    let B = FMCal.runningSorted(out.curve(k))
                    let kept = netRows.map { r in B[r].map(Float.init) }
                    cache.put(p.key, FMCalCutCache.Entry(lv: out.levels, rows: kept))
                    let (lv, bq) = table(kept, levels: out.levels, cLast: p.meta.cLast, relative: relative)
                    cuts[p.slot] = (p.c, Cut(c: p.c, cLast: p.meta.cLast, usedC: p.meta.used, resetC: p.meta.reset,
                                             phase: p.meta.phase, act: p.meta.act, lv: lv, bq: bq))
                }
                b += 32
            }
        }

        /// The PIT records: (lead index, pit, level, phase, age ms, act).
        public struct Records: Sendable {
            public var li: [Int] = []
            public var pit: [Double] = []
            public var lev: [Double] = []
            public var phase: [Double] = []
            public var age: [Double] = []
            public var act: [Double] = []
        }

        /// `records`: one PIT per (cut, lead) whose lead ended before now and
        /// inside the cut's cycle, with a fresh reading then. `u01` draws the
        /// position inside a tie (the Python draws `rng.random()` for every
        /// record, tie or not).
        public func records(_ s: FMSeries.MeterSeries, now: Millis, u01: () -> Double) -> Records {
            var out = Records()
            let minMs = Double(FMSeries.minMs)
            for (_, cut) in cuts {
                guard let cut else { continue }
                for (i, L) in leads.enumerated() {
                    let te = cut.c + Millis(L * minMs)
                    if te > now || te > cut.resetC { break }
                    let j = Self.lastAtOrBefore(s.times, te)
                    if j < 0 || te - s.times[j] > stale || !s.active[j] { continue }
                    if abs(Double(s.reset[j] - cut.resetC)) >= Double(duration) / 2 { continue }
                    let realised = s.cycleUtil[j]
                    let pos = L * minMs / Double(step)
                    let j0 = min(Int(pos.rounded(.down)), H)
                    let j1 = min(j0 + 1, H)
                    let f = pos - Double(j0)
                    let r0 = cut.bq[rowIndex[j0]!], r1 = cut.bq[rowIndex[j1]!]
                    var row = [Double](repeating: 0, count: r0.count)
                    for k in 0..<r0.count {
                        let x = cut.usedC + (1 - f) * Double(r0[k]) + f * Double(r1[k])
                        row[k] = min(max(x, cut.usedC), 100.0)
                    }
                    out.li.append(i)
                    out.pit.append(FMCal.pit(cut.lv, row, realised, u01()))
                    out.lev.append(cut.usedC)
                    out.phase.append(cut.phase)
                    out.age.append(Double(now - cut.c))
                    out.act.append(cut.act)
                }
            }
            return out
        }

        /// `searchsorted(times, t, side="right") - 1`.
        @inline(__always)
        static func lastAtOrBefore(_ times: [Millis], _ t: Millis) -> Int {
            var lo = 0, hi = times.count
            while lo < hi { let mid = (lo + hi) >> 1; if times[mid] <= t { lo = mid + 1 } else { hi = mid } }
            return lo - 1
        }
    }

    // MARK: - Calibration

    /// `Calibration`: per-lead PIT quantile maps for one forecast, weighted
    /// toward cuts like now.
    public struct Calibration: Sendable {
        public let leads: [Double]
        /// `[leads][ALPHA]`: the forecaster's level for each nominal level.
        public var maps: [[Double]]
        /// The effective number of PITs behind each lead's map (negative:
        /// carried from a shorter lead).
        public var n: [Double]

        public init(leads: [Double], records r: SelfBacktest.Records, levelNow: Double, phaseNow: Double,
                    cfg: ArenaConfig, priorRows: [[Double]]?, priorLevels: [Double]?, actNow: Double) throws {
            self.leads = leads
            let alpha = FMCal.alpha
            let n0 = cfg.double("cal_n0", 30)
            let sl = cfg.double("cal_sigma_level", 15.0)
            let sp = cfg.double("cal_sigma_phase", 0.2)
            let ta = cfg.double("cal_age_tau_d", 30.0) * 86_400_000
            let calPrior = cfg.string("cal_prior", "offline")
            guard calPrior == "offline" else {
                // "pooled" (one map over every lead) is not ported: neither model uses it.
                throw ArenaError.invalid("fmcal cal_prior \(calPrior) is not ported")
            }
            let count = r.pit.count
            var wAll = [Double](repeating: 1, count: count)
            if count > 0 {
                if sl > 0 { for i in 0..<count { let z = (r.lev[i] - levelNow) / sl; wAll[i] *= exp(-0.5 * (z * z)) } }
                if sp > 0 { for i in 0..<count { let z = (r.phase[i] - phaseNow) / sp; wAll[i] *= exp(-0.5 * (z * z)) } }
                if ta > 0 { for i in 0..<count { wAll[i] *= exp(-r.age[i] / ta) } }
                let mm = cfg.double("cal_act_mismatch_w", 0.25)
                for i in 0..<count { wAll[i] *= ((r.act[i] > 0) == (actNow > 0)) ? 1.0 : mm }
            }
            maps = [[Double]](repeating: alpha, count: leads.count)
            n = [Double](repeating: 0, count: leads.count)
            var priors: [[Double]]?
            if let priorRows, let priorLevels {
                let k = cfg.double("prior_strength", 1.0)
                priors = priorRows.map { row in
                    alpha.map { a in k * KitDetQ.npInterp(a, xs: priorLevels, ys: row) + (1 - k) * a }
                }
            }
            // Group the records by lead once (the Python masks per lead).
            var byLead = [[Int]](repeating: [], count: leads.count)
            for (k, i) in r.li.enumerated() where i < leads.count { byLead[i].append(k) }
            var prior = alpha
            var lastOK: Int?
            let pmin = cfg.double("prior_min_lead", 60)
            for i in 0..<leads.count {
                if let priors { prior = leads[i] >= pmin ? priors[min(i, priors.count - 1)] : alpha }
                let idx = byLead[i]
                let w = idx.map { wAll[$0] }
                let wSum = KitMath.sum(w)
                if idx.count >= 3 && wSum > 0 {
                    let neff = wSum * wSum / KitMath.sum(w.map { $0 * $0 })
                    let emp = FMCal.wquantile(idx.map { r.pit[$0] }, w, alpha)
                    let a = neff / (neff + n0)
                    maps[i] = (0..<alpha.count).map { a * emp[$0] + (1 - a) * prior[$0] }
                    n[i] = neff
                    lastOK = i
                } else if let lastOK, priors == nil {
                    maps[i] = maps[lastOK]
                    n[i] = -n[lastOK]
                } else {
                    maps[i] = prior
                }
            }
        }

        /// `levels`: `[leadMin.count][ALPHA]`, the maps interpolated in
        /// log-lead (flat beyond the backtest's leads), clipped to [0, 1].
        public func levels(_ leadMin: [Double]) -> [[Double]] {
            let xs = leads.map { log($0) }
            let na = FMCal.alpha.count
            return leadMin.map { L in
                let x = log(max(L, 1e-3))
                var row = [Double](repeating: 0, count: na)
                // np.interp per level, sharing the bracket.
                if x <= xs[0] {
                    for a in 0..<na { row[a] = maps[0][a] }
                } else if x >= xs[xs.count - 1] {
                    for a in 0..<na { row[a] = maps[xs.count - 1][a] }
                } else {
                    var lo = 0, hi = xs.count - 1
                    while hi - lo > 1 { let mid = (lo + hi) >> 1; if xs[mid] <= x { lo = mid } else { hi = mid } }
                    if xs[lo] == x {
                        for a in 0..<na { row[a] = maps[lo][a] }
                    } else {
                        let dx = xs[lo + 1] - xs[lo]
                        for a in 0..<na {
                            let slope = (maps[lo + 1][a] - maps[lo][a]) / dx
                            row[a] = slope * (x - xs[lo]) + maps[lo][a]
                        }
                    }
                }
                return row.map { min(max($0, 0.0), 1.0) }
            }
        }
    }
}

// MARK: - The network calls' memo

/// The self-backtest's network calls, memoized by content: a cut's context
/// (the cumulative burn on its regular grid) and the forecaster settings
/// decide its answer completely, so the same context forecast again (the
/// next forecast's backtest shares all but its newest cuts; g2-06 shares
/// g1-08's) is answered from here. The arena's Python keeps the same cuts on
/// its model instance; a Swift instance lives for one forecast, and the
/// contract's runner memo only covers declared children, so this is
/// process-wide. Bounded: each entry keeps only the rows the PIT records
/// read (a few KB); past `capacity` the least recently used half goes.
public final class FMCalCutCache: @unchecked Sendable {
    public static let shared = FMCalCutCache(capacity: 4096)

    public struct Key: Hashable, Sendable {
        let tag: String
        let digest: SHA256.Digest
        /// The settings and a SHA-256 of the context's exact bits (NaN
        /// included), so a key is small whatever the context length.
        public init(tag: String, context: [Double]) {
            self.tag = tag
            digest = context.withUnsafeBytes { SHA256.hash(data: $0) }
        }
    }

    /// The network's levels and its relative answer, run up and sorted
    /// (`FMCal.runningSorted`), at the rows a cut's records read.
    public final class Entry: @unchecked Sendable {
        public let lv: [Double]
        public let rows: [[Float]]
        public init(lv: [Double], rows: [[Float]]) { self.lv = lv; self.rows = rows }
    }

    private let lock = NSLock()
    private var map: [Key: (entry: Entry, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    public let capacity: Int
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(capacity: Int) { self.capacity = max(capacity, 16) }

    public func get(_ key: Key) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        tick &+= 1
        guard let e = map[key] else { misses += 1; return nil }
        hits += 1
        map[key] = (e.entry, tick)
        return e.entry
    }

    public func put(_ key: Key, _ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        tick &+= 1
        map[key] = (entry, tick)
        if map.count > capacity {
            // Drop the least recently used half (amortized O(1) per insert).
            let cut = map.values.map(\.tick).sorted()[map.count / 2]
            map = map.filter { $0.value.tick >= cut }
        }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }

    /// For memory pressure: everything here can be recomputed.
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
    }
}
