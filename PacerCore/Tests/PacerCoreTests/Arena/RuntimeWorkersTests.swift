import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The grader's workers (`ArenaScoringCrew`): the rows do not depend on how
/// many there are or on any of them stopping part-way, and the count follows
/// what it is told. `RuntimeWorkersProbe` is the same check on a real store.
@Suite("Arena runtime: the grader's workers", .serialized)
struct RuntimeWorkersTests {
    typealias Fixtures = RuntimeEngineTests

    /// A flat forecast from a calibration-shaped model: it asks its child at
    /// every point of a lattice shared with its neighbours, draws from its own
    /// seeded generator and takes real time, so a worker's answer depends on
    /// everything a worker could get wrong: the shared memo, the seed, a
    /// cancelled child.
    final class Parent: ArenaModel {
        let ctx: ArenaContext
        var history: ArenaHistory?
        init(context: ArenaContext) { ctx = context }
        func fit(_ history: ArenaHistory) { self.history = history }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            var out: [String: ArenaTargetForecast] = [:]
            guard let h = history else { throw ArenaError.invalid("not fitted") }
            let since = KitSpend.floorDiv(h.now - 12 * ArenaTime.hour, ArenaTime.hour) * ArenaTime.hour
            let items = try ctx.backtest("test-child", every: ArenaTime.hour, targets: [.meterFiveHour],
                                         since: since)
            let sum = items.reduce(0.0) { $0 + ($1.forecast.byKey.values.first?.median.last ?? 0) }
            for tr in request.targets {
                let noise = (0..<50).reduce(0.0) { acc, _ in acc + ctx.rng.normal() }
                out[tr.key] = .point(Array(repeating: sum / 1000 + noise, count: tr.grid.count))
            }
            return ArenaForecast(byKey: out)
        }
    }

    /// The reading it can see, plus a seeded draw; counts its runs, and checks
    /// for cancellation as a real child does.
    final class Child: ArenaModel {
        nonisolated(unsafe) static var runs = 0
        static let lock = NSLock()
        let ctx: ArenaContext
        var history: ArenaHistory?
        init(context: ArenaContext) { ctx = context }
        func fit(_ history: ArenaHistory) {
            self.history = history
            Self.lock.lock(); Self.runs += 1; Self.lock.unlock()
        }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            try ctx.checkCancelled()
            guard let h = history else { throw ArenaError.invalid("not fitted") }
            var out: [String: ArenaTargetForecast] = [:]
            for tr in request.targets {
                let last = h.readings(tr.meter).last?.utilPct ?? 0
                out[tr.key] = .point(Array(repeating: last + ctx.rng.uniform(), count: tr.grid.count))
            }
            return ArenaForecast(byKey: out)
        }
    }

    /// Swallows its child's cancellation, as a model with a fallback might,
    /// and answers from less than it should.
    final class Swallower: ArenaModel {
        let ctx: ArenaContext
        var history: ArenaHistory?
        init(context: ArenaContext) { ctx = context }
        func fit(_ history: ArenaHistory) { self.history = history }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            guard let h = history else { throw ArenaError.invalid("not fitted") }
            let since = KitSpend.floorDiv(h.now - 6 * ArenaTime.hour, ArenaTime.hour) * ArenaTime.hour
            let child = (try? ctx.backtest("test-child", every: ArenaTime.hour, targets: [.meterFiveHour], since: since)) ?? []
            var out: [String: ArenaTargetForecast] = [:]
            for tr in request.targets {
                out[tr.key] = .point(Array(repeating: Double(child.count), count: tr.grid.count))
            }
            return ArenaForecast(byKey: out)
        }
    }

    static let meters = Fixtures.meters
    static let child = ArenaModelSpec(name: "test-child", targets: meters, config: ["selectable": false]) { Child(context: $0) }
    static let parent = ArenaModelSpec(name: "test-parent", targets: meters, children: ["test-child"]) { Parent(context: $0) }
    static let swallower = ArenaModelSpec(name: "test-swallower", targets: meters, children: ["test-child"]) {
        Swallower(context: $0)
    }
    /// The real ports that need no weights and are quick unoptimised:
    /// arithmetic, an analog with its store-level table, spend.
    static let real = ["naive-flat", "g1-10-fable-analog", "spend-decay-1h"]
    static var roster: ArenaRoster {
        ArenaRoster(registry: ArenaRegistry.all + [child, parent, swallower],
                    only: Set(real + ["test-parent", "test-swallower"]))
    }

    /// Everything a grade is, but when it was written, exactly.
    static func rows(_ container: ModelContainer) throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>()).map { o in
            [o.surface, o.method, o.bucket, o.periodKey, String(o.predicted.bitPattern, radix: 16),
             String(o.truth.bitPattern, radix: 16), o.inputs ?? "-",
             o.reading.map { String($0.bitPattern, radix: 16) } ?? "-"].joined(separator: "|")
        }.sorted()
    }

    static func config() -> ArenaRecordScorer.Config {
        var c = Fixtures.noSleep()
        c.adaptiveBudget = false
        c.sessionCycleCap = 6
        c.pricing = PricingTable.Snapshot(pricingByModel: RuntimeHistoryBuilderTests.catalog)
        c.gradeInputs = ArenaGradeInputs(pricing: "1", history: "1")
        return c
    }

    static func runtime(_ container: ModelContainer, config: ArenaRecordScorer.Config = config(),
                        roster: ArenaRoster = roster, workers: Int) -> ArenaRuntime {
        let rt = ArenaRuntime(container: container, roster: roster, weights: { _ in nil }, ensureWeights: { _ in },
                              config: config, costs: ArenaModelCosts(defaults: nil),
                              progress: ArenaScoringProgressBoard(), speedUp: ArenaSpeedUp(), maxWorkers: workers,
                              pressure: MemoryPressure(), onRecordLanded: { _, _ in },
                              onLiveLanded: { _ in })
        rt.budget.rate = Double(max(1, workers))
        rt.budget.scorerWorkers = workers
        // Background, the default, can wait minutes for a core on a loaded Mac.
        rt.budget.scorerQoS = QOS_CLASS_UTILITY
        return rt
    }

    /// The reference: one worker over the whole fixture.
    static let baseline: Result<[String], any Error> = {
        Result { try oneWorkerRows() }
    }()

    static func oneWorkerRows() throws -> [String] {
        final class Box: @unchecked Sendable { var rows: Result<[String], any Error> = .success([]) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let container = try Fixtures.seeded(cycles: 6)
                let rt = Self.runtime(container, workers: 1)
                let r = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
                #expect(r.outcomes > 0)
                box.rows = .success(try Self.rows(container))
            } catch {
                box.rows = .failure(error)
            }
            done.signal()
        }
        done.wait()
        return try box.rows.get()
    }

    /// The same cuts, the same forecasts, the same rows, bit for bit, at any
    /// worker count; in the same order on disk or not.
    @Test(arguments: [2, 4, 8])
    func theRowsDoNotDependOnTheWorkerCount(workers: Int) async throws {
        let one = try Self.baseline.get()
        #expect(!one.isEmpty)
        let container = try Fixtures.seeded(cycles: 6)
        let rt = Self.runtime(container, workers: workers)
        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(try Self.rows(container) == one)
    }

    /// Every cycle's rows are saved, however the last handback and the last
    /// worker's leaving fall on the actor's side: a race here lost the end of a
    /// pass on a loaded Mac, and only a later pass made them again.
    @Test func everyHandbackIsCollected() async throws {
        let roster = ArenaRoster(registry: [Fixtures.peeker])
        for workers in [1, 4, 8] {
            for _ in 0..<4 {
                let container = try Fixtures.seeded(cycles: 3)
                let rt = Self.runtime(container, roster: roster, workers: workers)
                let r = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
                #expect(r.cycles == 3)
                #expect(r.outcomes == 3 * Fixtures.cuts)
                #expect(try Self.rows(container).count == 3 * Fixtures.cuts)
            }
        }
    }

    /// Workers on neighbouring cycles need nearly the same lattice: each child
    /// forecast is made once, however many of them ask, not once a worker. This
    /// is what makes more workers faster rather than only busier.
    @Test func eachChildIsMadeOnceHoweverManyWorkersAsk() async throws {
        func runs(workers: Int) async throws -> Int {
            let container = try Fixtures.seeded(cycles: 6)
            let rt = Self.runtime(container, roster: ArenaRoster(registry: [Self.child, Self.parent, Self.swallower]),
                                  workers: workers)
            Child.lock.withLock { Child.runs = 0 }
            _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
            return Child.lock.withLock { Child.runs }
        }
        let one = try await runs(workers: 1)
        #expect(one > 0)
        #expect(try await runs(workers: 8) == one)
    }

    /// The claim itself: one holder, a waiter gets it when it is released, and
    /// a waiter told to stop stops, holding nothing.
    @Test func aClaimHasOneHolderAndAWaiterCanStop() async throws {
        struct Stop: Error {}
        let flight = ArenaInFlight()
        #expect(flight.tryClaim("k"))
        #expect(!flight.tryClaim("k"))
        #expect(flight.tryClaim("other"))
        #expect(throws: Stop.self) { try flight.claim("k", check: { throw Stop() }) }
        let waiter = Task.detached {
            try flight.claim("k", check: {})
            flight.release("k")
        }
        try await Task.sleep(for: .milliseconds(30))
        flight.release("k")
        try await waiter.value
        #expect(flight.tryClaim("k"))
    }

    /// A bucket's training, asked from two threads at once, is done once.
    @Test func aBucketsTrainingIsDoneOnce() async throws {
        let cache = KitMLStateCache(capacity: 4)
        let trained = ArenaCancelFlag(), count = RuntimeRunnerMemoTests.Counts()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try? cache.value("meter", bucket: 7, sharesWork: true) {
                        count.add("train")
                        usleep(20_000)
                        trained.set(true)
                        return 1
                    }
                }
            }
        }
        #expect(trained.isSet)
        #expect(count.of("train") == 1)
    }

    /// A calibration layer over an analog: real child backtests through the
    /// shared memo, seconds a forecast unoptimised.
    @Test func aRealCalibrationLayerGivesTheSameRows() async throws {
        let roster = ArenaRoster(registry: ArenaRegistry.all, only: ["calib-g1-10-fable-analog"])
        var config = Self.config()
        config.sessionCycleCap = 2
        var rows: [Int: [String]] = [:]
        for workers in [1, 4] {
            let container = try Fixtures.seeded(cycles: 2)
            let rt = Self.runtime(container, config: config, roster: roster, workers: workers)
            _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
            rows[workers] = try Self.rows(container)
        }
        #expect(rows[1]?.isEmpty == false)
        #expect(rows[1] == rows[4])
    }

    /// A pass whose count keeps changing (a speed-up stopped, the Mac heating
    /// up, a pause): forecasts are abandoned part-way, cycles go back in the
    /// queue, and still nothing differs and nothing is lost.
    @Test func workersStoppingPartWayChangeNothing() async throws {
        let one = try Self.baseline.get()
        let container = try Fixtures.seeded(cycles: 6)
        let rt = Self.runtime(container, workers: 4)
        let churn = Task.detached {
            var i = 0
            let plan = [1, 4, 0, 2, 8, 3, 0, 4]
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(15))
                rt.budget.scorerWorkers = plan[i % plan.count]
                i += 1
            }
        }
        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        churn.cancel()
        _ = await churn.value
        #expect(try Self.rows(container) == one)
    }

    /// Quit part-way at any worker count: what was saved is right, and the
    /// next launch's pass finishes the same record.
    @Test func quittingPartWayAndResumingChangesNothing() async throws {
        let one = try Self.baseline.get()
        let container = try Fixtures.seeded(cycles: 6)
        var config = Self.config()
        config.flushOutcomes = 20
        let first = Self.runtime(container, config: config, workers: 4)
        let pass = Task.detached { await first.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now) }
        try await Task.sleep(for: .milliseconds(40))
        await first.stop()
        _ = await pass.value
        let saved = Set(try Self.rows(container))
        #expect(saved.isSubset(of: Set(one)))
        let second = Self.runtime(container, workers: 4)
        _ = await second.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(try Self.rows(container) == one)
    }

    /// A model that swallows its child's cancellation answers from less than
    /// it should: that answer is neither saved as a grade nor left in the memo
    /// for another worker.
    @Test func aForecastAbandonedPartWayLeavesNoTrace() async throws {
        // The worker's latch turns on after the forecast has begun, at the
        // first check inside it.
        let abandoned = ArenaCancelFlag()
        final class Checks: @unchecked Sendable {
            let lock = NSLock()
            var armed = false
            var left = 0
            func arm(after n: Int) { lock.withLock { armed = true; left = n } }
            func disarm() { lock.withLock { armed = false } }
            func next() -> Bool { lock.withLock { guard armed else { return false }; left -= 1; return left < 0 } }
        }
        let checks = Checks()
        let services = ArenaServices(weights: { _ in nil }, isCancelled: {
            if checks.next() { abandoned.set(true) }
            return abandoned.isSet
        }, isAbandoned: { abandoned.isSet })
        let memo = ArenaForecastMemo()
        let runner = ArenaRunner(registry: [Self.child, Self.swallower, Self.parent], services: services, memo: memo)
        let container = try Fixtures.seeded(cycles: 2)
        let built = ArenaHistoryBuilder.build(container: container, account: Fixtures.account, now: Fixtures.now,
                                              pricing: .init(pricingByModel: [:], ledger: .empty))
        let h = ArenaHistory(store: built.store, now: ArenaTime.millis(Fixtures.now), accounts: [Fixtures.account])
        let cycle = try #require(ArenaRunner.cycleAt(h.readings(account: Fixtures.account, windowKind: "five_hour"), now: h.now))
        let binding = ArenaWindowBinding(account: Fixtures.account, windowKey: "five_hour", target: .meterFiveHour, cap: nil)
        checks.arm(after: 1)
        // Past the runner's first check, nothing below can run: it answers
        // zero, from nothing, and that goes nowhere.
        let shallow = try runner.projection(model: "test-swallower", binding: binding, history: h, resetAt: cycle.resetAt)
        #expect(shallow.median.allSatisfy { $0 == 0 })
        #expect(memo.count == 0)
        checks.disarm()
        abandoned.set(false)
        // Once the worker is back the same question gets the true answer.
        let full = try runner.projection(model: "test-swallower", binding: binding, history: h, resetAt: cycle.resetAt)
        #expect(full.median.allSatisfy { $0 > 0 })
    }

    /// A paused grader runs nothing, holds no thread, and picks up where it
    /// stopped when the count comes back.
    @Test func aPausedGraderRunsNothingAndResumes() async throws {
        let one = try Self.baseline.get()
        let container = try Fixtures.seeded(cycles: 6)
        let rt = Self.runtime(container, workers: 2)
        rt.budget.scorerWorkers = 0
        Child.lock.withLock { Child.runs = 0 }
        let pass = Task.detached { await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(Child.lock.withLock { Child.runs } == 0)
        #expect(try Self.rows(container).isEmpty)
        rt.budget.scorerWorkers = 2
        _ = await pass.value
        #expect(try Self.rows(container) == one)
    }

    /// A worker's CPU counts as spent, but one let go leaves no debt for the
    /// worker that stays: at a fifth of a core, nine workers' last moments
    /// would be minutes of nothing.
    @Test func aWorkerLeavingLeavesNoDebt() {
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 0.2, burst: 0, clock: script.clock)
        script.thread = 2
        budget.mark()
        script.work(5)
        budget.leave()
        script.thread = 1
        budget.mark()
        let start = script.wall
        script.work(0.1)
        budget.checkpoint()
        // Only its own tenth of a second, not five seconds at a fifth of a core.
        #expect(script.wall - start < 1)
        #expect(abs(budget.totals.spent - 5.1) < 1e-9)
    }

    /// Several threads' CPU adds up against a rate of several cores, each by
    /// its own clock.
    @Test func severalThreadsShareARateOfSeveralCores() {
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 3, burst: 0, clock: script.clock)
        for t: UInt64 in 1...3 { script.thread = t; budget.mark() }
        let start = script.wall
        // Three threads, each 10 s of CPU. The scripted clock moves wall time
        // with each, so what matters is what was charged and that no thread
        // owed more than its share.
        for _ in 0..<100 {
            for t: UInt64 in 1...3 {
                script.thread = t
                script.work(0.1)
                budget.checkpoint()
            }
        }
        #expect(abs(budget.totals.spent - 30) < 1e-9)
        #expect(script.wall - start < 30.5)
    }

    /// At one core or less the workers wait for the live lane; at several the
    /// budget has room for both.
    @Test func theLiveLaneOnlyHoldsTheScorerBackAtOneCoreOrLess() {
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 1, burst: 0, clock: script.clock)
        budget.beginUrgent()
        budget.mark()
        let start = script.wall
        budget.checkpoint()
        #expect(script.wall - start >= ArenaCPUBudget.maxUrgentYield)
        budget.rate = 2
        let next = script.wall
        budget.checkpoint()
        #expect(script.wall - next < 0.01)
        budget.endUrgent()
    }

    /// Each network keeps as many workspaces as workers call it at once, and
    /// the count comes back down with the pass.
    @Test func aPassPutsTheScratchPolicyBack() async throws {
        let container = try Fixtures.seeded(cycles: 4)
        let rt = Self.runtime(container, workers: 3)
        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(FMScratch.keepPerNetwork == 1)
    }

    /// The board's time left is measured at the count running now: a pace at
    /// one core says nothing about nine, and until nine have been timed the
    /// board says no time rather than a wrong one.
    @Test func thePaceIsKeptPerWorkerCount() throws {
        var plan = ArenaRecordScorer.ProgressPlan()
        plan.visited(.cores(1))
        plan.visited(.cores(4))
        plan.visited(.cores(4))
        #expect(plan.pace.secondsPerCycle(.cores(1)) != nil)
        #expect(plan.pace.secondsPerCycle(.cores(4)) != nil)
        #expect(plan.pace.secondsPerCycle(.cores(9)) == nil)
        #expect(plan.pace.secondsPerCycle(.share) == nil)

        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let p = ArenaScoringProgress(phase: .cheap, cyclesDone: 0, cyclesTotal: 10, models: [], updatedAt: at,
                                     pace: .init(seconds: [.cores(1): 12, .cores(4): 3]), cyclesAhead: 10)
        #expect(p.eta(rate: .cores(4), now: at) == 30)
        #expect(p.eta(rate: .cores(1), now: at) == 120)
        #expect(p.eta(rate: .cores(9), now: at) == nil)

        #expect(ArenaBudgetPolicy.paceRate(.cores(9)) == .cores(9))
        #expect(ArenaBudgetPolicy.paceRate(.fullCore) == .cores(1))
        #expect(ArenaBudgetPolicy.paceRate(.share(.inUse)) == .share)
        #expect(ArenaBudgetPolicy.paceRate(.paused) == .share)

        let container = try Fixtures.seeded(cycles: 1)
        #expect(Self.runtime(container, workers: 4).scorer.currentRate == .cores(4))
    }

    @Test func theMemoGrowsWithTheWorkersBeyondTwo() {
        #expect(ArenaRecordScorer.memoLimit(3, workers: 0) == 3)
        #expect(ArenaRecordScorer.memoLimit(3, workers: 1) == 3)
        #expect(ArenaRecordScorer.memoLimit(3, workers: 2) == 3)
        #expect(ArenaRecordScorer.memoLimit(3, workers: 4) == 6)
        #expect(ArenaRecordScorer.memoLimit(3, workers: 8) == 12)
        #expect(ArenaRecordScorer.memoLimit(3, workers: 9) == 15)
    }

    @Test func theWorkerCountKeepsACoreFreeAndNeverDropsToNothing() {
        let gb: UInt64 = 1 << 30
        #expect(ArenaWorkerPolicy.maxWorkers(performanceCores: 10, physicalMemory: 48 * gb) == 9)
        #expect(ArenaWorkerPolicy.maxWorkers(performanceCores: 2, physicalMemory: 48 * gb) == 1)
        #expect(ArenaWorkerPolicy.maxWorkers(performanceCores: 1, physicalMemory: 48 * gb) == 1)
        // A small Mac: memory is the limit only at 8 GB.
        #expect(ArenaWorkerPolicy.maxWorkers(performanceCores: 4, physicalMemory: 16 * gb) == 3)
        #expect(ArenaWorkerPolicy.maxWorkers(performanceCores: 4, physicalMemory: 8 * gb) == 2)
        #expect(ArenaWorkerPolicy.maxWorkers(performanceCores: 10, physicalMemory: 24 * gb) == 9)
        #expect(ArenaWorkerPolicy.maxWorkers(performanceCores: 10, physicalMemory: 4 * gb) == 1)
        #expect(ArenaWorkerPolicy.forThisMac >= 1)
        #expect(ArenaWorkerPolicy.forThisMac <= ProcessInfo.processInfo.activeProcessorCount)
    }
}

