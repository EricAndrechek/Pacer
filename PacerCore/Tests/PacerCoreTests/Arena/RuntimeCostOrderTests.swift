import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The scorer does the cheap models first (`ArenaModelCosts`,
/// `ArenaRecordScorer` phases): every cycle in depth for the models that cost
/// milliseconds, before the first forecast of one that costs seconds; and
/// every window's first turn covers the cycles selection needs.
@Suite("Arena runtime: cheap models first", .serialized)
struct RuntimeCostOrderTests {

    typealias Fixtures = RuntimeEngineTests

    /// The peeker under another name, so two can be told apart.
    static let heavy = ArenaModelSpec(name: "test-heavy", targets: Fixtures.meters, complexity: 3) {
        Fixtures.Peeker(context: $0)
    }

    /// The peeker, after burning about `spinMs` of CPU.
    final class Spinner: ArenaModel {
        static let spinMs = 30.0
        let inner: Fixtures.Peeker
        init(context: ArenaContext) { inner = Fixtures.Peeker(context: context) }
        func fit(_ history: ArenaHistory) { inner.fit(history) }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            let start = ArenaCPUBudget.Clock.system.threadCPU()
            var x = 0.0
            while ArenaCPUBudget.Clock.system.threadCPU() - start < Self.spinMs / 1000 { x += sin(x + 1) }
            _ = x
            return try inner.forecast(request)
        }
    }
    static let spinner = ArenaModelSpec(name: "test-spinner", targets: Fixtures.meters) { Spinner(context: $0) }

    /// Every batch, with whose it is.
    final class Landed: @unchecked Sendable {
        let lock = NSLock()
        var outcomes: [(account: String, outcome: EngineSelfEval.NewOutcome)] = []
        func add(_ account: String, _ b: [EngineSelfEval.NewOutcome]) {
            lock.lock(); outcomes += b.map { (account, $0) }; lock.unlock()
        }
        var all: [(account: String, outcome: EngineSelfEval.NewOutcome)] { lock.lock(); defer { lock.unlock() }; return outcomes }
    }

    static func runtime(_ container: ModelContainer, roster: [ArenaModelSpec], costs: ArenaModelCosts,
                        config: ArenaRecordScorer.Config, landed: Landed) -> ArenaRuntime {
        ArenaRuntime(container: container, roster: ArenaRoster(registry: roster), config: config, costs: costs,
                     onRecordLanded: { account, news in landed.add(account, news) }, onLiveLanded: { _ in })
    }

    /// A batch a cycle, so the order things were scored in is the order
    /// they land.
    static func perCycle() -> ArenaRecordScorer.Config {
        var c = Fixtures.noSleep()
        c.flushOutcomes = 1
        return c
    }

    // MARK: Priors and averages

    @Test func priorsAreConservativeAboutNetworksAndParents() {
        func spec(_ name: String, weights: [String] = [], children: [String] = []) -> ArenaModelSpec {
            ArenaModelSpec(name: name, targets: Fixtures.meters, children: children, weights: weights) {
                Fixtures.Peeker(context: $0)
            }
        }
        let specs = [
            spec("plain"),
            spec("small-net", weights: [FMWeights.timestral5M]),
            spec("unsized-net", weights: [ChronosWeights.chronos2]),
            spec("big-net", weights: [FMWeights.timestral123M]),
            spec("calib-plain", children: ["plain"]),
            spec("pool", children: ["plain", "small-net"]),
            spec("over-big", children: ["big-net"]),
        ]
        let registry = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
        func prior(_ n: String) -> Double { ArenaModelCosts.prior(registry[n]!, registry: registry) }
        #expect(prior("plain") == 10)
        #expect(prior("small-net") == 100)
        #expect(prior("unsized-net") == 100)
        #expect(prior("big-net") == 3000)
        #expect(prior("calib-plain") == 30)
        #expect(prior("pool") == 10 + 2 * (10 + 100))
        #expect(prior("over-big") == 10 + 2 * 3000)
        #expect(ArenaModelCosts.networkMillions(FMWeights.timestral209M) == 209)
        #expect(ArenaModelCosts.networkMillions("google/timesfm-2.5-200m-pytorch@abc") == 200)
        #expect(ArenaModelCosts.networkMillions(ChronosWeights.chronos2) == nil)
        // A cycle of children ends rather than recursing forever.
        let loop = Dictionary(uniqueKeysWithValues: [spec("a", children: ["b"]), spec("b", children: ["a"])]
            .map { ($0.name, $0) })
        #expect(ArenaModelCosts.prior(loop["a"]!, registry: loop) == 30)
    }

    @Test func averagesMoveSlowlyAndSurviveARelaunch() throws {
        let suite = "pacer.test.arena-costs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let costs = ArenaModelCosts(defaults: defaults)
        #expect(costs.measured("m", weekly: false) == nil)
        costs.record("m", weekly: false, cpuMs: 200)
        #expect(costs.measured("m", weekly: false) == 200)
        costs.record("m", weekly: false, cpuMs: 100)
        #expect(abs(costs.measured("m", weekly: false)! - 190) < 1e-9)
        costs.record("m", weekly: true, cpuMs: 7)
        #expect(costs.measured("m", weekly: true) == 7)
        costs.save()
        let again = ArenaModelCosts(defaults: defaults)
        #expect(abs(again.measured("m", weekly: false)! - 190) < 1e-9)
        #expect(again.measured("m", weekly: true) == 7)
        // A measured cost wins over the prior.
        let spec = ArenaModelSpec(name: "m", targets: Fixtures.meters, weights: [FMWeights.timestral209M]) {
            Fixtures.Peeker(context: $0)
        }
        #expect(again.cost(spec, weekly: true, registry: ["m": spec]) == 7)
    }

    // MARK: Order

    /// A model timed at seconds a forecast waits until every cheap one has
    /// covered every cycle, then is scored over all of them too.
    @Test func cheapModelsCoverEveryCycleBeforeAHeavyOne() async throws {
        let container = try Fixtures.seeded(cycles: 12)
        let costs = ArenaModelCosts(defaults: nil)
        costs.record("test-heavy", weekly: false, cpuMs: 5000)
        let landed = Landed()
        let rt = Self.runtime(container, roster: [Fixtures.peeker, Self.heavy], costs: costs,
                              config: Self.perCycle(), landed: landed)
        let report = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        let order = landed.all.map(\.outcome)
        let firstHeavy = try #require(order.firstIndex { $0.method == "test-heavy" })
        let lastCheap = try #require(order.lastIndex { $0.method == "test-peeker" })
        #expect(lastCheap < firstHeavy)
        // Both end with the same cycles.
        let cheapPeriods = Set(order.filter { $0.method == "test-peeker" }.map(\.periodKey))
        let heavyPeriods = Set(order.filter { $0.method == "test-heavy" }.map(\.periodKey))
        #expect(cheapPeriods.count == 12)
        #expect(heavyPeriods == cheapPeriods)
        #expect(report.phaseCycles[1] == 12)
        #expect(report.phaseCycles[2] == 12)
        // A second pass has nothing left in either phase.
        let again = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(again.forecasts == 0)
    }

    /// A model whose prior said cheap but which times heavy here leaves
    /// phase 1 after the cycle it was timed in (its first forecast on a
    /// runner is not timed), and its cost is remembered.
    @Test func aModelTimedHeavierThanItsPriorMovesToPhaseTwo() async throws {
        let container = try Fixtures.seeded(cycles: 10)
        let costs = ArenaModelCosts(defaults: nil)
        var config = Self.perCycle()
        // Above the arithmetic prior (10 ms), below the spinner.
        config.cheapCostMs = 15
        let landed = Landed()
        let rt = Self.runtime(container, roster: [Fixtures.peeker, Self.spinner], costs: costs,
                              config: config, landed: landed)
        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        let order = landed.all.map(\.outcome)
        let lastCheap = try #require(order.lastIndex { $0.method == "test-peeker" })
        let spunEarly = order[...lastCheap].filter { $0.method == "test-spinner" }
        #expect(spunEarly.count <= config.grading.cuts.count)
        #expect(Set(order.filter { $0.method == "test-spinner" }.map(\.periodKey)).count == 10)
        let timed = try #require(costs.measured("test-spinner", weekly: false))
        #expect(timed > config.cheapCostMs)
        #expect((costs.measured("test-peeker", weekly: false) ?? .infinity) <= config.cheapCostMs)
    }

    /// `n` completed five-hour cycles for each account, as `seeded` makes them.
    static func seeded(accounts: [String], cycles: Int) throws -> ModelContainer {
        let container = try PacerStore.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let now = Fixtures.now
        for (i, account) in accounts.enumerated() {
            ctx.insert(Account(id: account, organizationId: account, displayName: "Test \(i)", isActive: i == 0,
                               firstSeenAt: now.addingTimeInterval(-90 * 86400), lastSeenAt: now))
            let liveStart = now.addingTimeInterval(-2 * 3600)
            for c in 0...cycles {
                let start = liveStart.addingTimeInterval(-Double(cycles - c) * (Fixtures.fiveHours + 3600))
                let reset = start.addingTimeInterval(Fixtures.fiveHours)
                var t = start.addingTimeInterval(300)
                while t < reset && t <= now {
                    let h = t.timeIntervalSince(start) / 3600
                    ctx.insert(RateLimitSample(sampledAt: t, window: "five_hour", usedPercentage: (h * 8).rounded(),
                                               resetsAt: reset, source: "oauth", accountId: account))
                    t = t.addingTimeInterval(600)
                }
            }
        }
        try ctx.save()
        return container
    }

    /// Every window's first turn scores the cycles selection needs before any
    /// window goes deeper; after that, a few cycles a turn.
    @Test func everyWindowGetsEnoughCyclesToBePickedFirst() async throws {
        let accounts = ["acct-first", "acct-second"]
        let container = try Self.seeded(accounts: accounts, cycles: 14)
        var config = Self.perCycle()
        config.sessionCyclesPerTurn = 1
        let landed = Landed()
        let rt = Self.runtime(container, roster: [Fixtures.peeker], costs: ArenaModelCosts(defaults: nil),
                              config: config, landed: landed)
        _ = await rt.scorer.pass(accounts: accounts, now: Fixtures.now)
        // The cycles in the order they were visited, by account.
        var visits: [(String, String)] = []
        for (account, o) in landed.all where !visits.contains(where: { $0 == (account, o.periodKey) }) {
            visits.append((account, o.periodKey))
        }
        let need = EngineSelfEval.rlMinPeriods(weekly: false)
        #expect(visits.count == 2 * 14)
        #expect(visits.prefix(need).allSatisfy { $0.0 == "acct-first" })
        #expect(visits.dropFirst(need).prefix(need).allSatisfy { $0.0 == "acct-second" })
        // Then one a turn each.
        #expect(visits[2 * need].0 == "acct-first")
        #expect(visits[2 * need + 1].0 == "acct-second")
    }
}

