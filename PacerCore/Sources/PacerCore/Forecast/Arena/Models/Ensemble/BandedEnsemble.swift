import Foundation

/// `models/g1-05-opus-ens-meter-big/ens.py` `BandedEnsemble`: a calibrated,
/// lead-aware ensemble over meter children. Three things it adds to
/// `KitMLCombiner`:
///
/// 1. **Lead-banded weights.** A child that reads the next half hour well is
///    not the one that reads the whole cycle well. Weights are fitted per
///    lead band (the share of the forecast's span the point sits at) and
///    interpolated along the grid, so the pooled path can follow one child
///    early and another late.
/// 2. **Spread calibration.** The pooled forecast is rescaled around its own
///    median by a factor fitted on the same past forecasts (a 1-D grid
///    search on CRPS, per band): a linear pool of over-wide children is
///    wider still, and shrinking it is worth more than any reweighting.
/// 3. **A nowcast head.** The pooled path is blended toward the live level
///    with a weight that decays over `anchor_tau_min`.
///
/// Everything is fitted on the ledger of `KitMLCombine` (backtest origins
/// plus this run's own forecasts, scored only on readings that have
/// arrived), so nothing here sees the future.
///
/// Port notes. Given the same child forecasts this is deterministic and
/// matches the Python to float precision, with one exception: the band
/// weights are the exact minimum of the same convex quadratic the Python
/// hands to SLSQP (`KitMLCombine.simplexMinQuadratic`), so they agree to
/// SLSQP's own tolerance, not bit for bit. The `beta` recalibration
/// (`scipy.special.betaincinv`) is not ported; g1-05 configures
/// `recal = "scale"`, and a config asking for beta is logged and runs
/// without it. `time_to_limit` (a per-path array in the Python's extras) is
/// left out: extras here are numbers.
public final class BandedEnsemble: KitMLCombiner {
    override public class var rule: String { "banded-stack" }
    override public class var defaultPool: String { "quantile" }

    /// What was learned for one (kind, children, lead band): pool weights,
    /// the spread factor that minimized CRPS there, the rise factor.
    public struct Cell: Sendable {
        public let w: [Double]
        public let scale: Double
        public let n: Int
        public let rise: Double
    }

    public let edges: [Double]
    public let nb: Int
    let mFit: Int
    let minPoints: Int
    let scales: [Double]
    let scaleShrink: Double
    let rises: [Double]
    let riseShrink: Double
    let shrink: Double
    let recal: Set<String>
    let caller: ArenaChildCaller
    public internal(set) var cells: [String: Cell] = [:]
    var cellsAt: [String: Millis] = [:]

