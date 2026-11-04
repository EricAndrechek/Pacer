import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The arena's CPU fixes (#368): a trained bucket state outlives the live
/// lane's history extensions, so a refit does not retrain it; a training
/// pays for its CPU at every tree and stops there when cancelled.
@Suite("Arena CPU: training cost and pacing", .serialized)
struct RuntimeCPUBudgetFixTests {
    typealias Log = MLModelTests.Log
    static let account = "S1"

    /// The registered GBM, cut down so a training is quick; the alignment
    /// (72 h seven-day buckets) is the registered one.
    static func spec() -> ArenaModelSpec {
        var s = ArenaRegistry.spec("ml-gbm-quantile")!
        s.config.values["n_estimators"] = 5
        return s
    }

    /// A built history on a synthetic store, as a full build hands it over.
    static func built() -> (ArenaHistoryBuilder.Built, Millis) {
        let store = MLTimingTests.synthetic(days: 30, accounts: [account], seed: 7)
        let end = store.meters.values.compactMap { $0.last?.tKnown }.max()!
        return (ArenaHistoryBuilder.Built(store: store, builtThrough: ArenaTime.date(end), generation: UUID()), end)
    }

    /// The store as a build at `t` would hold it: rows known by then.
    static func through(_ store: ArenaHistoryStore, _ t: Millis) -> ArenaHistoryStore {
        ArenaHistoryStore(meters: store.meters.mapValues { $0.filter { $0.tKnown <= t } },
                          spend: store.spend.mapValues { $0.filter { $0.tKnown <= t } },
                          tzOffsetMin: store.tzOffsetMin, dataStart: store.dataStart)
    }

    /// One seven-day forecast at the built history's end, through a runner as
    /// the live lane makes it.
    static func forecast(_ built: ArenaHistoryBuilder.Built, spec: ArenaModelSpec, log: Log) throws {
        let cut = ArenaHistory(store: built.store, now: ArenaTime.millis(built.builtThrough), accounts: [account])
        let req = ArenaRunner.request(history: cut, targets: [.meterSevenDay])
        try #require(!req.targets.isEmpty)
        let runner = ArenaRunner(registry: [spec], services: ArenaServices(log: { _, m in log.add(m) }))
        _ = try runner.forecast(model: spec.name, history: cut, request: req)
    }

    /// The live lane's shape: a build, then an extension and a forecast every
    /// five minutes for an hour, all in one 72 h bucket. One training, not one
    /// per refit; a full rebuild (a new generation) trains again.
    @Test func aBucketIsTrainedOncePerGenerationNotOncePerRefit() throws {
        let container = try PacerStore.makeInMemoryContainer()
        let spec = Self.spec()
        let log = Log()
        var (built, end) = Self.built()
        // Start early in a bucket so an hour of refits stays in it.
        let bucket = 72 * ArenaTime.hour
        let start = KitMLData.floorDiv(end - 2 * ArenaTime.hour, bucket) * bucket + ArenaTime.hour
        built = .init(store: Self.through(built.store, start), builtThrough: ArenaTime.date(start),
                      generation: built.generation)
        try Self.forecast(built, spec: spec, log: log)
        let trainedFirst = log.trained
        #expect(trainedFirst >= 1, "\(log.lines)")
        for i in 1...12 {
            built = ArenaHistoryBuilder.extend(built, container: container, account: Self.account,
                                               now: ArenaTime.date(start + Millis(i) * 5 * ArenaTime.minute))
            try Self.forecast(built, spec: spec, log: log)
        }
        #expect(log.trained == trainedFirst, "an extension retrained a held bucket: \(log.lines)")
        // A full build is a new generation: its own memo, so it trains.
        let rebuilt = ArenaHistoryBuilder.Built(
            store: ArenaHistoryStore(meters: built.store.meters, spend: built.store.spend,
                                     tzOffsetMin: built.store.tzOffsetMin, dataStart: built.store.dataStart),
            builtThrough: built.builtThrough, generation: UUID())
        try Self.forecast(rebuilt, spec: spec, log: log)
        #expect(log.trained == 2 * trainedFirst)
    }

