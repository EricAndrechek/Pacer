import Foundation

/// `research/arena/kit/fm/meter_model.py` `MeterModel`: a pretrained
/// forecaster as a direct meter model (`models/fm-*-meter`).
///
/// For each meter target (5-hour, 7-day, a scoped cap) of one account:
///
/// 1. the meter's cumulative burn (`FMSeries.meterSeries`: this cycle's
///    readings at the end, the previous cycles before them), resampled onto
///    a regular grid ending at `now` (`step_min`, `context_steps`; a reading
///    older than `stale_min` leaves a NaN gap);
/// 2. the forecaster's quantiles of that series to the reset;
/// 3. burn since now = quantile − latest value, per level non-decreasing and
///    never negative; outer tails extended to 1 %/99 % where the head stops
///    short (Timestral's 21 levels already reach them);
/// 4. read at the request's grid times, added to the meter now (the latest
///    reading of the cycle, as read), clipped to [the meter now, 100].
///
/// Without a reading of the cycle within `stale_min` of now there is nothing
/// to continue: the forecast is the meter now, flat.
///
/// The arena draws comonotone paths from these quantiles (one level per path
/// at every time); the port hands back the quantiles themselves
/// (`ArenaTargetForecast(levels:quantiles:)`), whose `samplePaths` are the
/// same comonotone reading. The forecaster is the config's `backend`, any
/// of `FMBackends.factories` (the samples mode, Toto's, is not ported).
public final class FMMeterModel: ArenaModel {
    public static let windowFor: [ArenaTarget: String] = [
        .meterFiveHour: "five_hour", .meterSevenDay: "seven_day", .meterScoped: "weekly_scoped",
    ]
    static let defaultStepMin = ["five_hour": 5, "seven_day": 15, "weekly_scoped": 15]
    static let defaultContext = ["five_hour": 288, "seven_day": 672, "weekly_scoped": 672]

    let ctx: ArenaContext
    let cfg: ArenaConfig
    var history: ArenaHistory?
    let backendName: String
    private var _backend: (any FMBackend)?

    public init(context: ArenaContext) throws {
        ctx = context
        cfg = context.config
        backendName = cfg.string("backend", "timestral")
        guard FMBackends.factories[backendName] != nil else {
            throw ArenaError.invalid("kit.fm backend \(backendName) is not ported")
        }
    }

    var backend: any FMBackend {
        get throws {
            if let b = _backend { return b }
            let b = try FMBackends.backend(backendName, weights: cfg.string("weights", ""), services: ctx.services)
            _backend = b
            return b
        }
    }