    public required init(context: ArenaContext) throws {
        let cfg = context.config
        edges = [0.0] + cfg.doubles("bands", [0.15, 0.5]) + [1.0]
        nb = edges.count - 1
        mFit = cfg.int("m_fit", 40)
        minPoints = cfg.int("min_points", 12)
        scales = cfg.doubles("scales", [0.3, 0.4, 0.5, 0.6, 0.75, 0.9, 1.0, 1.2, 1.5])
        scaleShrink = cfg.double("scale_shrink", 0.25)
        rises = cfg.doubles("rises", [0.0, 0.25, 0.5, 0.75, 1.0, 1.25])
        riseShrink = cfg.double("rise_shrink", 0.15)
        shrink = cfg.double("shrink", 0.05)
        recal = Set(cfg.string("recal", "rise,scale,beta").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
        caller = ArenaChildCaller(context)
        try super.init(context: context)
        if recal.contains("beta") { context.log("recal beta is not ported; fitting without it") }
    }

    static func cellKey(_ kind: String, _ children: [String], _ band: Int) -> String {
        "\(kind)|\(children.joined(separator: ","))|\(band)"
    }

    public func cell(_ kind: String, _ children: [String], band: Int) -> Cell? {
        cells[Self.cellKey(kind, children, band)]
    }

    // MARK: - Fitting

    /// `_tau_ms`: the nowcast half-life for a kind (`anchor_tau_min`: per
    /// window, or one number), in ms.
    func tauMs(_ kind: String) -> Double {
        let w = KitCalib.windowOf(kind)
        let t: Double
        if let tab = cfg["anchor_tau_min"]?.table {
            t = tab.double(w, 15.0)
        } else if let v = cfg["anchor_tau_min"]?.double {
            t = v
        } else {
            t = ["five_hour": 8.0, "seven_day": 25.0, "weekly_scoped": 25.0][w] ?? 15.0
        }
        return t * Double(KitMLCombine.minMs)
    }

    /// `_band_of`: the lead band of each time (`np.digitize` on the inner
    /// edges of the span from origin to reset).
    func bandOf(_ g: KitMLCombine.Group, _ times: [Millis]) -> [Int] {
        let span = Double(max(g.reset - g.origin, 1))
        let inner = Array(edges.dropFirst().dropLast())
        return times.map { t in
            let f = (Double(t) - Double(g.origin)) / span
            let b = inner.filter { $0 <= f }.count
            return min(max(b, 0), nb - 1)
        }
    }

    /// `_fit_kind`: one cell per band, weights then the spread factor at
    /// those weights. Bands with too little truth inherit the next lower
    /// band's cell (and, failing that, equal weights at scale 1).
    func fitKind(_ kind: String, _ ch: [String], now: Millis) {
        let k = ch.count
        let eqCell = Cell(w: [Double](repeating: 1.0 / Double(k), count: k), scale: 1.0, n: 0, rise: 1.0)
        let groups = ledger.scored(kind, before: now).filter { g in ch.allSatisfy { g.entries[$0] != nil } }
        if groups.isEmpty {
            for b in 0..<nb { cells[Self.cellKey(kind, ch, b)] = eqCell }
            return
        }
        let hl = max(halfLife(kind), 1e-6)
        let origins = groups.map(\.origin)
        let disc = groups.map { g in pow(0.5, Double(origins.filter { $0 > g.origin }.count) / hl) }
        let bands = groups.map { bandOf($0, $0.times) }
        let wantBase = recal.contains("rise")
        let m = ledger.m
        var prev: Cell?
        for b in 0..<nb {
            // One array over every eval point of the band: X [k][m][E].
            var X = [[[Double]]](repeating: [[Double]](repeating: [], count: m), count: k)
            var y: [Double] = [], ws: [Double] = [], base: [Double] = []
            var any = false
            for (gi, g) in groups.enumerated() {
                let d = disc[gi]
                if d <= 1e-6 || g.y.isEmpty { continue }
                let sel = bands[gi].indices.filter { bands[gi][$0] == b }
                if sel.isEmpty { continue }
                any = true
                for (ci, c) in ch.enumerated() {
                    let xg = g.x(c)
                    for r in 0..<m { X[ci][r] += sel.map { xg[r][$0] } }
                }
                y += sel.map { g.y[$0] }
                ws += [Double](repeating: d, count: sel.count)
                let bv = wantBase ? baseAt(g) : 0.0
                base += [Double](repeating: bv, count: sel.count)
            }
            if y.count < minPoints || !any {
                cells[Self.cellKey(kind, ch, b)] = prev ?? eqCell
                continue
            }
            let tot = ws.reduce(0, +)
            let pw = ws.map { $0 / tot }
            let w = fitWeights(X, y, pw)
            let (scale, rise) = fitCalibration(X, y, pw, w, base)
            let c = Cell(w: w, scale: scale, n: y.count, rise: rise)
            prev = c
            cells[Self.cellKey(kind, ch, b)] = c
        }
    }

    /// `_fit_weights`: simplex weights minimising the pooled CRPS over the
    /// band's points. For a mixture the CRPS is the exact quadratic
    /// Σ wᵢaᵢ − ½ Σ wᵢwⱼDᵢⱼ, so `a` and `D` are formed once. For a quantile
    /// pool the weights are fitted on that same quadratic unless
    /// `fit_objective = "pool"`.
    func fitWeights(_ X: [[[Double]]], _ y: [Double], _ pw: [Double]) -> [Double] {
        let k = X.count
        let m = X.first?.count ?? 0
        let eq = [Double](repeating: 1.0 / Double(k), count: k)
        let e = y.count
        // a: Σₑ pwₑ · meanₛ |Xᵢ[s][e] − yₑ|.
        let a = (0..<k).map { i -> Double in
            var s = 0.0
            for c in 0..<e {
                var acc = 0.0
                for r in 0..<m { acc += abs(X[i][r][c] - y[c]) }
                s += acc / Double(m) * pw[c]
            }
            return s
        }
        var D = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var cols = [[[Double]]](repeating: [], count: k)          // [k][E][m], each sorted
        for i in 0..<k {
            cols[i] = (0..<e).map { c in
                let col = (0..<m).map { X[i][$0][c] }
                return KitMLCombine.isAscending(col) ? col : col.sorted()
            }
        }
        for i in 0..<k {
            var g = 0.0
            for c in 0..<e { g += Self.halfGiniSorted(cols[i][c]) * pw[c] }
            D[i][i] = 2.0 * g
            for j in stride(from: i + 1, to: k, by: 1) {
                var v = 0.0
                let mm = Double(cols[i][0].count * cols[j][0].count)
                for c in 0..<e { v += KitMLCombine.pairAbsSum(cols[i][c], cols[j][c]) / mm * pw[c] }
                D[i][j] = v
                D[j][i] = v
            }
        }
        let scale0 = max(a.reduce(0, +) / Double(k), 1e-6)
        if cfg.string("fit_objective", "mixture") == "pool" && poolKind == "quantile" {
            return KitMLCombine.simplexMin(k) { w in
                Self.wcrps(KitMLCombine.weightedSum(X, w), y, pw) / scale0
                    + self.shrink * zip(w, eq).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
            }
        }
        return KitMLCombine.simplexMinQuadratic(a: a, D: D, scale: scale0, shrink: shrink)
    }

    /// `_base_at`: the meter's level when the forecast was made (what a
    /// rise is measured from); 0 when there is none.
    func baseAt(_ g: KitMLCombine.Group) -> Double {
        guard let history, let rows = KitMLCombine.meterRows(history, g.target, account: g.account, cap: g.cap)
        else { return 0 }
        let v = KitMLCombine.levelAt(rows, asof: g.origin)
        return v.isNaN ? 0 : v
    }

    /// `_fit_calibration`: how much of the children's predicted rise to
    /// believe and how wide to make the result, by minimising the same
    /// weighted CRPS over the band's own past points. `recal` picks what is
    /// fitted (rise, scale; beta is not ported).
    func fitCalibration(_ X: [[[Double]]], _ y: [Double], _ pw: [Double], _ w: [Double],
                        _ base: [Double]) -> (scale: Double, rise: Double) {
        let q0 = poolKind == "quantile" ? KitMLCombine.weightedSum(X, w) : Self.mixSamples(X, w, mFit)
        let rs = recal.contains("rise") ? rises : [1.0]
        let ss = recal.contains("scale") ? scales : [1.0]
        var best: Double?
        var bestS = 1.0, bestR = 1.0
        let e = y.count
        for r in rs {
            let q = r != 1.0 ? q0.map { row in (0..<e).map { base[$0] + r * (row[$0] - base[$0]) } } : q0
            let med = Self.medianColumns(q)
            let penR = 1.0 + riseShrink * (1.0 - r) * (1.0 - r)
            for s in ss {
                let scaled = q.map { row in (0..<e).map { med[$0] + s * (row[$0] - med[$0]) } }
                let lg = log(s)
                let loss = Self.wcrps(scaled, y, pw) * penR * (1.0 + scaleShrink * lg * lg)
                if best == nil || loss < best! { best = loss; bestS = s; bestR = r }
            }
        }
        return (bestS, bestR)
    }

    // MARK: - Forecasting

    override public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let history else { throw ArenaError.invalid("forecast before fit") }
        try runBacktests(for: request)
        var got: [String: ArenaForecast] = [:]
        for c in children {
            guard let fc = try caller.ask(c, request) else { continue }
            got[c] = fc
            ledger.add(c, request, fc)
        }
        ledger.score(history)
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets where KitMLCombine.meter[tr.target] != nil {
            let avail = children.filter { got[$0]?.byKey[tr.key] != nil }
            if avail.isEmpty { out[tr.key] = flat(tr); continue }
            let kind = KitMLCombine.kindOf(tr.target, cap: tr.cap)
            let at = "\(kind)|\(avail.joined(separator: ","))"
            if cellsAt[at] != request.now {
                fitKind(kind, avail, now: request.now)
                cellsAt[at] = request.now
                for b in 0..<nb {
                    if let c = cell(kind, avail, band: b) {
                        ctx.log("cell \(kind) band \(b) @\(request.now): n=\(c.n) scale=\(c.scale) rise=\(c.rise) w="
                                + c.w.map { String(format: "%.3f", $0) }.joined(separator: ","))
                    }
                }
            }
            let S = avail.map { KitMLPaths.sortedSamples(got[$0]!.byKey[tr.key]!, m: tr.nPaths) }
            let P = blend(tr, now: request.now, S, kind: kind, children: avail)
            out[tr.key] = finish(tr, now: request.now, P, kind: kind)
        }
        return ArenaForecast(byKey: out)
    }

