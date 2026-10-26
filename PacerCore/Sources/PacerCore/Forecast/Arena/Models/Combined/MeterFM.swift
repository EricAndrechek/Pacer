import Foundation

/// `research/arena/models/g1-08-opus-fm/meters.py` `MeterFM` (identical in
/// g2-06-opus-fmgate2): a pretrained forecaster on the meter's cumulative
/// burn, recalibrated on the user's own past (`FMCal`), read at the
/// request's grid as meter paths.
///
/// Per meter target: the context (cumulative burn on a regular grid ending
/// at now); the forecaster's burn quantiles to the reset; the meter's
/// quantiles at the extended levels; the calibration's levels per grid time
/// (from self-backtests on this series); widening around the median
/// (`spread_k`); monotone in time and level; 200 stratified paths; then
/// rationing (a user near the limit often stops short of it).
///
/// Not ported (neither model's config sets them): `short` (a second
/// forecaster for the first minutes) and `ensemble` (several backends).
public final class MeterFM {
    public static let windowFor: [ArenaTarget: String] = [
        .meterFiveHour: "five_hour", .meterSevenDay: "seven_day", .meterScoped: "weekly_scoped",
    ]

    let cfg: ArenaConfig
    let ctx: ArenaContext
    /// Tests only: read every tied PIT at this position instead of drawing
    /// it (the parity fixtures' deterministic mode).
    var tieU01: Double?
    /// Where the self-backtest's network calls are memoized (tests use
    /// their own, to time a cold start).
    var cutCache: FMCalCutCache = .shared
    private var _backend: TimestralForecaster?

    init(cfg: ArenaConfig, context: ArenaContext) throws {
        self.cfg = cfg
        self.ctx = context
        let backend = cfg.string("backend", "timestral")
        guard backend == "timestral" else { throw ArenaError.invalid("MeterFM backend \(backend) is not ported") }
        if cfg["short"] != nil || cfg["ensemble"] != nil {
            throw ArenaError.invalid("MeterFM short/ensemble backends are not ported")
        }
    }

    var weightsID: String { cfg.string("weights", "") }

    var backend: TimestralForecaster {
        get throws {
            if let b = _backend { return b }
            let b = try FMBackends.timestral(weightsID, services: ctx.services)
            _backend = b
            return b
        }
    }

    /// `_c`: a per-window setting (a table keyed by window kind) or a scalar.
    func c(_ name: String, _ wk: String, _ fallback: Double) -> Double {
        switch cfg[name] {
        case .table(let t)?: t[wk]?.double ?? fallback
        case let v?: v.double ?? fallback
        case nil: fallback
        }
    }

    // MARK: - The deterministic part

    /// What the network and the arithmetic around it give, before any draw:
    /// shared by every model asked on one history cut (`history.memo`).
    public struct Base: @unchecked Sendable {
        public let used: Double
        public let ctxV: [Double]
        public let step: Millis
        public let ctxN: Int
        public let stale: Millis
        /// Nil: flat at `min(used, 100)` (no fresh reading, or at the limit).
        public let lv: [Double]?
        /// `[G][Q + 2]`: the meter's quantiles at `lv` at each grid time.
        public let mq: [[Double]]
        public let series: FMSeries.MeterSeries
        /// The self-backtest's table (nil when not calibrating or flat).
        public let backtest: FMCal.SelfBacktest?
    }

