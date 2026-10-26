import Foundation

// `research/arena/kit/calib.py`, in Swift: the calibration layer. One
// child's meter forecasts with their spread recalibrated around the child's
// own median, learned only from the child's own out-of-sample past
// (`ctx.backtest`: each made by a fresh fit at its origin, without seeing
// what followed), scored on the readings known now that came after each
// origin, in its cycle, up to its reset.
//
// Only the `scale` method is ported (port-spec § "The calibration layer":
// the default, the only one the calibrated fixtures use, and the one that
// improved calibration without costing CRPS). The map changes the spread
// and never the median, so the point a surface shows is the child's.
//
// Storage: in memory, per run. The records are rebuilt from the child's
// backtests on every fit (the runner memoizes the child's forecasts, and
// the backtest origins sit on a fixed lattice, so consecutive fits share
// almost all of them); nothing is kept between runs.

public enum KitCalib {
    static let minMs: Millis = 60_000
    static let hourMs: Millis = 3_600_000
    /// The central coverages fitted (cover50, cover80, cover95).
    public static let knots: [Double] = [0.5, 0.8, 0.95]
    /// A stored forecast: its quantiles at (i + 0.5) / 40 per grid time.
    public static let mLevels = 40
    /// Scale factors live in [1 / sMax, sMax].
    public static let sMax = 3.0
    /// A reading "equals" a quantile within this.
    static let eps = 1e-6
    /// Lead bins, seconds: (upper edges, centres). Parameters are
    /// interpolated in log-lead between centres and held flat beyond.
    static let fiveHourBins: (edges: [Double], centres: [Double]) = ([1800, 7200, .infinity], [300, 3600, 11400])
    static let weeklyBins: (edges: [Double], centres: [Double]) =
        ([7200, 86400, 259_200, .infinity], [600, 25200, 151_200, 396_000])

    /// The layer's settings (`DEFAULTS` overlaid by `model.toml`).
    public struct Config: Sendable {
        public var method = "scale"
        public var n0 = 8.0
        public var n0Bin = 8.0
        public var minOrigins = 3
        public var sMax = KitCalib.sMax
        public var perBin = 8
        public var round = true
        public var backtest = true
        public var backtestEveryH: [String: Double] = ["five_hour": 2, "seven_day": 8, "weekly_scoped": 8]
        public var backtestN: [String: Int] = ["five_hour": 24, "seven_day": 24, "weekly_scoped": 24]

        public init() {}
        public init(_ c: ArenaConfig) {
            method = c.string("method", method)
            n0 = c.double("n0", n0)
            n0Bin = c.double("n0_bin", n0Bin)
            minOrigins = c.int("min_origins", minOrigins)
            sMax = c.double("s_max", sMax)
            perBin = c.int("per_bin", perBin)
            round = c.bool("round", round)
            backtest = c.bool("backtest", backtest)
            let e = c.table("backtest_every_h"), n = c.table("backtest_n")
            if !e.values.isEmpty { backtestEveryH = e.values.compactMapValues(\.double) }
            if !n.values.isEmpty { backtestN = n.values.compactMapValues(\.int) }
        }
    }

    public static func windowOf(_ kind: String) -> String { String(kind.split(separator: ":", maxSplits: 1)[0]) }

    static func binsOf(_ kind: String) -> (edges: [Double], centres: [Double]) {
        windowOf(kind) == "five_hour" ? fiveHourBins : weeklyBins
    }

    /// `kind_of`: the window kind a target's map is fitted for (each scoped
    /// cap its own).
    public static func kindOf(_ target: ArenaTarget, cap: String?) -> String {
        target == .meterScoped ? "weekly_scoped:\(cap ?? "None")" : target.windowKind
    }

    // MARK: - Small exact pieces

    /// `level_grid`.
    public static func levelGrid(_ m: Int) -> [Double] { (0..<m).map { (Double($0) + 0.5) / Double(m) } }

    /// `tie_interval` for one record: (F(y−), F(y)) of its samples at y.
    @inline(__always)
    static func tieInterval(_ q: UnsafeBufferPointer<Double>, _ y: Double) -> (Double, Double) {
        var below = 0, atOrBelow = 0
        let lo = y - eps, hi = y + eps
        for v in q {
            if v < lo { below += 1 }
            if v <= hi { atOrBelow += 1 }
        }
        let m = Double(q.count)
        return (Double(below) / m, Double(atOrBelow) / m)
    }

