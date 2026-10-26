import Foundation

/// `models/g1-10-fable-analog/model.py` (`Model`), the meter targets: every
/// complete past cycle of the same meter is cut every few minutes; each cut
/// records the level, the rise over the last 15 min / 1 h (weekly: 1 / 6 /
/// 24 h), the local hour and weekday, and the increment trajectory from the
/// cut to its reset. At `now` the cuts are weighted by closeness in phase,
/// time of day, recent rise, account and recency, and the forecast is read
/// off their trajectories re-based on the latest reading.
///
/// Where the arena draws 200 cuts with probability ∝ weight (the five-hour
/// meter, and the scoped one when its cuts suffice), this port returns the
/// distribution those draws sample: its weighted type-1 quantiles, shrunk
/// toward the median (`kit/detq.analog_quantiles`, port-spec § "The analog
/// model"). The simulations (the weekly day model, the low-support mixture)
/// return paths, as the arena does.
final class FableAnalogModel: ArenaModel {
    let ctx: ArenaContext
    let cfg: ArenaConfig
    var rng: ArenaRNG
    private(set) var history: ArenaHistory?

    /// `build_meter_table`'s default: at most the latest 400 past cycles per account.
    static let maxCycles = 400

    init(context: ArenaContext) {
        ctx = context
        cfg = context.config
        rng = context.rng
    }

    func fit(_ history: ArenaHistory) {
        self.history = history
    }

