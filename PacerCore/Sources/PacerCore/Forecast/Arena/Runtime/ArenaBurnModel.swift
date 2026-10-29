import Foundation

/// Where the runtime cuts an arena history: `now` floored to a five-minute
/// boundary, in backtest cuts and live alike. A spend bucket's row is known
/// only at its last turn (`ArenaHistoryBuilder.spendRows`), so a cut inside a
/// bucket would hide up to five minutes of the latest activity and could flip
/// a model's active/idle read; at a boundary every bucket before it is whole,
/// which is what the per-turn arena saw (the simulation port found no
/// difference over 53 aligned cuts). Flooring sees less, so it cannot leak.
public enum ArenaCut {
    public static let step: Millis = ArenaHistoryBuilder.spendBucketMillis
    public static func millis(_ date: Date) -> Millis {
        ArenaHistoryBuilder.floorDiv(ArenaTime.millis(date), step) * step
    }
}

/// An arena forecast as the engine draws it: the median path on the request's
/// grid, linear in between, held at the first grid value before it and at the
/// last after it.
public struct ArenaProjection: Sendable, Equatable {
    public let grid: [Millis]
    public let median: [Double]

    public init?(grid: [Millis], median: [Double]) {
        guard !grid.isEmpty, grid.count == median.count, median.allSatisfy(\.isFinite) else { return nil }
        self.grid = grid; self.median = median
    }

    public func value(at date: Date) -> Double {
        let t = ArenaTime.millis(date)
        if t <= grid[0] { return median[0] }
        if t >= grid[grid.count - 1] { return median[median.count - 1] }
        var lo = 0, hi = grid.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if grid[mid] <= t { lo = mid } else { hi = mid } }
        let span = Double(grid[hi] - grid[lo])
        return span == 0 ? median[lo] : median[lo] + Double(t - grid[lo]) / span * (median[hi] - median[lo])
    }

    public var closure: @Sendable (Date) -> Double { { [self] in value(at: $0) } }
}

extension ArenaRunner {
    /// One arena model's median path for `binding`'s meter at `history.now`,
    /// for the cycle resetting at `resetAt`, on the runner's grid. Throws what
    /// the model throws (too little history, weights not here, cancelled).
    ///
    /// The history is the caller's cut: one `ArenaHistory` per instant, shared
    /// by every model asked at it, so the memo a cut carries is filled once.
    public func projection(model name: String, binding: ArenaWindowBinding, history: ArenaHistory,
                           resetAt: Millis) throws -> ArenaProjection {
        guard let grid = ArenaRunner.grid(target: binding.target, now: history.now, resetAt: resetAt) else {
            throw ArenaError.invalid("reset \(resetAt) is not after now \(history.now)")
        }
        let tr = ArenaTargetRequest(key: binding.target.key(account: binding.account, cap: binding.cap),
                                    target: binding.target, accounts: [binding.account], grid: grid,
                                    nPaths: nPaths, cap: binding.cap, resetAt: resetAt)
        let fc = try forecast(model: name, history: history,
                              request: ArenaRequest(now: history.now, accounts: [binding.account], targets: [tr]))
        guard let target = fc.byKey[tr.key],
              let p = ArenaProjection(grid: grid, median: target.median) else {
            throw ArenaError.invalid("\(name) gave no forecast for \(tr.key)")
        }
        return p
    }
}

/// A registered arena model as a `BurnTrajectory.Model`: what the engine's
/// scoring and selection read every forecaster through.
///
/// `fit` cuts the history at the partial cycle's `now`, floored to five
/// minutes (`ArenaCut`; rows known later are not seen: this is how backtest
/// cuts stay honest), asks the model for that
/// cycle's meter on the runner's grid and returns its median path. Any error
/// is a decline (nil), as a curve fit declines a cycle it can't fit.
///
/// Arena models are slow next to the curve fits, so the engine never calls
/// this on its actor: the background scorer does (`ArenaRecordScorer`) and the
/// live roster holds `ArenaCachedBurnModel`s instead.
public struct ArenaBurnModel: BurnTrajectory.Model {
    public let spec: ArenaModelSpec
    public let binding: ArenaWindowBinding
    public let store: ArenaHistoryStore
    public let registry: [ArenaModelSpec]
    public let services: ArenaServices

