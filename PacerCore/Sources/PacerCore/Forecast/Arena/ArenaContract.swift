import Foundation

// The forecast arena's model contract, in Swift.
//
// `research/arena/` is where forecasters are built and scored, in Python; this
// folder is where the winners run inside Pacer. The two are kept the same
// shape on purpose, so moving a model across is a translation, not a
// redesign: a model is a class built from a context, fitted on a history and
// asked for a forecast; it can ask its declared children for theirs and for
// their forecasts over its own past (`backtest`), and the runner, not the
// parent, runs them. Names follow the Python (`research/arena/arena/types.py`):
// `Millis`, `History`, `TargetRequest`, `Request`, `TargetForecast`,
// `Forecast`, `Context`, each with an `Arena` prefix. Where this file and
// `types.py` disagree on what a model may rely on, `types.py` wins and this
// file has a bug.
//
// Only the meter targets are ported: the engine forecasts limit meters, and
// the arena's spend, token, split and next-start targets have no reader in
// the app.

/// Epoch milliseconds, UTC: every time in the contract, as in the arena.
public typealias Millis = Int64

public enum ArenaTime {
    public static let second: Millis = 1_000
    public static let minute: Millis = 60_000
    public static let hour: Millis = 3_600_000
    public static let day: Millis = 86_400_000

    public static func millis(_ date: Date) -> Millis { Millis((date.timeIntervalSince1970 * 1000).rounded()) }
    public static func date(_ ms: Millis) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

/// Model families, in the arena's order (`arena/episodes.py` `FAMILIES`).
/// Per-family arrays (spend, conversion rates) are indexed in this order.
public let arenaFamilies = ["fable", "opus", "sonnet", "haiku", "other"]

// MARK: - Targets

public enum ArenaTarget: String, Sendable, Codable, CaseIterable, Hashable {
    case meterFiveHour = "meter.five_hour"
    case meterSevenDay = "meter.seven_day"
    /// A per-model weekly cap (`TargetRequest.cap`, e.g. "Fable").
    case meterScoped = "meter.scoped"

    /// The `window_kind` of the readings this target forecasts.
    public var windowKind: String {
        switch self {
        case .meterFiveHour: "five_hour"
        case .meterSevenDay: "seven_day"
        case .meterScoped: "weekly_scoped"
        }
    }

    public var windowMillis: Millis {
        self == .meterFiveHour ? 5 * ArenaTime.hour : 7 * ArenaTime.day
    }

    /// The runner's grid step after the dense head (`GRID_STEP`).
    public var gridStep: Millis { self == .meterFiveHour ? 5 * ArenaTime.minute : 30 * ArenaTime.minute }

    /// The dense head (`GRID_HEAD`): leads before the regular steps begin.
    public var gridHead: [Millis] {
        self == .meterFiveHour
            ? [30 * ArenaTime.second, ArenaTime.minute, 2 * ArenaTime.minute, 3 * ArenaTime.minute]
            : [ArenaTime.minute, 5 * ArenaTime.minute, 15 * ArenaTime.minute]
    }