/// Back-scoring under memory pressure (`ArenaMemoryHold`,
/// `ArenaBudgetPolicy.decide`) and through the governor, with a level the test
/// drives.
@Suite("Arena runtime: the memory hold")
struct RuntimeMemoryHoldTests {
    typealias Policy = ArenaBudgetPolicy
    static let idle = RuntimeBudgetGovernorTests.signals()
    static let inUse = RuntimeBudgetGovernorTests.signals(idle: 1)
    static let calm = ArenaMemoryHold.calmSeconds
    static let step = ArenaMemoryHold.rampStepSeconds

    static func hold(_ steps: [(MemoryPressure.Level, Double)]) -> ArenaMemoryHold {
        var h = ArenaMemoryHold()
        for (level, t) in steps { h.step(level: level, now: t) }
        return h
    }

    /// Only critical pauses; the calm counts from the moment it eased, down to
    /// warning or all the way; critical again starts it over.
    @Test func onlyCriticalPausesAndItsCalmCountsFromTheEasing() {
        #expect(!Self.hold([(.normal, 0)]).isPaused(now: 0))
        #expect(!Self.hold([(.warning, 0)]).isPaused(now: 0))
        #expect(Self.hold([(.critical, 0)]).isPaused(now: 0))
        #expect(Self.hold([(.critical, 0)]).isPaused(now: 10_000))
        let eased = Self.hold([(.critical, 0), (.normal, 100)])
        #expect(eased.isPaused(now: 100 + Self.calm - 1))
        #expect(!eased.isPaused(now: 100 + Self.calm))
        let toWarning = Self.hold([(.critical, 0), (.warning, 100)])
        #expect(toWarning.isPaused(now: 100 + Self.calm - 1))
        #expect(!toWarning.isPaused(now: 100 + Self.calm))
        let again = Self.hold([(.critical, 0), (.normal, 100), (.critical, 150), (.normal, 160)])
        #expect(again.isPaused(now: 100 + Self.calm))
        #expect(!again.isPaused(now: 160 + Self.calm))
    }