    /// An hour of live refits (12, five minutes apart) on the registered
    /// model, with the trained states kept across extensions or, as before
    /// #368, lost at each one. `PACER_ML_BENCH=1`, release:
    /// `PACER_ML_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter RuntimeCPUBudgetFixTests`.
    static func refitHour(keep: Bool) throws -> (trainings: Int, cpu: Double) {
        let container = try PacerStore.makeInMemoryContainer()
        let spec = ArenaRegistry.spec("ml-gbm-quantile")!
        let log = Log()
        let (whole, end) = Self.built()
        let bucket = 72 * ArenaTime.hour
        let start = KitMLData.floorDiv(end - 2 * ArenaTime.hour, bucket) * bucket + ArenaTime.hour
        var built = ArenaHistoryBuilder.Built(store: Self.through(whole.store, start), builtThrough: ArenaTime.date(start),
                                              generation: UUID())
        let c0 = MLAlignTests.cpuSeconds()
        try Self.forecast(built, spec: spec, log: log)
        for i in 1...12 {
            built = ArenaHistoryBuilder.extend(built, container: container, account: Self.account,
                                               now: ArenaTime.date(start + Millis(i) * 5 * ArenaTime.minute))
            if !keep {
                let s = built.store
                built = .init(store: ArenaHistoryStore(meters: s.meters, spend: s.spend, tzOffsetMin: s.tzOffsetMin,
                                                       dataStart: s.dataStart),
                              builtThrough: built.builtThrough, generation: built.generation)
            }
            try Self.forecast(built, spec: spec, log: log)
        }
        return (log.trained, MLAlignTests.cpuSeconds() - c0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PACER_ML_BENCH"] != nil))
    func refitHourCost() throws {
        let before = try Self.refitHour(keep: false), after = try Self.refitHour(keep: true)
        print(String(format: "ml-gbm-quantile, 1 build + 12 refits on one seven-day meter (registered model, serial):\n"
                     + "  states lost at each extension: %d trainings, %.2f CPU s\n"
                     + "  states kept (#368):            %d trainings, %.2f CPU s",
                     before.trainings, before.cpu, after.trainings, after.cpu))
    }

    // MARK: Pacing inside training

    /// Counts the calls and throws `cancelled` from call `cancelAt` on.
    final class Pace: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var cancelAt: Int
        init(cancelAt: Int = .max) { self.cancelAt = cancelAt }
        func call() -> Bool { lock.lock(); defer { lock.unlock() }; calls += 1; return calls >= cancelAt }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    static func dataset(n: Int = 400, features: Int = 5) -> (KitMLGBM.Dataset, [Double], KitMLGBM.Params) {
        var rng = ArenaRNG(seed: 3)
        var x: [Double] = [], y: [Double] = []
        for _ in 0..<n {
            let row = (0..<features).map { _ in rng.uniform() }
            x += row
            y.append(3 * row[0] + row[1] * row[2] + 0.3 * rng.uniform())
        }
        var p = KitMLGBM.Params()
        p.nEstimators = 30; p.numLeaves = 7; p.minDataInLeaf = 10; p.maxBin = 63
        p.baggingFraction = 0.8; p.baggingFreq = 1; p.featureFraction = 0.8; p.seed = 5
        return (KitMLGBM.Dataset(x: x, n: n, nFeatures: features, params: p), y, p)
    }

    /// One call before every tree, and the trees are the unpaced ones.
    @Test func aBoosterPacesOncePerTreeAndPacingChangesNoTree() throws {
        let (ds, y, p) = Self.dataset()
        let plain = KitMLGBM.trainQuantile(ds, y: y, alpha: 0.75, params: p)
        let pace = Pace()
        let paced = try KitMLGBM.trainQuantile(ds, y: y, alpha: 0.75, params: p, pace: { _ = pace.call() })
        #expect(plain.trees.count == p.nEstimators)
        #expect(pace.count == p.nEstimators)
        #expect(paced.trees.count == plain.trees.count)
        #expect(zip(paced.trees, plain.trees).allSatisfy {
            $0.leafValue == $1.leafValue && $0.threshold == $1.threshold && $0.feature == $1.feature
        })
    }

