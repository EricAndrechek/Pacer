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
//   engine's own methods are scored into. Cheap models first over the whole
//   depth, then the heavy ones (`ArenaModelCosts`); newest cycles first,
//   within a CPU budget (`ArenaCPUBudget`), resumable: it skips every key
//   already stored.
// - `ArenaLiveForecaster` makes the live projections the engine can draw
//   (the pick, and the few the compare sheet lists), into `ArenaLiveCache`.
// - `ArenaRuntime` holds both, the shared history, the CPU budget they share
//   and the engine's view of it all (`ArenaEngineLink`).
//
// Each runs on a serial dispatch queue of its own (a custom actor executor),
// not on Swift's shared cooperative pool: their work is long, synchronous and
// paced by sleeping the thread, which on a pool thread would take a thread
// the rest of the app's tasks need. The scorer's and the history's queues are
// background QoS (the lowest CPU and I/O tier macOS has), the live
// forecaster's utility.

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
    /// Read and clear (a one-shot request, like memory relief).
    func take() -> Bool { lock.lock(); defer { value = false; lock.unlock() }; return value }
}

/// Drops what the arena keeps that can be made again when macOS reports
/// memory pressure: the runners' forecast memos (up to 24 MB an account in a
/// pass, 16 MB an account live), the calibration layer's network cache and
/// the networks' kept scratch buffers (`FMScratch`).
/// On a Mac short of memory those pages were what got compressed and swapped,
/// and touching them again is a page-in on whatever thread asks.
final class ArenaMemoryRelief: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure

    /// - Parameter scorerFlag: read by the scorer between windows.
    init(live: ArenaLiveForecaster, scorerFlag flag: ArenaCancelFlag) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                         queue: .global(qos: .utility))
        source.setEventHandler { [source] in
            let level = source.data.contains(.critical) ? "critical" : "warning"
            FMCalCutCache.shared.removeAll()
            FMScratch.release()
            FMSeries.storeSeriesCache.removeAll()
            flag.set(true)
            Task.detached(priority: .utility) {
                await live.dropRunners()
                MemoryHygiene.relieve()
                Log.write("Arena", "memory pressure (\(level)): dropped forecast memos and caches")
            }
        }
        source.activate()
    }

    deinit { source.cancel() }
}

/// Models log through the runner, and during a backfill a model is asked
/// thousands of times: the calibration layer writes two lines a forecast,
/// each with its own numbers. A model's first few lines are written, then
/// one saying the rest are not, once per process.
final class ArenaLogGate: @unchecked Sendable {
    static let linesPerModel = 3
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func write(_ model: String, _ message: String) {
        lock.lock()
        let n = counts[model, default: 0]
        counts[model] = n + 1
        lock.unlock()
        if n < Self.linesPerModel {
            Log.write("Arena", "\(model): \(message)")
        } else if n == Self.linesPerModel {
            Log.write("Arena", "\(model): further lines not logged")
        }
    }
}

// MARK: - The record scorer