    /// One worker while there is any pressure and for the calm after, then one
    /// more per step, up to the Mac's count; pressure starts it over.
    @Test func theRampClimbsOneWorkerAtATimeAfterACalm() {
        #expect(Self.hold([]).workers(now: 0, maxWorkers: 9) == 9)
        #expect(Self.hold([(.normal, 0)]).workers(now: 0, maxWorkers: 9) == 9)
        #expect(Self.hold([(.warning, 0)]).workers(now: 10_000, maxWorkers: 9) == 1)
        let eased = Self.hold([(.warning, 0), (.normal, 50)])
        #expect(eased.workers(now: 50, maxWorkers: 9) == 1)
        #expect(eased.workers(now: 50 + Self.calm - 1, maxWorkers: 9) == 1)
        #expect(eased.workers(now: 50 + Self.calm, maxWorkers: 9) == 1)
        #expect(eased.workers(now: 50 + Self.calm + Self.step - 1, maxWorkers: 9) == 1)
        #expect(eased.workers(now: 50 + Self.calm + Self.step, maxWorkers: 9) == 2)
        #expect(eased.workers(now: 50 + Self.calm + 8 * Self.step, maxWorkers: 9) == 9)
        #expect(eased.workers(now: 50 + Self.calm + 100 * Self.step, maxWorkers: 9) == 9)
        var again = eased
        again.step(level: .warning, now: 50 + Self.calm + 3 * Self.step)
        #expect(again.workers(now: 50 + Self.calm + 3 * Self.step, maxWorkers: 9) == 1)
    }