    /// The arena's `target_key`: `meter.five_hour:A2`, `meter.scoped:A2:Fable`.
    public func key(account: String, cap: String? = nil) -> String {
        "\(rawValue):\(account)" + (cap.map { ":\($0)" } ?? "")
    }
}

// MARK: - History

/// One meter reading (`meter_readings` row). `utilPct` nil: unknown;
/// `resetsAt` nil: idle. `active` is the arena's `state == "active"`.
public struct ArenaReading: Sendable, Equatable, Codable {
    public var tEvent: Millis
    public var tKnown: Millis
    public var utilPct: Double?
    public var resetsAt: Millis?
    public var active: Bool
    public init(tEvent: Millis, tKnown: Millis, utilPct: Double?, resetsAt: Millis?, active: Bool) {
        self.tEvent = tEvent; self.tKnown = tKnown; self.utilPct = utilPct
        self.resetsAt = resetsAt; self.active = active
    }
}

/// Which meter a reading belongs to: account × window kind × scoped cap.
/// `scopeModel` is set only for `weekly_scoped` (the arena's `scope_model`).
public struct ArenaMeterID: Sendable, Hashable, Codable {
    public var account: String
    public var windowKind: String
    public var scopeModel: String?
    public init(account: String, windowKind: String, scopeModel: String? = nil) {
        self.account = account; self.windowKind = windowKind; self.scopeModel = scopeModel
    }
    public var target: ArenaTarget? {
        switch windowKind {
        case "five_hour": .meterFiveHour
        case "seven_day": .meterSevenDay
        case "weekly_scoped": .meterScoped
        default: nil
        }
    }
}

/// Spend, as the port fixtures carry it: one pseudo-turn per model family per
/// five minutes, already priced (the bucket's last `t_event`, its latest
/// `t_known`, the summed API-equivalent cost). `costUSD` nil: the bucket held
/// only unpriced turns (never 0 for "unknown": AGENTS.md, cost silent-zero).
/// `turns` and `tokens` count what the bucket summed, for models that read
/// activity rather than cost.
public struct ArenaSpendRow: Sendable, Equatable, Codable {
    public var tEvent: Millis
    public var tKnown: Millis
    public var family: String
    public var costUSD: Double?
    public var turns: Int
    public var tokens: Int
    public init(tEvent: Millis, tKnown: Millis, family: String, costUSD: Double?, turns: Int = 1, tokens: Int = 0) {
        self.tEvent = tEvent; self.tKnown = tKnown; self.family = family
        self.costUSD = costUSD; self.turns = turns; self.tokens = tokens
    }
}

/// Everything loaded, for every time: built once (from the store in the app,
/// from a fixture in tests) and shared by every `ArenaHistory` cut from it.
/// Rows are in event order.
public final class ArenaHistoryStore: Sendable {
    public let meters: [ArenaMeterID: [ArenaReading]]
    public let spend: [String: [ArenaSpendRow]]
    /// The device's UTC offset in minutes (the arena: the latest known turn's;
    /// the app: the device clock's at `now`).
    public let tzOffsetMin: Int?
    /// The earliest row anything may see (`SnapshotData.data_start`).
    public let dataStart: Millis
    /// A memo for the store's lifetime: what is built once from every row and
    /// then read at many cuts (the analog model's table of past cycles, a
    /// loaded network's buffers keyed by the store). Per-cut values belong in
    /// `ArenaHistory.memo` instead, which cannot leak a later cut's rows.
    public let memo = ArenaMemo()
    /// True when every row's `tKnown` is non-decreasing in event order (the
    /// app: a row is known when it is written), so "known at t" is a prefix.
    let metersKnownInOrder: [ArenaMeterID: Bool]
    let spendKnownInOrder: [String: Bool]

    public init(meters: [ArenaMeterID: [ArenaReading]], spend: [String: [ArenaSpendRow]],
                tzOffsetMin: Int?, dataStart: Millis? = nil) {
        let m = meters.mapValues { $0.sorted { ($0.tEvent, $0.utilPct ?? -1) < ($1.tEvent, $1.utilPct ?? -1) } }
        let s = spend.mapValues { $0.sorted { $0.tEvent < $1.tEvent } }
        self.meters = m
        self.spend = s
        self.tzOffsetMin = tzOffsetMin
        self.dataStart = dataStart
            ?? min(m.values.compactMap { $0.first?.tEvent }.min() ?? 0, s.values.compactMap { $0.first?.tEvent }.min() ?? .max)
        self.metersKnownInOrder = m.mapValues { Self.inOrder($0.map(\.tKnown)) }
        self.spendKnownInOrder = s.mapValues { Self.inOrder($0.map(\.tKnown)) }
    }

    private static func inOrder(_ xs: [Millis]) -> Bool {
        zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 }
    }
}

/// Everything known at `now` (`types.History`): rows with `tKnown <= now` and
/// `tEvent >= start`, for the scope's accounts. Cheap to cut (`asOf`): it
/// shares the store and filters on read, memoized per instance, so a runner
/// that cuts once per backtest time and runs every model on that cut filters
/// once per cut.
public struct ArenaHistory: Sendable {
    public let store: ArenaHistoryStore
    public let now: Millis
    public let accounts: [String]
    /// Rows with `tEvent` before this are not seen (the fixtures'
    /// `history_start`; nil: the store's `dataStart`).
    public let start: Millis?
    /// Per-instance memo for derived values (the Python kits' `_memo`).
    public let memo: ArenaMemo

    public init(store: ArenaHistoryStore, now: Millis, accounts: [String], start: Millis? = nil) {
        self.store = store; self.now = now; self.accounts = accounts; self.start = start
        self.memo = ArenaMemo()
    }