/// The window's drawn arena models: the pick, then the best-ranked others,
/// counting only models ranked over the shared span (`rlMinPeriods` cycles
/// graded). The cheap models are graded first, so for hours a heavy one has a
/// cycle or two, and an error from one cycle must not draw it ahead of a real
/// record.
@Suite("Arena runtime: the drawn models need a record")
struct RuntimeCompareListTests {

    /// `periods` cycles ending at the newest, missing by `err` at every cut.
    static func rows(_ m: String, err: Double, periods: Int) -> [EngineSelfEval.Record] {
        (0..<periods).flatMap { i in
            EngineSelfEval.rlCutFractions.map { cut in
                EngineSelfEval.Record(method: m, bucket: EngineSelfEval.rlBucket(cut),
                                      periodKey: EngineSelfEval.periodKeyRL(Date(timeIntervalSince1970: 1_800_000_000
                                                                                 - Double(i) * 18000)),
                                      predicted: 50 + err, truth: 50)
            }
        }
    }

    @Test func aModelWithTooFewCyclesIsNotDrawn() {
        let names = ["arena-a", "arena-b", "arena-c", "arena-d"]
        let roster = ArenaRoster(registry: names.map { n in
            ArenaModelSpec(name: n, targets: RuntimeEngineTests.meters) { RuntimeEngineTests.Peeker(context: $0) }
        })
        let link = ArenaEngineLink(roster: roster, cache: ArenaLiveCache(), compareLimit: 3, requestLive: { _ in })
        for (kind, weekly) in [(RateLimitWindowKind.fiveHour, false), (.sevenDay, true)] {
            let need = EngineSelfEval.rlMinPeriods(weekly: weekly)
            let records = Self.rows("arena-a", err: 0.5, periods: 1)          // best error, one cycle
                + Self.rows("arena-b", err: 2, periods: need)
                + Self.rows("arena-c", err: 3, periods: need + 5)
                + Self.rows("arena-d", err: 1, periods: need - 1)
            let ranking = EngineSelfEval.rankRL(records, weekly: weekly, at: nil, depth: EngineSelfEval.rlDepth(weekly: weekly))
            let listed = UsageIntelligenceEngine.arenaRoster(window: .fixed(kind), account: "acct", arena: link,
                                                             pick: nil, ranking: ranking).models.map(\.id)
            #expect(listed == ["arena-b", "arena-c"])
            // The pick is drawn whatever its record (selection already
            // required one).
            let withPick = UsageIntelligenceEngine.arenaRoster(window: .fixed(kind), account: "acct", arena: link,
                                                               pick: "arena-a", ranking: ranking).models.map(\.id)
            #expect(withPick == ["arena-a", "arena-b", "arena-c"])
        }
    }
}