    /// `_blend`: pool per band, then interpolate between the bands' pooled
    /// quantile curves along the grid (so weights move smoothly). `S` is
    /// each child's n sorted samples per grid time.
    func blend(_ tr: ArenaTargetRequest, now: Millis, _ S: [[[Double]]], kind: String,
               children ch: [String]) -> [[Double]] {
        let n = tr.nPaths
        let grid = tr.grid.map(Double.init)
        let reset = Double(tr.resetAt ?? tr.grid.last ?? now)
        let span = max(reset - Double(now), 1.0)
        let f = grid.map { min(max(($0 - Double(now)) / span, 0.0), 1.0) }
        let mid = (0..<nb).map { 0.5 * (edges[$0] + edges[$0 + 1]) }
        let base = level(tr)
        let k = S.count
        var curves: [[[Double]]] = []
        for b in 0..<nb {
            let c = cell(kind, ch, band: b)
            let w = c?.w ?? [Double](repeating: 1.0 / Double(k), count: k)
            let s = c?.scale ?? 1.0
            let r = c?.rise ?? 1.0
            var q = poolKind == "mixture" ? Self.mixSamples(S, w, n) : KitMLCombine.weightedSum(S, w)
            if r != 1.0 { q = q.map { row in row.map { base + r * ($0 - base) } } }
            let med = Self.medianColumns(q)
            curves.append(q.map { row in row.indices.map { med[$0] + s * (row[$0] - med[$0]) } })
        }
        let rows = curves[0].count
        var Q = [[Double]](repeating: [Double](repeating: 0, count: grid.count), count: rows)
        for (j, fj) in f.enumerated() {
            // np.searchsorted(mid, fj) (left) − 1, clipped to the bands.
            let ss = mid.filter { $0 < fj }.count
            let lo = min(max(ss - 1, 0), nb - 1)
            let hi = min(max(lo + 1, 0), nb - 1)
            let a = (hi == lo || mid[hi] <= mid[lo]) ? 0.0 : min(max((fj - mid[lo]) / (mid[hi] - mid[lo]), 0.0), 1.0)
            for r in 0..<rows { Q[r][j] = (1 - a) * curves[lo][r][j] + a * curves[hi][r][j] }
        }
        return Q
    }