    func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let h = history else { throw ArenaError.invalid("forecast before fit") }
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets {
            do {
                out[tr.key] = try meter(h, tr)
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                // never fail the whole request (`_safe`)
                ctx.log("\(tr.key): fallback after \(error)")
                out[tr.key] = KitBaselines.meterFlat(h, tr)
            }
        }
        return ArenaForecast(byKey: out)
    }

    // MARK: - Meters

    /// What `_meter` builds before it weighs anything (`detq.analog_query`).
    struct Query {
        let q: Analog.MeterQuery
        let kind: String
        let cap: String?
        let cfg: ArenaConfig
        let tz: Millis
        let accounts: [String]
    }

    func query(_ h: ArenaHistory, _ tr: ArenaTargetRequest) -> Query {
        let acct = tr.accounts[0]
        let m = KitBaselines.meterNow(h, tr)
        let kind = m.windowKind, cap = m.scopeModel
        let kcfg = cfg.table("meter").table(kind)
        let tz = Analog.tzMs(h, acct)
        let now = h.now
        let lags = Analog.meterLags(kind)
        let uNow: Double
        let rates: [Double]
        if let last = m.util.last {
            uNow = last
            rates = lags.map { uNow - Analog.stepAt(m.t, m.util, now - $0) }
        } else {
            uNow = 0
            rates = [Double](repeating: 0, count: lags.count)
        }
        let q = Analog.MeterQuery(e: Double(now - m.start), remaining: Double(m.reset - now), u: uNow, rates: rates,
                                  hour: Analog.localHour(now, tz), dow: Analog.localDow(now, tz), acct: acct, now: now)
        var accounts = h.accounts.isEmpty ? [acct] : h.accounts
        if !accounts.contains(acct) { accounts.insert(acct, at: 0) }
        return Query(q: q, kind: kind, cap: cap, cfg: kcfg, tz: tz, accounts: accounts)
    }

    /// `_table`: the table of cuts as known at `h.now`, from the store's
    /// cycle index when that is provably the same table (`Analog.CycleIndex`),
    /// else built from this cut's past cycles, as the arena does.
    func table(_ h: ArenaHistory, kind: String, cap: String?, accounts: [String], tz: Millis,
               _ kcfg: ArenaConfig) -> Analog.MeterTable {
        let step = Millis(kcfg.int("step_min", 5)) * Analog.MIN
        let M = kcfg.int("M", 60)
        let W = KitSpend.windowMs(kind)
        if let blocks = Self.indexedBlocks(h, kind: kind, cap: cap, accounts: accounts, tz: tz, step: step, M: M) {
            return Analog.MeterTable(kind: kind, W: W, lags: Analog.meterLags(kind), M: M, blocks: blocks)
        }
        let key = "analog.table|\(kind)|\(cap ?? "")|\(accounts.joined(separator: "+"))|\(tz)|\(step)|\(M)"
        return h.memo.value(key) {
            let T = Analog.buildMeterTable(h, accounts: accounts, kind: kind, cap: cap, tz: tz, step: step, M: M,
                                           maxCycles: Self.maxCycles)
            if cfg.bool("verbose", false) { ctx.log("meter table \(kind)/\(cap ?? "-"): \(T.count) cuts from \(T.nCycles) cycles") }
            return T
        }
    }

    /// The table's blocks from the store's cycle index, or nil when some
    /// account's cycles cannot be selected exactly at this cut.
    static func indexedBlocks(_ h: ArenaHistory, kind: String, cap: String?, accounts: [String], tz: Millis,
                              step: Millis, M: Int) -> [Analog.CycleCuts]? {
        let memo = Analog.StoreMemo.memo(for: h.store)
        var blocks: [Analog.CycleCuts] = []
        for acct in accounts {
            let key = "analog.index|\(acct)|\(kind)|\(cap ?? "")|\(h.start.map { String($0) } ?? "-")|\(tz)|\(step)|\(M)"
            let index = memo.value(key) {
                Analog.CycleIndex(store: h.store, account: acct, kind: kind, cap: cap, start: h.start,
                                  tz: tz, step: step, M: M)
            }
            guard let sel = index.select(now: h.now, maxCycles: maxCycles) else { return nil }
            blocks += sel
        }
        return blocks
    }

    /// `_meter`.
    func meter(_ h: ArenaHistory, _ tr: ArenaTargetRequest) throws -> ArenaTargetForecast {
        let Q = query(h, tr)
        let q = Q.q, kcfg = Q.cfg
        let grid = tr.grid
        let nPaths = tr.nPaths
        let minEss = kcfg.double("min_ess", 8)
        let blockShare = kcfg.double("block_share", 0)
        let verbose = cfg.bool("verbose", false)
        var paths: [[Double]]?
        var e = 0.0
        // With `block_share` 1 (the weekly meter) every analog path is
        // replaced by a day-model path: the arena builds, weighs and draws
        // the table only to overwrite all of it, so here it is skipped.
        if blockShare < 1 {
            let T = table(h, kind: Q.kind, cap: Q.cap, accounts: Q.accounts, tz: Q.tz, kcfg)
            try ctx.checkCancelled()
            if T.count > 0 {
                let (w, scale, ess) = Analog.meterWeights(T, q, kcfg)
                if verbose {
                    ctx.log("meter \(T.kind): n=\(T.count) ess=\(ess) scale=\(scale) u=\(q.u) rates=\(q.rates) e_h=\(q.e / Double(Analog.HOUR))")
                }
                var total = 0.0
                for x in w { total += x }
                if total.isFinite && total > 0 && w.allSatisfy(\.isFinite) {
                    e = ess
                    if ess >= minEss && blockShare <= 0 {
                        // The pure analog draw: its exact quantiles.
                        try ctx.checkCancelled()
                        let (quantiles, _) = Analog.analogQuantiles(T, q, grid, w: w, levels: Analog.forecastLevels, kcfg)
                        return ArenaTargetForecast(levels: Analog.forecastLevels, quantiles: quantiles, extras: ["ess": ess])
                    }
                    paths = Analog.meterPathsFromTable(T, q, grid, nPaths: nPaths, rng: &rng, kcfg, w: w)
                }
            }
        }
        // The day model: a second component that uses every reading (the
        // current cycle too), and the whole answer when no complete cycle
        // exists yet. (`block_method` "bootstrap" and `use_turns` are not
        // ported: no shipped config uses them.)
        var block: [[Double]]?
        if blockShare > 0 || paths == nil || e < minEss {
            try ctx.checkCancelled()
            let series = KitSpend.meterSeries(h, account: q.acct, windowKind: Q.kind, scopeModel: Q.cap)
            block = Analog.meterDaymodelPaths(series, q, grid, W: KitSpend.windowMs(Q.kind), tz: Q.tz, nPaths: nPaths,
                                              rng: &rng, kcfg, log: verbose ? { [ctx] in ctx.log($0) } : nil)
        }
        var P: [[Double]]
        if var analog = paths {
            let share = e >= minEss ? blockShare : max(blockShare, 1 - e / minEss)
            let k = min(Int((Double(nPaths) * share).rounded(.toNearestOrEven)), analog.count)
            if k > 0, let block {
                for i in 0..<k { analog[i] = block[i] }
            } else if k > 0 {
                let pace = Analog.meterPathsPace(q, grid, nPaths: k, rng: &rng, kind: Q.kind)
                for i in 0..<k { analog[i] = pace[i] }
            }
            P = analog
        } else {
            P = block ?? Analog.meterPathsPace(q, grid, nPaths: nPaths, rng: &rng, kind: Q.kind)
        }
        // Dispersion shrink toward the ensemble median (hidden-tier
        // five-hour bands were far too wide: 50 % bands covered ~94 %).
        let shrink = kcfg.double("shrink", 1.0)
        if shrink < 1.0 && !P.isEmpty {
            for j in 0..<grid.count {
                let col = P.map { $0[j] }.sorted()
                let n = col.count
                let med = n % 2 == 1 ? col[n / 2] : (col[n / 2 - 1] + col[n / 2]) / 2   // np.median
                for i in P.indices {
                    P[i][j] = min(max((med + shrink * (P[i][j] - med)).rounded(.toNearestOrEven), 0), 100)
                }
            }
        }
        // The support behind the analog share (none when the table was skipped).
        return ArenaTargetForecast(paths: P, extras: blockShare < 1 ? ["ess": e] : [:])
    }
}