    /// `below_share`: the randomized PIT's chance of falling at or below x
    /// (a tie's PIT spread uniformly over it); for a point PIT, whether it
    /// is <= x.
    @inline(__always)
    static func belowShare(_ flo: Double, _ fhi: Double, _ x: Double) -> Double {
        let width = fhi - flo
        if width > 1e-12 { return max(min(fhi, x) - flo, 0) / width }
        return flo <= x + 1e-12 ? 1 : 0
    }

    /// `origin_weights`: each origin's records share a total weight of 1.
    static func originWeights(_ origin: [Millis]) -> [Double] {
        var count: [Millis: Int] = [:]
        for o in origin { count[o, default: 0] += 1 }
        return origin.map { 1.0 / Double(count[$0]!) }
    }

    /// The records' median (`read_sorted(q.T, [0.5])`): position m/2 − 0.5.
    @inline(__always)
    static func recordMedian(_ q: UnsafeBufferPointer<Double>) -> Double {
        let n = q.count
        let pos = min(max(0.5 * Double(n) - 0.5, 0), Double(n - 1))
        let i0 = Int(pos.rounded(.down)), i1 = min(i0 + 1, n - 1)
        let a = pos - Double(i0)
        return q[i0] * (1.0 - a) + q[i1] * a
    }

    /// One knot's records, flat: `q` is `[N × m]` row-major.
    public struct Records: Sendable {
        public var q: [Double] = []
        public var m = KitCalib.mLevels
        public var y: [Double] = []
        public var leadS: [Double] = []
        public var origin: [Millis] = []
        public var floor: [Double] = []
        public var whole: [Bool] = []
        public var count: Int { y.count }

        public init(m: Int = KitCalib.mLevels) { self.m = m }

        public init(q: [[Double]], y: [Double], leadS: [Double], origin: [Millis], floor: [Double], whole: [Bool]) {
            self.m = q.first?.count ?? KitCalib.mLevels
            self.q = q.flatMap { $0 }; self.y = y; self.leadS = leadS; self.origin = origin
            self.floor = floor; self.whole = whole
        }

        func take(_ idx: [Int]) -> Records {
            var r = Records(m: m)
            r.q.reserveCapacity(idx.count * m)
            for i in idx {
                r.q.append(contentsOf: q[(i * m)..<((i + 1) * m)])
                r.y.append(y[i]); r.leadS.append(leadS[i]); r.origin.append(origin[i])
                r.floor.append(floor[i]); r.whole.append(whole[i])
            }
            return r
        }

        mutating func append(_ o: Records) {
            q += o.q; y += o.y; leadS += o.leadS; origin += o.origin; floor += o.floor; whole += o.whole
        }
    }