    public init(spec: ArenaModelSpec, binding: ArenaWindowBinding, store: ArenaHistoryStore,
                registry: [ArenaModelSpec], services: ArenaServices = ArenaServices()) {
        self.spec = spec; self.binding = binding; self.store = store
        self.registry = registry; self.services = services
    }

    public var id: String { spec.name }
    public var complexity: Int { spec.complexity }

    public func fit(_ cycle: BurnTrajectory.PartialCycle) -> (@Sendable (Date) -> Double)? {
        let cut = ArenaHistory(store: store, now: ArenaCut.millis(cycle.now), accounts: [binding.account])
        let runner = ArenaRunner(registry: registry, services: services)
        return (try? runner.projection(model: spec.name, binding: binding, history: cut,
                                       resetAt: ArenaTime.millis(cycle.resetsAt)))?.closure
    }
}

// MARK: - Live projections

/// What the live roster reads: each arena model's latest projection for each
/// window, computed off the engine actor (`ArenaLiveForecaster`). Thread-safe;
/// the engine reads it synchronously inside `fit`.
public final class ArenaLiveCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public let account: String
        public let windowKey: String
        public let model: String
    }

    public struct Entry: Sendable {
        /// The cycle's reset the projection is for.
        public let resetsAt: Date
        /// The history cut it was made at.
        public let asOf: Date
        public let projection: ArenaProjection
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// Keys asked for that could not be answered, and why (for the sheet).
    private var failures: [Key: String] = [:]

    public init() {}

    public func store(_ entry: Entry, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = entry
        failures[key] = nil
    }

    public func fail(_ key: Key, reason: String) {
        lock.lock(); defer { lock.unlock() }
        failures[key] = reason
    }

    public func entry(_ key: Key) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    public func failure(_ key: Key) -> String? {
        lock.lock(); defer { lock.unlock() }
        return failures[key]
    }

    /// How stale a projection may be and still be drawn: a few polls on a
    /// five-hour window, a couple of hours on a weekly one. The engine
    /// anchors it to the live value either way; older than this the model
    /// simply has no line until the next one lands.
    public static func maxAge(duration: TimeInterval) -> TimeInterval {
        WindowSpec.isWeeklyScale(duration: duration) ? 2 * 3600 : 15 * 60
    }

    /// The projection for `cycle`, when one was made for this cycle recently
    /// enough. A past cut (a backtest, a calibrator walk) belongs to another
    /// cycle or is far older, and gets nothing.
    public func projection(_ key: Key, cycle: BurnTrajectory.PartialCycle) -> ArenaProjection? {
        guard let e = entry(key) else { return nil }
        let duration = cycle.resetsAt.timeIntervalSince(cycle.cycleStart)
        guard duration > 0,
              RateLimitCycle.contains(sampleReset: e.resetsAt, resets: cycle.resetsAt, duration: duration),
              abs(cycle.now.timeIntervalSince(e.asOf)) <= Self.maxAge(duration: duration)
        else { return nil }
        return e.projection
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); failures.removeAll()
    }
}

/// An arena model in the engine's live roster: answers from `ArenaLiveCache`
/// and declines on a miss, so the engine's stand-in rule shows the
/// best-recorded model that can fit until the projection lands. Never runs
/// the model itself: a refit or an ask must not wait on it.
public struct ArenaCachedBurnModel: BurnTrajectory.Model {
    public let id: String
    public let complexity: Int
    public let binding: ArenaWindowBinding
    public let cache: ArenaLiveCache

    public init(spec: ArenaModelSpec, binding: ArenaWindowBinding, cache: ArenaLiveCache) {
        self.id = spec.name; self.complexity = spec.complexity; self.binding = binding; self.cache = cache
    }

    public var key: ArenaLiveCache.Key {
        .init(account: binding.account, windowKey: binding.windowKey, model: id)
    }

    public func fit(_ cycle: BurnTrajectory.PartialCycle) -> (@Sendable (Date) -> Double)? {
        cache.projection(key, cycle: cycle)?.closure
    }
}
