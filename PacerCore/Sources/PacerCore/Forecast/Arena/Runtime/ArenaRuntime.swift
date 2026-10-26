import Foundation
import SwiftData

// The arena models running for real: scored over every user's own history in
// the background, picked by the engine's self-evaluation where they beat its
// curve fits, and drawn live from projections made off the engine actor.
//
// Three parts, none of which runs on the engine actor (a refit already takes
// seconds, and every ask queues behind it):
//
// - `ArenaRecordScorer` back-computes each arena model over the account's
//   completed cycles, at the engine's cuts and graded by the value the app
//   shows (`displayedAtReset`), into the same `EngineEvalOutcome` rows the
//   engine's own methods are scored into. Newest cycles first, at a fraction
//   of one core, resumable: it skips every key already stored.
// - `ArenaLiveForecaster` makes the live projections the engine can draw
//   (the pick, and the few the compare sheet lists), into `ArenaLiveCache`.
// - `ArenaRuntime` holds both, the shared history and the engine's view of
//   it (`ArenaEngineLink`).

/// What an engine needs from the runtime. A value: the engine reads the
/// roster and cache synchronously and never awaits the runtime.
public struct ArenaEngineLink: Sendable {
    public let roster: ArenaRoster
    public let cache: ArenaLiveCache
    /// How many arena models a window's compare sheet lists beyond the pick,
    /// best record first. Each one listed is a live projection per refit.
    public let compareLimit: Int
    /// Ask for live projections. Returns at once; they land in `cache`.
    public let requestLive: @Sendable ([ArenaLiveRequest]) -> Void

    public init(roster: ArenaRoster, cache: ArenaLiveCache, compareLimit: Int = 3,
                requestLive: @escaping @Sendable ([ArenaLiveRequest]) -> Void) {
        self.roster = roster; self.cache = cache; self.compareLimit = compareLimit; self.requestLive = requestLive
    }
}

/// One window's live projections to make.
public struct ArenaLiveRequest: Sendable, Hashable {
    public let binding: ArenaWindowBinding
    public let resetsAt: Date
    /// The newest reading the engine fitted on: a projection made after it
    /// is current.
    public let latestReadingAt: Date
    public let models: [String]

    public init(binding: ArenaWindowBinding, resetsAt: Date, latestReadingAt: Date, models: [String]) {
        self.binding = binding; self.resetsAt = resetsAt; self.latestReadingAt = latestReadingAt; self.models = models
    }
}

/// A flag checked between models and inside them (`ArenaServices.isCancelled`).
final class ArenaCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// Models log through the runner; during a backfill one model asked
/// thousands of times would say the same thing thousands of times. Each
/// distinct line is written once per process.
final class ArenaLogGate: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<String>()
    func write(_ model: String, _ message: String) {
        let line = "\(model): \(message)"
        lock.lock()
        let first = seen.count < 500 && seen.insert(line).inserted
        lock.unlock()
        if first { Log.write("Arena", line) }
    }
}

// MARK: - The record scorer