    /// `fit_scale`: scale factors at `knots`. For knot c, the s in
    /// [1/sMax, sMax] at which the weighted chance that the reading falls
    /// outside the new central c-range is 1 − c. The records' samples are
    /// scaled around their median by s (both sides alike), clipped and
    /// rounded as `apply` would (`finish`), and the chance read from the
    /// randomized PIT. It only falls as s grows: bisection in log s, 40
    /// halvings, the smallest s that reaches the target (the nearer bound
    /// when none does).
    public static func fitScale(_ r: Records, weights w: [Double], sMax: Double = KitCalib.sMax) -> [Double] {
        var out = [Double](repeating: 1, count: knots.count)
        let n = r.count, m = r.m
        if n == 0 || KitMath.sum(w) <= 0 { return out }
        let wSum = KitMath.sum(w)
        var meds = [Double](repeating: 0, count: n)
        r.q.withUnsafeBufferPointer { qb in
            for i in 0..<n { meds[i] = recordMedian(UnsafeBufferPointer(rebasing: qb[(i * m)..<((i + 1) * m)])) }
        }
        // A record's samples are sorted, and what `miss` does to them (scale
        // around the median by s > 0, clip, round) never reorders them, so
        // F(y−) and F(y) are two binary searches instead of a pass over all
        // 40 (rows that are not sorted take the pass).
        let sorted: [Bool] = r.q.withUnsafeBufferPointer { qb in
            (0..<n).map { i in (1..<m).allSatisfy { qb[i * m + $0 - 1] <= qb[i * m + $0] } }
        }
        let mD = Double(m)
        var scaled = [Double](repeating: 0, count: m)
        var v = [Double](repeating: 0, count: n)
        func miss(_ s: Double, _ c: Double) -> Double {
            let a = (1.0 - c) / 2.0, b = (1.0 + c) / 2.0
            r.q.withUnsafeBufferPointer { qb in
                scaled.withUnsafeMutableBufferPointer { sb in
                    for i in 0..<n {
                        let med = meds[i], fl = r.floor[i], wh = r.whole[i]
                        let base = i * m
                        // scale_samples, then finish: clip to [floor, 100],
                        // round half to even where the child was whole.
                        @inline(__always) func t(_ j: Int) -> Double {
                            let x = min(max(med + s * (qb[base + j] - med), fl), 100.0)
                            return wh ? x.rounded(.toNearestOrEven) : x
                        }
                        let flo: Double, fhi: Double
                        if sorted[i] {
                            let y = r.y[i], lo = y - eps, hi = y + eps
                            var a0 = 0, a1 = m
                            while a0 < a1 { let mid = (a0 + a1) >> 1; if t(mid) < lo { a0 = mid + 1 } else { a1 = mid } }
                            var b0 = a0, b1 = m
                            while b0 < b1 { let mid = (b0 + b1) >> 1; if t(mid) <= hi { b0 = mid + 1 } else { b1 = mid } }
                            (flo, fhi) = (Double(a0) / mD, Double(b0) / mD)
                        } else {
                            for j in 0..<m { sb[j] = t(j) }
                            (flo, fhi) = tieInterval(UnsafeBufferPointer(sb), r.y[i])
                        }
                        v[i] = (belowShare(flo, fhi, a) + 1.0 - belowShare(flo, fhi, b)) * w[i]
                    }
                }
            }
            // weighted_mean: (v · w).sum() / w.sum(), numpy's pairwise sums.
            return KitMath.sum(v) / wSum
        }
        let lo0 = -log(sMax), hi0 = log(sMax)
        for (k, c) in knots.enumerated() {
            let target = 1.0 - c
            if miss(exp(hi0), c) > target { out[k] = sMax; continue }
            if miss(exp(lo0), c) <= target { out[k] = 1.0 / sMax; continue }
            var lo = lo0, hi = hi0
            for _ in 0..<40 {
                let mid = 0.5 * (lo + hi)
                if miss(exp(mid), c) <= target { hi = mid } else { lo = mid }
            }
            out[k] = exp(hi)
        }
        return out
    }

    // MARK: - A kind's fit

    /// The learned map of one window kind: per lead bin, the scale of the
    /// deviations from the median at `knots`, and how many forecast origins
    /// each rests on. (`h_lo`/`h_hi` belong to the unported `pit` method and
    /// stay "no change"; they are kept so the JSON round-trips.)
    public struct KindFit: Sendable, Codable, Equatable {
        public var kind: String
        public var method: String
        public var centersS: [Double]
        /// `[bins][3]`.
        public var s: [[Double]]
        public var hLo: [[Double]]
        public var hHi: [[Double]]
        public var nBin: [Int]
        public var n: Int

        enum CodingKeys: String, CodingKey {
            case kind, method, s, n
            case centersS = "centers_s", hLo = "h_lo", hHi = "h_hi", nBin = "n_bin"
        }

        public static func identity(_ kind: String, method: String, n: Int = 0) -> KindFit {
            let centres = binsOf(kind).centres
            let b = centres.count
            return KindFit(kind: kind, method: method, centersS: centres,
                           s: Array(repeating: [1, 1, 1], count: b), hLo: Array(repeating: knots, count: b),
                           hHi: Array(repeating: knots, count: b), nBin: Array(repeating: 0, count: b), n: n)
        }

        /// `at(lead_s)["s"]`: `[L][3]` at leads (seconds), linear in log-lead
        /// between the bins' centres (scales in log), flat beyond.
        public func scales(at leadS: [Double]) -> [[Double]] {
            let xc = centersS.map { Foundation.log($0) }
            let logS = (0..<3).map { k in s.map { Foundation.log($0[k]) } }
            return leadS.map { l in
                let x = Foundation.log(max(l, 1.0))
                return (0..<3).map { k in exp(KitDetQ.npInterp(x, xs: xc, ys: logS[k])) }
            }
        }

