import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// A pruned arena model (`EngineSelfEval.arenaLosers`) stops only the deep
/// back-fill: it is still scored on every cycle that completes, so its record
/// keeps up with the user, and a model that starts winning on recent cycles
/// becomes the pick.
@Suite("Arena runtime: pruned models keep being scored", .serialized)
struct RuntimePrunedModelsTests {

    typealias Fixtures = RuntimeEngineTests

    static let cycles = 64
    /// Cycle `c`'s reset, as `RuntimeEngineTests.seeded` lays them out (the
    /// live cycle is `cycles`).
    static func reset(_ c: Int) -> Date {
        let liveStart = Fixtures.now.addingTimeInterval(-2 * 3600)
        return liveStart.addingTimeInterval(-Double(cycles - c) * (Fixtures.fiveHours + 3600) + Fixtures.fiveHours)
    }
    /// Half an hour after cycle 31's reset: cycles 0–31 have completed.
    static let earlier = reset(31).addingTimeInterval(1800)

    /// The oracle, off by ten points on every cycle that reset before
    /// `turnsAt` and exact after: a model the user's habits caught up with.
    final class Turncoat: ArenaModel {
        nonisolated(unsafe) static var turnsAt: Millis = 0
        let inner: Fixtures.Oracle
        init(context: ArenaContext) { inner = Fixtures.Oracle(context: context) }
        func fit(_ history: ArenaHistory) { inner.fit(history) }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            let exact = try inner.forecast(request)
            var out: [String: ArenaTargetForecast] = [:]
            for tr in request.targets {
                guard let fc = exact.byKey[tr.key] else { continue }
                let off = (tr.resetAt ?? 0) < Self.turnsAt ? 10.0 : 0
                out[tr.key] = .point(fc.median.map { $0 + off })
            }
            return ArenaForecast(byKey: out)
        }
    }
    static let turncoat = ArenaModelSpec(name: "test-turncoat", targets: Fixtures.meters, complexity: 1) {
        Turncoat(context: $0)
    }

    /// Each engine method's record on cycles `range`: `linearRecentMiss`
    /// points off for `linear-recent`, `otherMiss` for the rest, as the
    /// refit would have saved them (so it saves none of its own over them).
    static func engineRecord(_ container: ModelContainer, _ range: ClosedRange<Int>, linearRecentMiss: Double,
                             otherMiss: Double, methods: [String] = RateLimitRoster.engineIds) throws {
        let ctx = ModelContext(container)
        let surface = EngineScope.account(Fixtures.account).qualify(EngineSelfEval.rlSurface("five_hour"))
        for c in range {
            let period = EngineSelfEval.periodKeyRL(reset(c))
            for method in methods {
                let miss = method == "linear-recent" ? linearRecentMiss : otherMiss
                for cf in EngineSelfEval.rlCutFractions {
                    ctx.insert(EngineEvalOutcome(surface: surface, method: method, bucket: EngineSelfEval.rlBucket(cf),
                                                 periodKey: period, predicted: 50 + miss, truth: 50))
                }
            }
        }
        try ctx.save()
    }

    static func periods(_ container: ModelContainer, method: String) throws -> Set<String> {
        Set(try Fixtures.arenaRows(container, method: method).map(\.periodKey))
    }

    /// Two models fall clearly behind and are pruned; a cycle later, every
    /// model is scored on the cycle that completed, the pruned ones
    /// included, and nobody goes deeper.
    @Test func aNewlyCompletedCycleIsScoredForEveryModel() async throws {
        Turncoat.turnsAt = .max      // off by ten throughout
        let container = try Fixtures.seeded(cycles: Self.cycles)
        try Self.engineRecord(container, 0...Self.cycles - 1, linearRecentMiss: 0, otherMiss: 0,
                              methods: ["linear-recent"])
        let rt = Fixtures.runtime(container, roster: [Fixtures.oracle, Fixtures.peeker, Self.turncoat])
        let first = await rt.scorer.pass(accounts: [Fixtures.account], now: Self.earlier)
        #expect(try Self.periods(container, method: "test-oracle").count == 32)
        #expect(try Self.periods(container, method: "test-turncoat").count == 24)
        #expect(try Self.periods(container, method: "test-peeker").count == 24)
        #expect(first.cycles > 0)

        // One more cycle completes.
        let next = Self.reset(32).addingTimeInterval(1800)
        let second = await rt.scorer.pass(accounts: [Fixtures.account], now: next)
        #expect(second.cycles == 1)
        #expect(second.forecasts == 3 * 8)
        let newest = EngineSelfEval.periodKeyRL(Self.reset(32))
        for m in ["test-oracle", "test-peeker", "test-turncoat"] {
            let rows = try Fixtures.arenaRows(container, method: m).filter { $0.periodKey == newest }
            #expect(rows.count == 8, "\(m) scored on the new cycle")
        }
        #expect(try Self.periods(container, method: "test-turncoat").count == 25)
        #expect(try Self.periods(container, method: "test-peeker").count == 25)
        // Nothing left: a third pass scores nothing.
        #expect(await rt.scorer.pass(accounts: [Fixtures.account], now: next).forecasts == 0)
    }

    /// A model well behind the engine's best is pruned; the user's habits
    /// change, it is scored on every cycle since (never the deep ones it
    /// skipped), and once its recent record outweighs the old one the
    /// record picks it.
    @Test func aPrunedModelThatStartsWinningBecomesThePick() async throws {
        Turncoat.turnsAt = ArenaTime.millis(Self.earlier)
        let container = try Fixtures.seeded(cycles: Self.cycles)
        // Until the change the engine's straight line was exact and the
        // rest five points off; after it, every engine method is five off.
        try Self.engineRecord(container, 0...31, linearRecentMiss: 0, otherMiss: 5)
        try Self.engineRecord(container, 32...Self.cycles - 1, linearRecentMiss: 5, otherMiss: 5)
        let engine = await Fixtures.engine(container)
        let rt = Fixtures.runtime(container, roster: [Self.turncoat], engine: engine)
        await engine.adopt(arena: rt.link)

        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Self.earlier)
        let pruned = try Self.periods(container, method: "test-turncoat")
        #expect(pruned.count == 24)
        await engine.recompute(now: Self.earlier)
        #expect(await engine.resolvedMethod(windowKey: "five_hour").selected == "linear-recent")

        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        let scored = try Self.periods(container, method: "test-turncoat")
        // Every cycle since its newest, and not the eight older ones it
        // never had.
        let since = Set((32...Self.cycles - 1).map { EngineSelfEval.periodKeyRL(Self.reset($0)) })
        #expect(scored == pruned.union(since))
        #expect(!scored.contains(EngineSelfEval.periodKeyRL(Self.reset(0))))

        await engine.recompute(now: Fixtures.now)
        #expect(await engine.resolvedMethod(windowKey: "five_hour").selected == "test-turncoat")
    }

    /// Where a loser stops: above its newest scored cycle, never short of
    /// the recent few; all of depth when it has nothing there.
    @Test func theShallowBound() {
        typealias K = ArenaRecordScorer.DoneKey
        let existing: Set<K> = [K(model: 1, cut: 0, period: 12), K(model: 1, cut: 3, period: 20), K(model: 2, cut: 0, period: 2)]
        #expect(ArenaRecordScorer.shallowBound(model: 1, existing: existing, cycles: 40, recent: 8) == 12)
        #expect(ArenaRecordScorer.shallowBound(model: 2, existing: existing, cycles: 40, recent: 8) == 8)
        #expect(ArenaRecordScorer.shallowBound(model: 3, existing: existing, cycles: 40, recent: 8) == 40)
        #expect(ArenaRecordScorer.shallowBound(model: nil, existing: existing, cycles: 5, recent: 8) == 8)
    }
}