    public var tzOffsetMin: Int? { store.tzOffsetMin }
    public var historyStart: Millis { start ?? store.dataStart }

    /// The same view as known at an earlier `t` (`t <= now`).
    public func asOf(_ t: Millis) -> ArenaHistory {
        precondition(t <= now, "asOf(\(t)) is after now (\(now)): that would leak the future")
        return ArenaHistory(store: store, now: t, accounts: accounts, start: start)
    }

    /// The meters this view holds for `account`.
    public func meters(account: String) -> [ArenaMeterID] {
        store.meters.keys.filter { $0.account == account }
            .sorted { ($0.windowKind, $0.scopeModel ?? "") < ($1.windowKind, $1.scopeModel ?? "") }
    }

    /// One meter's readings known at `now`, in event order.
    public func readings(_ id: ArenaMeterID) -> [ArenaReading] {
        guard accounts.contains(id.account), let all = store.meters[id] else { return [] }
        return memo.value("readings|\(id.account)|\(id.windowKind)|\(id.scopeModel ?? "")") {
            Self.known(all, now: now, start: historyStart, inOrder: store.metersKnownInOrder[id] ?? false,
                       tEvent: \.tEvent, tKnown: \.tKnown)
        }
    }

    public func readings(account: String, windowKind: String, scopeModel: String? = nil) -> [ArenaReading] {
        readings(ArenaMeterID(account: account, windowKind: windowKind, scopeModel: scopeModel))
    }

    /// One account's spend rows known at `now`, in event order.
    public func spend(account: String) -> [ArenaSpendRow] {
        guard accounts.contains(account), let all = store.spend[account] else { return [] }
        return memo.value("spend|\(account)") {
            Self.known(all, now: now, start: historyStart, inOrder: store.spendKnownInOrder[account] ?? false,
                       tEvent: \.tEvent, tKnown: \.tKnown)
        }
    }

    private static func known<R>(_ rows: [R], now: Millis, start: Millis, inOrder: Bool,
                                 tEvent: KeyPath<R, Millis>, tKnown: KeyPath<R, Millis>) -> [R] {
        if inOrder {
            // Binary search for the known prefix, then drop rows before start.
            var lo = 0, hi = rows.count
            while lo < hi { let mid = (lo + hi) / 2; if rows[mid][keyPath: tKnown] <= now { lo = mid + 1 } else { hi = mid } }
            var first = 0
            var a = 0, b = lo
            while a < b { let mid = (a + b) / 2; if rows[mid][keyPath: tEvent] < start { a = mid + 1 } else { b = mid } }
            first = a
            return Array(rows[first..<lo])
        }
        return rows.filter { $0[keyPath: tKnown] <= now && $0[keyPath: tEvent] >= start }
    }
}

/// A memo for derived values, shared by every model run on one history cut.
public final class ArenaMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    public init() {}

    /// `make()` runs outside the lock, so a slow derivation never blocks
    /// another key; two racing callers may both compute it, and the first
    /// stored value wins.
    ///
    /// The stored value is unwrapped before the cast: with an Optional `T`,
    /// `values[key] as? T` succeeds on a missing key (nil casts to any
    /// Optional), which returned nil and never computed.
    public func value<T>(_ key: String, _ make: () throws -> T) rethrows -> T {
        lock.lock()
        if let stored = values[key], let v = stored as? T { lock.unlock(); return v }
        lock.unlock()
        let v = try make()
        lock.lock(); defer { lock.unlock() }
        if let stored = values[key], let existing = stored as? T { return existing }
        values[key] = v
        return v
    }
}

// MARK: - Requests and forecasts

/// One thing to forecast (`types.TargetRequest`). `grid` is strictly
/// increasing, every value after `now`, ending exactly at the reset; it is
/// not evenly spaced (see `ArenaRunner.grid`).
public struct ArenaTargetRequest: Sendable, Equatable {
    public var key: String
    public var target: ArenaTarget
    public var accounts: [String]
    public var grid: [Millis]
    public var nPaths: Int
    public var cap: String?
    public var resetAt: Millis?
    public init(key: String, target: ArenaTarget, accounts: [String], grid: [Millis],
                nPaths: Int = 200, cap: String? = nil, resetAt: Millis?) {
        self.key = key; self.target = target; self.accounts = accounts; self.grid = grid
        self.nPaths = nPaths; self.cap = cap; self.resetAt = resetAt
    }
    public var account: String { accounts[0] }
    public var meter: ArenaMeterID {
        ArenaMeterID(account: account, windowKind: target.windowKind, scopeModel: cap)
    }
}