    public func fit(_ history: ArenaHistory) { self.history = history }

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let history else { throw ArenaError.invalid("forecast before fit") }
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets {
            guard let wk = Self.windowFor[tr.target] else { continue }
            try ctx.checkCancelled()
            out[tr.key] = try meter(history, now: request.now, tr, wk)
        }
        return ArenaForecast(byKey: out)
    }

    // MARK: -

    func stepMs(_ wk: String) -> Millis {
        Millis(cfg.table("step_min").int(wk, Self.defaultStepMin[wk] ?? 15)) * FMSeries.minMs
    }

    func contextSteps(_ wk: String) -> Int {
        cfg.table("context_steps").int(wk, Self.defaultContext[wk] ?? 672)
    }

    func meter(_ history: ArenaHistory, now: Millis, _ tr: ArenaTargetRequest, _ wk: String) throws -> ArenaTargetForecast {
        let mq = try meterQuantiles(history, now: now, tr, wk)
        guard let levels = mq.levels else { return .point(mq.q.map { $0[0] }) }
        // Rows are levels in the contract, grid times in the Python.
        let byLevel = levels.indices.map { k in mq.q.map { $0[k] } }
        return ArenaTargetForecast(levels: levels, quantiles: byLevel)
    }

    /// `(used, ctx_v, step)`: the meter now, the context the forecaster reads
    /// (cumulative burn, resampled, NaN = stale), its step.
    func inputs(_ history: ArenaHistory, now: Millis, _ tr: ArenaTargetRequest, _ wk: String)
        -> (used: Double, ctxV: [Double], step: Millis) {
        let cap = tr.target == .meterScoped ? tr.cap : nil
        // The cut's rows are the first `k` of `s` (no copy: see meterSeriesPrefix).
        let (s, k) = FMSeries.meterSeriesPrefix(history, account: tr.accounts[0], windowKind: wk, scopeModel: cap, now: now)
        // No reading of this cycle known: the latest active reading, else 0.
        let used = tr.resetAt.flatMap { s.usedNow($0, count: k) } ?? s.lastActiveUtil(count: k) ?? 0
        let step = stepMs(wk)
        let ctxT = FMSeries.regularGrid(now: now, stepMs: step, n: contextSteps(wk))
        let stale = Millis(cfg.int("stale_min", 120)) * FMSeries.minMs
        return (used, FMSeries.resampleLast(times: s.times, values: s.cum, grid: ctxT, staleMs: stale, count: k), step)
    }

    /// `MeterQuantiles`: `q` `[G][Q]`, the meter at each grid time at `levels`
    /// (nil: a flat forecast at `used`, one column), and the intermediates a
    /// port checks itself against.
    public struct MeterQuantiles: Sendable {
        public let used: Double
        public let levels: [Double]?
        public let q: [[Double]]
        public let ctxV: [Double]
        public let step: Millis
        public let horizon: Int
        public let rawLevels: [Double]?
        /// `[horizon][Q']`: the forecaster's own quantiles of the cumulative burn.
        public let raw: [[Double]]?
    }

    /// `meter_quantiles`: the forecast's quantiles on the request grid,
    /// deterministic given the weights.
    public func meterQuantiles(_ history: ArenaHistory, now: Millis, _ tr: ArenaTargetRequest,
                               _ wk: String) throws -> MeterQuantiles {
        let (used, ctxV, step) = inputs(history, now: now, tr, wk)
        let grid = tr.grid
        guard let cLast = ctxV.last, cLast.isFinite, used < 100, let gLast = grid.last else {
            return MeterQuantiles(used: used, levels: nil, q: grid.map { _ in [min(used, 100)] }, ctxV: ctxV,
                                  step: step, horizon: 0, rawLevels: nil, raw: nil)
        }
        let horizon = Self.horizonSteps(now: now, last: gLast, step: step)
        let out = try backend.quantiles(context: [[ctxV]], horizon: horizon)
        let raw = out.curve()
        let (levels, q) = Self.meterQuantiles(raw: raw, rawLevels: out.levels, used: used, cLast: cLast, step: step,
                                              horizon: horizon, now: now, grid: grid)
        return MeterQuantiles(used: used, levels: levels, q: q, ctxV: ctxV, step: step, horizon: horizon,
                              rawLevels: out.levels, raw: raw)
    }

    /// `max(1, ceil((grid[-1] - now) / step))`.
    static func horizonSteps(now: Millis, last: Millis, step: Millis) -> Int {
        max(1, Int((last - now + step - 1) / step))
    }

    /// The arithmetic after the network (`meter_quantiles` from `burn` on):
    /// pure, so a port can check it on the fixture's own `raw` to 1e-6.
    public static func meterQuantiles(raw: [[Double]], rawLevels: [Double], used: Double, cLast: Double,
                                      step: Millis, horizon: Int, now: Millis,
                                      grid: [Millis]) -> (levels: [Double], q: [[Double]]) {
        var burn = FMPaths.burnQuantiles(raw, cLast: cLast)                         // [H][Q]
        let ext = FMPaths.extendTails(rawLevels, burn)
        let levels = ext.levels
        burn = ext.q
        // np.maximum.accumulate(np.maximum(burn, 0), axis=0), then sorted rows.
        if let nq = burn.first?.count {
            var running = [Double](repeating: -.infinity, count: nq)
            burn = FMPaths.fixCrossing(burn.map { row in
                (0..<nq).map { k in running[k] = max(running[k], max(row[k], 0)); return running[k] }
            })
        }
        burn.insert([Double](repeating: 0, count: levels.count), at: 0)
        let tRel = (0...horizon).map { Double(step) * Double($0) }
        let gRel = grid.map { Double($0 - now) }
        let at = FMPaths.interpTimes(tRel, gRel, burn)                                // [G][Q]
        let q = at.map { row in row.map { min(max(used + $0, used), 100.0) } }
        return (levels, q)
    }
}
