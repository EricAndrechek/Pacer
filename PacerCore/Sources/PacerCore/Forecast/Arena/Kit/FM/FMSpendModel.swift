import Foundation

/// `research/arena/kit/fm/spend_model.py` `SpendModel`: a pretrained
/// forecaster as an hourly spend model (`models/fm-*-spend`).
///
/// For each hourly target (a group of accounts; optionally one model family):
///
/// 1. the group's hourly spend over the last `context_hours`, aligned to
///    `now` (`FMSeries.TurnFrame`);
/// 2. covariates (`covariates`): `calendar` (known over the horizon: hour of
///    day and day of week, sin/cos, local time); `meter` (past only: the
///    5-hour and 7-day meters at each hour's end); `sessions` and `prompts`
///    (past only; see `TurnFrame` for what the contract lets them be);
/// 3. the forecaster's quantiles to the horizon, clipped at 0 and at
///    `cap_factor` times the context's largest hour, tails extended, turned
///    into paths by a Gaussian copula with AR(1) correlation `rho` per hour
///    (hourly spend is autocorrelated, not comonotone).
///
/// The contract's targets are meters only, so this model answers no
/// `ArenaRequest` target: the structural models call `hourly` on it
/// directly (the arena's `spend.hourly` requests). `multivariate = "none"`
/// (every registered model's setting) is the only mode ported.
public final class FMSpendModel: ArenaModel {
    /// One `spend.hourly` (or `tokens.hourly`) target.
    public struct HourlyTarget: Sendable {
        public var key: String
        public var accounts: [String]
        public var family: String?
        public var grid: [Millis]
        public var nPaths: Int
        public var what: String
        public init(key: String, accounts: [String], family: String?, grid: [Millis], nPaths: Int = 200,
                    what: String = "spend") {
            self.key = key; self.accounts = accounts; self.family = family; self.grid = grid
            self.nPaths = nPaths; self.what = what
        }
    }

    let cfg: ArenaConfig
    let services: ArenaServices
    var rng: ArenaRNG
    var history: ArenaHistory?
    private var _backend: TimestralForecaster?

    public convenience init(context: ArenaContext) throws {
        try self.init(config: context.config, services: context.services, seed: context.seed)
    }

    public init(config: ArenaConfig, services: ArenaServices, seed: UInt64) throws {
        cfg = config
        self.services = services
        rng = ArenaRNG(seed: seed)
        let backend = cfg.string("backend", "timestral")
        guard backend == "timestral" else { throw ArenaError.invalid("kit.fm backend \(backend) is not ported") }
        let mode = cfg.string("multivariate", "none")
        guard mode == "none" else { throw ArenaError.invalid("multivariate = \(mode) is not ported") }
    }

    var backend: TimestralForecaster {
        get throws {
            if let b = _backend { return b }
            let b = try FMBackends.timestral(cfg.string("weights", ""), services: services)
            _backend = b
            return b
        }
    }

    public func fit(_ history: ArenaHistory) { self.history = history }

    /// No meter targets: an empty forecast (see the type's note).
    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast { ArenaForecast(byKey: [:]) }

    /// The paths `[nPaths][grid.count]` for each target, by key.
    public func hourly(_ targets: [HourlyTarget], now: Millis) throws -> [String: [[Double]]] {
        let q = try hourlyQuantiles(targets, now: now)
        var out: [String: [[Double]]] = [:]
        let rho = cfg.double("rho", 0.8)
        for tr in targets {
            guard let (lv, qs) = q[tr.key] else { continue }
            out[tr.key] = FMPaths.toPaths(lv, qs, nPaths: tr.nPaths, .ar1, rho: rho, rng: &rng)
                .map { $0.map { max($0, 0) } }
        }
        return out
    }