        /// `is_identity` (np.allclose: |a − b| <= 1e-8 + 1e-5 · |b|).
        public var isIdentity: Bool {
            func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-8 + 1e-5 * abs(b) }
            return s.allSatisfy { $0.allSatisfy { close($0, 1) } }
                && hLo.allSatisfy { zip($0, knots).allSatisfy { close($0, $1) } }
                && hHi.allSatisfy { zip($0, knots).allSatisfy { close($0, $1) } }
        }
    }

    /// `lead_bin`: `searchsorted(edges[:-1], lead, "left")`.
    public static func leadBin(_ kind: String, _ leadS: Double) -> Int {
        let edges = binsOf(kind).edges
        var b = 0
        for e in edges.dropLast() where e < leadS { b += 1 }
        return b
    }

    static func shrinkLog(_ raw: [Double], toward: [Double], _ lam: Double) -> [Double] {
        zip(raw, toward).map { exp(lam * log($0) + (1.0 - lam) * log($1)) }
    }

    /// `fit_kind` (method `scale`): fit one kind's map from its records.
    public static func fitKind(_ kind: String, _ r: Records, method: String = "scale", n0: Double = 6, n0Bin: Double = 6,
                               minOrigins: Int = 3, sMax: Double = KitCalib.sMax) -> KindFit {
        precondition(method == "scale", "only the calibration layer's scale method is ported")
        let nb = binsOf(kind).centres.count
        let n = Set(r.origin).count
        var fit = KindFit.identity(kind, method: method, n: n)
        if n < minOrigins { return fit }
        let b = r.leadS.map { leadBin(kind, $0) }
        fit.nBin = (0..<nb).map { j in Set((0..<r.count).filter { b[$0] == j }.map { r.origin[$0] }).count }
        let lam = Double(n) / (Double(n) + n0)
        let m = r.m
        // A single point that missed: no scale fixes it.
        let ok: [Bool] = r.q.withUnsafeBufferPointer { qb in
            (0..<r.count).map { i in
                let row = UnsafeBufferPointer(rebasing: qb[(i * m)..<((i + 1) * m)])
                let spread = row[m - 1] - row[0]
                return spread > eps || abs(r.y[i] - recordMedian(row)) <= eps
            }
        }
        func raw(_ idx: [Int]) -> [Double] {
            let sub = r.take(idx)
            return fitScale(sub, weights: originWeights(sub.origin), sMax: sMax)
        }
        let okIdx = (0..<r.count).filter { ok[$0] }
        let pooled = okIdx.isEmpty ? [1.0, 1.0, 1.0] : shrinkLog(raw(okIdx), toward: [1, 1, 1], lam)
        fit.s = (0..<nb).map { j in
            let idx = okIdx.filter { b[$0] == j }
            let nj = Set(idx.map { r.origin[$0] }).count
            return nj > 0 ? shrinkLog(raw(idx), toward: pooled, Double(nj) / (Double(nj) + n0Bin)) : pooled
        }
        return fit
    }

    // MARK: - Applying a fit to paths (or to a comonotone set of curves)

    /// `mid_ranks` for one column: (average 1-based rank − 0.5) / n, ties
    /// averaged (scipy's `rankdata(method="average")`).
    static func midRanks(_ col: [Double]) -> [Double] {
        let n = col.count
        let o = col.indices.sorted { col[$0] != col[$1] ? col[$0] < col[$1] : $0 < $1 }
        var r = [Double](repeating: 0, count: n)
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n && col[o[j + 1]] == col[o[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[o[k]] = (avg - 0.5) / Double(n) }
            i = j + 1
        }
        return r
    }

    /// The least-squares non-decreasing fit of one path (pool adjacent
    /// violators, unit weights: scipy's `isotonic_regression`).
    static func isotonic(_ y: [Double]) -> [Double] {
        var means: [Double] = [], weights: [Double] = [], sizes: [Int] = []
        for v in y {
            means.append(v); weights.append(1); sizes.append(1)
            while means.count > 1 && means[means.count - 2] > means[means.count - 1] {
                let w = weights[weights.count - 2] + weights[weights.count - 1]
                let mu = (means[means.count - 2] * weights[weights.count - 2]
                    + means[means.count - 1] * weights[weights.count - 1]) / w
                let sz = sizes[sizes.count - 2] + sizes[sizes.count - 1]
                means.removeLast(2); weights.removeLast(2); sizes.removeLast(2)
                means.append(mu); weights.append(w); sizes.append(sz)
            }
        }
        var out: [Double] = []
        out.reserveCapacity(y.count)
        for (mu, sz) in zip(means, sizes) { out.append(contentsOf: repeatElement(mu, count: sz)) }
        return out
    }

    /// `monotone_paths`: each path's closest non-decreasing path, only
    /// where it falls.
    static func monotonePaths(_ P: inout [[Double]]) {
        for i in P.indices where zip(P[i], P[i].dropFirst()).contains(where: { $1 - $0 < -1e-12 }) {
            P[i] = isotonic(P[i])
        }
    }

    /// `apply`: the child's paths `[n][G]` recalibrated by `fit` (nil or
    /// identity: unchanged).
    public static func apply(_ fit: KindFit?, _ paths: [[Double]], grid: [Millis], now: Millis,
                             roundWhole: Bool = true, cap: Double = 100) -> [[Double]] {
        guard let fit, !fit.isIdentity, paths.count >= 2, let g = paths.first?.count, g == grid.count else {
            return paths
        }
        let n = paths.count
        let k = fit.scales(at: grid.map { Double($0 - now) / 1000.0 })
        var V = paths
        var childMed = [Double](repeating: 0, count: g)
        var col = [Double](repeating: 0, count: n)
        for j in 0..<g {
            for i in 0..<n { col[i] = paths[i][j] }
            let r = midRanks(col)
            let med = KitDetQ.median(col)
            childMed[j] = med
            // V = m + s(c) · (P − m), s linear between the knots in the
            // central level c = |2r − 1|, flat outside.
            var newVals = (0..<n).map { i -> Double in
                let c = abs(2.0 * r[i] - 1.0)
                return med + KitDetQ.npInterp(c, xs: knots, ys: k[j]) * (col[i] - med)
            }
            // Rearrange: the k-th smallest child value (stable order) gets the
            // k-th smallest new one.
            let order = col.indices.sorted { col[$0] != col[$1] ? col[$0] < col[$1] : $0 < $1 }
            newVals.sort()
            for (rank, i) in order.enumerated() { V[i][j] = newVals[rank] }
        }
        // Shift each column so its median is exactly the child's (the two
        // middle paths sit either side of the median and move by a hair).
        for j in 0..<g {
            for i in 0..<n { col[i] = V[i][j] }
            let shift = childMed[j] - KitDetQ.median(col)
            for i in 0..<n { V[i][j] += shift }
        }
        let childMonotone = paths.allSatisfy { p in zip(p, p.dropFirst()).allSatisfy { $1 - $0 >= -1e-12 } }
        if childMonotone { monotonePaths(&V) }
        let whole = paths.allSatisfy { $0.allSatisfy { abs($0 - $0.rounded(.toNearestOrEven)) < 1e-9 } }
        if roundWhole && whole {
            for i in 0..<n { for j in 0..<g { V[i][j] = V[i][j].rounded(.toNearestOrEven) } }
        }
        var pMin = Double.infinity, pMax = -Double.infinity
        for p in paths { for x in p { pMin = min(pMin, x); pMax = max(pMax, x) } }
        let hi = max(cap, pMax)
        for i in 0..<n { for j in 0..<g { V[i][j] = min(max(V[i][j], pMin), hi) } }
        return V
    }

    // MARK: - Stored forecasts and their records

    /// One stored child forecast.
    final class Stored {
        let origin: Millis
        let key: String
        let kind: String
        let meter: ArenaMeterID
        let reset: Millis
        let grid: [Millis]
        /// `[mLevels][G]`, rounded through Float as the Python stores it.
        let q: [[Double]]
        /// The child's lowest value in this forecast (`apply` clips there).
        let floor: Double
        /// Every value a whole point (`apply` rounds).
        let whole: Bool
        var final = false
        var rec: Records?

        init(origin: Millis, key: String, kind: String, meter: ArenaMeterID, reset: Millis, grid: [Millis],
             q: [[Double]], floor: Double, whole: Bool) {
            self.origin = origin; self.key = key; self.kind = kind; self.meter = meter; self.reset = reset
            self.grid = grid; self.q = q; self.floor = floor; self.whole = whole
        }
    }

    /// The child's values on the grid as paths `[n][G]`: its own paths, or
    /// its quantile curves at the 200 curve levels treated as comonotone
    /// paths (how `kit/detq.calib_quantiles` feeds the layer).
    public static func curves(_ tf: ArenaTargetForecast) -> [[Double]] {
        if let p = tf.paths { return p }
        return KitDetQ.quantileRows(tf, levels: KitDetQ.curveLevels)
    }

    /// `Store`: the child's forecasts seen so far (backtests and this run's
    /// own), and the records they give against the readings known at a
    /// moment.
    final class Store {
        let perBin: Int
        private(set) var items: [String: Stored] = [:]
        private var order: [String] = []

        init(perBin: Int = 8) { self.perBin = perBin }

        @discardableResult
        func add(_ request: ArenaRequest, _ forecast: ArenaForecast) -> Int {
            var added = 0
            for tr in request.targets {
                guard let tf = forecast.byKey[tr.key], let reset = tr.resetAt else { continue }
                let p = curves(tf)
                guard p.count >= 1, p.allSatisfy({ $0.count == tr.grid.count && $0.allSatisfy(\.isFinite) }) else {
                    continue
                }
                let g = tr.grid.count
                // sorted_levels: per grid time, the values at (i + 0.5)/40,
                // stored as float32.
                var q = [[Double]](repeating: [Double](repeating: 0, count: g), count: mLevels)
                var col = [Double](repeating: 0, count: p.count)
                for j in 0..<g {
                    var inOrder = true
                    for i in p.indices {
                        col[i] = p[i][j]
                        if i > 0 && col[i] < col[i - 1] { inOrder = false }
                    }
                    if !inOrder { col.sort() }
                    for (li, lv) in levelGrid(mLevels).enumerated() {
                        q[li][j] = col.count == mLevels ? col[li] : KitDetQ.readSorted(col, lv)
                        q[li][j] = Double(Float(q[li][j]))
                    }
                }
                var pMin = Double.infinity
                var whole = true
                for row in p { for x in row { pMin = min(pMin, x); if abs(x - x.rounded(.toNearestOrEven)) >= 1e-9 { whole = false } } }
                let id = "\(request.now)|\(tr.key)"
                if items[id] == nil { order.append(id) }
                items[id] = Stored(origin: request.now, key: tr.key, kind: kindOf(tr.target, cap: tr.cap),
                                   meter: tr.meter, reset: reset, grid: tr.grid, q: q, floor: pMin, whole: whole)
                added += 1
            }
            return added
        }

        /// `{kind: records}` from every stored forecast made before now,
        /// against readings known at now.
        func records(_ history: ArenaHistory, now: Millis) -> [String: Records] {
            var acc: [String: Records] = [:]
            var kinds: [String] = []
            for id in order {
                guard let st = items[id], st.origin < now else { continue }
                let rec: Records?
                if st.final, let cached = st.rec {
                    rec = cached
                } else {
                    let (times, vals) = truth(history, st.meter, after: st.origin, until: now, resetAt: st.reset)
                    let keep = times.indices.filter { times[$0] <= st.grid[st.grid.count - 1] }
                    rec = select(st, keep.map { times[$0] }, keep.map { vals[$0] })
                    st.final = st.reset <= now - 10 * minMs
                    st.rec = st.final ? rec : nil
                }
                guard var r = rec else { continue }
                let k = r.count
                r.origin = Array(repeating: st.origin, count: k)
                r.floor = Array(repeating: st.floor, count: k)
                r.whole = Array(repeating: st.whole, count: k)
                if acc[st.kind] == nil { acc[st.kind] = Records(m: mLevels); kinds.append(st.kind) }
                acc[st.kind]!.append(r)
            }
            return acc
        }

        /// `_select`: at most `perBin` readings per lead bin, evenly spaced
        /// by index; the forecast's 40 quantiles read at each one's time.
        func select(_ st: Stored, _ times: [Millis], _ vals: [Double]) -> Records? {
            if times.isEmpty { return nil }
            let lead = times.map { Double($0 - st.origin) / 1000.0 }
            let b = lead.map { leadBin(st.kind, $0) }
            var pick: [Int] = []
            for j in Set(b).sorted() {
                var ix = b.indices.filter { b[$0] == j }
                if ix.count > perBin {
                    // np.unique(np.linspace(0, len − 1, per_bin).round()).
                    let step = Double(ix.count - 1) / Double(perBin - 1)
                    let at = Set((0..<perBin).map { i -> Int in
                        let x = i == perBin - 1 ? Double(ix.count - 1) : Double(i) * step
                        return Int(x.rounded(.toNearestOrEven))
                    }).sorted()
                    ix = at.map { ix[$0] }
                }
                pick += ix
            }
            pick.sort()
            let g = st.grid.map(Double.init)
            var r = Records(m: mLevels)
            for i in pick {
                let t = Double(times[i])
                for row in st.q { r.q.append(KitDetQ.npInterp(t, xs: g, ys: row)) }
                r.y.append(vals[i]); r.leadS.append(lead[i])
            }
            return r
        }
    }

    /// `MeterIndex.truth`: readings of the cycle resetting at `resetAt` with
    /// `tEvent` in (after, min(until, resetAt)], known at the history's now:
    /// real times, real values, never interpolated, never past the reset.
    static func truth(_ history: ArenaHistory, _ meter: ArenaMeterID, after: Millis, until: Millis,
                      resetAt: Millis) -> ([Millis], [Double]) {
        let rows = history.readings(meter)
        let end = min(until, resetAt)
        let half = Double(KitSpend.windowMs(meter.windowKind)) / 2
        // Rows are in event order: a binary search to the first after `after`.
        var lo = 0, hi = rows.count
        while lo < hi { let mid = (lo + hi) >> 1; if rows[mid].tEvent <= after { lo = mid + 1 } else { hi = mid } }
        var t: [Millis] = [], v: [Double] = []
        var i = lo
        while i < rows.count && rows[i].tEvent <= end {
            let r = rows[i]
            if r.active, let rs = r.resetsAt, abs(Double(rs - resetAt)) < half, let u = r.utilPct, u.isFinite {
                t.append(r.tEvent); v.append(u)
            }
            i += 1
        }
        return (t, v)
    }

    /// `fit_all`.
    static func fitAll(_ records: [String: Records], _ cfg: Config) -> [String: KindFit] {
        Dictionary(uniqueKeysWithValues: records.map { kind, r in
            (kind, fitKind(kind, r, method: cfg.method, n0: cfg.n0, n0Bin: cfg.n0Bin, minOrigins: cfg.minOrigins,
                           sMax: cfg.sMax))
        })
    }
}