public struct ArenaRequest: Sendable, Equatable {
    public var now: Millis
    public var accounts: [String]
    public var targets: [ArenaTargetRequest]
    public init(now: Millis, accounts: [String], targets: [ArenaTargetRequest]) {
        self.now = now; self.accounts = accounts; self.targets = targets
    }
}

/// The forecast for one target (`types.TargetForecast`). The arena's form is
/// sample paths; a deterministic port may hand back quantiles instead (the
/// port fixtures compare quantiles). Either way every answer the app reads
/// (the median path, a range) comes from this one value.
public struct ArenaTargetForecast: Sendable {
    /// `[nPaths][grid.count]`, when the model made paths.
    public var paths: [[Double]]?
    /// Quantile levels, increasing, and `[levels.count][grid.count]`, when the
    /// model made quantiles.
    public var levels: [Double]?
    public var quantiles: [[Double]]?
    /// Direct estimates (`p_hit_limit`, ...), by name.
    public var extras: [String: Double]

    public init(paths: [[Double]], extras: [String: Double] = [:]) {
        self.paths = paths; self.levels = nil; self.quantiles = nil; self.extras = extras
    }
    public init(levels: [Double], quantiles: [[Double]], extras: [String: Double] = [:]) {
        precondition(levels.count == quantiles.count, "one quantile row per level")
        self.paths = nil; self.levels = levels; self.quantiles = quantiles; self.extras = extras
    }
    /// A model with no idea of uncertainty (`TargetForecast.point`).
    public static func point(_ values: [Double]) -> ArenaTargetForecast {
        ArenaTargetForecast(levels: [0.5], quantiles: [values])
    }

    public var gridCount: Int { paths?.first?.count ?? quantiles?.first?.count ?? 0 }

    /// How many doubles this forecast holds (for memory bounds).
    public var valueCount: Int {
        (paths?.reduce(0) { $0 + $1.count } ?? 0) + (quantiles?.reduce(0) { $0 + $1.count } ?? 0)
    }

    /// The value at quantile `q` at every grid time: linear between the
    /// model's levels (held flat beyond the outermost), or numpy's default
    /// (linear, type 7) over the paths.
    public func quantile(_ q: Double) -> [Double] {
        if let levels, let quantiles {
            return (0..<gridCount).map { j in
                ArenaMath.interp(q, xs: levels, ys: quantiles.map { $0[j] })
            }
        }
        guard let paths, !paths.isEmpty else { return [] }
        return (0..<gridCount).map { j in ArenaMath.quantile(paths.map { $0[j] }.sorted(), q) }
    }

    public var median: [Double] { quantile(0.5) }

    /// Sample paths: the model's own, or comonotone ones drawn from its
    /// quantiles (`TargetForecast.from_quantiles`: one uniform per path, read
    /// at that level at every grid time).
    public func samplePaths(_ n: Int, rng: inout ArenaRNG) -> [[Double]] {
        if let paths { return paths }
        guard let levels, let quantiles, let lo = levels.first, let hi = levels.last else { return [] }
        let us = (0..<n).map { _ in lo + (hi - lo) * rng.uniform() }.sorted()
        return us.map { u in (0..<gridCount).map { j in ArenaMath.interp(u, xs: levels, ys: quantiles.map { $0[j] }) } }
    }
}

public struct ArenaForecast: Sendable {
    public var byKey: [String: ArenaTargetForecast]
    public init(byKey: [String: ArenaTargetForecast]) { self.byKey = byKey }
}

// MARK: - Models

/// A forecaster (`types.ModelProtocol`). Built once per run from its
/// context, fitted on the history known at the run's `now`, then asked.
/// Instances are single-threaded and short-lived; anything a model wants to
/// keep across runs goes through its context's services, never statics.
public protocol ArenaModel: AnyObject {
    init(context: ArenaContext) throws
    func fit(_ history: ArenaHistory) throws
    /// The history moved on to `history.now` (`update(events)`): by default,
    /// fit again on the extended history, which is what a model that keeps no
    /// state of its own does.
    func update(_ history: ArenaHistory) throws
    func forecast(_ request: ArenaRequest) throws -> ArenaForecast
}