    /// The deterministic part (`_paths` before `to_paths`): per target, the
    /// levels and `[grid.count][Q]` quantiles the paths are drawn from.
    public func hourlyQuantiles(_ jobs: [HourlyTarget], now: Millis) throws -> [String: ([Double], [[Double]])] {
        guard let history else { throw ArenaError.invalid("forecast before fit") }
        guard !jobs.isEmpty else { return [:] }
        let t = cfg.int("context_hours", 336)
        let accounts = Array(Set(jobs.flatMap(\.accounts))).sorted()
        let tf = FMSeries.TurnFrame(history, hours: t, accounts: accounts, now: now)
        let steps = Dictionary(uniqueKeysWithValues: jobs.map { ($0.key, Self.steps(now: now, grid: $0.grid)) })
        let h = steps.values.map { $0.max() ?? 1 }.max() ?? 1
        let covNames = cfg["covariates"]?.array?.compactMap(\.string) ?? []
        let raw = jobs.map { [tf.hourly($0.accounts, what: $0.what, family: $0.family)] }      // [B][1][T]
        let (past, known) = covariates(history, tf, jobs, now: now, t: t, h: h, names: covNames)
        let out = try FMBackends.quantiles(try backend, context: raw.map { $0.map { $0.map(fwd) } }, horizon: h,
                                           pastCov: past, knownCov: known)
        var res: [String: ([Double], [[Double]])] = [:]
        for (b, tr) in jobs.enumerated() {
            res[tr.key] = paths(out.levels, out.curve(b, 0).map { $0.map(inv) }, steps: steps[tr.key]!, context: raw[b][0])
        }
        return res
    }

    // Hourly spend is intermittent: a quantile head reads a few spikes among
    // hundreds of idle hours as a fat top tail, so every quantile is capped at
    // `cap_factor` times the context's largest hour. `transform = "log1p"`
    // was worse in the arena and is off by default.
    func fwd(_ y: Double) -> Double { cfg.string("transform", "none") == "log1p" ? log1p(max(y, 0)) : y }
    func inv(_ q: Double) -> Double { cfg.string("transform", "none") == "log1p" ? expm1(min(q, 700)) : q }

    /// Grid times as hours after now (`np.round`: half to even), at least 1.
    static func steps(now: Millis, grid: [Millis]) -> [Int] {
        grid.map { max(1, Int((Double($0 - now) / Double(FMSeries.hourMs)).rounded(.toNearestOrEven))) }
    }

    func covariates(_ history: ArenaHistory, _ tf: FMSeries.TurnFrame, _ jobs: [HourlyTarget], now: Millis,
                    t: Int, h: Int, names: [String]) -> (past: [[[Double]]]?, known: [[[Double]]]?) {
        guard !names.isEmpty else { return (nil, nil) }
        var known: [[[Double]]]?
        if names.contains("calendar") {
            let ends = (-(t - 1)...h).map { now + FMSeries.hourMs * Millis($0) }
            let cal = FMSeries.calendar(ends, tzOffsetMin: tf.tzOffsetMin)                      // [4][T + H]
            known = jobs.map { _ in cal }
        }
        // A request's targets share a group's rows.
        var byGroup: [[String]: [[Double]]] = [:]
        var pastRows: [[[Double]]] = []
        for tr in jobs {
            let g = tr.accounts
            if byGroup[g] == nil {
                var rows: [[Double]] = []
                if names.contains("meter") {
                    for wk in ["five_hour", "seven_day"] {
                        rows.append(FMSeries.meterLevelHourly(history, accounts: g, windowKind: wk, now: now, hours: t))
                    }
                }
                if names.contains("sessions") { rows.append(tf.sessionsPerHour(g, hours: t)) }
                if names.contains("prompts") { rows.append(tf.promptsPerHour(g, hours: t)) }
                byGroup[g] = rows
            }
            pastRows.append(byGroup[g]!)
        }
        let past = (pastRows.first?.isEmpty ?? true) ? nil : pastRows
        return (past, known)
    }

    /// `_paths` up to the draw: the quantiles at each grid hour, non-negative,
    /// tails extended, capped.
    func paths(_ levels: [Double], _ q: [[Double]], steps: [Int], context: [Double]) -> ([Double], [[Double]]) {
        var qs = FMPaths.fixCrossing(steps.map { s in q[min(s, q.count) - 1].map { max($0, 0) } })
        let ext = FMPaths.extendTails(levels, qs)
        qs = ext.q.map { $0.map { max($0, 0) } }
        let cap = cfg.double("cap_factor", 1.5)
        let finite = context.filter(\.isFinite)
        if cap > 0, let mx = finite.max() {
            qs = qs.map { $0.map { min($0, cap * mx) } }
        }
        return (ext.levels, qs)
    }
}
