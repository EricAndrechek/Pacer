import Foundation

// `research/arena/kit/ml/combine.py`, in Swift: combining children's meter
// forecasts.
//
// **The ledger.** Every child forecast a combiner sees, from `ctx.backtest`
// (made over the parent's past without hindsight) or from its own calls
// during the run, is kept as m sorted samples per grid time. At each
// forecast the ledger scores every kept forecast on the readings known *now*
// that came after its origin, in its cycle, up to the reset (the scorer's
// truth, thinned to at most `maxEvals` readings per forecast): so the
// weights only ever use truth that has arrived.
//
// **Weights**, per target kind (five-hour, seven-day, each scoped cap):
// `ewaWeights` (exponentially weighted averaging of discounted relative
// losses) and `stackWeights` (the simplex weights minimizing the pooled
// forecast's own CRPS over the scored forecasts). The Python's
// `FformaWeights` is not ported: it reads `kit/ml/features`
// (`FeatureBuilder`), which no ported model here uses.
//
// **Pools** turn weights and children's samples into paths: `poolMixture`
// (draw each child's share of paths: a linear pool), `poolQuantile`
// (Vincentization), `poolMedian`; `poolMixtureExact` is the linear pool as
// its exact quantile function, no draws (what a deterministic port uses).
//
// A child here may answer with paths or with quantiles (the Swift ports of
// the arena's sampling models answer with the exact quantiles of what the
// Python draws); `KitMLPaths.sortedSamples(_:m:)` reads either as m sorted
// samples per grid time, which is all the ledger and the pools need.

public enum KitMLCombine {
    static let minMs: Millis = 60_000
    static let hourMs: Millis = 3_600_000

    /// `METER`: the meter targets and their window kinds.
    public static let meter: [ArenaTarget: String] = [
        .meterFiveHour: "five_hour", .meterSevenDay: "seven_day", .meterScoped: "weekly_scoped",
    ]
    /// `METER_TARGETS`, in the Python's order.
    public static let meterTargets: [ArenaTarget] = [.meterFiveHour, .meterSevenDay, .meterScoped]

    /// `kind_of`: the window, with the cap for a scoped meter.
    public static func kindOf(_ target: ArenaTarget, cap: String?) -> String {
        let w = meter[target] ?? target.windowKind
        return w == "weekly_scoped" ? "\(w):\(cap ?? "None")" : w
    }

    /// The meter a target reads (`data.meter(account, METER[target], cap)`:
    /// the cap only for a scoped meter).
    static func meterID(_ target: ArenaTarget, account: String, cap: String?) -> ArenaMeterID {
        ArenaMeterID(account: account, windowKind: target.windowKind, scopeModel: target == .meterScoped ? cap : nil)
    }

    static func windowMs(_ target: ArenaTarget) -> Millis { target.windowMillis }

    // MARK: - The ledger

    /// One child's forecast of one target from one origin: m sorted samples
    /// per grid time, stored as float32 as the Python stores them.
    public struct Entry: Sendable {
        public let child: String
        public let origin: Millis
        public let grid: [Millis]
        /// `[m][G]`, float32 values held in Double.
        public let q: [[Double]]
    }

    /// Every child's forecast of one target key from one origin, and its
    /// truth so far.
    public final class Group {
        public let origin: Millis
        public let key: String
        public let kind: String
        public let target: ArenaTarget
        public let account: String
        public let cap: String?
        public let reset: Millis
        public internal(set) var entries: [String: Entry] = [:]
        public internal(set) var times: [Millis] = []
        public internal(set) var y: [Double] = []
        public internal(set) var scoredAt: Millis?
        public internal(set) var final = false
        var xCache: [String: [[Double]]] = [:]

        init(origin: Millis, key: String, kind: String, target: ArenaTarget, account: String, cap: String?,
             reset: Millis) {
            self.origin = origin; self.key = key; self.kind = kind; self.target = target
            self.account = account; self.cap = cap; self.reset = reset
        }

        /// `[m][E]`: the child's sorted samples read at the truth times
        /// (`np.interp` on its grid).
        public func x(_ child: String) -> [[Double]] {
            if let hit = xCache[child] { return hit }
            guard let e = entries[child] else { return [] }
            let g = e.grid.map(Double.init)
            let t = times.map(Double.init)
            let v = e.q.map { row in t.map { KitDetQ.npInterp($0, xs: g, ys: row) } }
            xCache[child] = v
            return v
        }

