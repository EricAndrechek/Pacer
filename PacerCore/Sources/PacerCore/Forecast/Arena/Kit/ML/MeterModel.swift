import Foundation

// `research/arena/kit/ml/meter_model.py`, in Swift: the plumbing every
// learned meter model shares. As-of data (`KitMLData.AsOfData`), a model per
// window kind trained lazily on a walk-forward set from the history, a
// fallback when there is too little to learn from, and the answer on the
// request grid.
//
// A subclass implements `train(_:kind:)` and `predict(...)`, as the Python's
// `train(ts, kind)` and `predict(state, row, lead_X, fracs, grid_fracs,
// used, ...)`. The Python draws comonotone paths from the quantiles it
// predicts (`rise_paths`); the port answers with those quantiles
// (`KitMLPaths.riseForecast`), the distribution the draws sample.
//
// When training happens (`train_align_h`, a Swift-only setting):
// - 0: at the cut itself, memoized on that cut (`history.memo`), so several
//   asks on one cut train once. What the Python does per episode, and what
//   the parity tests run.
// - h > 0 (the registered model, h = `retrain_h`): at the start of the
//   cut's h-hour bucket, `b = ⌊t / h⌋·h`, on `history.asOf(b)`, memoized on
//   the store (`history.store.memo`) for every cut in that bucket. That is
//   the Python's `update` rule (a model fitted at a cutoff keeps
//   forecasting from fresh features until `retrain_h` of new data have
//   arrived) made a function of the cut alone, so the app's backfill (eight
//   cuts of every past cycle) trains once per bucket instead of once per
//   cut, and it cannot leak: `b <= t`, and the training sees only what was
//   known at `b`. The seed is the bucket's (`bucketSeed`), so the model does
//   not depend on which cut asked first. The store keeps the most recent
//   `train_cache_buckets` buckets per meter (`KitMLStateCache`).

public enum KitMLMeterModel {
    /// Where the model reads its rise distribution at forecast time.
    public static let anchors: [Double] = [0.01, 0.03, 0.06, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    public static let fallbackLevels: [Double] = [0.05, 0.15, 0.3, 0.5, 0.7, 0.85, 0.95]

    /// `fallback_quantiles`: no model. The average of the cycle's burn so
    /// far and the recent burn (readings, or converted spend when higher)
    /// carried to each lead, with a wide spread. `[levels][fracs]`.
    public static func fallbackQuantiles(_ row: [Double], _ fracs: [Double],
                                         levels: [Double] = fallbackLevels) -> [[Double]] {
        typealias F = KitMLFeatures.F
        let remH = row[F.remainingH]
        let recent = KitMLFeatures.pmax(row[F.rate0 + 1], row[F.convRate1])
        let rate = 0.5 * (row[F.rateCycle] + recent)
        let leadH = fracs.map { $0 * remH }
        let med = leadH.map { rate * $0 }
        return levels.map { lv in
            let z = KitDetQ.ndtri(lv)
            return fracs.indices.map { j in
                med[j] * exp(0.8 * z) + max(z, 0) * (0.5 * leadH[j].squareRoot() + 0.3 * med[j])
            }
        }
    }
}

/// `LearnedMeterModel`. Config keys (all optional): `max_rows`, `min_rows`,
/// `min_cycles`, `retrain_h`, `step_min` and `max_days` (`{kind: value}`).
open class KitMLLearnedMeterModel: ArenaModel {
    open class var modelName: String { "learned" }
    public let ctx: ArenaContext
    public let cfg: ArenaConfig
    public private(set) var data: KitMLData.AsOfData?
    public private(set) var history: ArenaHistory?
    var historyStart: Millis?
    struct StateKey: Hashable { var kind: String; var cap: String?; var bucket: Millis? = nil }
    /// (trained at, state); state nil: the fallback.
    var states: [StateKey: (Millis, Any?)] = [:]
    /// The seed the current training draws from (`random_state`): the
    /// context's at the cut, the bucket's when aligned.
    public internal(set) var trainingSeed: UInt64
    var builders: [String: KitMLFeatures.FeatureBuilder] = [:]

    public required init(context: ArenaContext) throws {
        ctx = context
        cfg = context.config
        trainingSeed = context.seed
    }

    // contract ------------------------------------------------------------
    open func fit(_ history: ArenaHistory) throws {
        self.history = history
        data = KitMLData.AsOfData.of(history)
        historyStart = history.start
        states = [:]
        builders = [:]
    }