    /// `_level`: the meter's latest known value, the forecast's own
    /// starting point (0 when there is no such meter or it is idle).
    func level(_ tr: ArenaTargetRequest) -> Double {
        guard let history, let rows = KitMLCombine.meterRows(history, tr.target, account: tr.accounts[0], cap: tr.cap)
        else { return 0 }
        let v = KitMLCombine.levelAt(rows, asof: history.now)
        return v.isNaN ? 0 : v
    }

    /// `_finish`: nowcast head, monotonicity, bounds, and the direct limit
    /// extras. A meter whose newest reading has no value gets no nowcast
    /// (the Python's NaN level would make every path NaN).
    func finish(_ tr: ArenaTargetRequest, now: Millis, _ P0: [[Double]], kind: String) -> ArenaTargetForecast {
        var P = P0
        let grid = tr.grid.map(Double.init)
        if let history, let rows = KitMLCombine.meterRows(history, tr.target, account: tr.accounts[0], cap: tr.cap) {
            let lvl = KitMLCombine.levelAt(rows, asof: history.now)
            if !lvl.isNaN {
                let tau = tauMs(kind)
                if tau > 0 {
                    let a = grid.map { exp(-($0 - Double(now)) / tau) }
                    for r in P.indices { for j in P[r].indices { P[r][j] = a[j] * lvl + (1 - a[j]) * P[r][j] } }
                }
                if cfg.bool("floor_live", true) {
                    let fl = lvl - cfg.double("floor_slack", 0.0)
                    for r in P.indices { for j in P[r].indices where P[r][j] < fl { P[r][j] = fl } }
                }
            }
        }
        if cfg.bool("monotone", true) { for r in P.indices { KitMLPaths.runningMax(&P[r]) } }
        for r in P.indices { for j in P[r].indices { P[r][j] = min(max(P[r][j], 0.0), 100.0) } }
        var extras: [String: Double] = [:]
        if cfg.bool("direct_extras", true), !P.isEmpty {
            let hits = P.filter { $0.contains { $0 >= 99.5 } }.count
            extras["p_hit_limit"] = Double(hits) / Double(P.count)
        }
        return ArenaTargetForecast(paths: P, extras: extras)
    }

    // MARK: - Small numerics (the module's own helpers)

