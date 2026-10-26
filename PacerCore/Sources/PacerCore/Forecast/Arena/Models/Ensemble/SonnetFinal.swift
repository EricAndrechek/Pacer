import Foundation

/// `models/g2-05-sonnet-final/model.py`: single-process calibrated meters.
/// Timestral-123M on the burn series (`FMMeterModel`, the Python's
/// `kit.fm.meter_model.MeterModel`), the 6-hour burn-decay model
/// (`decay6h.py`, the same code as `spend-decay-6h`: `SpendDecayModel`), a
/// fixed mixture of the two for the weekly meters, then a zero-mass layer.
///
/// **The zero-mass layer.** A meter that has not moved yet reads exactly its
/// current value; polls arrive every minute or so whether or not the user is
/// working, so at short and medium leads a large share of the truth sits
/// exactly at the current level. A continuous forecaster has no such mass,
/// so the truth falls below its whole forecast. `flatShare` estimates
/// P(meter unchanged at lead L) from this meter's own history: past reading
/// times weighted by how long since the meter last rose, how much it rose
/// over the last hour, and recency. The child's samples are then remapped:
/// levels below the flat share read the current level, the rest read the
/// child's quantile function over the remaining probability (`remap`); the
/// upper side is then widened about the median (`up_k`).
///
/// Port notes. The Python draws: Timestral's paths (`from_quantiles`), the
/// decay's paths, and the weekly mixture (`pool_mixture`, 100 of each
/// child's 200 paths at random). This port takes the exact distributions
/// those draws sample instead: Timestral's quantiles read at the sample
/// levels, the decay's exact type-1 quantiles (`KitDetQ`), and the
/// mixture as each child's share of evenly spaced quantiles
/// (`KitMLCombine.poolMixtureExact`'s rule). The layer itself is
/// deterministic and matches the Python to float precision on the same
/// samples. The answer is the layer's 200 sorted samples as comonotone
/// paths, as the Python's is.
public final class SonnetFinalModel: ArenaModel {
    /// `LEADS_MIN`: the leads (minutes) the flat share is estimated at.
    public static let leadsMin: [Double] = [0.5, 1, 2, 3, 5, 10, 20, 30, 60, 120, 240, 480, 960, 1920, 3840, 7680, 10080]
    static let logLeads = leadsMin.map { log($0) }
    static let minMs: Millis = 60_000
    static let hourMs: Millis = 3_600_000
    static let dayMs: Millis = 86_400_000

    let ctx: ArenaContext
    let cfg: ArenaConfig
    var history: ArenaHistory?
    let fm: FMMeterModel
    let decay: SpendDecayModel

    public init(context: ArenaContext) throws {
        ctx = context
        cfg = context.config
        // `_Ctx`: the embedded models read their own config table, and the
        // parent's services (weights, log, cancellation).
        fm = try FMMeterModel(context: Self.embedded(context, "fm", cfg.table("fm")) { try FMMeterModel(context: $0) })
        decay = SpendDecayModel(context: Self.embedded(context, "decay", cfg.table("decay")) {
            SpendDecayModel(context: $0)
        })
    }

    static func embedded(_ parent: ArenaContext, _ part: String, _ config: ArenaConfig,
                         make: @escaping @Sendable (ArenaContext) throws -> any ArenaModel) -> ArenaContext {
        let spec = ArenaModelSpec(name: "\(parent.name)/\(part)", targets: parent.spec.targets, config: config,
                                  make: make)
        return ArenaContext(spec: spec, seed: parent.seed, services: parent.services, runner: parent.runner,
                            history: { nil })
    }