/// Scores arena models over completed cycles into the engine's record, in the
/// background. See the file header.
public actor ArenaRecordScorer {

    public struct Config: Sendable {
        /// Share of one core the arena may use, in CPU time, scorer and live
        /// projections together (`ArenaCPUBudget`). A fifth: with the refits,
        /// scans and views on top, the app as a whole stays near a quarter
        /// to a third of one core while a backfill runs.
        public var dutyCycle: Double = 0.2
        /// The share while the Mac is plugged in, cool and idle
        /// (`ArenaBudgetGovernor`): one core, never more.
        public var idleDutyCycle: Double = 1
        /// Whether `ArenaRuntime.start` lets the governor raise the share
        /// to `idleDutyCycle` (the app); off, it stays at `dutyCycle`.
        public var adaptiveBudget = true
        /// New outcomes are saved and handed to the engines in batches, at
        /// most this often (or at `flushOutcomes`), and at the end of a pass:
        /// a save per cycle was hundreds of saves on a first pass, each a
        /// write on the store the scan and the views read, and each batch an
        /// ingest on the engine actor every ask queues behind.
        public var flushInterval: TimeInterval = 60
        public var flushOutcomes = 2000
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
        /// What each account's runner keeps (`ArenaRunner.memoLimitValues`,
        /// in doubles). One runner serves an account for the whole pass, so a
        /// parent's child backtests, made on a fixed lattice (the calibration
        /// layer's: 24 origins 2 h apart on five-hour windows, 8 h on weekly
        /// ones), are made once and read at every later cut and cycle: a calib
        /// forecast costs 12–25 ms on a reused runner against 86–232 ms on a
        /// fresh one. Only the account being scored keeps one, so this is
        /// the whole bound: 3 M doubles, 24 MB.
        public var memoLimitValues = 3_000_000
        /// Cycles a window scores before the next window's turn. A
        /// window's first turn in each phase scores enough for selection
        /// (`EngineSelfEval.arenaMinPeriods`), so every window can pick
        /// before any goes deep.
        public var sessionCyclesPerTurn = 4
        public var weeklyCyclesPerTurn = 2
        /// A model whose forecast costs at most this much CPU on this Mac
        /// (`ArenaModelCosts`) is scored in phase 1, over every cycle in
        /// depth, before any heavier one is scored at all.
        public var cheapCostMs = 150.0
        /// Prices for the history's spend; nil: the store's ledger, as the
        /// live meter resolves it (tests and probes pass their own).
        public var pricing: PricingTable.Snapshot?
        public init() {}
    }

    public struct Report: Sendable, Equatable {
        public var cycles = 0
        public var outcomes = 0
        public var forecasts = 0
        public var declined = 0
        public var busySeconds = 0.0
        /// Busy (wall) seconds, CPU seconds and forecasts per model, for the
        /// log's slowest list.
        public var modelSeconds: [String: Double] = [:]
        public var modelCPUSeconds: [String: Double] = [:]
        public var modelForecasts: [String: Int] = [:]
        /// Cycles visited in each phase (1: the cheap models, 2: the rest).
        public var phaseCycles: [Int: Int] = [:]
        public init() {}
    }

    private let container: ModelContainer
    private let roster: ArenaRoster
    private let history: ArenaHistoryCache
    private let services: ArenaServices
    private let budget: ArenaCPUBudget
    private let costs: ArenaModelCosts
    /// Every registered model's place in the registry (`DoneKey`).
    private let modelIndex: [String: UInt16]
    private let cancel: ArenaCancelFlag
    /// Set on memory pressure: the pass drops its runners (and their memos)
    /// at the next window's turn.
    let relief = ArenaCancelFlag()
    private let config: Config
    private let calendar: Calendar
    private let landed: @Sendable (_ account: String, _ outcomes: [EngineSelfEval.NewOutcome]) async -> Void
    /// See the file header.
    private let queue = DispatchSerialQueue(label: "com.ericandrechek.pacer.arena.scorer", qos: .background)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    /// Outcomes scored but not yet saved (`Config.flushInterval`).
    private var unsaved: [(account: String, surface: String, news: [EngineSelfEval.NewOutcome])] = []
    private var unsavedCount = 0
    private var lastFlush = SuspendingClock.now
    /// (surface, model, cut, period) keys a model declined this process, so a
    /// pass doesn't ask again every fifteen minutes. Relaunch retries them.
    private var declined = Set<String>()
    private var loop: Task<Void, Never>?
    /// The accounts the last full pass covered, with the roster it scored.
    private var coveredFingerprint: [String: String] = [:]

    /// - Parameter services: the scorer's own: its `isCancelled` is the CPU
    ///   budget's checkpoint (`ArenaRuntime`).
    init(container: ModelContainer, roster: ArenaRoster, history: ArenaHistoryCache, services: ArenaServices,
         budget: ArenaCPUBudget, costs: ArenaModelCosts = ArenaModelCosts(defaults: nil), cancel: ArenaCancelFlag,
         config: Config = Config(), calendar: Calendar = .current,
         landed: @escaping @Sendable (String, [EngineSelfEval.NewOutcome]) async -> Void) {
        self.container = container; self.roster = roster; self.history = history; self.services = services
        self.budget = budget; self.costs = costs; self.cancel = cancel; self.config = config; self.calendar = calendar
        self.modelIndex = Dictionary(roster.registry.enumerated().map { ($0.element.name, UInt16($0.offset)) },
                                     uniquingKeysWith: { a, _ in a })
        self.landed = landed
    }

    /// What a full pass is for: the models that can run and how deep. A
    /// change runs a full pass again (so a network whose weights just
    /// arrived is scored over months, not only the recent weeks); otherwise
    /// passes read only the recent weeks.
    var fingerprint: String {
        "v1|\(EngineSelfEval.rlBucketVersion)|\(config.sessionCycleCap)/\(config.weeklyCycleCap)|"
            + roster.selectable.filter { Self.weightsPresent($0, roster: roster, services: services) }
                .map(\.name).sorted().joined(separator: ",")
    }

    // MARK: Loop

    /// Score now, then every `rescanInterval`, until `stop()`. `beforePass`
    /// runs first each time (the runtime fetches any weights still missing).
    func start(accounts: @escaping @Sendable () async -> [String],
               beforePass: @escaping @Sendable () async -> Void = {}) {
        guard loop == nil, !roster.isEmpty, !cancel.isSet else { return }
        loop = Task.detached(priority: .background) { [weak self] in
            while let self, !Task.isCancelled {
                await beforePass()
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
        /// Every cycle in depth with something still to score, newest first.
        let cycles: [BurnTrajectory.Cycle]
        /// The current phase's cycles still to visit, newest first.
        var queue: [BurnTrajectory.Cycle] = []
        /// What is already scored, arena models only, as small integers: a
        /// pass lasts days on a first launch, and this as strings (every
        /// method, ~90 characters a key) was megabytes a window.
        var existing: Set<DoneKey>
        /// Each cycle's place in `cycles`, by period key.
        let periodIndex: [String: UInt16]
        /// Turns this window has had in the current phase.
        var turns = 0
    }

    /// One (model, cut, cycle) of a window's record, by index: the model in
    /// the registry, the cut in `Config.cuts`, the cycle among the window's
    /// completed cycles in depth (`periodIndex`).
    struct DoneKey: Hashable { let model: UInt16; let cut: UInt8; let period: UInt16 }

    private func doneKey(_ s: Stream, _ model: String, cut: Int, period: String) -> DoneKey? {
        guard let m = modelIndex[model], let p = s.periodIndex[period] else { return nil }
        return DoneKey(model: m, cut: UInt8(cut), period: p)
    }

    private func isDone(_ s: Stream, _ model: String, cut: Int, period: String) -> Bool {
        doneKey(s, model, cut: cut, period: period).map { s.existing.contains($0) } ?? false
    }

    /// The two phases of a pass: the cheap models over every cycle in depth,
    /// then the rest (`Config.cheapCostMs`, `ArenaModelCosts`).
    enum Phase: Int, CaseIterable { case cheap = 1, heavy = 2 }

    /// One account's runner for the pass, and the models that have run on it
    /// (a model's first forecast on a runner is not timed: `ArenaModelCosts`).
    private final class RunnerSlot {
        let runner: ArenaRunner
        var warm = Set<String>()
        init(_ runner: ArenaRunner) { self.runner = runner }
    }

    /// The stream's models this phase scores: in phase 1 the ones whose
    /// forecast costs at most `cheapCostMs` here (re-read every cycle, so a
    /// model timed heavier than its prior moves to phase 2 at once); in
    /// phase 2 every one still missing anything.
    private func phaseModels(_ s: Stream, _ phase: Phase) -> [ArenaModelSpec] {
        switch phase {
        case .heavy: return s.models
        case .cheap:
            let weekly = s.window.isWeeklyScale
            return s.models.filter { costs.cost($0, weekly: weekly, registry: roster.registryByName) <= config.cheapCostMs }
        }
    }

    /// Whether any of `models` is missing at any cut of `cycle`.
    private func needs(_ s: Stream, _ cycle: BurnTrajectory.Cycle, models: [ArenaModelSpec]) -> Bool {
        let period = EngineSelfEval.periodKeyRL(cycle.resetsAt)
        for ci in config.cuts.indices {
            for m in models where !isDone(s, m.name, cut: ci, period: period) { return true }
        }
        return false
    }

    /// One pass over `accounts`: a full one (120 days, the first time an
    /// account is seen with this roster) or an incremental one (the recent
    /// weeks). Returns what it did.
    @discardableResult
    public func pass(accounts: [String], now: Date = Date()) async -> Report {
        var report = Report()
        guard !roster.isEmpty, !cancel.isSet else { return report }
        // Nothing can run yet (every model waits on a download): no history
        // to read.
        guard roster.selectable.contains(where: { Self.weightsPresent($0, roster: roster, services: services) })
        else { return report }
        let started = SuspendingClock.now
        var streams: [Stream] = []
        let fingerprint = self.fingerprint
        for account in accounts {
            guard !cancel.isSet else { saveUnsaved(); return report }
            let full = coveredFingerprint[account] != fingerprint
            streams += await self.streams(account: account, now: now, full: full)
            coveredFingerprint[account] = fingerprint
        }
        let depth = streams.reduce(0) { $0 + $1.cycles.count }
        guard depth > 0 else { return report }

        // Phase 1 scores only the models that are cheap on this Mac, over
        // every cycle in depth; phase 2 the rest. Within a phase each window
        // takes its turn, newest cycles first, so every window's selection
        // has something to go on early. The account being scored keeps one
        // runner across its turns: a parent's child backtests over
        // neighbouring cuts and cycles mostly repeat, and its memo answers
        // them.
        var runners: [String: RunnerSlot] = [:]
        var lastLog = SuspendingClock.now
        var planned = 0
        for phase in Phase.allCases {
            for i in streams.indices {
                let models = phaseModels(streams[i], phase)
                streams[i].queue = models.isEmpty ? [] : streams[i].cycles.filter { needs(streams[i], $0, models: models) }
                streams[i].turns = 0
            }
            let queued = streams.reduce(0) { $0 + $1.queue.count }
            guard queued > 0 else { continue }
            planned += queued
            let names = Set(streams.flatMap { phaseModels($0, phase).map(\.name) })
            Log.write("Arena", "phase \(phase.rawValue): scoring \(queued) cycle(s) over "
                      + "\(streams.filter { !$0.queue.isEmpty }.count) window(s), \(names.count) model(s)"
                      + (phase == .cheap ? String(format: " (≤ %.0f ms a forecast)", config.cheapCostMs) : "")
                      + String(format: ", %.0f%% of a core", budget.rate * 100))
            while streams.contains(where: { !$0.queue.isEmpty }) {
                for i in streams.indices where !streams[i].queue.isEmpty {
                    if relief.take() { runners.removeAll() }
                    let weekly = streams[i].window.isWeeklyScale
                    let account = streams[i].account
                    // One account's runner at a time: each holds a memo of up
                    // to `memoLimitValues` (24 MB), and four accounts' were a
                    // hundred megabytes for the days a first pass lasts. An
                    // account's windows are consecutive streams, so its memo
                    // still serves all of them in a round; what a switch costs
                    // is a model's first forecast on the next turn.
                    if runners.count > 1 || runners[account] == nil { runners = runners.filter { $0.key == account } }
                    let slot = runners[account] ?? {
                        let r = ArenaRunner(registry: roster.registry, services: services)
                        r.memoLimitValues = config.memoLimitValues
                        return RunnerSlot(r)
                    }()
                    runners[account] = slot
                    defer { prune(&streams[i]); streams[i].turns += 1 }
                    let perTurn = weekly ? config.weeklyCyclesPerTurn : config.sessionCyclesPerTurn
                    let turn = streams[i].turns == 0 ? max(perTurn, EngineSelfEval.arenaMinPeriods(weekly: weekly)) : perTurn
                    for _ in 0..<turn {
                        guard !cancel.isSet else { saveUnsaved(); costs.save(); return report }
                        guard !streams[i].queue.isEmpty else { break }
                        let models = phaseModels(streams[i], phase)
                        guard !models.isEmpty else { streams[i].queue.removeAll(); break }
                        let cycle = streams[i].queue.removeFirst()
                        let news = score(cycle, in: &streams[i], models: models, slot: slot, report: &report)
                        report.cycles += 1
                        report.phaseCycles[phase.rawValue, default: 0] += 1
                        if !news.isEmpty {
                            report.outcomes += news.count
                            streams[i].records += news.map {
                                EngineSelfEval.Record(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey,
                                                      predicted: $0.predicted, truth: $0.truth)
                            }
                            unsaved.append((streams[i].account, streams[i].surface, news))
                            unsavedCount += news.count
                        }
                        if unsavedCount >= config.flushOutcomes
                            || SuspendingClock.now - lastFlush >= .seconds(config.flushInterval) {
                            await flush()
                        }
                        if SuspendingClock.now - lastLog >= .seconds(120) {
                            lastLog = SuspendingClock.now
                            log(report, phase: phase, of: planned, since: started)
                        }
                    }
                }
            }
            log(report, phase: phase, of: planned, since: started, done: true)
        }
        await flush()
        // Nothing runs a network until the next pass or refit: its kept
        // scratch is only memory now (`FMScratch`).
        runners.removeAll()
        FMScratch.release()
        MemoryHygiene.relieve()
        return report
    }

    /// Save what is unsaved, then hand each account's share to its engine.
    private func flush() async {
        lastFlush = SuspendingClock.now
        costs.save()
        let batch = saveUnsaved()
        for (account, news) in batch where !news.isEmpty { await landed(account, news) }
    }

    /// Save what is unsaved in one transaction; returns it by account. Also
    /// what a cancelled pass does on its way out (the engines are stopping
    /// with it).
    @discardableResult
    private func saveUnsaved() -> [String: [EngineSelfEval.NewOutcome]] {
        guard !unsaved.isEmpty else { return [:] }
        let context = ModelContext(container)
        let now = Date()
        var byAccount: [String: [EngineSelfEval.NewOutcome]] = [:]
        for (account, surface, news) in unsaved {
            for n in news {
                context.insert(EngineEvalOutcome(surface: surface, method: n.method, bucket: n.bucket,
                                                 periodKey: n.periodKey, predicted: n.predicted, truth: n.truth,
                                                 recordedAt: now))
            }
            byAccount[account, default: []] += news
        }
        try? context.save()
        unsaved.removeAll()
        unsavedCount = 0
        return byAccount
    }

    private func log(_ r: Report, phase: Phase, of total: Int, since started: SuspendingClock.Instant,
                     done: Bool = false) {
        let awake = SuspendingClock.now - started
        let cpu = budget.totals
        // The three that cost the most CPU in all, with their CPU per forecast.
        let slowest = r.modelCPUSeconds.sorted { $0.value > $1.value }.prefix(3).map { id, s in
            String(format: "%@ %.0f ms", id, s * 1000 / Double(max(1, r.modelForecasts[id] ?? 1)))
        }.joined(separator: ", ")
        Log.write("Arena", (done ? "phase \(phase.rawValue) done, " : "phase \(phase.rawValue) progress ")
                  + "\(r.cycles)/\(total) cycle(s): +\(r.outcomes) outcome(s) "
                  + "from \(r.forecasts) forecast(s), \(r.declined) declined, "
                  + String(format: "busy %.0f s of %.0f s awake; arena cpu %.0f s since launch "
                           + "(%.0f%% of a core), paced %.0f s", r.busySeconds,
                           Double(awake.components.seconds), cpu.spent, budget.averageShare * 100, cpu.slept)
                  + (slowest.isEmpty ? "" : "; slowest: \(slowest)"))
    }

    /// The windows of `account` there is something to score in.
    private func streams(account: String, now: Date, full: Bool) async -> [Stream] {
        // All of this is the scorer's work, charged to the budget: the reads,
        // the build, segmenting and the record below.
        let budget = self.budget, cancel = self.cancel
        budget.mark()
        let days = full ? ArenaHistoryBuilder.depthDays : config.incrementalDays
        let limits = ArenaHistoryBuilder.readLimits(
            container: container, account: account, since: now.addingTimeInterval(-Double(days) * 86400))
        guard limits.count > 0 else { budget.checkpoint(cancelled: { cancel.isSet }); return [] }
        let store: ArenaHistoryStore
        if full {
            // Months of turns, priced: the pass's one burst of reading,
            // paced by the budget a day at a time.
            let built = ArenaHistoryBuilder.build(container: container, account: account, now: now, limits: limits,
                                                  pricing: config.pricing,
                                                  pace: { budget.checkpoint(cancelled: { cancel.isSet }) })
            budget.checkpoint(cancelled: { cancel.isSet })
            await history.install(built, account: account)
            store = built.store
        } else {
            budget.checkpoint(cancelled: { cancel.isSet })
            store = await history.store(account: account, now: now)
        }
        // A suspension may have moved this to another thread.
        budget.mark()
        defer { budget.checkpoint(cancelled: { cancel.isSet }) }
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
            var periodIndex: [String: UInt16] = [:]
            for (i, c) in completed.enumerated() { periodIndex[EngineSelfEval.periodKeyRL(c.resetsAt)] = UInt16(i) }
            let cutIndex = Dictionary(config.cuts.enumerated().map { (EngineSelfEval.rlBucket($0.element), $0.offset) },
                                      uniquingKeysWith: { a, _ in a })
            let arenaNames = Set(available.map(\.name))
            var existing = Set<DoneKey>()
            for r in stored where arenaNames.contains(r.method) {
                guard let m = modelIndex[r.method], let c = cutIndex[r.bucket], let p = periodIndex[r.periodKey]
                else { continue }
                existing.insert(DoneKey(model: m, cut: UInt8(c), period: p))
            }
            // One copy of each method name and period key, shared by every
            // record that names it: read from SQLite, each row had its own.
            var interned: [String: String] = [:]
            func intern(_ x: String) -> String {
                if let c = interned[x] { return c }
                interned[x] = x
                return x
            }
            let records = stored.filter { EngineSelfEval.isCurrentRLBucket($0.bucket) }.map {
                EngineSelfEval.Record(method: intern($0.method), bucket: intern($0.bucket), periodKey: intern($0.periodKey),
                                      predicted: $0.predicted, truth: $0.truth)
            }
            let losers = EngineSelfEval.arenaLosers(records, arenaIds: Set(available.map(\.name)),
                                                    weekly: window.isWeeklyScale)
            if !losers.isEmpty {
                Log.write("Arena", "\(window.key) …\(account.suffix(4)): not scoring deeper (well behind the record): "
                          + losers.sorted().joined(separator: ", "))
            }
            let models = available.filter { !losers.contains($0.name) }
            guard !models.isEmpty else { continue }
            let wanted = models.count * config.cuts.count
            let todo = completed.filter { c in
                guard let p = periodIndex[EngineSelfEval.periodKeyRL(c.resetsAt)] else { return false }
                var have = 0
                for ci in config.cuts.indices {
                    for m in models {
                        if let mi = modelIndex[m.name], existing.contains(DoneKey(model: mi, cut: UInt8(ci), period: p)) {
                            have += 1
                        }
                    }
                }
                return have < wanted
            }
            guard !todo.isEmpty else { continue }
            out.append(Stream(account: account, window: window, binding: binding, models: models, records: records,
                              store: store, surface: surface, cycles: Array(todo), existing: existing,
                              periodIndex: periodIndex))
        }
        return out
    }

    /// Every cut of one completed cycle, every one of `models` still missing
    /// at it: cuts outer, models inner, one history cut shared by the models.
    private func score(_ cycle: BurnTrajectory.Cycle, in s: inout Stream, models: [ArenaModelSpec],
                       slot: RunnerSlot, report: inout Report)
        -> [EngineSelfEval.NewOutcome] {
        let runner = slot.runner
        let weekly = s.window.isWeeklyScale
        guard let truth = cycle.samples.map(\.usedPercentage).max(), truth > 0 else { return [] }
        let duration = cycle.resetsAt.timeIntervalSince(cycle.cycleStart)
        guard duration > 0 else { return [] }
        let period = EngineSelfEval.periodKeyRL(cycle.resetsAt)
        let baseSurface = EngineSelfEval.rlSurface(s.window.key)
        var out: [EngineSelfEval.NewOutcome] = []
        for (ci, cf) in config.cuts.enumerated() {
            guard !cancel.isSet else { return out }
            let cutNow = cycle.cycleStart.addingTimeInterval(duration * cf)
            let seen = cycle.samples.filter { $0.at <= cutNow }
            // The engine's own rule (`newOutcomesRL`), so both are scored on
            // the same cuts.
            guard seen.count >= 3 else { continue }
            let missing = models.filter {
                !isDone(s, $0.name, cut: ci, period: period) && !declined.contains(Self.key(s.surface, $0.name, cf, period))
            }
            guard !missing.isEmpty else { continue }
            let partial = BurnTrajectory.PartialCycle(samples: seen, now: cutNow, cycleStart: cycle.cycleStart,
                                                      resetsAt: cycle.resetsAt)
            let cut = ArenaHistory(store: s.store, now: ArenaCut.millis(cutNow), accounts: [s.account])
            let busyStart = SuspendingClock.now
            for spec in missing {
                let k = Self.key(s.surface, spec.name, cf, period)
                report.forecasts += 1
                let modelStart = SuspendingClock.now
                // CPU, not wall: the wall time is mostly the budget's sleeps.
                let cpuStart = budget.threadCPUSeconds()
                var timed = true
                defer {
                    let d = SuspendingClock.now - modelStart
                    report.modelSeconds[spec.name, default: 0] += Double(d.components.seconds)
                        + Double(d.components.attoseconds) * 1e-18
                    let cpu = max(0, budget.threadCPUSeconds() - cpuStart)
                    report.modelCPUSeconds[spec.name, default: 0] += cpu
                    report.modelForecasts[spec.name, default: 0] += 1
                    // A model's first forecast on this runner fills its memo
                    // (see `ArenaModelCosts`); a cancelled one is partial.
                    if timed, !slot.warm.insert(spec.name).inserted {
                        costs.record(spec.name, weekly: weekly, cpuMs: cpu * 1000)
                    }
                }
                // The model's CPU is charged at every check inside it (the
                // scorer's `isCancelled`) and its tail here.
                budget.mark()
                defer { budget.checkpoint(cancelled: { cancel.isSet }) }
                do {
                    let p = try runner.projection(model: spec.name, binding: s.binding, history: cut,
                                                    resetAt: ArenaTime.millis(cycle.resetsAt))
                    let shown = BurnTrajectory.displayedAtReset(p.closure, partial: partial)
                    guard shown.isFinite else { declined.insert(k); report.declined += 1; continue }
                    out.append(EngineSelfEval.NewOutcome(
                        surface: baseSurface, method: spec.name, bucket: EngineSelfEval.rlBucket(cf),
                        periodKey: period, predicted: shown, truth: truth))
                    if let done = doneKey(s, spec.name, cut: ci, period: period) { s.existing.insert(done) }
                } catch ArenaError.cancelled {
                    timed = false
                    return out
                } catch {
                    declined.insert(k)
                    report.declined += 1
                }
            }
            let busy = SuspendingClock.now - busyStart
            report.busySeconds += Double(busy.components.seconds) + Double(busy.components.attoseconds) * 1e-18
        }
        return out
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

    /// Whether every pinned weight `spec` and its children need is on this
    /// Mac (`ArenaRunner.requiredWeights`, transitive). A model missing one
    /// throws `weightsUnavailable` at every cut, so it is not offered.
    static func weightsPresent(_ spec: ArenaModelSpec, roster: ArenaRoster, services: ArenaServices) -> Bool {
        ArenaRunner(registry: roster.registry).requiredWeights(spec.name).allSatisfy { services.weights($0) != nil }
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
    private let budget: ArenaCPUBudget
    private let cancel: ArenaCancelFlag
    private let landed: @Sendable (Set<String>) async -> Void
    /// See the file header.
    private let queue = DispatchSerialQueue(label: "com.ericandrechek.pacer.arena.live", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private var pending: [String: ArenaLiveRequest] = [:]
    private var draining = false
    /// One runner per account, kept across refits for as long as the history
    /// it ran on is the same full build: the calibration layer's child
    /// backtests sit on a fixed lattice, so a later cut reuses all but the
    /// newest (12–25 ms a calib forecast warm, 86–232 ms cold).
    private var runners: [String: (generation: UUID, runner: ArenaRunner)] = [:]
    static let liveMemoLimitValues = 2_000_000
    /// Failures already logged, so a model that can't forecast a window
    /// says so once, not every refit.
    private var logged = Set<String>()

    /// - Parameter services: the live forecaster's own: its `isCancelled` is
    ///   the CPU budget's urgent checkpoint (`ArenaRuntime`).
    init(roster: ArenaRoster, history: ArenaHistoryCache, cache: ArenaLiveCache, services: ArenaServices,
         budget: ArenaCPUBudget, cancel: ArenaCancelFlag, landed: @escaping @Sendable (Set<String>) async -> Void) {
        self.roster = roster; self.history = history; self.cache = cache; self.services = services
        self.budget = budget; self.cancel = cancel; self.landed = landed
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

    /// Forget the kept runners and their memos (memory pressure); the next
    /// request makes fresh ones.
    func dropRunners() { runners.removeAll() }

    /// Wait until everything queued so far has been made (tests).
    public func settle() async {
        while draining || !pending.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func drain() async {
        // While this works the scorer waits at its checkpoints: the budget
        // goes to what the dashboard is waiting for.
        budget.beginUrgent()
        defer { budget.endUrgent() }
        while !pending.isEmpty, !cancel.isSet {
            let batch = Array(pending.values)
            pending.removeAll()
            var changed = Set<String>()
            for (account, requests) in Dictionary(grouping: batch, by: { $0.binding.account }) {
                let built = await history.built(account: account)
                let cutMs = ArenaCut.millis(built.builtThrough)
                let cut = ArenaHistory(store: built.store, now: cutMs, accounts: [account])
                let runner: ArenaRunner
                if let kept = runners[account], kept.generation == built.generation {
                    runner = kept.runner
                } else {
                    runner = ArenaRunner(registry: roster.registry, services: services)
                    runner.memoLimitValues = Self.liveMemoLimitValues
                    runners[account] = (built.generation, runner)
                }
                for r in requests where make(r, cut: cut, asOf: ArenaTime.date(cutMs), runner: runner) {
                    changed.insert(account)
                }
            }
            if !changed.isEmpty { await landed(changed) }
        }
        draining = false
    }

    /// Returns whether anything new landed.
    private func make(_ r: ArenaLiveRequest, cut: ArenaHistory, asOf: Date, runner: ArenaRunner) -> Bool {
        let duration = TimeInterval(r.binding.target.windowMillis) / 1000
        var any = false
        for model in r.models {
            guard !cancel.isSet else { return any }
            let key = ArenaLiveCache.Key(account: r.binding.account, windowKey: r.binding.windowKey, model: model)
            // Already made at this cut, for this cycle: the same answer.
            if let e = cache.entry(key), e.asOf >= asOf,
               RateLimitCycle.contains(sampleReset: e.resetsAt, resets: r.resetsAt, duration: duration) {
                continue
            }
            budget.mark()
            defer { budget.checkpoint(urgent: true, cancelled: { cancel.isSet }) }
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
    /// The arena's share of the CPU, scorer and live together.
    public let budget: ArenaCPUBudget
    /// Raises the share while the Mac is plugged in and idle, from `start`.
    public let governor: ArenaBudgetGovernor?
    let cancel = ArenaCancelFlag()
    private let relief: ArenaMemoryRelief
    /// Frees a network's kept scratch once it has gone two minutes unused
    /// (`FMScratch.releaseIdle`): a backfill keeps its networks warm, and
    /// between passes and refits nothing is held.
    private let scratchSweep: DispatchSourceTimer
    private let ensureWeights: @Sendable ([String]) async -> Void
    private let weights: @Sendable (String) -> URL?
    public let compareLimit: Int

    /// Pretrained weights (`ArenaWeightStore`): the folder holding a pinned
    /// network when it is on this Mac, never a download. A model whose
    /// weights (or a child's) are missing is not offered or scored until a
    /// later pass finds them.
    public static let defaultWeights: @Sendable (String) -> URL? = ArenaWeightStore.services
    /// Fetches what is missing: one file at a time, never on an expensive or
    /// constrained network, each verified against its pin.
    public static let defaultEnsureWeights: @Sendable ([String]) async -> Void = { ids in
        await ArenaWeightStore.ensureAvailable(ids)
    }

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
                costs: ArenaModelCosts = ArenaModelCosts(defaults: nil),
                onRecordLanded: @escaping @Sendable (String, [EngineSelfEval.NewOutcome]) async -> Void,
                onLiveLanded: @escaping @Sendable (Set<String>) async -> Void) {
        self.roster = roster
        self.compareLimit = compareLimit
        self.ensureWeights = ensureWeights
        self.weights = weights
        // One thread per BLAS call, process-wide (only the arena uses BLAS),
        // from before the first live forecast: Accelerate otherwise spreads
        // each matrix product over every core, so a quarter of a core by the
        // calling thread's clock could be the whole machine by the process's,
        // and the budget counts the calling thread.
        FMBackends.setBLASThreading(singleThreaded: true)
        let cancel = self.cancel
        let budget = ArenaCPUBudget(rate: config.dutyCycle)
        self.budget = budget
        self.governor = config.adaptiveBudget
            ? ArenaBudgetGovernor(budget: budget, shareRate: config.dutyCycle, fullRate: config.idleDutyCycle)
            : nil
        // The history pays like the rest but never waits for the urgent lane:
        // the live forecaster is often what it is building for, and waits on it.
        let history = ArenaHistoryCache(container: container, pricing: config.pricing,
                                        pace: { budget.checkpoint(urgent: true, cancelled: { cancel.isSet }) })
        self.history = history
        let gate = ArenaLogGate()
        // Every check a model makes for cancellation is also where it pays
        // for its CPU: the scorer's waits behind live work, the live
        // forecaster's does not.
        let scorerServices = ArenaServices(weights: weights, log: { gate.write($0, $1) }, isCancelled: {
            budget.checkpoint(cancelled: { cancel.isSet })
            return cancel.isSet
        })
        let liveServices = ArenaServices(weights: weights, log: { gate.write($0, $1) }, isCancelled: {
            budget.checkpoint(urgent: true, cancelled: { cancel.isSet })
            return cancel.isSet
        })
        self.scorer = ArenaRecordScorer(container: container, roster: roster, history: history,
                                        services: scorerServices, budget: budget, costs: costs, cancel: cancel,
                                        config: config, landed: onRecordLanded)
        self.live = ArenaLiveForecaster(roster: roster, history: history, cache: cache, services: liveServices,
                                        budget: budget, cancel: cancel, landed: onLiveLanded)
        self.relief = ArenaMemoryRelief(live: live, scorerFlag: scorer.relief)
        let sweep = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        sweep.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        sweep.setEventHandler { FMScratch.releaseIdle() }
        // Active from here, as the memory relief is: a source released
        // before it was ever activated is a crash in libdispatch.
        sweep.activate()
        self.scratchSweep = sweep
    }

    deinit { scratchSweep.cancel() }

    /// What every engine adopts.
    public var link: ArenaEngineLink {
        let live = self.live
        return ArenaEngineLink(roster: roster, cache: cache, compareLimit: compareLimit,
                               requestLive: { reqs in Task.detached(priority: .utility) { await live.submit(reqs) } })
    }

    /// Start scoring `accounts()` in the background, and fetch any pinned
    /// weights the roster needs (without waiting: models whose weights are
    /// missing are skipped until a later pass finds them). Every pass asks
    /// for the missing weights again, so a download that failed is retried
    /// in the same process (`ArenaWeightStore` backs off between tries).
    public func start(accounts: @escaping @Sendable () async -> [String]) {
        guard !roster.isEmpty else { return }
        // What the models that can be picked need, children included.
        let runner = ArenaRunner(registry: roster.registry)
        let ids = Array(Set(roster.selectable.flatMap { runner.requiredWeights($0.name) })).sorted()
        let ensure = ensureWeights, local = weights
        let fetchMissing: @Sendable () async -> Void = {
            let missing = ids.filter { local($0) == nil }
            guard !missing.isEmpty else { return }
            // Not awaited: a download takes minutes and the pass needs none.
            Task.detached(priority: .background) { await ensure(missing) }
        }
        let scorer = self.scorer
        governor?.start()
        Task.detached(priority: .background) { await scorer.start(accounts: accounts, beforePass: fetchMissing) }
    }

    /// Stop at the next model boundary and wait for it.
    public func stop() async {
        cancel.set(true)
        governor?.stop()
        await scorer.stop()
        FMScratch.release()
    }
}