        /// How much of the forecast's span (origin to reset) the truth so far
        /// covers: a forecast scored only on its first hour says little about
        /// how it reads a whole cycle, so learners weight groups by this.
        public func coverage() -> Double {
            if final { return 1.0 }
            guard let at = scoredAt, reset > origin else { return 0.0 }
            return min(max(Double(min(at, reset) - origin) / Double(reset - origin), 0.0), 1.0)
        }

        /// Mean CRPS per child (NaN when the child has no forecast here).
        public func losses(_ children: [String]) -> [Double] {
            children.map { c in
                guard entries[c] != nil else { return .nan }
                let crps = KitMLPaths.crpsSorted(x(c), y)
                return crps.isEmpty ? .nan : crps.reduce(0, +) / Double(crps.count)
            }
        }
    }

    public final class Ledger {
        public let m: Int
        public let maxEvals: Int
        struct GroupKey: Hashable { let origin: Millis; let key: String }
        private(set) var groupsByKey: [GroupKey: Group] = [:]
        /// Insertion order, as the Python's dict keeps it.
        private var order: [GroupKey] = []

        public init(m: Int = 40, maxEvals: Int = 16) { self.m = m; self.maxEvals = maxEvals }

        public var groups: [Group] { order.compactMap { groupsByKey[$0] } }

        /// Keep each meter target's forecast; a forecast with the wrong
        /// shape or a non-finite value is skipped. Returns how many it kept.
        @discardableResult
        public func add(_ child: String, _ request: ArenaRequest, _ forecast: ArenaForecast) -> Int {
            var n = 0
            for tr in request.targets {
                guard meter[tr.target] != nil, let tf = forecast.byKey[tr.key], let reset = tr.resetAt else { continue }
                if let p = tf.paths, p.contains(where: { $0.count != tr.grid.count }) { continue }
                if tf.paths == nil, tf.gridCount != tr.grid.count { continue }
                let s = KitMLPaths.sortedSamples(tf, m: m)
                guard s.count == m, s.allSatisfy({ $0.count == tr.grid.count && $0.allSatisfy(\.isFinite) }) else {
                    continue
                }
                let k = GroupKey(origin: request.now, key: tr.key)
                let g: Group
                if let hit = groupsByKey[k] {
                    g = hit
                } else {
                    g = Group(origin: request.now, key: tr.key, kind: kindOf(tr.target, cap: tr.cap), target: tr.target,
                              account: tr.accounts[0], cap: tr.cap, reset: reset)
                    groupsByKey[k] = g
                    order.append(k)
                }
                g.entries[child] = Entry(child: child, origin: request.now, grid: tr.grid,
                                         q: s.map { row in row.map { Double(Float($0)) } })
                g.xCache[child] = nil
                g.scoredAt = nil
                n += 1
            }
            return n
        }

        /// Truth for every group from the readings known at `history.now`.
        public func score(_ history: ArenaHistory) {
            let now = history.now
            for k in order {
                guard let g = groupsByKey[k], !g.final, g.scoredAt != now else { continue }
                let id = meterID(g.target, account: g.account, cap: g.cap)
                guard history.store.meters[id] != nil, history.accounts.contains(g.account) else { continue }
                let rows = history.readings(id)
                var (t, y) = cycleReadings(rows, reset: g.reset, duration: windowMs(g.target), asof: now,
                                           upto: min(g.reset, now), after: g.origin)
                if t.count > maxEvals {
                    let pick = linspaceIndices(t.count, maxEvals)
                    t = pick.map { t[$0] }; y = pick.map { y[$0] }
                }
                g.times = t
                g.y = y
                g.xCache = [:]
                g.scoredAt = now
                g.final = g.reset <= now - 10 * minMs
            }
        }

        /// The scored groups of one kind made before `before`, in order.
        public func scored(_ kind: String, before: Millis) -> [Group] {
            groups.filter { $0.kind == kind && !$0.y.isEmpty && $0.origin < before }
        }
    }

    /// `MeterSeries.cycle_readings(reset, asof, upto)` restricted to
    /// `t_event > after`: the readings of the cycle resetting at `reset`
    /// known at `asof`, active, under that reset (within half a window),
    /// with a value, `t_event` in [reset − window − 1 h, min(upto, reset)].
    static func cycleReadings(_ rows: [ArenaReading], reset: Millis, duration: Millis, asof: Millis, upto: Millis,
                              after: Millis) -> ([Millis], [Double]) {
        let lowT = max(reset - duration - hourMs, after + 1)
        let highT = min(upto, reset)
        var lo = 0, hi = rows.count
        while lo < hi { let mid = (lo + hi) >> 1; if rows[mid].tEvent < lowT { lo = mid + 1 } else { hi = mid } }
        let half = Double(duration) / 2
        var t: [Millis] = [], v: [Double] = []
        var i = lo
        while i < rows.count && rows[i].tEvent <= highT {
            let r = rows[i]
            i += 1
            guard r.active, r.tKnown <= asof, let rs = r.resetsAt, abs(Double(rs - reset)) < half,
                  let u = r.utilPct, u.isFinite else { continue }
            t.append(r.tEvent); v.append(u)
        }
        return (t, v)
    }