    public func fit(_ history: ArenaHistory) throws {
        self.history = history
        fm.fit(history)
        decay.fit(history)
    }

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        let trs = request.targets.filter { FMMeterModel.windowFor[$0.target] != nil }
        guard !trs.isEmpty else { return ArenaForecast(byKey: [:]) }
        let now = request.now
        let fmOut = try fm.forecast(ArenaRequest(now: now, accounts: request.accounts, targets: trs)).byKey
        let wd = cfg.double("w_decay", 0.5)
        var out: [String: ArenaTargetForecast] = [:]
        for tr in trs {
            try ctx.checkCancelled()
            guard let tf = fmOut[tr.key] else { continue }
            var child = tf
            if tr.target != .meterFiveHour && wd > 0 {
                // `pool_mixture([fm, decay], [1 − wd, wd], n)`, as its exact
                // quantile function: each child's share of evenly spaced
                // quantiles, pooled and sorted.
                let n = tr.nPaths
                let cnt = KitMLCombine.counts([1.0 - wd, wd], n)
                var rows = KitMLPaths.sortedSamples(tf, m: cnt[0])
                if cnt[1] > 0 {
                    let p = decay.parts(tr)
                    let lv = KitMLPaths.levelGrid(cnt[1])
                    rows += KitDetQ.spendDecayQuantiles(p, gridCount: tr.grid.count, levels: lv)
                }
                KitMLPaths.sortColumns(&rows)
                child = ArenaTargetForecast(paths: rows)
            }
            out[tr.key] = layer(tr, child, now: now)
        }
        return ArenaForecast(byKey: out)
    }

    /// `_layer`: the zero-mass layer on one target's child forecast.
    func layer(_ tr: ArenaTargetRequest, _ tf: ArenaTargetForecast, now: Millis) -> ArenaTargetForecast {
        guard let history, let wk = FMMeterModel.windowFor[tr.target], let resetAt = tr.resetAt else { return tf }
        if (cfg["passthrough"]?.array?.compactMap(\.string) ?? []).contains(wk) { return tf }
        let cap = tr.target == .meterScoped ? tr.cap : nil
        let s = FMSeries.meterSeries(history, account: tr.accounts[0], windowKind: wk, scopeModel: cap, now: now)
        guard let b = s.usedNow(resetAt), let piL = flatShareMemo(history, s, tr, cap: cap, now: now, resetAt: resetAt)
        else { return tf }
        let g = tr.grid.count
        let pi0 = tr.grid.map { t -> Double in
            let leadMin = max(Double(t - now) / Double(Self.minMs), 0.5)
            return KitDetQ.npInterp(log(leadMin), xs: Self.logLeads, ys: piL)
        }
        // The Python's P has n paths (its child's); m = max(n, 100).
        let nRows = tf.paths?.count ?? tr.nPaths
        let m = max(nRows, 100)
        let X = KitMLPaths.sortedSamples(tf, m: m)
        let delta = cfg.double("delta", 0.5)
        var piC = [Double](repeating: 0, count: g)
        for j in 0..<g {
            var c = 0
            for r in 0..<m where X[r][j] <= b + delta { c += 1 }
            piC[j] = Double(c) / Double(m)
        }
        let ps = Self.perWindow(cfg, "pi_scale", wk, 1.0)
        // Never less mass at b than the child already has; at most 0.98
        // (np.clip(pi · ps, pi_c, 0.98) clips to the upper bound last).
        let pi = (0..<g).map { j in min(max(max(pi0[j], piC[j]) * ps, piC[j]), 0.98) }
        var Q = Self.remap(X, b: b, pi: pi, piC: piC)
        let uk = Self.perWindow(cfg, "up_k", wk, 1.0)
        if uk != 1.0 {
            // Widen the upper side about the median (the thin upper tail of
            // the FM: truth lands above its top decile).
            let med = BandedEnsemble.medianColumns(Q)
            for r in Q.indices {
                for j in 0..<g {
                    let v = Q[r][j] > med[j] ? med[j] + uk * (Q[r][j] - med[j]) : Q[r][j]
                    Q[r][j] = min(max(v, b), 100.0)
                }
            }
        }
        if Q.count != nRows { Q = KitMLPaths.sortedSamples(Q, m: nRows) }
        return ArenaTargetForecast(paths: Q)
    }

    /// A `{window: value}` table or one number.
    static func perWindow(_ cfg: ArenaConfig, _ key: String, _ wk: String, _ fallback: Double) -> Double {
        if let t = cfg[key]?.table { return t.double(wk, 1.0) }
        return cfg.double(key, fallback)
    }

    /// `flat_share`, memoized on the history cut (it reads only the
    /// readings and this model's settings).
    func flatShareMemo(_ history: ArenaHistory, _ s: FMSeries.MeterSeries, _ tr: ArenaTargetRequest, cap: String?,
                       now: Millis, resetAt: Millis) -> [Double]? {
        let key = "g2-05.flatShare|\(ctx.name)|\(tr.accounts[0])|\(tr.target.windowKind)|\(cap ?? "")|\(now)|\(resetAt)"
        return history.memo.value(key) { KitBox(Self.flatShare(s, now: now, resetAt: resetAt, cfg: cfg)) }.value
    }

    /// `flat_share`: P(meter reading at lead L == reading now) for
    /// `leadsMin`, non-increasing; nil when the series is too short or the
    /// cycle is not in it.
    public static func flatShare(_ s: FMSeries.MeterSeries, now: Millis, resetAt: Millis,
                                 cfg: ArenaConfig) -> [Double]? {
        let t = s.times, u = s.cycleUtil, rs = s.reset, act = s.active
        let n = t.count
        if n < 20 { return nil }
        let dur = Double(s.duration)
        // Cycle id: a new cycle when the active reset moves half a window.
        var prev = [Int](repeating: -1, count: n)
        var running = -1
        for i in 0..<n { prev[i] = running; if act[i] { running = max(running, i) } }
        var newc = [Bool](repeating: false, count: n)
        var cid = [Int](repeating: 0, count: n)
        var rise = [Bool](repeating: false, count: n)
        var lastRise = [Double](repeating: 0, count: n)
        var c = 0
        var marker = -1e15
        for i in 0..<n {
            let p = prev[i]
            let prevR: Double = p >= 0 ? Double(rs[p]) : -1
            newc[i] = act[i] && (p < 0 || abs(Double(rs[i]) - prevR) >= dur / 2)
            if newc[i] { c += 1 }
            cid[i] = c
            let uPrev = p >= 0 ? u[p] : 0.0
            rise[i] = act[i] && !newc[i] && (u[i] > uPrev + 1e-9)
            if newc[i] || rise[i] { marker = max(marker, Double(t[i])) }
            lastRise[i] = marker
        }
        let since = (0..<n).map { (Double(t[$0]) - lastRise[$0]) / Double(minMs) }
        // The rise over the trailing hour within the cycle (the cycle's first
        // hour counts from 0).
        let r60 = (0..<n).map { i -> Double in
            let j = max(searchRight(t, t[i] - hourMs) - 1, 0)
            return max(cid[j] == cid[i] ? u[i] - u[j] : u[i], 0.0)
        }
        // The state now.
        guard let ic = (0..<n).last(where: { act[$0] && abs(Double(rs[$0] - resetAt)) < dur / 2 }) else { return nil }
        let sNow = (Double(now) - lastRise[ic]) / Double(minMs)
        let jn = max(searchRight(t, now - hourMs) - 1, 0)
        let rNow = max(u[ic] - (cid[jn] == cid[ic] ? u[jn] : 0.0), 0.0)
        // Candidate sample points: active readings of the last 120 days, thinned.
        var cand = (0..<n).filter { act[$0] && t[$0] >= now - 120 * dayMs }
        let mx = cfg.int("max_samples", 6000)
        if cand.count > mx {
            let step = Double(cand.count - 1) / Double(mx - 1)
            cand = (0..<mx).map { i in
                cand[Int((i == mx - 1 ? Double(cand.count - 1) : Double(i) * step).rounded(.toNearestOrEven))]
            }
        }
        let stale = Millis(cfg.int("stale_min", 120)) * minMs
        let tau = cfg.double("tau_d", 14.0) * Double(dayMs)
        let hs = cfg.double("h_since", 0.8), hr = cfg.double("h_rate", 0.8)
        let tod = cfg.double("tod_h", 0.0)
        let n0 = cfg.double("n0", 3.0)
        let ls0 = log1p(sNow), lr0 = log1p(rNow)
        var w = [Double](repeating: 0, count: cand.count)
        var pooled = [Double](repeating: 0, count: cand.count)
        for (k, i) in cand.enumerated() {
            let rec = exp(-(Double(now) - Double(t[i])) / tau)
            pooled[k] = rec
            let zs = (log1p(since[i]) - ls0) / hs
            let zr = (log1p(r60[i]) - lr0) / hr
            var v = rec * exp(-0.5 * zs * zs) * exp(-0.5 * zr * zr)
            if tod > 0 {
                let dh = fmod(fmod((Double(t[i]) - Double(now)) / Double(hourMs) + 12.0, 24.0) + 24.0, 24.0) - 12.0
                v *= exp(-0.5 * (dh / tod) * (dh / tod))
            }
            w[k] = v
        }
        var out = [Double](repeating: .nan, count: leadsMin.count)
        for (k, L) in leadsMin.enumerated() {
            let off = Millis(L * Double(minMs))
            var cnt = 0
            var sw = 0.0, swf = 0.0, sp = 0.0, spf = 0.0
            for (ci, i) in cand.enumerated() {
                let te = t[i] + off
                guard te <= now, te <= rs[i] else { continue }
                let j = max(searchRight(t, te) - 1, 0)
                guard j > i, te - t[j] <= stale, act[j], cid[j] == cid[i] else { continue }
                cnt += 1
                let flat = u[j] <= u[i] + 1e-9 ? 1.0 : 0.0
                sp += pooled[ci]; spf += pooled[ci] * flat
                sw += w[ci]; swf += w[ci] * flat
            }
            if cnt < 5 { continue }
            let flatAll = spf / sp
            out[k] = (swf + n0 * flatAll) / (sw + n0)
        }
        let good = out.indices.filter { out[$0].isFinite }
        if good.count < 2 { return nil }
        // Unsupported long leads take the last supported value; monotone.
        let xs = good.map { logLeads[$0] }, ys = good.map { out[$0] }
        var res = logLeads.map { min(max(KitDetQ.npInterp($0, xs: xs, ys: ys), 0.0), 1.0) }
        for i in 1..<res.count where res[i] > res[i - 1] { res[i] = res[i - 1] }
        return res
    }

    /// `np.searchsorted(t, x, side="right")`.
    static func searchRight(_ t: [Millis], _ x: Millis) -> Int {
        var lo = 0, hi = t.count
        while lo < hi { let mid = (lo + hi) >> 1; if t[mid] <= x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// `remap`: `x` `[m][G]` sorted child samples; `pi` `[G]` the target
    /// flat share; `piC` `[G]` the child's own mass at b. Quantile levels
    /// below pi read b; above, the child's quantile function over its
    /// non-flat mass.
    public static func remap(_ x: [[Double]], b: Double, pi: [Double], piC: [Double]) -> [[Double]] {
        let m = x.count
        guard m >= 2, let g = x.first?.count else { return x }
        let lv = KitMLPaths.levelGrid(m)
        let lvSrc = [0.0] + lv + [1.0]
        var out = [[Double]](repeating: [Double](repeating: 0, count: g), count: m)
        var src = [Double](repeating: 0, count: m + 2)
        for j in 0..<g {
            src[0] = b
            for r in 0..<m { src[r + 1] = x[r][j] }
            src[m + 1] = min(x[m - 1][j] + (x[m - 1][j] - x[m - 2][j]), 100.0)
            let denom = max(1.0 - pi[j], 1e-6)
            for r in 0..<m {
                var q = min(max((lv[r] - pi[j]) / denom, 0.0), 1.0)
                q = piC[j] + q * (1.0 - piC[j])
                let v = lv[r] <= pi[j] ? b : KitDetQ.npInterp(q, xs: lvSrc, ys: src)
                out[r][j] = min(max(v, b), 100.0)
            }
        }
        return out
    }
}