public extension ArenaModel {
    func update(_ history: ArenaHistory) throws { try fit(history) }
}

/// A model's identity and settings (`model.toml`): `name` is its folder
/// under `research/arena/models/`, so a port and its reference share one id.
public struct ArenaModelSpec: Sendable {
    public var name: String
    public var targets: Set<ArenaTarget>
    /// The only names `ArenaContext.model` and `backtest` take.
    public var children: [String]
    /// `model.toml` `[config]`, transcribed.
    public var config: ArenaConfig
    /// Pinned weights (`"mistralai/Timestral-5M@<revision>"`); a model whose
    /// weights are not on this Mac yet is not run (`ArenaServices.weights`).
    public var weights: [String]
    /// Near-tie break for the engine's per-user pick: simpler wins (1–5,
    /// as `BurnTrajectory.Model.complexity`).
    public var complexity: Int
    public var make: @Sendable (ArenaContext) throws -> any ArenaModel

    public init(name: String, targets: Set<ArenaTarget>, children: [String] = [], config: ArenaConfig = [:],
                weights: [String] = [], complexity: Int = 3,
                make: @escaping @Sendable (ArenaContext) throws -> any ArenaModel) {
        self.name = name; self.targets = targets; self.children = children; self.config = config
        self.weights = weights; self.complexity = complexity; self.make = make
    }
}

/// What a model can reach outside its inputs: pinned weights, a log, and the
/// run's cancellation. The app supplies the real ones; tests a stub.
public struct ArenaServices: Sendable {
    /// The local file for a pinned weights id, or nil when it is not on this
    /// Mac (yet). Never downloads.
    public var weights: @Sendable (String) -> URL?
    public var log: @Sendable (_ model: String, _ message: String) -> Void
    /// Checked between expensive steps; a model throws `ArenaError.cancelled`
    /// when it turns true.
    public var isCancelled: @Sendable () -> Bool

    public init(weights: @escaping @Sendable (String) -> URL? = { _ in nil },
                log: @escaping @Sendable (String, String) -> Void = { _, _ in },
                isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.weights = weights; self.log = log; self.isCancelled = isCancelled
    }
}

public enum ArenaError: Error, Equatable, CustomStringConvertible {
    case unknownModel(String)
    case notDeclaredChild(String)
    case weightsUnavailable(String)
    case insufficientHistory(String)
    case invalid(String)
    case cancelled

    public var description: String {
        switch self {
        case .unknownModel(let n): "unknown model \(n)"
        case .notDeclaredChild(let n): "\(n) is not a declared child"
        case .weightsUnavailable(let w): "weights not on this Mac: \(w)"
        case .insufficientHistory(let s): "not enough history: \(s)"
        case .invalid(let s): s
        case .cancelled: "cancelled"
        }
    }
}

/// Handed to a model's constructor (`types.Context`).
public final class ArenaContext {
    public let spec: ArenaModelSpec
    public let seed: UInt64
    public var rng: ArenaRNG
    public let services: ArenaServices
    unowned let runner: ArenaRunner
    let history: () -> ArenaHistory?

    init(spec: ArenaModelSpec, seed: UInt64, services: ArenaServices, runner: ArenaRunner,
         history: @escaping () -> ArenaHistory?) {
        self.spec = spec; self.seed = seed; self.rng = ArenaRNG(seed: seed)
        self.services = services; self.runner = runner; self.history = history
    }

    public var name: String { spec.name }
    public var config: ArenaConfig { spec.config }
    public var children: [String] { spec.children }

    /// A declared child. The runner runs it with exactly this model's view at
    /// the moment it is asked (the history this model was last fitted on).
    public func model(_ name: String) throws -> ArenaChildModel {
        guard children.contains(name) else { throw ArenaError.notDeclaredChild(name) }
        return ArenaChildModel(name: name, context: self)
    }

    /// The child's forecasts over this model's own past, each made without
    /// seeing what followed (`Context.backtest`): every `every` ms from
    /// `since` (or the history's start) to now, at most the runner's
    /// `maxBacktestPoints` most recent, each asked what a request at that
    /// time would have asked for `targets`.
    public func backtest(_ name: String, every: Millis, targets: Set<ArenaTarget>,
                         since: Millis? = nil) throws -> [(request: ArenaRequest, forecast: ArenaForecast)] {
        guard children.contains(name) else { throw ArenaError.notDeclaredChild(name) }
        guard let h = history() else { throw ArenaError.invalid("backtest before fit") }
        return try runner.backtest(child: name, history: h, every: every, targets: targets, since: since)
    }