    /// Memory before everything: a speed-up does not override it, nor does an
    /// idle Mac. Warning: one worker, the share, each window's pick. Critical:
    /// no worker, no live lane.
    @Test func aSpeedUpNeverOverridesTheHold() {
        let warned = Self.hold([(.warning, 0)])
        let critical = Self.hold([(.critical, 0)])
        for spedUp in [true, false] {
            for s in [Self.idle, Self.inUse] {
                let w = Policy.decide(s, spedUp: spedUp, hold: warned, now: 1, maxWorkers: 9, shareRate: 0.2)
                #expect(w.mode == .share(.lowMemory))
                #expect(w.workers == 1)
                #expect(w.rate == 0.2)
                #expect(w.liveLane == .picksOnly)
                let c = Policy.decide(s, spedUp: spedUp, hold: critical, now: 1, maxWorkers: 9, shareRate: 0.2)
                #expect(c.mode == .paused)
                #expect(c.workers == 0)
                #expect(c.rate == 0.2)
                #expect(c.liveLane == .none)
            }
        }
        // The calm after critical: still paused, and the live lane follows the
        // level as it is now.
        let calming = Self.hold([(.critical, 0), (.normal, 1)])
        let d = Policy.decide(Self.idle, hold: calming, now: 2, maxWorkers: 9, shareRate: 0.2)
        #expect(d.mode == .paused)
        #expect(d.liveLane == .all)
        // Hotter or in Low Power Mode, the Mac's first reason is the one said.
        #expect(Policy.decide(RuntimeBudgetGovernorTests.signals(thermal: .serious), hold: warned, now: 1,
                              shareRate: 0.2).mode == .share(.thermal))
    }

    /// The default does not change when Speed up is not on, whatever the Mac.
    @Test func theEverydayRuleIsUntouched() {
        for ac in [true, false] {
            for low in [true, false] {
                for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
                    for idle in [0.0, 119, 120, 600] {
                        let s = RuntimeBudgetGovernorTests.signals(ac: ac, lowPower: low, thermal: thermal, idle: idle)
                        let d = Policy.decide(s, maxWorkers: 9, shareRate: 0.2)
                        #expect(d.workers == 1)
                        #expect(d.liveLane == .all)
                        #expect(d.mode == Policy.mode(s))
                        #expect(d.rate == (d.mode == .fullCore ? 1 : 0.2))
                    }
                }
            }
        }
    }

    /// Plugged in, several cores. On battery, one. Hot or in Low Power Mode,
    /// the everyday share, sped up or not.
    @Test func whatASpeedUpGives() {
        let sig = RuntimeBudgetGovernorTests.signals
        func d(_ s: ArenaBudgetSignals, max: Int = 9) -> Policy.Decision {
            Policy.decide(s, spedUp: true, maxWorkers: max, shareRate: 0.2)
        }
        #expect(d(sig(true, false, .nominal, 0)).mode == .cores(9))
        #expect(d(sig(true, false, .nominal, 0)).workers == 9)
        #expect(d(sig(true, false, .nominal, 0)).rate == 9)
        #expect(d(sig(false, false, .nominal, 0)).mode == .fullCore)
        #expect(d(sig(false, false, .nominal, 0)).workers == 1)
        #expect(d(sig(true, false, .nominal, 0), max: 1).mode == .fullCore)
        #expect(d(sig(true, false, .serious, 0)).mode == .share(.thermal))
        #expect(d(sig(true, false, .serious, 0)).workers == 1)
        #expect(d(sig(true, true, .nominal, 0)).mode == .share(.lowPower))
        #expect(Policy.scorerQoS(.cores(9)) == QOS_CLASS_UTILITY)
        #expect(Policy.scorerQoS(.paused) == QOS_CLASS_BACKGROUND)
        #expect(Policy.scorerQoS(.share(.lowMemory)) == QOS_CLASS_BACKGROUND)
        #expect(Policy.telemetryName(.cores(9)) == "multi")
        #expect(Policy.telemetryName(.paused) == "paused")
        #expect(Policy.telemetryName(.share(.lowMemory)) == "fifth")
        #expect(Policy.describe(.cores(9), shareRate: 0.2, spedUp: true) == "9 cores (sped up)")
        #expect(Policy.describe(.paused, shareRate: 0.2) == "paused (low memory)")
        #expect(Policy.describe(.share(.lowMemory), shareRate: 0.2) == "20% of a core (low memory)")
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ s: TimeInterval) { lock.lock(); value = value.addingTimeInterval(s); lock.unlock() }
    }

    /// The governor is the one place that decides: pressure goes through it,
    /// its calm and ramp run on its clock, and it publishes what the board says.
    @Test func theGovernorHoldsAndRampsWithAnInjectedLevel() {
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 0.2, burst: 0, clock: script.clock)
        let pressure = MemoryPressure()
        let speedUp = ArenaSpeedUp()
        let clock = Clock()
        let s = RuntimeBudgetGovernorTests.Signals()
        s.set(Self.inUse)
        let g = ArenaBudgetGovernor(budget: budget, shareRate: 0.2, fullRate: 1, maxWorkers: 4, pressure: pressure,
                                    speedUp: speedUp, now: { clock.now }, read: { s.get() }, log: { s.log($0) })
        speedUp.start(now: clock.now)
        #expect(g.evaluate() == .cores(4))
        #expect(budget.rate == 4)
        #expect(budget.scorerWorkers == 4)
        #expect(budget.scorerQoS == QOS_CLASS_UTILITY)

        // A warning: one worker at the share, whatever was asked.
        pressure.set(.warning)
        #expect(g.evaluate() == .share(.lowMemory))
        #expect(budget.scorerWorkers == 1)
        #expect(budget.rate == 0.2)
        #expect(budget.scorerQoS == QOS_CLASS_BACKGROUND)
        #expect(budget.liveLane == .picksOnly)
        #expect(speedUp.currentPace?.mode == .share(.lowMemory))
        #expect(speedUp.currentPace?.isSpedUp == true)

        // Critical: nothing.
        pressure.set(.critical)
        #expect(g.evaluate() == .paused)
        #expect(budget.scorerWorkers == 0)
        #expect(budget.rate == 0.2)
        #expect(budget.liveLane == .none)
        #expect(speedUp.currentPace?.mode == .paused)

        // Eased: the pause holds through its calm, the live lane does not.
        pressure.set(.normal)
        #expect(g.evaluate() == .paused)
        #expect(budget.liveLane == .all)
        clock.advance(ArenaMemoryHold.calmSeconds - 1)
        #expect(g.evaluate() == .paused)
        clock.advance(1)
        // One worker first, a sped-up one, then a step at a time.
        #expect(g.evaluate() == .fullCore)
        #expect(budget.scorerWorkers == 1)
        #expect(budget.rate == 1)
        clock.advance(ArenaMemoryHold.rampStepSeconds)
        #expect(g.evaluate() == .cores(2))
        #expect(budget.scorerWorkers == 2)
        #expect(budget.rate == 2)
        clock.advance(ArenaMemoryHold.rampStepSeconds)
        #expect(g.evaluate() == .cores(3))
        clock.advance(10 * ArenaMemoryHold.rampStepSeconds)
        #expect(g.evaluate() == .cores(4))
        #expect(s.logged.contains("budget: paused (low memory)"))
        #expect(s.logged.contains("budget: 20% of a core (low memory)"))
        #expect(s.logged.contains("budget: 3 cores (sped up)"))

        // A warning mid-speed-up and it eases: the calm again, at one worker.
        pressure.set(.warning)
        #expect(g.evaluate() == .share(.lowMemory))
        pressure.set(.normal)
        #expect(g.evaluate() == .fullCore)
        #expect(budget.scorerWorkers == 1)
        clock.advance(ArenaMemoryHold.calmSeconds + ArenaMemoryHold.rampStepSeconds)
        #expect(g.evaluate() == .cores(2))

        // Click to stop: back to the everyday rule, at one worker, at once.
        speedUp.stop(now: clock.now)
        #expect(g.evaluate() == .share(.inUse))
        #expect(budget.scorerWorkers == 1)
        #expect(budget.rate == 0.2)
    }

    /// With no speed-up, a warning only lowers an idle Mac's full core to the
    /// share, and the everyday rule comes straight back when it eases.
    @Test func aWarningWithoutASpeedUpIsOnlyTheEverydayShare() {
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 0.2, burst: 0, clock: script.clock)
        let pressure = MemoryPressure()
        let clock = Clock()
        let g = ArenaBudgetGovernor(budget: budget, shareRate: 0.2, fullRate: 1, maxWorkers: 4, pressure: pressure,
                                    now: { clock.now }, read: { Self.idle }, log: { _ in })
        #expect(g.evaluate() == .fullCore)
        pressure.set(.warning)
        #expect(g.evaluate() == .share(.lowMemory))
        #expect(budget.scorerWorkers == 1)
        #expect(budget.rate == 0.2)
        pressure.set(.normal)
        #expect(g.evaluate() == .fullCore)
        #expect(budget.scorerWorkers == 1)
        #expect(budget.rate == 1)
    }

    /// A change of level reaches a running governor by itself, not at its next
    /// tick.
    @Test func aRunningGovernorHearsTheLevelChange() async {
        let script = RuntimeBudgetTests.Script()
        let budget = ArenaCPUBudget(rate: 0.2, burst: 0, clock: script.clock)
        let pressure = MemoryPressure()
        let g = ArenaBudgetGovernor(budget: budget, shareRate: 0.2, fullRate: 1, pressure: pressure,
                                    read: { Self.inUse }, log: { _ in })
        g.start()
        defer { g.stop() }
        // Generously: a utility queue can wait a long while on a loaded Mac.
        for _ in 0..<24_000 where g.current == nil { try? await Task.sleep(for: .milliseconds(5)) }
        pressure.set(.critical)
        for _ in 0..<24_000 where budget.scorerWorkers != 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(budget.scorerWorkers == 0)
        #expect(g.current == .paused)
    }

    /// The live lane under pressure: a warning leaves each window's pick and
    /// nothing else; critical, nothing.
    @Test func theLiveLaneFollowsTheLevel() async throws {
        let container = try RuntimeEngineTests.seeded()
        let rt = RuntimeWorkersTests.runtime(container, config: RuntimeWorkersTests.config(),
                                             roster: ArenaRoster(registry: [RuntimeEngineTests.oracle, RuntimeEngineTests.peeker]),
                                             workers: 1)
        let account = RuntimeEngineTests.account
        let binding = ArenaWindowBinding(account: account, windowKey: "five_hour", target: .meterFiveHour, cap: nil)
        let reset = RuntimeEngineTests.now.addingTimeInterval(3 * 3600)
        let pick = ArenaLiveCache.Key(account: account, windowKey: "five_hour", model: "test-oracle")
        let other = ArenaLiveCache.Key(account: account, windowKey: "five_hour", model: "test-peeker")
        let request = ArenaLiveRequest(binding: binding, resetsAt: reset, latestReadingAt: RuntimeEngineTests.now,
                                       models: ["test-oracle", "test-peeker"])
        rt.budget.liveLane = .none
        await rt.live.submit([request])
        await rt.live.settle()
        #expect(rt.cache.entry(pick) == nil)
        rt.budget.liveLane = .picksOnly
        await rt.live.submit([request])
        await rt.live.settle()
        #expect(rt.cache.entry(pick) != nil)
        #expect(rt.cache.entry(other) == nil)
        rt.budget.liveLane = .all
        await rt.live.submit([request])
        await rt.live.settle()
        #expect(rt.cache.entry(other) != nil)
    }

    /// A full read waits out pressure, up to its bound, so a busy Mac still
    /// gets one; a paused grader reads nothing however long it takes.
    @Test func aFullReadWaitsOutPressureButNotForever() async throws {
        let container = try RuntimeEngineTests.seeded(cycles: 2)
        var config = RuntimeWorkersTests.config()
        config.fullReadWait = 0.2
        let rt = RuntimeWorkersTests.runtime(container, config: config, workers: 1)
        rt.budget.liveLane = .picksOnly
        let clock = ContinuousClock(), t0 = clock.now
        _ = await rt.scorer.pass(accounts: [RuntimeEngineTests.account], now: RuntimeEngineTests.now)
        #expect(clock.now - t0 >= .seconds(0.2))

        let reading = RuntimeWorkersTests.runtime(container, config: config, workers: 0)
        rt.budget.liveLane = .all
        let pass = Task.detached { await reading.scorer.pass(accounts: [RuntimeEngineTests.account], now: RuntimeEngineTests.now) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reading.progress.progress(account: RuntimeEngineTests.account)?.readingHistory == true)
        reading.budget.scorerWorkers = 1
        _ = await pass.value
        #expect(reading.progress.progress(account: RuntimeEngineTests.account) == nil)
    }
}