    /// `np.unique(np.linspace(0, n - 1, k).round().astype(int))`.
    static func linspaceIndices(_ n: Int, _ k: Int) -> [Int] {
        guard k > 1 else { return [0] }
        let step = Double(n - 1) / Double(k - 1)
        var out: [Int] = []
        for i in 0..<k {
            let x = i == k - 1 ? Double(n - 1) : Double(i) * step
            let r = Int(x.rounded(.toNearestOrEven))
            if out.last != r { out.append(r) }
        }
        return out
    }

    /// `MeterSeries.level_at(asof)[0]`: the newest reading known at `asof`
    /// (by event time; on a tie the later-known copy) when its cycle is
    /// still active, else 0. NaN when that reading has no value, as in the
    /// Python; callers decide what a NaN level means.
    static func levelAt(_ rows: [ArenaReading], asof: Millis) -> Double {
        var best: ArenaReading?
        var i = rows.count - 1
        while i >= 0 {
            let r = rows[i]
            i -= 1
            if r.tKnown > asof { continue }
            if let b = best {
                if r.tEvent < b.tEvent { break }
                if r.tKnown > b.tKnown { best = r }
            } else {
                best = r
            }
        }
        guard let r = best, r.active, let reset = r.resetsAt, reset > asof, r.tEvent <= asof else { return 0 }
        return r.utilPct ?? .nan
    }

    /// The readings of the meter a target reads (`data.meter(...)`), or nil
    /// when the history holds no such meter.
    static func meterRows(_ history: ArenaHistory, _ target: ArenaTarget, account: String,
                          cap: String?) -> [ArenaReading]? {
        let id = meterID(target, account: account, cap: cap)
        guard history.store.meters[id] != nil, history.accounts.contains(account) else { return nil }
        return history.readings(id)
    }

    // MARK: - Losses and discounting

    /// `relative_losses`: `[groups][children]` CRPS / the mean over the
    /// children present (at least `floor` points); a missing child takes
    /// the worst present loss. Rows with no child present are NaN.
    public static func relativeLosses(_ groups: [Group], _ children: [String], floor: Double = 0.25) -> [[Double]] {
        groups.map { g in
            let row = g.losses(children)
            let ok = row.filter(\.isFinite)
            if ok.isEmpty { return row.map { _ in .nan } }
            let denom = max(ok.reduce(0, +) / Double(ok.count), floor)
            let r = row.map { $0 / denom }
            let worst = r.filter(\.isFinite).max() ?? .nan
            return r.map { $0.isFinite ? $0 : worst }
        }
    }

    /// `discount`: each group's weight in learning, halving every
    /// `halfLife` newer forecasts of its kind (forgetting by evidence, not
    /// by the clock), times the share of its span the truth covers.
    public static func discount(_ groups: [Group], halfLife: Double) -> [Double] {
        let origins = groups.map(\.origin)
        return groups.map { g in
            let newer = Double(origins.filter { $0 > g.origin }.count)
            return pow(0.5, newer / max(halfLife, 1e-6)) * g.coverage()
        }
    }

    // MARK: - Weights

    /// `ewa_weights`: w ∝ exp(−η Σ discounted relative losses).
    public static func ewaWeights(_ groups: [Group], _ children: [String], eta: Double = 0.5,
                                  halfLife: Double = 24.0) -> [Double] {
        let k = children.count
        let eq = [Double](repeating: 1.0 / Double(k), count: k)
        guard !groups.isEmpty else { return eq }
        let R = relativeLosses(groups, children)
        let ok = R.map { $0.allSatisfy(\.isFinite) }
        guard ok.contains(true) else { return eq }
        let d = discount(groups, halfLife: halfLife)
        var S = [Double](repeating: 0, count: k)
        for (i, row) in R.enumerated() where ok[i] { for c in 0..<k { S[c] += d[i] * row[c] } }
        let lo = S.min() ?? 0
        let w = S.map { exp(-eta * ($0 - lo)) }
        let tot = w.reduce(0, +)
        return w.map { $0 / tot }
    }