    public func log(_ message: String) { services.log(spec.name, message) }

    public func checkCancelled() throws {
        if services.isCancelled() { throw ArenaError.cancelled }
    }
}

public struct ArenaChildModel {
    public let name: String
    let context: ArenaContext
    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let h = context.history() else { throw ArenaError.invalid("child asked before fit") }
        return try context.runner.forecast(model: name, history: h, request: request)
    }
}

// MARK: - Runner

/// Runs models in process, children included, the way the arena's runner
/// does (`arena/runner.py`): a model is built, fitted on the history known at
/// the request's `now`, and asked; a child is run by the runner with its
/// parent's view, and its forecasts are memoized for the runner's lifetime
/// (the arena's child cache). Not thread-safe: one runner per task.
public final class ArenaRunner {
    public let registry: [String: ArenaModelSpec]
    public let services: ArenaServices
    public let seed: UInt64
    public var maxBacktestPoints: Int
    public var nPaths: Int
    /// Memoized forecasts, keyed by model, history cut and request. Cleared
    /// whole when it holds more than `memoLimitValues` doubles (64 MB by
    /// default): a weekly forecast as paths is ~200 × 340 values, so a count
    /// of entries alone let a long backfill's memo reach gigabytes.
    private var memo: [String: ArenaForecast] = [:]
    private var memoValues = 0
    public var memoLimitValues = 8_000_000