    open func update(_ history: ArenaHistory) throws {
        self.history = history
        data = KitMLData.AsOfData.of(history)
        builders = [:]          // caches are as-of buckets; rebuild over the new data
        let limit = cfg.double("retrain_h", 24) * Double(KitMLData.hourMs)
        states = states.filter { Double(history.now - $0.value.0) <= limit }
    }

    open func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets {
            try ctx.checkCancelled()
            out[tr.key] = try meter(request.now, tr, kind: tr.target.windowKind)
        }
        return ArenaForecast(byKey: out)
    }

    // internals -----------------------------------------------------------
    public func builder(_ kind: String) -> KitMLFeatures.FeatureBuilder {
        if let b = builders[kind] { return b }
        let b = KitMLFeatures.FeatureBuilder(data: data!, kind: kind)
        builders[kind] = b
        return b
    }

    func meter(_ now: Millis, _ tr: ArenaTargetRequest, kind: String) throws -> ArenaTargetForecast {
        guard let data else { throw ArenaError.invalid("\(Self.modelName): forecast before fit") }
        let acct = tr.accounts[0]
        let cap = kind == "weekly_scoped" ? tr.cap : nil
        let series = data.meter(acct, kind, cap)
        guard let series, let st = series.stateAt(now, reset: tr.resetAt) else {
            // Nothing known of this cycle: a flat path at the latest level.
            let lvl = series?.levelAt(now).util ?? 0
            return .point([Double](repeating: lvl, count: tr.grid.count))
        }
        let reset = tr.resetAt ?? st.reset
        let b = builder(kind)
        let row = b.row(series, now, reset: reset, st: st)!
        let g = KitMLPaths.gridFracs(tr.grid, now: now, reset: reset)
        let anchors = KitMLMeterModel.anchors
        guard let state = try state(kind, cap) else {
            return KitMLPaths.riseForecast(levels: KitMLMeterModel.fallbackLevels,
                                           q: KitMLMeterModel.fallbackQuantiles(row, anchors), anchorFracs: anchors,
                                           gridFracs: g, used: st.used)
        }
        let leadX = b.leadRows(row, series, now, reset: reset, fracs: anchors)
        return predict(state, row: row, leadX: leadX, fracs: anchors, gridFracs: g, used: st.used)
    }

    /// `train_align_h` for a kind, in ms (a number, or `{kind: hours}`); 0:
    /// train at the cut.
    func alignMs(_ kind: String) -> Millis {
        let h = cfgKind("train_align_h", kind, unit: KitMLData.hourMs)
            ?? Millis(cfg.double("train_align_h", 0) * Double(KitMLData.hourMs))
        return max(h, 0)
    }

    /// The trained state for a kind (and cap): the instance's, else the
    /// memo's (the cut's, or the store's for the cut's bucket), else trained
    /// now (nil: too little to learn from).
    func state(_ kind: String, _ cap: String?) throws -> Any? {
        guard let data, let history else { throw ArenaError.invalid("\(Self.modelName): state before fit") }
        let align = alignMs(kind)
        if align > 0 {
            let b = KitMLData.floorDiv(data.now, align) * align
            let key = StateKey(kind: kind, cap: cap, bucket: b)
            if let s = states[key] { return s.1 }
            let cache = KitMLStateCache.of(history.store, capacity: max(cfg.int("train_cache_buckets", 8), 1))
            let meter = "\(Self.modelName)|\(configSalt)|\(history.accounts.joined(separator: "+"))|"
                + "\(historyStart.map(String.init) ?? "-")|\(kind)|\(cap ?? "")"
            let state = try cache.value(meter, bucket: b) {
                // Leak-free by construction: the training sees the history as
                // known at the bucket's start, never the cut's later rows.
                let hb = history.asOf(b)
                let saved = trainingSeed
                trainingSeed = Self.bucketSeed(Self.modelName, b)
                defer { trainingSeed = saved }
                let db = KitMLData.AsOfData.of(hb)
                return try trainState(data: db, builder: KitMLFeatures.FeatureBuilder(data: db, kind: kind),
                                      kind: kind, cap: cap)
            }
            states[key] = (b, state)
            return state
        }
        let key = StateKey(kind: kind, cap: cap)
        if let s = states[key] { return s.1 }
        let memoKey = "kitml.state|\(Self.modelName)|\(memoSalt)|\(kind)|\(cap ?? "")|\(historyStart.map(String.init) ?? "-")"
        let boxed: KitBox<Any?> = try history.memo.value(memoKey) {
            KitBox(try self.trainState(data: data, builder: builder(kind), kind: kind, cap: cap))
        }
        states[key] = (data.now, boxed.value)
        return boxed.value
    }