    /// `stack_weights`: simplex weights minimizing the discounted mean CRPS
    /// of the pooled forecast over the scored groups where every child
    /// answered, plus `shrink` × ‖w − 1/k‖² toward equal weights. For a
    /// mixture the CRPS is the exact quadratic Σ wᵢaᵢ − ½ Σ wᵢwⱼDᵢⱼ and the
    /// minimum is found exactly (`simplexMinQuadratic`); for a quantile pool
    /// by `simplexMin`.
    public static func stackWeights(_ groups: [Group], _ children: [String], pool: String = "mixture",
                                    halfLife: Double = 48.0, shrink: Double = 0.05) -> [Double] {
        let k = children.count
        let eq = [Double](repeating: 1.0 / Double(k), count: k)
        let full = groups.filter { g in children.allSatisfy { g.entries[$0] != nil } }
        guard !full.isEmpty, k > 1 else { return eq }
        var d = discount(full, halfLife: halfLife)
        let dsum = d.reduce(0, +)
        guard dsum > 0 else { return eq }
        d = d.map { $0 / dsum }
        if pool == "mixture" {
            var a = [Double](repeating: 0, count: k)
            var D = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
            for (wg, g) in zip(d, full) {
                let X = children.map { g.x($0) }
                for i in 0..<k { a[i] += wg * meanAbs(X[i], g.y) }
                for i in 0..<k {
                    for j in stride(from: i + 1, to: k, by: 1) {
                        let v = meanPairAbs(X[i], X[j])
                        D[i][j] += wg * v
                        D[j][i] += wg * v
                    }
                    D[i][i] += wg * 2 * mean(halfGini(X[i]))
                }
            }
            let scale = max(a.reduce(0, +) / Double(k), 1e-6)
            return simplexMinQuadratic(a: a, D: D, scale: scale, shrink: shrink)
        }
        let Xs = zip(d, full).map { wg, g in (wg, children.map { g.x($0) }, g.y) }
        let scale = max(Xs.map { _, X, y in X.map { meanAbs($0, y) }.reduce(0, +) / Double(k) }.reduce(0, +)
                        / Double(Xs.count), 1e-6)
        return simplexMin(k) { w in
            var s = 0.0
            for (wg, X, y) in Xs {
                let mixed = weightedSum(X, w)
                let c = KitMLPaths.crpsSorted(mixed, y)
                s += wg * c.reduce(0, +) / Double(max(c.count, 1))
            }
            return s / scale + shrink * zip(w, eq).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
        }
    }

    /// `_half_gini`: E|X − X'| / 2 per column of sorted samples `[m][E]`.
    public static func halfGini(_ x: [[Double]]) -> [Double] {
        let m = x.count
        guard m > 0 else { return [] }
        var out = [Double](repeating: 0, count: x[0].count)
        for i in 0..<m {
            let w = Double(2 * (i + 1) - m - 1)
            for e in out.indices { out[e] += w * x[i][e] }
        }
        let mm = Double(m * m)
        return out.map { $0 / mm }
    }

    /// `np.abs(x - y[None, :]).mean()` over every sample and column.
    static func meanAbs(_ x: [[Double]], _ y: [Double]) -> Double {
        var s = 0.0
        for row in x { for e in y.indices { s += abs(row[e] - y[e]) } }
        return s / Double(max(x.count * y.count, 1))
    }

    /// `np.abs(Xi[:, None, :] - Xj[None, :, :]).mean()`: E|Xᵢ − Xⱼ| over
    /// every pair of samples and every column. From sorted columns, by a
    /// merge (Σ over pairs of |a − b| = Σ over values of value × (pairs it
    /// is the larger of − pairs it is the smaller of)), O(m) per column.
    static func meanPairAbs(_ xi: [[Double]], _ xj: [[Double]]) -> Double {
        let mi = xi.count, mj = xj.count
        guard mi > 0, mj > 0, let e = xi.first?.count, e > 0 else { return 0 }
        var total = 0.0
        var a = [Double](repeating: 0, count: mi), b = [Double](repeating: 0, count: mj)
        for c in 0..<e {
            for s in 0..<mi { a[s] = xi[s][c] }
            for s in 0..<mj { b[s] = xj[s][c] }
            total += pairAbsSum(a, b)
        }
        return total / Double(mi * mj * e)
    }