    func base(_ history: ArenaHistory, now: Millis, _ tr: ArenaTargetRequest, _ wk: String) throws -> Base {
        let cap = tr.target == .meterScoped ? tr.cap : nil
        let acct = tr.accounts[0]
        let step = Millis(c("step_min", wk, wk == "five_hour" ? 5 : 15)) * FMSeries.minMs
        let ctxN = Int(c("context_steps", wk, wk == "five_hour" ? 144 : 288))
        let stale = Millis(cfg.int("stale_min", 120)) * FMSeries.minMs
        let calibrate = cfg.bool("calibrate", true)
        let every = Millis(c("cal_every_min", wk, wk == "five_hour" ? 60 : 240)) * FMSeries.minMs
        let maxCuts = Int(c("cal_cuts", wk, 240))
        let gridLast = tr.grid[tr.grid.count - 1]
        var gh = Hasher()
        gh.combine(tr.grid)
        let key = "MeterFM.base|\(weightsID)|\(acct)|\(wk)|\(cap ?? "")|\(now)|\(tr.resetAt.map(String.init) ?? "-")"
            + "|\(step)|\(ctxN)|\(stale)|\(calibrate)|\(every)|\(maxCuts)|\(tr.grid.count)|\(gh.finalize())"
        return try history.memo.value(key) {
            let s = FMSeries.meterSeries(history, account: acct, windowKind: wk, scopeModel: cap, now: now)
            let used = tr.resetAt.flatMap { s.usedNow($0) } ?? s.lastActiveUtil ?? 0
            let ctxV = FMSeries.resampleLast(times: s.times, values: s.cum,
                                             grid: FMSeries.regularGrid(now: now, stepMs: step, n: ctxN), staleMs: stale)
            guard let cLast = ctxV.last, cLast.isFinite, used < 100 else {
                return Base(used: used, ctxV: ctxV, step: step, ctxN: ctxN, stale: stale, lv: nil,
                            mq: tr.grid.map { _ in [min(used, 100)] }, series: s, backtest: nil)
            }
            let fc = try backend
            try ctx.checkCancelled()
            let H = max(1, Int(((Double(gridLast - now)) / Double(step)).rounded(.up)))
            let out = try FMBackends.quantiles(fc, context: [[ctxV]], horizon: H)
            var burn = FMPaths.burnQuantiles(out.curve(), cLast: cLast)
            burn.insert([Double](repeating: 0, count: out.q), at: 0)                 // [H+1][Q] at t_rel
            let (lv, bq) = FMCal.extLevels(out.levels, burn)
            let tRel = (0...H).map { Double(step) * Double($0) }
            let gRel = tr.grid.map { Double($0 - now) }
            let bqG = FMPaths.interpTimes(tRel, gRel, bq)                              // [G][Q+2]
            let mq = bqG.map { row in row.map { min(max(used + $0, used), 100.0) } }
            var bt: FMCal.SelfBacktest?
            if calibrate {
                let b = FMCal.SelfBacktest(wk: wk, step: step, ctxN: ctxN, stale: stale, every: every,
                                           maxCuts: maxCuts, duration: s.duration)
                try b.refresh(fc, weightsID: weightsID, series: s, now: now, cache: cutCache,
                              checkCancelled: ctx.checkCancelled)
                bt = b
            }
            return Base(used: used, ctxV: ctxV, step: step, ctxN: ctxN, stale: stale, lv: lv, mq: mq, series: s,
                        backtest: bt)
        }
    }

    // MARK: - Forecast

    /// `[G][ALPHA]`: the calibrated, widened, monotone meter quantiles at
    /// the 200 stratified levels (nil: flat at `used`), and the calibration.
    public struct Levels {
        public let used: Double
        public let out: [[Double]]?
        public let calibration: FMCal.Calibration?
        public let phase: Double
        public let actNow: Double
        public let base: Base
    }

    func levels(_ history: ArenaHistory, now: Millis, _ tr: ArenaTargetRequest) throws -> Levels {
        guard let wk = Self.windowFor[tr.target] else { throw ArenaError.invalid("not a meter target") }
        let b = try base(history, now: now, tr, wk)
        guard let lv = b.lv else { return Levels(used: b.used, out: nil, calibration: nil, phase: 0, actNow: 0, base: b) }
        let used = b.used
        let s = b.series
        let gRel = tr.grid.map { Double($0 - now) }
        let alpha = FMCal.alpha
        var lev: [[Double]]
        var cal: FMCal.Calibration?
        var phase = 0.5, actNow = 0.0
        if let bt = b.backtest {
            phase = tr.resetAt.map { 1.0 - Double($0 - now) / Double(s.duration) } ?? 0.5
            let recs: FMCal.SelfBacktest.Records
            if let u = tieU01 {
                recs = bt.records(s, now: now, u01: { u })
            } else {
                recs = bt.records(s, now: now, u01: { ctx.rng.uniform() })
            }
            let k30 = max(1, Int((30.0 * Double(FMSeries.minMs) / Double(b.step)).rounded(.toNearestOrEven)))
            let v = FMSeries.resampleLast(times: s.times, values: s.cum,
                                          grid: FMSeries.regularGrid(now: now, stepMs: b.step, n: k30 + 1), staleMs: b.stale)
            actNow = v.allSatisfy(\.isFinite) ? v[v.count - 1] - v[0] : 0.0
            let pr = cfg.table("prior")
            let rows = pr[wk]?.array?.map { $0.array?.compactMap(\.double) ?? [] }
            let c = try FMCal.Calibration(leads: bt.leads, records: recs, levelNow: used, phaseNow: phase, cfg: cfg,
                                          priorRows: rows, priorLevels: pr["levels"] != nil ? pr.doubles("levels", []) : nil,
                                          actNow: actNow)
            cal = c
            lev = c.levels(gRel.map { max($0 / Double(FMSeries.minMs), 0.5) })
        } else {
            lev = [[Double]](repeating: alpha, count: tr.grid.count)
        }
        var out = [[Double]](repeating: [], count: tr.grid.count)
        for j in 0..<tr.grid.count {
            out[j] = lev[j].map { KitDetQ.npInterp($0, xs: lv, ys: b.mq[j]) }.sorted()
        }
        let k = c("spread_k", wk, 1.0)
        if k != 1.0 {
            // Widen around the median (out of sample the calibrated tails stay thin).
            let mid = alpha.count / 2
            for j in 0..<out.count {
                let med = out[j][mid]
                out[j] = out[j].map { min(max(med + k * ($0 - med), used), 100.0) }
            }
        }
        // np.maximum.accumulate(out, axis=0): monotone in time, per level.
        if out.count > 1 {
            for j in 1..<out.count { for a in 0..<alpha.count { out[j][a] = max(out[j][a], out[j - 1][a]) } }
        }
        return Levels(used: used, out: out, calibration: cal, phase: phase, actNow: actNow, base: b)
    }