    /// `_mix_samples`: a linear pool of children's sorted samples
    /// (`[k][m][G]`) as n sorted samples: child i's largest-remainder share
    /// cᵢ read at levels (j + 0.5) / cᵢ of its m samples, pooled, sorted per
    /// column. Deterministic, unlike drawing paths.
    static func mixSamples(_ S: [[[Double]]], _ w0: [Double], _ n: Int) -> [[Double]] {
        let tot = max(w0.reduce(0, +), 1e-12)
        let cnt = KitMLCombine.counts(w0.map { $0 / tot }, n)
        var rows: [[Double]] = []
        rows.reserveCapacity(n)
        for (i, c) in cnt.enumerated() where c > 0 {
            let Si = S[i]
            let m = Si.count
            for jj in 0..<c {
                let lv = (Double(jj) + 0.5) / Double(c)
                let pos = min(max(lv * Double(m) - 0.5, 0), Double(m - 1))
                let lo = Int(pos.rounded(.down))
                let hi = min(lo + 1, m - 1)
                let fr = pos - Double(lo)
                if fr == 0 { rows.append(Si[lo]); continue }
                rows.append(Si[lo].indices.map { Si[lo][$0] * (1 - fr) + Si[hi][$0] * fr })
            }
        }
        KitMLPaths.sortColumns(&rows)
        return rows
    }

    /// `_wcrps`: weighted mean empirical CRPS of sorted samples `[m][E]`
    /// against y: E|X − y| − ½ E|X − X'| per column (the second term from
    /// the sorted values), weighted by pw.
    static func wcrps(_ q: [[Double]], _ y: [Double], _ pw: [Double]) -> Double {
        let m = q.count
        guard m > 0 else { return .nan }
        var total = 0.0
        var col = [Double](repeating: 0, count: m)
        for e in y.indices {
            var a = 0.0
            for r in 0..<m { col[r] = q[r][e]; a += abs(col[r] - y[e]) }
            if !KitMLCombine.isAscending(col) { col.sort() }
            total += (a / Double(m) - halfGiniSorted(col)) * pw[e]
        }
        return total
    }

    /// `_half_gini` of one ascending column: E|X − X'| / 2.
    static func halfGiniSorted(_ x: [Double]) -> Double {
        let m = x.count
        var s = 0.0
        for (i, v) in x.enumerated() { s += Double(2 * (i + 1) - m - 1) * v }
        return s / Double(m * m)
    }

    /// `np.median(q, axis=0)`.
    static func medianColumns(_ q: [[Double]]) -> [Double] {
        guard let g = q.first?.count else { return [] }
        let m = q.count
        var col = [Double](repeating: 0, count: m)
        return (0..<g).map { j in
            for r in 0..<m { col[r] = q[r][j] }
            if !KitMLCombine.isAscending(col) { col.sort() }
            return m % 2 == 1 ? col[m / 2] : (col[m / 2 - 1] + col[m / 2]) / 2
        }
    }
}

/// `models/g1-05-opus-ens-meter-big/robust_child.py` `ChildCaller`: calling
/// a child that does not cover everything that was asked. The request goes
/// to the child whole (the cheap path, and the one the runner's memo shares
/// with the parent's own request); only if that fails is it retried per
/// target kind, remembering which kinds the child cannot serve.
final class ArenaChildCaller {
    let ctx: ArenaContext
    var whole: [String: Bool] = [:]
    var bad: [String: Set<ArenaTarget>] = [:]

    init(_ ctx: ArenaContext) { self.ctx = ctx }

    func ask(_ name: String, _ request: ArenaRequest) throws -> ArenaForecast? {
        if whole[name] ?? true {
            do {
                let fc = try ctx.model(name).forecast(request)
                whole[name] = true
                return fc
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                ctx.log("child \(name) whole request failed: \(error)")
                whole[name] = false
            }
        }
        var kinds: [ArenaTarget: [ArenaTargetRequest]] = [:]
        var order: [ArenaTarget] = []
        for tr in request.targets {
            if kinds[tr.target] == nil { order.append(tr.target) }
            kinds[tr.target, default: []].append(tr)
        }
        var out: [String: ArenaTargetForecast] = [:]
        for target in order where !(bad[name]?.contains(target) ?? false) {
            do {
                let sub = ArenaRequest(now: request.now, accounts: request.accounts, targets: kinds[target]!)
                let fc = try ctx.model(name).forecast(sub)
                out.merge(fc.byKey) { _, b in b }
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                bad[name, default: []].insert(target)
                ctx.log("child \(name) cannot serve \(target.rawValue): \(error)")
            }
        }
        return out.isEmpty ? nil : ArenaForecast(byKey: out)
    }
}