    /// Σᵢⱼ |aᵢ − bⱼ| for ascending a and b (re-sorted when they are not).
    static func pairAbsSum(_ a0: [Double], _ b0: [Double]) -> Double {
        let a = isAscending(a0) ? a0 : a0.sorted()
        let b = isAscending(b0) ? b0 : b0.sorted()
        // For each a_s: Σ_t |a_s − b_t| = a_s·(#b ≤ a_s) − Σ(b ≤ a_s) + Σ(b > a_s) − a_s·(#b > a_s).
        var prefix = [Double](repeating: 0, count: b.count + 1)
        for t in 0..<b.count { prefix[t + 1] = prefix[t] + b[t] }
        let totalB = prefix[b.count]
        var s = 0.0
        var t = 0
        for x in a {
            while t < b.count && b[t] <= x { t += 1 }
            let below = Double(t), above = Double(b.count - t)
            s += x * below - prefix[t] + (totalB - prefix[t]) - x * above
        }
        return s
    }

    static func isAscending(_ x: [Double]) -> Bool {
        zip(x, x.dropFirst()).allSatisfy { $0 <= $1 }
    }

    static func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }

    /// `np.tensordot(w, X, axes=1)`: Σᵢ wᵢ Xᵢ for `[k][m][E]`.
    static func weightedSum(_ X: [[[Double]]], _ w: [Double]) -> [[Double]] {
        guard let first = X.first else { return [] }
        var out = first.map { row in row.map { _ in 0.0 } }
        for (i, Xi) in X.enumerated() where w[i] != 0 {
            for r in Xi.indices { for c in Xi[r].indices { out[r][c] += w[i] * Xi[r][c] } }
        }
        return out
    }

    // MARK: - The simplex

    /// `_simplex_min` for the mixture objective
    /// `(a·w − ½ wᵀDw) / scale + shrink · ‖w − 1/k‖²`, solved exactly.
    ///
    /// The Python hands the same function to SLSQP (`ftol` 1e-10). It is a
    /// strictly convex quadratic on the simplex (the energy distance makes
    /// −D conditionally positive definite there; the shrink term adds
    /// curvature), so its minimum is unique and is the one support set whose
    /// equality-constrained optimum is feasible and meets the KKT conditions.
    /// With k ≤ 6 children every support (at most 63) is tried; the result
    /// is what SLSQP converges toward, to its own tolerance.
    public static func simplexMinQuadratic(a: [Double], D: [[Double]], scale: Double, shrink: Double) -> [Double] {
        let k = a.count
        guard k > 1 else { return [1.0] }
        let eq = 1.0 / Double(k)
        // f(w) = c·w + ½ wᵀHw + const.
        let c = (0..<k).map { a[$0] / scale - 2 * shrink * eq }
        let H = (0..<k).map { i in (0..<k).map { j in -D[i][j] / scale + (i == j ? 2 * shrink : 0) } }
        func f(_ w: [Double]) -> Double {
            var s = 0.0
            for i in 0..<k {
                var hw = 0.0
                for j in 0..<k { hw += H[i][j] * w[j] }
                s += c[i] * w[i] + 0.5 * w[i] * hw
            }
            return s
        }
        var best: [Double]?
        var bestF = Double.infinity
        let tol = 1e-12
        for mask in 1..<(1 << k) {
            let S = (0..<k).filter { mask & (1 << $0) != 0 }
            let n = S.count
            // [H_SS 1; 1ᵀ 0] [w_S; μ] = [−c_S; 1].
            var A = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n + 1)
            var rhs = [Double](repeating: 0, count: n + 1)
            for (r, i) in S.enumerated() {
                for (cc, j) in S.enumerated() { A[r][cc] = H[i][j] }
                A[r][n] = 1
                A[n][r] = 1
                rhs[r] = -c[i]
            }
            rhs[n] = 1
            guard let sol = solve(A, rhs) else { continue }
            if sol.prefix(n).contains(where: { $0 < -tol }) { continue }
            var w = [Double](repeating: 0, count: k)
            for (r, i) in S.enumerated() { w[i] = max(sol[r], 0) }
            let mu = sol[n]
            // KKT for the coordinates held at zero: ∂f/∂wᵢ + μ ≥ 0.
            var kkt = true
            for i in 0..<k where mask & (1 << i) == 0 {
                var g = c[i]
                for j in 0..<k { g += H[i][j] * w[j] }
                if g + mu < -1e-10 { kkt = false; break }
            }
            guard kkt else { continue }
            let fw = f(w)
            if fw < bestF { bestF = fw; best = w }
        }
        guard var w = best else { return simplexMin(k) { f($0) } }
        let s = w.reduce(0, +)
        if s > 0 { w = w.map { $0 / s } } else { w = [Double](repeating: eq, count: k) }
        return w
    }

    /// `_simplex_min` for any (convex) function of the weights: projected
    /// gradient descent from equal weights, central-difference gradients,
    /// a backtracking step. The Python uses SLSQP; both find the minimum of
    /// a convex function to their own tolerance, not bit for bit.
    public static func simplexMin(_ k: Int, _ fun: ([Double]) -> Double) -> [Double] {
        guard k > 1 else { return [1.0] }
        var w = [Double](repeating: 1.0 / Double(k), count: k)
        var fw = fun(w)
        var step = 0.5
        for _ in 0..<400 {
            let h = 1e-7
            let g = (0..<k).map { i -> Double in
                var p = w, m = w
                p[i] += h; m[i] -= h
                return (fun(p) - fun(m)) / (2 * h)
            }
            var improved = false
            while step > 1e-12 {
                let cand = projectSimplex(zip(w, g).map { $0 - step * $1 })
                let fc = fun(cand)
                if fc < fw - 1e-15 { w = cand; fw = fc; improved = true; step *= 1.5; break }
                step *= 0.5
            }
            if !improved { break }
        }
        let s = w.reduce(0, +)
        return s > 0 ? w.map { max($0, 0) / s } : [Double](repeating: 1.0 / Double(k), count: k)
    }

    /// The Euclidean projection onto the probability simplex.
    static func projectSimplex(_ v: [Double]) -> [Double] {
        let u = v.sorted(by: >)
        var css = 0.0, theta = 0.0
        for (i, x) in u.enumerated() {
            css += x
            let t = (css - 1) / Double(i + 1)
            if x - t > 0 { theta = t }
        }
        return v.map { max($0 - theta, 0) }
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solve(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        let n = b.count
        for col in 0..<n {
            var p = col
            for r in stride(from: col + 1, to: n, by: 1) where abs(A[r][col]) > abs(A[p][col]) { p = r }
            guard abs(A[p][col]) > 1e-14 else { return nil }
            if p != col { A.swapAt(p, col); b.swapAt(p, col) }
            for r in stride(from: col + 1, to: n, by: 1) {
                let f = A[r][col] / A[col][col]
                if f == 0 { continue }
                for c in col..<n { A[r][c] -= f * A[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in stride(from: r + 1, to: n, by: 1) { s -= A[r][c] * x[c] }
            x[r] = s / A[r][r]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    // MARK: - Pools

    /// The largest-remainder split of n among weights (`pool_mixture`'s
    /// counts): floor(wᵢ n), the rest to the largest remainders (stable).
    public static func counts(_ w: [Double], _ n: Int) -> [Int] {
        let raw = w.map { $0 * Double(n) }
        var cnt = raw.map { Int($0.rounded(.down)) }
        let rest = n - cnt.reduce(0, +)
        if rest > 0 {
            let order = cnt.indices.sorted { a, b in
                let ra = raw[a] - Double(cnt[a]), rb = raw[b] - Double(cnt[b])
                return ra != rb ? ra > rb : a < b
            }
            for i in order.prefix(rest) { cnt[i] += 1 }
        }
        return cnt
    }

    /// `pool_mixture`: a linear pool, round(wᵢ n) of child i's own paths
    /// (largest remainder), drawn without replacement when it has enough.
    /// `ArenaRNG`, not numpy's stream: within Monte-Carlo bounds only.
    public static func poolMixture(_ paths: [[[Double]]], _ w: [Double], _ n: Int, rng: inout ArenaRNG) -> [[Double]] {
        let cnt = counts(w, n)
        var out: [[Double]] = []
        out.reserveCapacity(n)
        for (P, c) in zip(paths, cnt) where c > 0 && !P.isEmpty {
            if c > P.count {
                for _ in 0..<c { out.append(P[min(Int(rng.uniform() * Double(P.count)), P.count - 1)]) }
            } else {
                var idx = Array(P.indices)
                for i in 0..<c {
                    let j = i + min(Int(rng.uniform() * Double(idx.count - i)), idx.count - i - 1)
                    idx.swapAt(i, j)
                    out.append(P[idx[i]])
                }
            }
        }
        return out
    }

    /// The linear pool as its exact quantile function, no draws: child i's
    /// share cᵢ (the same largest-remainder counts) read as cᵢ sorted
    /// samples at (j + 0.5) / cᵢ, pooled and sorted per grid time. What
    /// `pool_mixture` samples, without its noise (`[n][G]`, sorted).
    public static func poolMixtureExact(_ forecasts: [ArenaTargetForecast], _ w: [Double], _ n: Int) -> [[Double]] {
        let tot = max(w.reduce(0, +), 1e-12)
        let cnt = counts(w.map { $0 / tot }, n)
        var rows: [[Double]] = []
        rows.reserveCapacity(n)
        for (tf, c) in zip(forecasts, cnt) where c > 0 { rows += KitMLPaths.sortedSamples(tf, m: c) }
        KitMLPaths.sortColumns(&rows)
        return rows
    }

    /// `pool_quantile`: Vincentization, the weighted average of the
    /// children's quantiles at n levels per grid time.
    public static func poolQuantile(_ paths: [[[Double]]], _ w: [Double], _ n: Int) -> [[Double]] {
        weightedSum(paths.map { KitMLPaths.sortedSamples($0, m: n) }, w)
    }

    /// `pool_median`: per grid time and level, the median of the children's
    /// quantiles.
    public static func poolMedian(_ paths: [[[Double]]], _ n: Int) -> [[Double]] {
        let S = paths.map { KitMLPaths.sortedSamples($0, m: n) }
        guard let first = S.first else { return [] }
        return first.indices.map { r in first[r].indices.map { c in KitDetQ.median(S.map { $0[r][c] }) } }
    }

    public static func pool(_ kind: String, _ paths: [[[Double]]], _ w: [Double], _ n: Int,
                            rng: inout ArenaRNG) -> [[Double]] {
        switch kind {
        case "quantile": poolQuantile(paths, w, n)
        case "median": poolMedian(paths, n)
        default: poolMixture(paths, w, n, rng: &rng)
        }
    }
}

// MARK: - The combiner model

/// `kit/ml/combine.Combiner`: an arena model over children named in config
/// `children` (else every declared child). Subclasses override `weightsFor`
/// (and may replace `forecast`). Config: `pool` (mixture | quantile |
/// median), `backtest_every_h`, `backtest_n`, `backtest` (bool), `m`,
/// `max_evals`, `half_life_n` (forgetting in forecasts of a kind: {window:
/// n} or a number).
///
/// The Python runs the children's backtests in `fit`. The Swift contract
/// hands a model its view only once `fit` has returned (`ArenaContext
/// .backtest` before then throws "backtest before fit"), so they run on the
/// first `forecast` instead, on the same history: the same origins, the
/// same forecasts. And only the plans whose targets the request asks for:
/// weights are per kind, so a five-hour forecast never reads a weekly
/// backtest (each plan still asks for all of its targets, so the runner's
/// memo is shared with every other parent on the same lattice).
public class KitMLCombiner: ArenaModel {
    public class var rule: String { "equal" }
    public class var defaultPool: String { "mixture" }
    public class var usesBacktest: Bool { true }

    public let ctx: ArenaContext
    public let cfg: ArenaConfig
    public let children: [String]
    public var rng: ArenaRNG
    public let poolKind: String
    public let ledger: KitMLCombine.Ledger
    public internal(set) var history: ArenaHistory?
    public internal(set) var lastWeights: [String: [String: Double]] = [:]
    var backtested: Set<Millis> = []

    public required init(context: ArenaContext) throws {
        ctx = context
        cfg = context.config
        let named = context.config["children"]?.array?.compactMap(\.string) ?? []
        children = named.isEmpty ? context.children : named
        if children.isEmpty {
            throw ArenaError.invalid("a combiner needs children (model.toml `children`, config `children`)")
        }
        rng = context.rng
        poolKind = context.config.string("pool", Self.defaultPool)
        ledger = KitMLCombine.Ledger(m: context.config.int("m", 40), maxEvals: context.config.int("max_evals", 16))
    }

    /// Forgetting, in forecasts of the kind (config `half_life_n`: a
    /// number, or {window: n}).
    public func halfLife(_ kind: String) -> Double {
        if let t = cfg["half_life_n"]?.table {
            return t.double(KitCalib.windowOf(kind), 24.0)
        }
        return cfg.double("half_life_n", 24.0)
    }

    public func fit(_ history: ArenaHistory) throws {
        self.history = history
        backtested = []
    }

    /// `backtest_plan`: (every, targets) per backtest call. Weekly meters
    /// need origins spread over more than a cycle, or none of their truth is
    /// complete (the runner keeps the latest 48 origins).
    public func backtestPlan() -> [(every: Millis, targets: Set<ArenaTarget>)] {
        var hours: [String: Double] = ["five_hour": 2, "seven_day": 8, "weekly_scoped": 8]
        if let t = cfg["backtest_every_h"] {
            if let tab = t.table { hours = tab.values.compactMapValues(\.double) }
            else if let h = t.double { hours = ["five_hour": h, "seven_day": h, "weekly_scoped": h] }
        }
        var by: [Millis: Set<ArenaTarget>] = [:]
        for t in KitMLCombine.meterTargets {
            guard let w = KitMLCombine.meter[t], let h = hours[w] else { continue }
            by[Millis(h * Double(KitMLCombine.hourMs)), default: []].insert(t)
        }
        return by.keys.sorted().map { ($0, by[$0]!) }
    }

    /// The backtests the request needs that have not run on this fit.
    public func runBacktests(for request: ArenaRequest) throws {
        guard let history, Self.usesBacktest, cfg.bool("backtest", true) else { return }
        let wanted = Set(request.targets.map(\.target))
        let n = cfg["backtest_n"]?.int
        for (every, targets) in backtestPlan() where !backtested.contains(every) && !targets.isDisjoint(with: wanted) {
            backtested.insert(every)
            // The latest `backtest_n` origins (the runner caps them at 48): each
            // one is a fresh fit of every child, which a heavy child pays for.
            // On a fixed lattice, so runs share origins (and the runner's memo).
            let since = n.map { KitSpend.floorDiv(history.now - Millis($0) * every, every) * every }
            for c in children {
                try ctx.checkCancelled()
                do {
                    let items = try ctx.backtest(c, every: every, targets: targets, since: since)
                    let added = items.reduce(0) { $0 + ledger.add(c, $1.request, $1.forecast) }
                    ctx.log("backtest \(c) every \(Double(every) / Double(KitMLCombine.hourMs))h: \(items.count) origins, \(added) forecasts")
                } catch ArenaError.cancelled {
                    throw ArenaError.cancelled
                } catch {
                    // A child without a backtest just starts unweighted.
                    ctx.log("backtest \(c): \(error)")
                }
            }
        }
    }

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let history else { throw ArenaError.invalid("forecast before fit") }
        try runBacktests(for: request)
        var got: [String: ArenaForecast] = [:]
        for c in children {
            do {
                got[c] = try ctx.model(c).forecast(request)
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                // A failing child is left out of this forecast.
                ctx.log("child \(c) failed: \(error)")
                continue
            }
            ledger.add(c, request, got[c]!)
        }
        ledger.score(history)
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets where KitMLCombine.meter[tr.target] != nil {
            let avail = children.filter { got[$0]?.byKey[tr.key] != nil }
            if avail.isEmpty { out[tr.key] = flat(tr); continue }
            // A child's own paths, or its quantiles as that many sorted samples.
            let paths = avail.map { c -> [[Double]] in
                let tf = got[c]!.byKey[tr.key]!
                return tf.paths ?? KitMLPaths.sortedSamples(tf, m: tr.nPaths)
            }
            let kind = KitMLCombine.kindOf(tr.target, cap: tr.cap)
            let w = weightsFor(kind, tr, avail, paths, now: request.now)
            lastWeights[tr.key] = Dictionary(uniqueKeysWithValues: zip(avail, w))
            ctx.log("weights \(tr.key) @\(request.now): " + zip(avail, w).map { "\($0)=\(String(format: "%.3f", $1))" }
                .joined(separator: ", "))
            let P = KitMLCombine.pool(poolKind, paths, w, tr.nPaths, rng: &rng)
            out[tr.key] = ArenaTargetForecast(paths: P.map { $0.map { min(max($0, 0), 100) } })
        }
        return ArenaForecast(byKey: out)
    }

    /// `_flat`: the meter's level now, flat (0 when the history has no such
    /// meter or its window is idle).
    public func flat(_ tr: ArenaTargetRequest) -> ArenaTargetForecast {
        var lvl = 0.0
        if let history, let rows = KitMLCombine.meterRows(history, tr.target, account: tr.accounts[0], cap: tr.cap) {
            lvl = KitMLCombine.levelAt(rows, asof: history.now)
        }
        return .point([Double](repeating: lvl.isNaN ? 0 : lvl, count: tr.grid.count))
    }

    /// Equal weights; subclasses learn them.
    public func weightsFor(_ kind: String, _ tr: ArenaTargetRequest, _ children: [String], _ paths: [[[Double]]],
                           now: Millis) -> [Double] {
        [Double](repeating: 1.0 / Double(children.count), count: children.count)
    }
}