/// `kit/calib.CalibModel`: an arena model over one child (`model.toml`
/// `children`, or config `child`). Meter targets come back recalibrated;
/// anything else the child answers passes through unchanged. The
/// `models/calib-*` folders are this class with their own settings.
public final class CalibModel: ArenaModel {
    let ctx: ArenaContext
    public let cfg: KitCalib.Config
    public let child: String
    let store: KitCalib.Store
    var history: ArenaHistory?
    public private(set) var fits: [String: KitCalib.KindFit] = [:]

    public init(context: ArenaContext) throws {
        ctx = context
        cfg = KitCalib.Config(context.config)
        child = context.config.string("child", context.children.first ?? "")
        if child.isEmpty { throw ArenaError.invalid("a calibration wrapper needs one child (model.toml `children`)") }
        if cfg.method != "scale" {
            throw ArenaError.invalid("calibration method \(cfg.method) is not ported (only scale)")
        }
        store = KitCalib.Store(perBin: cfg.perBin)
    }

    public func fit(_ history: ArenaHistory) throws {
        self.history = history
        backtested = false
    }

    /// The Python runs the child's backtests in `fit`. The Swift contract
    /// hands a model its view only once `fit` has returned
    /// (`ArenaContext.backtest` before then throws "backtest before fit"),
    /// so they run on the first `forecast` instead, on the same history:
    /// the same origins, the same records.
    private var backtested = false