    /// What distinguishes two trainings on one cut: the seed and the config.
    var memoSalt: String { "\(ctx.seed)|\(configSalt)" }

    var configSalt: String {
        cfg.values.keys.sorted().map { "\($0)=\(cfg.values[$0]!)" }.joined(separator: ";")
    }

    /// A bucket's seed: FNV-1a of "model|bucket start", the same whichever
    /// cut trains it.
    static func bucketSeed(_ name: String, _ b: Millis) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for c in "\(name)|\(b)".utf8 { h = (h ^ UInt64(c)) &* 0x0000_0100_0000_01B3 }
        return h
    }

    func trainState(data: KitMLData.AsOfData, builder: KitMLFeatures.FeatureBuilder, kind: String,
                    cap: String?) throws -> Any? {
        let t0 = Date()
        let ts = try KitMLWalkforward.buildTrainset(
            data, builder, kind: kind, cap: cap, now: data.now, start: historyStart,
            step: cfgKind("step_min", kind, unit: KitMLData.minMs), maxDays: cfgKind("max_days", kind, unit: 1),
            maxRows: cfg.int("max_rows", 4000), checkCancelled: { try ctx.checkCancelled() })
        let nCyc = ts.count > 0 ? (ts.cycle.max() ?? -1) + 1 : 0
        let enough = ts.count >= cfg.int("min_rows", 60) && nCyc >= cfg.int("min_cycles", 4)
        let state = enough ? try train(ts, kind: kind) : nil
        ctx.log(String(format: "%@ %@%@: %d rows, %d cycles, %@ in %.2fs (data to %lld)", Self.modelName, kind,
                       cap.map { ":" + $0 } ?? "", ts.count, nCyc, state != nil ? "trained" : "fallback",
                       Date().timeIntervalSince(t0), data.now))
        return state
    }

    /// `_cfg_kind`: a per-kind setting (`{kind: value}`) times `unit`.
    func cfgKind(_ name: String, _ kind: String, unit: Millis) -> Millis? {
        guard let v = cfg.table(name).values[kind]?.double else { return nil }
        return Millis(v * Double(unit))
    }

    // subclass API --------------------------------------------------------
    open func train(_ ts: KitMLWalkforward.TrainSet, kind: String) throws -> Any {
        fatalError("subclass")
    }

    open func predict(_ state: Any, row: [Double], leadX: [[Double]], fracs: [Double], gridFracs: [Double],
                      used: Double) -> ArenaTargetForecast {
        fatalError("subclass")
    }
}

/// The store's trained states, by meter and bucket, the most recent
/// `capacity` buckets per meter (least recently used out). Lives in
/// `ArenaHistoryStore.memo` under one key, which has no eviction of its own.
final class KitMLStateCache: @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var entries: [String: [(bucket: Millis, state: KitBox<Any?>, used: Int)]] = [:]
    private var tick = 0

    init(capacity: Int) { self.capacity = capacity }

    static func of(_ store: ArenaHistoryStore, capacity: Int) -> KitMLStateCache {
        store.memo.value("kitml.statecache|\(capacity)") { KitMLStateCache(capacity: capacity) }
    }

    /// The meter's state for `bucket`, trained by `make` (outside the lock:
    /// another meter's training never waits on it) when not held.
    func value(_ meter: String, bucket: Millis, _ make: () throws -> Any?) rethrows -> Any? {
        if let hit = lookup(meter, bucket) { return hit.value }
        let v = try make()
        lock.lock(); defer { lock.unlock() }
        tick += 1
        var list = entries[meter] ?? []
        if let i = list.firstIndex(where: { $0.bucket == bucket }) {      // raced: the first stored wins
            list[i].used = tick
            entries[meter] = list
            return list[i].state.value
        }
        list.append((bucket, KitBox(v), tick))
        while list.count > capacity {
            let oldest = list.indices.min { list[$0].used < list[$1].used }!
            list.remove(at: oldest)
        }
        entries[meter] = list
        return v
    }

    private func lookup(_ meter: String, _ bucket: Millis) -> KitBox<Any?>? {
        lock.lock(); defer { lock.unlock() }
        guard var list = entries[meter], let i = list.firstIndex(where: { $0.bucket == bucket }) else { return nil }
        tick += 1
        list[i].used = tick
        entries[meter] = list
        return list[i].state
    }

    /// The buckets held for a meter, oldest first (tests).
    func buckets(_ meter: String) -> [Millis] {
        lock.lock(); defer { lock.unlock() }
        return (entries[meter] ?? []).map(\.bucket).sorted()
    }

    var meters: [String] { lock.lock(); defer { lock.unlock() }; return entries.keys.sorted() }
}