    public init(registry: [ArenaModelSpec], services: ArenaServices = ArenaServices(), seed: UInt64 = 42,
                maxBacktestPoints: Int = 48, nPaths: Int = 200) {
        self.registry = Dictionary(registry.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        self.services = services; self.seed = seed
        self.maxBacktestPoints = maxBacktestPoints; self.nPaths = nPaths
    }

    /// Fit `model` on `history` (which must be as of `request.now`) and ask it.
    public func forecast(model name: String, history: ArenaHistory, request: ArenaRequest) throws -> ArenaForecast {
        guard let spec = registry[name] else { throw ArenaError.unknownModel(name) }
        precondition(history.now == request.now, "a model is asked at the moment it was fitted")
        let key = Self.memoKey(name, history: history, request: request)
        if let hit = memo[key] { return hit }
        // Every weights file the model's whole family of children needs, not
        // just its own: a pool whose network child is still downloading would
        // otherwise answer as its other child alone, and the engine would
        // score that under the pool's name and keep the record.
        for w in requiredWeights(name) where services.weights(w) == nil { throw ArenaError.weightsUnavailable(w) }
        try checkCancelled()
        var fitted: ArenaHistory?
        let ctx = ArenaContext(spec: spec, seed: Self.deriveSeed(seed, name, request.now), services: services,
                               runner: self, history: { fitted })
        let instance = try spec.make(ctx)
        try instance.fit(history)
        fitted = history
        let fc = try instance.forecast(request)
        let size = fc.byKey.values.reduce(0) { $0 + $1.valueCount }
        if memoValues + size > memoLimitValues { memo.removeAll(keepingCapacity: false); memoValues = 0 }
        memo[key] = fc
        memoValues += size
        return fc
    }

    /// The weights `name` and its children (transitively) are pinned to.
    public func requiredWeights(_ name: String) -> [String] {
        var seen: Set<String> = [], out: [String] = []
        func walk(_ n: String) {
            guard seen.insert(n).inserted, let s = registry[n] else { return }
            out += s.weights.filter { !out.contains($0) }
            s.children.forEach(walk)
        }
        walk(name)
        return out
    }

    func backtest(child: String, history: ArenaHistory, every: Millis, targets: Set<ArenaTarget>,
                  since: Millis?) throws -> [(request: ArenaRequest, forecast: ArenaForecast)] {
        guard every > 0 else { throw ArenaError.invalid("every must be > 0") }
        let floor = history.historyStart
        let start = since.map { max($0, floor) } ?? floor
        var times: [Millis] = []
        var t = start
        while t < history.now { times.append(t); t += every }
        var out: [(ArenaRequest, ArenaForecast)] = []
        for t in times.suffix(maxBacktestPoints) {
            try checkCancelled()
            let cut = history.asOf(t)
            let req = Self.request(history: cut, targets: targets, nPaths: nPaths)
            guard !req.targets.isEmpty else { continue }
            out.append((req, try forecast(model: child, history: cut, request: req)))
        }
        return out
    }

    func checkCancelled() throws {
        if services.isCancelled() { throw ArenaError.cancelled }
    }

    /// What a request at `history.now` would ask for `targets`, for every
    /// account in view, built only from what is known then
    /// (`runner._backtest_specs` → `episodes.meter_specs`).
    public static func request(history: ArenaHistory, targets: Set<ArenaTarget>, nPaths: Int = 200) -> ArenaRequest {
        var trs: [ArenaTargetRequest] = []
        for a in history.accounts {
            for id in history.meters(account: a) {
                guard let target = id.target, targets.contains(target) else { continue }
                if let tr = targetRequest(history: history, meter: id, nPaths: nPaths) { trs.append(tr) }
            }
        }
        return ArenaRequest(now: history.now, accounts: history.accounts, targets: trs)
    }

    /// The request for one meter at `history.now`, or nil when its window is
    /// idle then (no cycle in progress as known at now).
    public static func targetRequest(history: ArenaHistory, meter: ArenaMeterID, nPaths: Int = 200) -> ArenaTargetRequest? {
        guard let target = meter.target,
              let cycle = cycleAt(history.readings(meter), now: history.now),
              let grid = grid(target: target, now: history.now, resetAt: cycle.resetAt)
        else { return nil }
        return ArenaTargetRequest(key: target.key(account: meter.account, cap: meter.scopeModel), target: target,
                                  accounts: [meter.account], grid: grid, nPaths: nPaths, cap: meter.scopeModel,
                                  resetAt: cycle.resetAt)
    }

    /// The cycle in progress at `now` as known at `now`
    /// (`snapshot/cycles.MeterIndex.cycle_at`): the newest reading known then
    /// (by event time; on a tie the later-known copy), when it is active, its
    /// reset is still ahead and it is not from the future.
    public static func cycleAt(_ readings: [ArenaReading], now: Millis)
        -> (resetAt: Millis, utilPct: Double?, tEvent: Millis)? {
        var latest: ArenaReading?
        for r in readings where r.tKnown <= now {
            if let l = latest, r.tEvent < l.tEvent || (r.tEvent == l.tEvent && r.tKnown < l.tKnown) { continue }
            latest = r
        }
        guard let r = latest, r.active, let reset = r.resetsAt, reset > now, r.tEvent <= now else { return nil }
        return (reset, r.utilPct, r.tEvent)
    }

    /// The runner's meter grid (`episodes.grid_for`): the dense head, then
    /// every step from `now + step`, everything before the reset, and the
    /// reset itself. Nil when the reset is not ahead.
    public static func grid(target: ArenaTarget, now: Millis, resetAt: Millis) -> [Millis]? {
        guard resetAt > now else { return nil }
        var g = target.gridHead.map { now + $0 }
        var t = now + target.gridStep
        while t < resetAt { g.append(t); t += target.gridStep }
        g = g.filter { $0 < resetAt }
        g.append(resetAt)
        return g
    }

    /// A per-(model, now) seed, so a model's draws do not depend on what ran
    /// before it. Not the arena's (`derive_seed` is SHA-256 of JSON, and the
    /// streams differ anyway): Monte-Carlo ports match within bounds only.
    static func deriveSeed(_ base: UInt64, _ name: String, _ now: Millis) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ base
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h ^ UInt64(bitPattern: now) &* 0x9e37_79b9_7f4a_7c15
    }

    static func memoKey(_ name: String, history: ArenaHistory, request: ArenaRequest) -> String {
        var hasher = Hasher()
        for t in request.targets { hasher.combine(t.key); hasher.combine(t.grid); hasher.combine(t.resetAt) }
        return "\(name)|\(request.now)|\(history.historyStart)|\(history.accounts.joined(separator: "+"))|\(hasher.finalize())"
    }
}

// MARK: - Config