    func runBacktests() throws {
        guard !backtested, let history else { return }
        backtested = true
        guard cfg.backtest else { return }
        let now = history.now
        for (every, targets, n) in backtestPlan() {
            try ctx.checkCancelled()
            // On a fixed lattice, so the child's backtest forecasts are
            // shared (the runner's memo) by fits at nearby moments.
            let since = KitSpend.floorDiv(now - Millis(n) * every, every) * every
            do {
                let items = try ctx.backtest(child, every: every, targets: targets, since: since)
                var added = 0
                for (req, fc) in items { added += store.add(req, fc) }
                ctx.log("backtest \(child) every \(Double(every) / Double(KitCalib.hourMs))h: \(items.count) origins, \(added) forecasts")
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                // No backtest: the layer starts as "no change".
                ctx.log("backtest \(child): \(error)")
            }
        }
    }

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        try runBacktests()
        let fc = try ctx.model(child).forecast(request)
        let now = request.now
        fits = calibrate(now)
        store.add(request, fc)
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets {
            guard let tf = fc.byKey[tr.key] else { continue }
            out[tr.key] = apply(KitCalib.kindOf(tr.target, cap: tr.cap), tf, grid: tr.grid, now: now)
        }
        return ArenaForecast(byKey: out)
    }

    /// The fitted maps from the records known at `now`.
    public func calibrate(_ now: Millis) -> [String: KitCalib.KindFit] {
        guard let history else { return [:] }
        let fits = KitCalib.fitAll(store.records(history, now: now), cfg)
        for (kind, f) in fits.sorted(by: { $0.key < $1.key }) {
            ctx.log("calib \(kind) @\(now): n=\(f.n) bins=\(f.nBin) s=\(f.s)")
        }
        return fits
    }

    /// The child's forecast for one target through the map in force: its
    /// paths through `apply` when it drew paths; otherwise its curves at
    /// the 200 curve levels, through `apply`, read at
    /// `KitDetQ.forecastLevels` (`kit/detq.calib_quantiles`: position
    /// α · 200 − 0.5 of each sorted column).
    public func apply(_ kind: String, _ tf: ArenaTargetForecast, grid: [Millis], now: Millis) -> ArenaTargetForecast {
        let fit = fits[kind]
        if tf.paths != nil {
            return ArenaTargetForecast(paths: KitCalib.apply(fit, KitCalib.curves(tf), grid: grid, now: now,
                                                             roundWhole: cfg.round), extras: tf.extras)
        }
        guard let fit, !fit.isIdentity else { return tf }
        let q = KitCalib.calibratedQuantiles(fit, curves: KitCalib.curves(tf), grid: grid, now: now,
                                             levels: KitDetQ.forecastLevels, roundWhole: cfg.round)
        return ArenaTargetForecast(levels: KitDetQ.forecastLevels, quantiles: q, extras: tf.extras)
    }

    /// `backtest_plan`: (every, targets, origins) per backtest call;
    /// windows sharing a cadence share a call. Only the wrapper's own
    /// targets are asked for: a fit is per window kind and only its own
    /// kinds are ever applied, so the Python's backtests of the others
    /// (spend-decay-30m's weekly forecasts under calib-spend-decay-30m) are
    /// work nothing reads.
    func backtestPlan() -> [(Millis, Set<ArenaTarget>, Int)] {
        var by: [Millis: (Set<ArenaTarget>, Int)] = [:]
        for t in [ArenaTarget.meterFiveHour, .meterSevenDay, .meterScoped] where ctx.spec.targets.contains(t) {
            guard let h = cfg.backtestEveryH[t.windowKind] else { continue }
            let every = Millis(h * Double(KitCalib.hourMs))
            let n = cfg.backtestN[t.windowKind] ?? 24
            let cur = by[every] ?? ([], 0)
            by[every] = (cur.0.union([t]), max(cur.1, n))
        }
        return by.keys.sorted().map { ($0, by[$0]!.0, by[$0]!.1) }
    }
}

extension KitCalib {
    /// `kit/detq.calib_quantiles` for one target: the child's curves
    /// through `apply`, each column sorted, read at `levels` (position
    /// level · n − 0.5). `[levels][G]`.
    public static func calibratedQuantiles(_ fit: KindFit?, curves: [[Double]], grid: [Millis], now: Millis,
                                           levels: [Double], roundWhole: Bool = true) -> [[Double]] {
        let V = apply(fit, curves, grid: grid, now: now, roundWhole: roundWhole)
        let g = grid.count
        var out = [[Double]](repeating: [Double](repeating: 0, count: g), count: levels.count)
        var col = [Double](repeating: 0, count: V.count)
        for j in 0..<g {
            for i in V.indices { col[i] = V[i][j] }
            col.sort()
            for (li, lv) in levels.enumerated() { out[li][j] = KitDetQ.readSorted(col, lv) }
        }
        return out
    }
}