    /// `forecast`: the meter's sample paths (`tr.nPaths` of them), or a flat
    /// point forecast.
    public func forecast(_ history: ArenaHistory, now: Millis, _ tr: ArenaTargetRequest) throws -> ArenaTargetForecast {
        let L = try levels(history, now: now, tr)
        guard let out = L.out else {
            return .point([Double](repeating: min(L.used, 100), count: tr.grid.count))
        }
        let n = tr.nPaths
        let na = FMCal.alpha.count
        // np.linspace(0, A - 1, n).round(): numpy's linspace (step times i,
        // the last exactly the end), then round half to even.
        let idx: [Int] = (0..<n).map { i in
            if n == 1 { return 0 }
            if i == n - 1 { return na - 1 }
            let v = Double(i) * (Double(na - 1) / Double(n - 1))
            return Int(v.rounded(.toNearestOrEven))
        }
        var order = Array(0..<n)
        FMPaths.shuffle(&order, rng: &ctx.rng)                                       // rng.permutation(n)
        var paths = order.map { i in out.map { $0[idx[i]] } }
        paths = FMPaths.monotoneMeter(paths, floor: L.used)
        if cfg.bool("ration", true) && L.used < 99.5 {
            paths = ration(paths, s: L.base.series, resetAt: tr.resetAt, used: L.used)
        }
        return ArenaTargetForecast(paths: paths)
    }

    /// `_ration`: a user near the limit often stops short of it. Of this
    /// meter's past cycles that came within `ration_band` points of 100, the
    /// share that stopped short (Beta prior) is the chance a path that
    /// reaches the limit is held instead at a level those cycles stopped at.
    func ration(_ paths: [[Double]], s: FMSeries.MeterSeries, resetAt: Millis?, used: Double) -> [[Double]] {
        let band = cfg.double("ration_band", 5.0)
        var maxes: [Double] = []
        if !s.isEmpty {
            let ref = resetAt ?? 0
            let half = Double(s.duration) / 2
            // Readings of other cycles, grouped by cycle: resets within half a
            // window are one cycle (sorted by reset, stable).
            var rows: [(r: Millis, u: Double)] = []
            for i in 0..<s.count where s.active[i] && abs(Double(s.reset[i] - ref)) >= half {
                rows.append((s.reset[i], s.cycleUtil[i]))
            }
            let sorted = rows.enumerated().sorted { ($0.element.r, $0.offset) < ($1.element.r, $1.offset) }.map(\.element)
            var cur = -Double.infinity
            for (i, row) in sorted.enumerated() {
                if i > 0 && Double(row.r - sorted[i - 1].r) >= half { maxes.append(cur); cur = -.infinity }
                cur = max(cur, row.u)
            }
            if !sorted.isEmpty { maxes.append(cur) }
        }
        let near = maxes.filter { $0 >= 100.0 - band }
        let short = near.filter { $0 < 100.0 }
        let a0 = cfg.double("ration_prior_short", 1.0), b0 = cfg.double("ration_prior_hit", 2.0)
        let rho = (Double(short.count) + a0) / (Double(near.count) + a0 + b0)
        let hit = paths.map { $0.contains { $0 >= 99.5 } }
        guard hit.contains(true), rho > 0 else { return paths }
        let pool = short.isEmpty ? [98.0, 99.0] : short
        var out = paths
        let draws = paths.map { _ in ctx.rng.uniform() }                            // rng.random(len(paths))
        for i in out.indices where hit[i] && draws[i] < rho {
            let pick = pool[min(Int(ctx.rng.uniform() * Double(pool.count)), pool.count - 1)]
            let lvl = max(pick, used)
            out[i] = out[i].map { min($0, lvl) }
        }
        return out
    }
}