/// A `model.toml` value.
public indirect enum ArenaValue: Sendable, Equatable {
    case int(Int), double(Double), string(String), bool(Bool), array([ArenaValue]), table([String: ArenaValue])

    public var double: Double? {
        switch self { case .double(let d): d; case .int(let i): Double(i); default: nil }
    }
    public var int: Int? {
        switch self { case .int(let i): i; case .double(let d) where d == d.rounded(): Int(d); default: nil }
    }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [ArenaValue]? { if case .array(let a) = self { a } else { nil } }
    public var table: ArenaConfig? { if case .table(let t) = self { ArenaConfig(t) } else { nil } }
}

extension ArenaValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(integerLiteral v: Int) { self = .int(v) }
    public init(floatLiteral v: Double) { self = .double(v) }
    public init(stringLiteral v: String) { self = .string(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral xs: ArenaValue...) { self = .array(xs) }
    public init(dictionaryLiteral kv: (String, ArenaValue)...) {
        self = .table(Dictionary(kv, uniquingKeysWith: { _, b in b }))
    }
}

/// `model.toml` `[config]`, transcribed into the model's spec as a literal.
public struct ArenaConfig: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public var values: [String: ArenaValue]
    public init(_ values: [String: ArenaValue]) { self.values = values }
    public init(dictionaryLiteral kv: (String, ArenaValue)...) {
        values = Dictionary(kv, uniquingKeysWith: { _, b in b })
    }
    public subscript(_ key: String) -> ArenaValue? { values[key] }
    public func double(_ key: String, _ fallback: Double) -> Double { values[key]?.double ?? fallback }
    public func int(_ key: String, _ fallback: Int) -> Int { values[key]?.int ?? fallback }
    public func string(_ key: String, _ fallback: String) -> String { values[key]?.string ?? fallback }
    public func bool(_ key: String, _ fallback: Bool) -> Bool { values[key]?.bool ?? fallback }
    public func doubles(_ key: String, _ fallback: [Double]) -> [Double] {
        values[key]?.array?.compactMap(\.double) ?? fallback
    }
    /// A nested table (`[config.meter.five_hour]` → `table("meter").table("five_hour")`).
    public func table(_ key: String) -> ArenaConfig { values[key]?.table ?? [:] }
}

// MARK: - Random numbers and small numerics

/// A seeded generator (xoshiro256**). Not numpy's PCG64: Monte-Carlo ports
/// match the arena within bounds, never draw for draw.
public struct ArenaRNG: RandomNumberGenerator, Sendable {
    private var s: (UInt64, UInt64, UInt64, UInt64)
    public init(seed: UInt64) {
        var x = seed
        func splitmix() -> UInt64 {
            x &+= 0x9e37_79b9_7f4a_7c15
            var z = x
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
        s = (splitmix(), splitmix(), splitmix(), splitmix())
    }
    public mutating func next() -> UInt64 {
        let result = ((s.1 &* 5) << 7 | (s.1 &* 5) >> 57) &* 9
        let t = s.1 << 17
        s.2 ^= s.0; s.3 ^= s.1; s.1 ^= s.2; s.0 ^= s.3; s.2 ^= t
        s.3 = (s.3 << 45) | (s.3 >> 19)
        return result
    }
    /// Uniform on [0, 1).
    public mutating func uniform() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    /// Standard normal (Box–Muller).
    public mutating func normal() -> Double {
        let u1 = max(uniform(), .leastNonzeroMagnitude)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * uniform())
    }
}

public enum ArenaMath {
    /// numpy's default quantile (linear, type 7) of an ascending array.
    public static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let h = Double(sorted.count - 1) * min(max(q, 0), 1)
        let lo = Int(h.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (h - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    /// `np.interp`: linear in increasing `xs`, held flat beyond either end.
    public static func interp(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        guard let first = xs.first, let last = xs.last else { return .nan }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if xs[mid] <= x { lo = mid } else { hi = mid } }
        let span = xs[hi] - xs[lo]
        return span == 0 ? ys[lo] : ys[lo] + (x - xs[lo]) / span * (ys[hi] - ys[lo])
    }
}

// MARK: - Registry

/// Every ported model. Each family of ports registers in its own file (an
/// `extension ArenaRegistry` with one static array), so two ports never edit
/// the same line; this list only concatenates them.
public enum ArenaRegistry {
    public static var all: [ArenaModelSpec] {
        portModels + spendModels + fmModels + analogModels + simulationModels + combinedModels
            + ensembleModels + mlModels + timesfmModels + chronosModels
    }

    public static func spec(_ name: String) -> ArenaModelSpec? { all.first { $0.name == name } }
}