    @Test func aCancelledBoosterStopsAtTheNextTree() {
        let (ds, y, p) = Self.dataset()
        let pace = Pace(cancelAt: 10)
        #expect(throws: ArenaError.cancelled) {
            _ = try KitMLGBM.trainQuantile(ds, y: y, alpha: 0.5, params: p, pace: {
                if pace.call() { throw ArenaError.cancelled }
            })
        }
        #expect(pace.count == 10, "no tree after the one that was cancelled")
    }

    /// The model's cancellation check (the arena's CPU checkpoint) is reached
    /// at every tree of a real training, serial as registered, and in
    /// parallel. A training cancelled part-way stores nothing, so the next
    /// forecast trains the same state an uninterrupted one does.
    @Test(arguments: [false, true])
    func aTrainingIsPacedPerTreeAndCanBeCancelledInside(parallel: Bool) throws {
        var spec = Self.spec()
        spec.config.values["n_estimators"] = 20
        spec.config.values["parallel"] = .bool(parallel)
        let (whole, end) = Self.built()
        let store = Self.through(whole.store, end)
        let t = end - 2 * ArenaTime.hour

        func run(_ store: ArenaHistoryStore, _ pace: Pace, log: Log) throws -> MLGBMQuantileModel {
            let h = ArenaHistory(store: store, now: t, accounts: [Self.account])
            let services = ArenaServices(log: { _, m in log.add(m) }, isCancelled: { pace.call() })
            let runner = ArenaRunner(registry: [spec], services: services)
            let ctx = ArenaContext(spec: spec, seed: 1, services: services, runner: runner, history: { h })
            let m = try MLGBMQuantileModel(context: ctx)
            try m.fit(h)
            let req = try #require(MLModelTests.request(h, account: Self.account, kind: "seven_day"))
            _ = try m.forecast(req)
            withExtendedLifetime(runner) {}
            return m
        }
        let bucket = KitMLData.floorDiv(t, 72 * ArenaTime.hour) * 72 * ArenaTime.hour
        func state(_ m: MLGBMQuantileModel) -> MLGBMQuantileModel.State? {
            m.states[.init(kind: "seven_day", cap: nil, bucket: bucket)]?.1 as? MLGBMQuantileModel.State
        }

        // Uninterrupted, on its own store: how many checks, and the state.
        let refLog = Log(), refPace = Pace()
        let ref = try run(Self.through(whole.store, end), refPace, log: refLog)
        let refState = try #require(state(ref), "\(refLog.lines)")
        let trees = refState.boosters.reduce(0) { $0 + $1.trees.count }
        #expect(refPace.count >= trees, "a check per tree of the final boosters at least")

        // Cancelled near the end: inside the boosting, after the walk-forward.
        let cancelLog = Log()
        #expect(throws: ArenaError.cancelled) {
            _ = try run(store, Pace(cancelAt: refPace.count - 3), log: cancelLog)
        }
        #expect(cancelLog.trained == 0, "cancelled before the training finished: \(cancelLog.lines)")
        // Nothing was cached: the next forecast trains, and gets the same state.
        let againLog = Log()
        let again = try run(store, Pace(), log: againLog)
        #expect(againLog.trained == 1)
        #expect(MLAlignTests.same(state(again), refState))
    }

    // MARK: The live lane skips what has seen the newest reading

    final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var now: Date
        init(_ now: Date) { self.now = now }
        var value: Date {
            get { lock.lock(); defer { lock.unlock() }; return now }
            set { lock.lock(); now = newValue; lock.unlock() }
        }
    }

    /// Counts its fits; forecasts flat.
    final class Counted: ArenaModel {
        nonisolated(unsafe) static var runs = 0
        static let lock = NSLock()
        static var count: Int { lock.lock(); defer { lock.unlock() }; return runs }
        init(context: ArenaContext) {}
        func fit(_ history: ArenaHistory) { Self.lock.lock(); Self.runs += 1; Self.lock.unlock() }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            ArenaForecast(byKey: Dictionary(uniqueKeysWithValues: request.targets.map {
                ($0.key, ArenaTargetForecast.point(Array(repeating: 10, count: $0.grid.count)))
            }))
        }
    }

    /// The same request after the history moved on (a refit extends it) runs
    /// nothing while no new reading has arrived; a newer reading, or an entry
    /// past `refreshAge`, runs the model again.
    @Test func theLiveLaneSkipsAModelUntilANewReadingArrives() async throws {
        Counted.runs = 0
        typealias E = RuntimeEngineTests
        let container = try E.seeded()
        let spec = ArenaModelSpec(name: "test-counted", targets: E.meters) { Counted(context: $0) }
        // The lane's clock is pinned: the real one made the outcome depend on
        // where the wall clock sat in a 5-minute cut bucket (a rebuild less
        // than `reuseInterval` after the last one is not extended, so the
        // test's `later` sometimes moved nothing).
        // Started a minute into a cut bucket, so `later` (five minutes and a
        // second past the first cut) is well over `reuseInterval` from it.
        let t0 = ArenaTime.date(ArenaCut.millis(E.now) + 60_000)
        let clock = ClockBox(t0)
        let rt = E.runtime(container, roster: [spec], clock: { clock.value })
        let binding = ArenaWindowBinding(account: E.account, windowKey: "five_hour", target: .meterFiveHour, cap: nil)
        let resets = E.now.addingTimeInterval(3 * 3600)
        func submit(latest: Date) async {
            await rt.live.submit([ArenaLiveRequest(binding: binding, resetsAt: resets, latestReadingAt: latest,
                                                   models: ["test-counted"])])
            await rt.live.settle()
        }
        // Readings up to ten minutes ago: before any cut the lane makes now.
        let reading = t0.addingTimeInterval(-600)
        await submit(latest: reading)
        #expect(Counted.count == 1)
        let key = ArenaLiveCache.Key(account: E.account, windowKey: "five_hour", model: "test-counted")
        let first = try #require(rt.cache.entry(key)).asOf

        // A refit five minutes on: the history extends, the cut moves, no new reading.
        let later = first.addingTimeInterval(5 * 60 + 1)
        clock.value = later
        await submit(latest: reading)
        #expect(Counted.count == 1, "re-ran a model that had seen the newest reading")

        // A reading after the entry's cut: made again.
        await submit(latest: first.addingTimeInterval(60))
        #expect(Counted.count == 2)
        let second = try #require(rt.cache.entry(key)).asOf
        #expect(second > first)

        // No new reading, but the entry is older than the bound: made again.
        let age = ArenaLiveForecaster.refreshAge(duration: E.fiveHours)
        clock.value = second.addingTimeInterval(age + 5 * 60)
        await submit(latest: reading)
        #expect(Counted.count == 3)
    }

    @Test func aProjectionIsCurrentOnlyForItsCycleItsReadingsAndItsAge() {
        let duration: TimeInterval = 5 * 3600
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let made = reset.addingTimeInterval(-3600)
        let binding = ArenaWindowBinding(account: "a", windowKey: "five_hour", target: .meterFiveHour, cap: nil)
        let entry = ArenaLiveCache.Entry(resetsAt: reset, asOf: made,
                                         projection: ArenaProjection(grid: [1], median: [0])!)
        func req(latest: Date, resets: Date = reset) -> ArenaLiveRequest {
            ArenaLiveRequest(binding: binding, resetsAt: resets, latestReadingAt: latest, models: ["m"])
        }
        let isCurrent = ArenaLiveForecaster.isCurrent
        let bound = ArenaLiveForecaster.refreshAge(duration: duration)
        #expect(bound < ArenaLiveCache.maxAge(duration: duration), "remade before the cache stops serving it")
        #expect(isCurrent(entry, req(latest: made), made, duration), "the same cut")
        #expect(isCurrent(entry, req(latest: made.addingTimeInterval(-60)), made.addingTimeInterval(300), duration))
        #expect(!isCurrent(entry, req(latest: made.addingTimeInterval(60)), made.addingTimeInterval(300), duration),
                "a newer reading")
        #expect(!isCurrent(entry, req(latest: made), made.addingTimeInterval(bound), duration), "too old")
        #expect(!isCurrent(entry, req(latest: made, resets: reset.addingTimeInterval(duration)), made, duration),
                "another cycle")
    }

    // MARK: Only the pick is urgent

    /// Records whether an urgent lane was working when it ran.
    final class UrgencyProbe: ArenaModel {
        nonisolated(unsafe) static var seen: [String: Int] = [:]
        nonisolated(unsafe) static var budget: ArenaCPUBudget?
        static let lock = NSLock()
        let name: String
        init(context: ArenaContext) { name = context.spec.name }
        func fit(_ history: ArenaHistory) {
            Self.lock.lock(); Self.seen[name] = Self.budget?.urgentLanes ?? -1; Self.lock.unlock()
        }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            ArenaForecast(byKey: Dictionary(uniqueKeysWithValues: request.targets.map {
                ($0.key, ArenaTargetForecast.point(Array(repeating: 10, count: $0.grid.count)))
            }))
        }
    }

    /// A refit's request: the pick runs while the lane is urgent (the scorer
    /// waits), the comparison models after, at the everyday share.
    @Test func onlyTheWindowsPickRunsUrgent() async throws {
        typealias E = RuntimeEngineTests
        let container = try E.seeded()
        let specs = ["test-pick", "test-compare-1", "test-compare-2"].map { n in
            ArenaModelSpec(name: n, targets: E.meters) { UrgencyProbe(context: $0) }
        }
        let rt = E.runtime(container, roster: specs)
        UrgencyProbe.seen = [:]
        UrgencyProbe.budget = rt.budget
        defer { UrgencyProbe.budget = nil }
        let binding = ArenaWindowBinding(account: E.account, windowKey: "five_hour", target: .meterFiveHour, cap: nil)
        await rt.live.submit([ArenaLiveRequest(binding: binding, resetsAt: E.now.addingTimeInterval(3 * 3600),
                                               latestReadingAt: E.now, models: specs.map(\.name))])
        await rt.live.settle()
        #expect(UrgencyProbe.seen == ["test-pick": 1, "test-compare-1": 0, "test-compare-2": 0])
        #expect(rt.budget.urgentLanes == 0)
    }

    @Test func aRoundOfSkipsSaysNothing() {
        var r = ArenaLiveForecaster.Round()
        r.skipped = 40
        #expect(r.line(wall: 0.1) == nil)
        r.made = 3; r.picks = 1; r.cpu = 2.25
        #expect(r.line(wall: 4) == "live round: 3 made (1 picks), 40 skipped, 0 failed, 2.2 CPU s in 4.0 s")
    }
}