/// Scores arena models over completed cycles into the engine's record, in the
/// background. See the file header.
public actor ArenaRecordScorer {

    public struct Config: Sendable {
        /// Share of one core the scorer may use, averaged: it sleeps after
        /// each cut for `busy × (1 − duty) / duty`.
        public var dutyCycle: Double = 0.25
        /// The longest single sleep, so a slow cut can't stall the queue.
        public var maxSleep: TimeInterval = 30
        /// The most completed cycles scored per window, newest first:
        /// selection compares models over the cycles every one of them was
        /// scored on (`EngineSelfEval.arenaComparable`), so depth past a few
        /// months buys little and costs first-launch time.
        public var sessionCycleCap = 180
        public var weeklyCycleCap = 18
        /// Between passes: one pass scores whatever completed since.
        public var rescanInterval: TimeInterval = 15 * 60
        /// What an incremental pass reads, as the engine's refit does.
        public var incrementalDays = 32
        public var cuts = EngineSelfEval.rlCutFractions
        /// Child forecasts a window's runner keeps (`ArenaRunner.memoLimit`).
        /// A parent's backtests at successive cuts of a cycle mostly repeat
        /// (their times are aligned to the history's start), so the memo is
        /// what makes ensembles affordable. Bounded by memory: a Monte-Carlo
        /// child keeps 200 paths over its grid, ~100 KB on a five-hour grid
        /// and ~550 KB on a weekly one, so the worst case is about 50 MB and
        /// 100 MB per window being scored.
        public var sessionMemoLimit = 512
        public var weeklyMemoLimit = 192
        /// Cycles a window scores before the next window's turn.
        public var sessionCyclesPerTurn = 4
        public var weeklyCyclesPerTurn = 2
        public init() {}
    }

    public struct Report: Sendable, Equatable {
        public var cycles = 0
        public var outcomes = 0
        public var forecasts = 0
        public var declined = 0
        public var busySeconds = 0.0
        public init() {}
    }

    private let container: ModelContainer
    private let roster: ArenaRoster
    private let history: ArenaHistoryCache
    private let services: ArenaServices
    private let cancel: ArenaCancelFlag
    private let config: Config
    private let calendar: Calendar
    private let landed: @Sendable (_ account: String, _ outcomes: [EngineSelfEval.NewOutcome]) async -> Void
    /// (surface, model, cut, period) keys a model declined this process, so a
    /// pass doesn't ask again every fifteen minutes. Relaunch retries them.
    private var declined = Set<String>()
    private var loop: Task<Void, Never>?
    /// The accounts the last full pass covered, with the roster it scored.
    private var coveredFingerprint: [String: String] = [:]

    init(container: ModelContainer, roster: ArenaRoster, history: ArenaHistoryCache, services: ArenaServices,
         cancel: ArenaCancelFlag, config: Config = Config(), calendar: Calendar = .current,
         landed: @escaping @Sendable (String, [EngineSelfEval.NewOutcome]) async -> Void) {
        self.container = container; self.roster = roster; self.history = history; self.services = services
        self.cancel = cancel; self.config = config; self.calendar = calendar; self.landed = landed
    }

    /// What a full pass is for: the scored models and how deep. A change runs
    /// a full pass again; otherwise passes read only the recent weeks.
    var fingerprint: String {
        "v1|\(EngineSelfEval.rlBucketVersion)|\(config.sessionCycleCap)/\(config.weeklyCycleCap)|"
            + roster.selectable.map(\.name).sorted().joined(separator: ",")
    }

    // MARK: Loop

    /// Score now, then every `rescanInterval`, until `stop()`.
    func start(accounts: @escaping @Sendable () async -> [String]) {
        guard loop == nil, !roster.isEmpty, !cancel.isSet else { return }
        loop = Task.detached(priority: .background) { [weak self] in
            while let self, !Task.isCancelled {
                let ids = await accounts()
                await self.pass(accounts: ids)
                if await self.isCancelled { return }
                try? await Task.sleep(for: .seconds(self.config.rescanInterval))
            }
        }
    }

    func stop() async {
        cancel.set(true)
        loop?.cancel()
        await loop?.value
        loop = nil
    }

    var isCancelled: Bool { cancel.isSet }

    // MARK: Pass

    private struct Stream {
        let account: String
        let window: WindowSpec
        let binding: ArenaWindowBinding
        /// The models still being scored deeper: losers drop out
        /// (`EngineSelfEval.arenaLosers`).
        var models: [ArenaModelSpec]
        /// This window's record over the cycles the pass may score, every
        /// method, kept current as the pass adds to it: what judges losers.
        var records: [EngineSelfEval.Record]
        let store: ArenaHistoryStore
        let surface: String
        /// Live only during the stream's turn (`pass`), so one window's memo
        /// is held at a time.
        var runner: ArenaRunner?
        var queue: [BurnTrajectory.Cycle]       // newest first
        var existing: Set<String>
    }

    /// One pass over `accounts`: a full one (120 days, the first time an
    /// account is seen with this roster) or an incremental one (the recent
    /// weeks). Returns what it did.
    @discardableResult
    public func pass(accounts: [String], now: Date = Date()) async -> Report {
        var report = Report()
        guard !roster.isEmpty, !cancel.isSet else { return report }
        let started = SuspendingClock.now
        var streams: [Stream] = []
        for account in accounts {
            guard !cancel.isSet else { return report }
            let full = coveredFingerprint[account] != fingerprint
            streams += await self.streams(account: account, now: now, full: full)
            coveredFingerprint[account] = fingerprint
        }
        let queued = streams.reduce(0) { $0 + $1.queue.count }
        guard queued > 0 else { return report }
        Log.write("Arena", "scoring \(queued) cycle(s) over \(streams.count) window(s), "
                  + "\(Set(streams.flatMap { $0.models.map(\.name) }).count) model(s), "
                  + String(format: "%.0f%% of a core", config.dutyCycle * 100))

        // Each window in turn, newest cycles first, a few cycles a turn, so
        // every window's selection has something to go on early. A turn's
        // cycles share one runner: a parent's backtests over neighbouring
        // cycles mostly repeat, and its memo answers them; dropping it at the
        // end of the turn keeps one window's memo in memory at a time.
        var lastLog = SuspendingClock.now
        while streams.contains(where: { !$0.queue.isEmpty }) {
            for i in streams.indices where !streams[i].queue.isEmpty {
                let weekly = streams[i].window.isWeeklyScale
                let runner = ArenaRunner(registry: roster.registry, services: services)
                runner.memoLimit = weekly ? config.weeklyMemoLimit : config.sessionMemoLimit
                streams[i].runner = runner
                defer { streams[i].runner = nil; prune(&streams[i]) }
                for _ in 0..<(weekly ? config.weeklyCyclesPerTurn : config.sessionCyclesPerTurn) {
                    guard !cancel.isSet else { return report }
                    guard !streams[i].queue.isEmpty else { break }
                    let cycle = streams[i].queue.removeFirst()
                    let news = await score(cycle, in: &streams[i], report: &report)
                    report.cycles += 1
                    if !news.isEmpty {
                        persist(news, surface: streams[i].surface)
                        report.outcomes += news.count
                        streams[i].records += news.map {
                            EngineSelfEval.Record(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey,
                                                  predicted: $0.predicted, truth: $0.truth)
                        }
                        await landed(streams[i].account, news)
                    }
                    if SuspendingClock.now - lastLog >= .seconds(120) {
                        lastLog = SuspendingClock.now
                        log(report, of: queued, since: started)
                    }
                }
            }
        }
        log(report, of: queued, since: started, done: true)
        MemoryHygiene.relieve()
        return report
    }

    private func log(_ r: Report, of total: Int, since started: SuspendingClock.Instant, done: Bool = false) {
        let awake = SuspendingClock.now - started
        Log.write("Arena", (done ? "scored " : "progress ") + "\(r.cycles)/\(total) cycle(s): +\(r.outcomes) outcome(s) "
                  + "from \(r.forecasts) forecast(s), \(r.declined) declined, "
                  + String(format: "busy %.0f s of %.0f s awake", r.busySeconds,
                           Double(awake.components.seconds)))
    }

    /// The windows of `account` there is something to score in.
    private func streams(account: String, now: Date, full: Bool) async -> [Stream] {
        let days = full ? ArenaHistoryBuilder.depthDays : config.incrementalDays
        let limits = ArenaHistoryBuilder.readLimits(
            container: container, account: account, since: now.addingTimeInterval(-Double(days) * 86400))
        guard limits.count > 0 else { return [] }
        let store: ArenaHistoryStore
        if full {
            // Months of turns, priced: the pass's one burst of reading. Paced
            // like a cut, so a first launch with several accounts doesn't
            // read them all back to back.
            let started = SuspendingClock.now
            let built = ArenaHistoryBuilder.build(container: container, account: account, now: now, limits: limits)
            await history.install(built, account: account)
            store = built.store
            let took = SuspendingClock.now - started
            await pace(Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18)
        } else {
            store = await history.store(account: account, now: now)
        }
        // The engine's own windows and cycles, from the same rows: what the
        // arena models are scored on is exactly what the curve fits are.
        let f = EngineFeatures.build(now: now, calendar: calendar, daily: [], hourly: [],
                                     rate: limits.rate, lastArrivalAt: nil, scoped: limits.scoped)
        var out: [Stream] = []
        for window in f.windows {
            guard let binding = ArenaWindowBinding.make(account: account, window: window),
                  let samples = f.rateLimit[window.key], !samples.isEmpty else { continue }
            let available = roster.specs(for: binding.target).filter { Self.weightsPresent($0, roster: roster, services: services) }
            guard !available.isEmpty else { continue }
            let (_, cycles) = BurnTrajectory.segment(samples: samples, duration: window.duration, now: now)
            let cap = window.isWeeklyScale ? config.weeklyCycleCap : config.sessionCycleCap
            let completed = cycles.filter { $0.resetsAt <= now }.sorted { $0.resetsAt > $1.resetsAt }.prefix(cap)
            let surface = EngineScope.account(account).qualify(EngineSelfEval.rlSurface(window.key))
            let stored = storedRecords(surface: surface,
                                       periods: completed.map { EngineSelfEval.periodKeyRL($0.resetsAt) })
            let existing = Set(stored.map {
                EngineEvalOutcome.makeKey(surface: surface, method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey)
            })
            let records = stored.filter { EngineSelfEval.isCurrentRLBucket($0.bucket) }
            let losers = EngineSelfEval.arenaLosers(records, arenaIds: Set(available.map(\.name)),
                                                    weekly: window.isWeeklyScale)
            if !losers.isEmpty {
                Log.write("Arena", "\(window.key) …\(account.suffix(4)): not scoring deeper (well behind the record): "
                          + losers.sorted().joined(separator: ", "))
            }
            let models = available.filter { !losers.contains($0.name) }
            guard !models.isEmpty else { continue }
            let wanted = models.count * config.cuts.count
            let queue = completed.filter { c in
                let period = EngineSelfEval.periodKeyRL(c.resetsAt)
                let have = config.cuts.reduce(0) { n, cf in
                    n + models.filter { existing.contains(Self.key(surface, $0.name, cf, period)) }.count
                }
                return have < wanted
            }
            guard !queue.isEmpty else { continue }
            out.append(Stream(account: account, window: window, binding: binding, models: models, records: records,
                              store: store, surface: surface, runner: nil, queue: Array(queue), existing: existing))
        }
        return out
    }

    /// Every cut of one completed cycle, every model still missing at it:
    /// cuts outer, models inner, one history cut shared by the models.
    private func score(_ cycle: BurnTrajectory.Cycle, in s: inout Stream, report: inout Report) async
        -> [EngineSelfEval.NewOutcome] {
        guard let truth = cycle.samples.map(\.usedPercentage).max(), truth > 0 else { return [] }
        let duration = cycle.resetsAt.timeIntervalSince(cycle.cycleStart)
        guard duration > 0 else { return [] }
        let period = EngineSelfEval.periodKeyRL(cycle.resetsAt)
        let baseSurface = EngineSelfEval.rlSurface(s.window.key)
        var out: [EngineSelfEval.NewOutcome] = []
        for cf in config.cuts {
            guard !cancel.isSet else { return out }
            let cutNow = cycle.cycleStart.addingTimeInterval(duration * cf)
            let seen = cycle.samples.filter { $0.at <= cutNow }
            // The engine's own rule (`newOutcomesRL`), so both are scored on
            // the same cuts.
            guard seen.count >= 3 else { continue }
            let missing = s.models.filter {
                let k = Self.key(s.surface, $0.name, cf, period)
                return !s.existing.contains(k) && !declined.contains(k)
            }
            guard !missing.isEmpty else { continue }
            let partial = BurnTrajectory.PartialCycle(samples: seen, now: cutNow, cycleStart: cycle.cycleStart,
                                                      resetsAt: cycle.resetsAt)
            let cut = ArenaHistory(store: s.store, now: ArenaTime.millis(cutNow), accounts: [s.account])
            let busyStart = SuspendingClock.now
            for spec in missing {
                let k = Self.key(s.surface, spec.name, cf, period)
                guard let runner = s.runner else { return out }
                report.forecasts += 1
                do {
                    let p = try runner.projection(model: spec.name, binding: s.binding, history: cut,
                                                    resetAt: ArenaTime.millis(cycle.resetsAt))
                    let shown = BurnTrajectory.displayedAtReset(p.closure, partial: partial)
                    guard shown.isFinite else { declined.insert(k); report.declined += 1; continue }
                    out.append(EngineSelfEval.NewOutcome(
                        surface: baseSurface, method: spec.name, bucket: EngineSelfEval.rlBucket(cf),
                        periodKey: period, predicted: shown, truth: truth))
                    s.existing.insert(k)
                } catch ArenaError.cancelled {
                    return out
                } catch {
                    declined.insert(k)
                    report.declined += 1
                }
            }
            let busy = SuspendingClock.now - busyStart
            let busySeconds = Double(busy.components.seconds) + Double(busy.components.attoseconds) * 1e-18
            report.busySeconds += busySeconds
            await pace(busySeconds)
        }
        return out
    }

    /// Sleep long enough that this cut's work averages out to the duty cycle.
    private func pace(_ busy: Double) async {
        let d = min(1, max(0.01, config.dutyCycle))
        let sleep = min(config.maxSleep, busy * (1 - d) / d)
        if sleep > 0.001 { try? await Task.sleep(for: .seconds(sleep)) } else { await Task.yield() }
    }

    static func key(_ surface: String, _ model: String, _ cut: Double, _ period: String) -> String {
        EngineEvalOutcome.makeKey(surface: surface, method: model, bucket: EngineSelfEval.rlBucket(cut), periodKey: period)
    }

    /// A window's stored rows for these cycles, every method: only the
    /// cycles a pass could score, so a pass every fifteen minutes doesn't
    /// load the whole record. Raw SQLite when the store is a file.
    private func storedRecords(surface: String, periods: [String]) -> [EngineSelfEval.Record] {
        guard !periods.isEmpty else { return [] }
        if let url = ArenaHistoryBuilder.storeURL(container),
           let rows = RawEvalReader.surfaceRows(storeURL: url, surface: surface, periods: periods) {
            return rows.map {
                .init(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey, predicted: $0.predicted, truth: $0.truth)
            }
        }
        let d = FetchDescriptor<EngineEvalOutcome>(
            predicate: #Predicate { $0.surface == surface && periods.contains($0.periodKey) })
        return ((try? ModelContext(container).fetch(d)) ?? []).map {
            .init(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey, predicted: $0.predicted, truth: $0.truth)
        }
    }

    /// Drop the stream's models that have fallen clearly behind.
    private func prune(_ s: inout Stream) {
        let losers = EngineSelfEval.arenaLosers(s.records, arenaIds: Set(s.models.map(\.name)),
                                                weekly: s.window.isWeeklyScale)
        guard !losers.isEmpty else { return }
        s.models.removeAll { losers.contains($0.name) }
        Log.write("Arena", "\(s.window.key) …\(s.account.suffix(4)): not scoring deeper (well behind the record): "
                  + losers.sorted().joined(separator: ", "))
        if s.models.isEmpty { s.queue.removeAll() }
    }

    private func persist(_ news: [EngineSelfEval.NewOutcome], surface: String) {
        let context = ModelContext(container)
        let now = Date()
        for n in news {
            context.insert(EngineEvalOutcome(surface: surface, method: n.method, bucket: n.bucket,
                                             periodKey: n.periodKey, predicted: n.predicted, truth: n.truth,
                                             recordedAt: now))
        }
        try? context.save()
    }

    /// Whether every pinned weight `spec` and its children need is on this
    /// Mac. A model missing one would only throw at every cut.
    static func weightsPresent(_ spec: ArenaModelSpec, roster: ArenaRoster, services: ArenaServices,
                               depth: Int = 0) -> Bool {
        guard depth < 8 else { return true }
        guard spec.weights.allSatisfy({ services.weights($0) != nil }) else { return false }
        return spec.children.allSatisfy { name in
            roster.spec(name).map { weightsPresent($0, roster: roster, services: services, depth: depth + 1) } ?? false
        }
    }
}

// MARK: - Live projections

/// Makes the live projections the engine draws, one request at a time, off
/// the engine actor. A request for a window whose projections already saw
/// its newest reading costs nothing.
public actor ArenaLiveForecaster {
    private let roster: ArenaRoster
    private let history: ArenaHistoryCache
    private let cache: ArenaLiveCache
    private let services: ArenaServices
    private let cancel: ArenaCancelFlag
    private let landed: @Sendable (Set<String>) async -> Void
    private var pending: [String: ArenaLiveRequest] = [:]
    private var draining = false
    /// Failures already logged, so a model that can't forecast a window
    /// says so once, not every refit.
    private var logged = Set<String>()

    init(roster: ArenaRoster, history: ArenaHistoryCache, cache: ArenaLiveCache, services: ArenaServices,
         cancel: ArenaCancelFlag, landed: @escaping @Sendable (Set<String>) async -> Void) {
        self.roster = roster; self.history = history; self.cache = cache; self.services = services
        self.cancel = cancel; self.landed = landed
    }

    /// Queue requests; the newest per window wins.
    public func submit(_ requests: [ArenaLiveRequest]) {
        for r in requests where !r.models.isEmpty {
            pending["\(r.binding.account)|\(r.binding.windowKey)"] = r
        }
        guard !draining, !pending.isEmpty else { return }
        draining = true
        Task.detached(priority: .utility) { [weak self] in await self?.drain() }
    }

    /// Wait until everything queued so far has been made (tests).
    public func settle() async {
        while draining || !pending.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func drain() async {
        while !pending.isEmpty, !cancel.isSet {
            let batch = Array(pending.values)
            pending.removeAll()
            var changed = Set<String>()
            for (account, requests) in Dictionary(grouping: batch, by: { $0.binding.account }) {
                let built = await history.built(account: account)
                let cut = ArenaHistory(store: built.store, now: ArenaTime.millis(built.builtThrough), accounts: [account])
                for r in requests where make(r, cut: cut, asOf: built.builtThrough) { changed.insert(account) }
            }
            if !changed.isEmpty { await landed(changed) }
        }
        draining = false
    }

    /// Returns whether anything new landed.
    private func make(_ r: ArenaLiveRequest, cut: ArenaHistory, asOf: Date) -> Bool {
        let runner = ArenaRunner(registry: roster.registry, services: services)
        let duration = TimeInterval(r.binding.target.windowMillis) / 1000
        var any = false
        for model in r.models {
            guard !cancel.isSet else { return any }
            let key = ArenaLiveCache.Key(account: r.binding.account, windowKey: r.binding.windowKey, model: model)
            if let e = cache.entry(key),
               RateLimitCycle.contains(sampleReset: e.resetsAt, resets: r.resetsAt, duration: duration),
               e.asOf >= r.latestReadingAt,
               asOf.timeIntervalSince(e.asOf) < ArenaLiveCache.maxAge(duration: duration) / 2 {
                continue
            }
            do {
                let p = try runner.projection(model: model, binding: r.binding, history: cut,
                                              resetAt: ArenaTime.millis(r.resetsAt))
                cache.store(.init(resetsAt: r.resetsAt, asOf: asOf, projection: p), for: key)
                any = true
            } catch ArenaError.weightsUnavailable {
                cache.fail(key, reason: "downloading")
            } catch ArenaError.cancelled {
                return any
            } catch {
                cache.fail(key, reason: "no forecast this cycle")
                if logged.insert("\(model)|\(r.binding.windowKey)").inserted {
                    Log.write("Arena", "live \(model) on \(r.binding.windowKey) …\(r.binding.account.suffix(4)): \(error)")
                }
            }
        }
        return any
    }
}

// MARK: - The runtime

/// The arena models in the app: one per process, made by
/// `AppBackgroundService` on the shared container.
public final class ArenaRuntime: Sendable {
    public let roster: ArenaRoster
    public let cache = ArenaLiveCache()
    public let history: ArenaHistoryCache
    public let scorer: ArenaRecordScorer
    public let live: ArenaLiveForecaster
    let cancel = ArenaCancelFlag()
    private let ensureWeights: @Sendable ([String]) async -> Void
    public let compareLimit: Int

    // MERGE (builder C, `Forecast/Arena/Kit/FM/`): the two wiring points for
    // pretrained weights. Replace the bodies with
    //   `ArenaWeightStore.localURL(for: id)` and
    //   `await ArenaWeightStore.ensureAvailable(ids)`.
    // Until then no model that pins weights runs (it is simply not
    // selectable), and nothing is downloaded.
    public static let defaultWeights: @Sendable (String) -> URL? = { _ in nil }
    public static let defaultEnsureWeights: @Sendable ([String]) async -> Void = { _ in }

    /// - Parameters:
    ///   - onRecordLanded: new outcomes for an account were saved; hand them
    ///     to its engine (`UsageIntelligenceEngine.ingestArenaOutcomes`).
    ///   - onLiveLanded: live projections for these accounts are in the
    ///     cache; have their engines draw them
    ///     (`UsageIntelligenceEngine.refreshArenaResolution`).
    public init(container: ModelContainer, roster: ArenaRoster = .standard,
                weights: @escaping @Sendable (String) -> URL? = ArenaRuntime.defaultWeights,
                ensureWeights: @escaping @Sendable ([String]) async -> Void = ArenaRuntime.defaultEnsureWeights,
                config: ArenaRecordScorer.Config = .init(), compareLimit: Int = 3,
                onRecordLanded: @escaping @Sendable (String, [EngineSelfEval.NewOutcome]) async -> Void,
                onLiveLanded: @escaping @Sendable (Set<String>) async -> Void) {
        self.roster = roster
        self.compareLimit = compareLimit
        self.ensureWeights = ensureWeights
        let history = ArenaHistoryCache(container: container)
        self.history = history
        let cancel = self.cancel
        let gate = ArenaLogGate()
        let services = ArenaServices(weights: weights, log: { gate.write($0, $1) }, isCancelled: { cancel.isSet })
        self.scorer = ArenaRecordScorer(container: container, roster: roster, history: history, services: services,
                                        cancel: cancel, config: config, landed: onRecordLanded)
        self.live = ArenaLiveForecaster(roster: roster, history: history, cache: cache, services: services,
                                        cancel: cancel, landed: onLiveLanded)
    }

    /// What every engine adopts.
    public var link: ArenaEngineLink {
        let live = self.live
        return ArenaEngineLink(roster: roster, cache: cache, compareLimit: compareLimit,
                               requestLive: { reqs in Task.detached(priority: .utility) { await live.submit(reqs) } })
    }

    /// Start scoring `accounts()` in the background, and fetch any pinned
    /// weights the roster needs (without waiting: models whose weights are
    /// missing are skipped until a later pass finds them).
    public func start(accounts: @escaping @Sendable () async -> [String]) {
        guard !roster.isEmpty else { return }
        let ids = Array(Set(roster.registry.flatMap(\.weights))).sorted()
        if !ids.isEmpty {
            let ensure = ensureWeights
            Task.detached(priority: .background) { await ensure(ids) }
        }
        let scorer = self.scorer
        Task { await scorer.start(accounts: accounts) }
    }

    /// Stop at the next model boundary and wait for it.
    public func stop() async {
        cancel.set(true)
        await scorer.stop()
    }
}
