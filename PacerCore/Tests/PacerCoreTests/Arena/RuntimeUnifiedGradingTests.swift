import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// One roster, one grader, one ranking: the engine's curve fits and the arena
/// models are graded on the same cuts of the same cycles into the same rows,
/// ranked over the same span at the point of the window the live cycle is at,
/// and none is pruned.
@Suite("Runtime: one ranking for every model")
struct RuntimeUnifiedRankingTests {

    /// Cycle `p` of a synthetic five-hour history, oldest first.
    static func periodKey(_ p: Int) -> String {
        EngineSelfEval.periodKeyRL(Date(timeIntervalSince1970: 1_800_000_000 + Double(p) * 5 * 3600))
    }

    /// One record per cut of `grading` for each cycle in `periods`, missing
    /// by `miss(p, cut)` points.
    static func records(_ method: String, _ periods: Range<Int>,
                        grading: EngineSelfEval.RLGrading = EngineSelfEval.rlGrading,
                        miss: (Int, Double) -> Double) -> [EngineSelfEval.Record] {
        periods.flatMap { p in
            grading.cuts.map { cut in
                EngineSelfEval.Record(method: method, bucket: grading.bucket(cut), periodKey: periodKey(p),
                                      predicted: 50 + miss(p, cut), truth: 50)
            }
        }
    }

    static func rank(_ rows: [EngineSelfEval.Record], at x: Double? = nil, weekly: Bool = false,
                     grading: EngineSelfEval.RLGrading = EngineSelfEval.rlGrading,
                     complexity: [String: Int] = [:]) -> EngineSelfEval.RLRanking {
        EngineSelfEval.rankRL(rows, grading: grading, complexity: complexity, weekly: weekly, at: x,
                              depth: EngineSelfEval.rlDepth(weekly: weekly), tieRelative: 0.05)
    }

    // MARK: Grading

    @Test func twelveCutsUnderANewBucketVersion() {
        let g = EngineSelfEval.rlGrading
        #expect(g.cuts.count == 12)
        #expect(g.cuts.first == 0.1 && g.cuts.last == 0.925)
        #expect(zip(g.cuts, g.cuts.dropFirst()).allSatisfy { abs($1 - $0 - 0.075) < 1e-9 })
        #expect(EngineSelfEval.rlBucket(0.175) == "cut=0.175|v3")
        #expect(EngineSelfEval.rlCutFraction("cut=0.175|v3") == 0.175)
        #expect(EngineSelfEval.isCurrentRLBucket("cut=0.175|v3"))
        #expect(!EngineSelfEval.isCurrentRLBucket("cut=0.20|v2"))
        #expect(EngineSelfEval.isReadRLBucket("cut=0.20|v2"))
        #expect(!EngineSelfEval.isReadRLBucket("cut=0.20"))
        #expect(EngineSelfEval.previousRLGrading.bucket(0.2) == "cut=0.20|v2")
    }

    @Test func weightedStatisticsAreTheUnweightedOnesAtEqualWeights() {
        for xs in [[3.0], [1, 5], [4, 1, 9], [2, 8, 3, 7], [0, 0, 1, 10, 12]] {
            let w = xs.map { (error: $0, weight: 1.0) }
            #expect(EngineSelfEval.weightedMedian(w) == EngineSelfEval.median(xs), "\(xs)")
            #expect(abs(EngineSelfEval.weightedMean(w) - EngineSelfEval.mean(xs)) < 1e-12)
        }
        // A weight counts as that many copies.
        #expect(EngineSelfEval.weightedMedian([(1, 3), (10, 1)]) == 1)
        #expect(EngineSelfEval.weightedMedian([(1, 1), (10, 3)]) == 10)
        #expect(EngineSelfEval.weightedMedian([(1, 0), (10, 0)]) == .infinity)
    }

    // MARK: Matching the live point

    @Test func eachCutCountsByItsClosenessToNow() {
        #expect(EngineSelfEval.cutWeight(0.4, at: nil) == 1)
        #expect(EngineSelfEval.cutWeight(0.4, at: 0.4) == 1)
        #expect(abs(EngineSelfEval.cutWeight(0.5, at: 0.4) - 0.5) < 1e-12)
        #expect(EngineSelfEval.cutWeight(0.6, at: 0.4) == 0)
        #expect(EngineSelfEval.cutWeight(0.9, at: 0.1) == 0)
    }

    /// One model reads the start of a window best, the other its end: the
    /// pick follows the live cycle along the window, with no jump at a
    /// half-way line.
    @Test func thePickFollowsTheLiveCycleAlongTheWindow() throws {
        let rows = Self.records("early-reader", 0..<20) { _, cut in cut < 0.5 ? 1 : 8 }
            + Self.records("late-reader", 0..<20) { _, cut in cut < 0.5 ? 7 : 0.5 }
        #expect(Self.rank(rows, at: 0.1).pick == "early-reader")
        #expect(Self.rank(rows, at: 0.3).pick == "early-reader")
        #expect(Self.rank(rows, at: 0.7).pick == "late-reader")
        #expect(Self.rank(rows, at: 0.95).pick == "late-reader")
        // The number shown is the matched one: at the start, the early cuts'.
        let early = try #require(Self.rank(rows, at: 0.1).standing("early-reader")?.typicalAbsError)
        #expect(early == 1)
        // A cycle just begun still has cuts near it (the grid starts at 0.1).
        #expect(Self.rank(rows, at: 0.0).at == 0.1)
    }

    // MARK: The span

    /// The engine's method graded over 61 cycles, two arena models over the
    /// newest 24 (still catching up): every number covers those 24.
    @Test func everyRankedNumberCoversTheSameCycles() throws {
        let rows = Self.records("linear-recent", 0..<61) { p, _ in p < 37 ? 6 : 2 }
            + Self.records("arena-a", 37..<61) { _, _ in 1 } + Self.records("arena-b", 37..<61) { _, _ in 1.5 }
        let r = Self.rank(rows)
        #expect(r.span == .init(start: Self.periodKey(37), cycles: 24, isWholeRecord: false))
        #expect(r.standing("linear-recent")?.typicalAbsError == 2)
        #expect(r.standing("linear-recent")?.cycles == 61)
        #expect(r.standing("linear-recent")?.spanCycles == 24)
        #expect(r.pick == "arena-a")
        #expect(r.standings.map(\.method) == ["arena-a", "arena-b", "linear-recent"])
        // The sheet's rows are the ranking's numbers.
        let acc = r.accuracy(surface: "rl-five_hour")
        #expect(acc.stat("linear-recent")?.typicalAbsError == 2)
        #expect(acc.partialCycles("arena-a") == nil)
    }

    /// A model graded on fewer cycles than the floor is not ranked and does
    /// not narrow the span; the engine's methods meet the same floor.
    @Test func everyMethodMeetsTheSameFloor() {
        let rows = Self.records("linear-recent", 0..<61) { _, _ in 2 } + Self.records("arena-a", 37..<61) { _, _ in 1 }
            + Self.records("arena-new", 58..<61) { _, _ in 0.5 }
        let r = Self.rank(rows)
        #expect(r.span?.start == Self.periodKey(37))
        #expect(r.standing("arena-new")?.isRanked == false)
        #expect(r.standing("arena-new")?.cycles == 3)
        #expect(r.pick == "arena-a")
        let thin = Self.records("linear-recent", 0..<7) { _, _ in 2 }
        #expect(Self.rank(thin).pick == nil)
        #expect(Self.rank(Self.records("linear-recent", 0..<8) { _, _ in 2 }).pick == "linear-recent")
    }

    /// Once every model is graded through the depth, the span is the depth:
    /// the newest `rlDepth` cycles, older grades past it left out.
    @Test func caughtUpTheSpanIsTheSharedDepth() {
        let depth = EngineSelfEval.rlDepth(weekly: false)
        let rows = Self.records("linear-recent", 0..<(depth + 50)) { p, _ in p < 50 ? 9 : 2 }
            + Self.records("arena-a", 0..<(depth + 50)) { _, _ in 3 }
        let r = Self.rank(rows)
        #expect(r.span?.cycles == depth)
        #expect(r.span?.start == Self.periodKey(50))
        #expect(r.depthCycles == depth)
        #expect(r.standing("linear-recent")?.typicalAbsError == 2)
        #expect(r.pick == "linear-recent")
    }

    // MARK: Well behind

    @Test func wellBehindIsAClearStatisticalLoss() throws {
        let rows = Self.records("best", 0..<40) { _, _ in 2 }
            + Self.records("close", 0..<40) { p, _ in p % 2 == 0 ? 1.8 : 2.6 }       // 2.2: 1.1× the best
            + Self.records("far", 0..<40) { _, _ in 5.5 }                            // > 1.5 × 2 + 1
            + Self.records("steady-loser", 0..<40) { _, _ in 2.5 }                   // 1.25×, every cycle
            + Self.records("thin", 35..<40) { _, _ in 9 }
        let r = Self.rank(rows)
        #expect(r.span?.cycles == 40)
        #expect(r.standing("close")?.wellBehind == false)
        #expect(r.standing("far")?.wellBehind == true)
        #expect(r.standing("steady-loser")?.wellBehind == true)
        #expect(r.standing("best")?.wellBehind == false)
        #expect(r.standing("thin")?.isRanked == false)
        // Ranked, then well behind, then the unranked.
        #expect(r.standings.map(\.method) == ["best", "close", "steady-loser", "far", "thin"])
        // Over too few cycles nothing is judged well behind.
        let short = Self.rank(Self.records("best", 0..<10) { _, _ in 2 } + Self.records("far", 0..<10) { _, _ in 9 })
        #expect(short.standing("far")?.wellBehind == false)
        #expect(EngineSelfEval.binomialUpperTail(n: 20, k: 0) == 1)
        #expect(abs(EngineSelfEval.binomialUpperTail(n: 2, k: 2) - 0.25) < 1e-12)
        #expect(EngineSelfEval.binomialUpperTail(n: 30, k: 30) < 1e-8)
    }

    // MARK: The bump

    /// The current grading takes over a window once it ranks every model
    /// the previous one did that can still run, or once the grader is
    /// through the depth; until then the previous one picks.
    @Test func thePreviousGradingBridgesTheBump() {
        let prev = EngineSelfEval.previousRLGrading
        let old = Self.records("linear-recent", 0..<30, grading: prev) { _, _ in 4 }
            + Self.records("arena-a", 0..<30, grading: prev) { _, _ in 1 }
        let engineOnly = Self.records("linear-recent", 0..<30) { _, _ in 4 }
        let withArena = engineOnly + Self.records("arena-a", 22..<30) { _, _ in 1 }
        func inUse(_ rows: [EngineSelfEval.Record], runnable: Set<String>? = nil, complete: Bool = false)
            -> EngineSelfEval.RLRanking {
            EngineSelfEval.rlGradingInUse(current: Self.rank(rows), previous: Self.rank(rows, grading: prev),
                                          runnable: runnable, currentComplete: complete)
        }
        // Only the old grades: they drive.
        #expect(inUse(old).grading == prev)
        #expect(inUse(old).pick == "arena-a")
        // The engine's methods graded anew first (cheap): still the old.
        #expect(inUse(old + engineOnly).grading == prev)
        // The arena model has its floor under the new grading: the new.
        #expect(inUse(old + withArena).grading == EngineSelfEval.rlGrading)
        #expect(inUse(old + withArena).pick == "arena-a")
        // A model that can no longer run doesn't hold it back...
        #expect(inUse(old + engineOnly, runnable: ["linear-recent"]).grading == EngineSelfEval.rlGrading)
        // ...nor one that never forecasts again, once the grader is through.
        #expect(inUse(old + engineOnly, complete: true).grading == EngineSelfEval.rlGrading)
        // With no old grades at all, the new one, whatever it holds.
        #expect(inUse(engineOnly).grading == EngineSelfEval.rlGrading)
    }

    // MARK: Inputs

    @Test func aGradesFingerprintNamesWhatItDependsOn() {
        let meter = ArenaModelSpec(name: "naive-flat", targets: RuntimeEngineTests.meters) { NaiveFlat(context: $0) }
        let spend = ArenaModelSpec(name: "spend-x", targets: RuntimeEngineTests.meters) { NaiveFlat(context: $0) }
        let parent = ArenaModelSpec(name: "parent", targets: RuntimeEngineTests.meters, children: ["naive-flat"]) {
            NaiveFlat(context: $0)
        }
        var bumped = meter
        bumped.version = 2
        let inputs = ArenaGradeInputs(pricing: "4", history: "11")
        let reg = ["naive-flat": meter, "spend-x": spend, "parent": parent]
        #expect(inputs.fingerprint(meter, registry: reg) == "m1")
        #expect(inputs.fingerprint(spend, registry: reg) == "m1.p4.h11")
        #expect(inputs.fingerprint(parent, registry: reg) == "m1.p4.h11")
        // A child's version moves its parent's grades too.
        let bumpedReg = ["naive-flat": bumped, "parent": parent]
        let moved = inputs.fingerprint(parent, registry: bumpedReg)
        #expect(moved != inputs.fingerprint(parent, registry: reg))
        #expect(moved.hasPrefix("m1-"))
        #expect(inputs.fingerprint(bumped, registry: bumpedReg) == "m2")
        // Prices move the spend readers only.
        let repriced = ArenaGradeInputs(pricing: "5", history: "11")
        #expect(repriced.fingerprint(meter, registry: reg) == inputs.fingerprint(meter, registry: reg))
        #expect(repriced.fingerprint(spend, registry: reg) != inputs.fingerprint(spend, registry: reg))
        #expect(RateLimitRoster.engineInputs("linear-recent") == "m1")
    }

    // MARK: The board

    static func spec(_ name: String, cx: Int = 3) -> ArenaModelSpec {
        ArenaModelSpec(name: name, targets: RuntimeEngineTests.meters, complexity: cx) { NaiveFlat(context: $0) }
    }

    @Test func theBoardListsEveryModelRankedThenTheRest() throws {
        let engineIds = ["linear-recent", "recent-rate", "saturating"]
        // 17 cycles: enough to judge (`wellBehindMinSpan`), too few for the
        // sign test, so well behind is the margin.
        let rows = Self.records("linear-recent", 0..<17) { _, _ in 3 } + Self.records("recent-rate", 0..<17) { _, _ in 9 }
            + Self.records("saturating", 0..<17) { _, _ in 2.5 }
            + Self.records("a-best", 0..<17) { _, _ in 1 } + Self.records("a-second", 0..<17) { _, _ in 1.5 }
            + Self.records("a-third", 0..<17) { _, _ in 2 } + Self.records("a-new", 14..<17) { _, _ in 0.1 }
        let ranking = Self.rank(rows, at: 0.4)
        let specs = ["a-best", "a-second", "a-third", "a-new", "a-net", "a-silent", "a-broken"].map { Self.spec($0) }
        let progress = ArenaScoringProgress(phase: .cheap, cyclesDone: 3, cyclesTotal: 17, models: ["a-new"],
                                            updatedAt: Date(), windowDepth: ["five_hour": 17], secondsPerCycle: 2,
                                            eta: 74)
        let board = UsageIntelligenceEngine.board(
            windowKey: "five_hour", weekly: false, ranking: ranking, current: ranking, engineIds: engineIds,
            specs: specs, complexity: [:], selected: "a-best", shown: "a-best", cutFraction: 0.4, canRunArena: true,
            weightsPresent: { $0.name != "a-net" }, liveFailure: { $0 == "a-broken" ? "no forecast this cycle" : nil },
            progress: progress, gradedThrough: false, drawLimit: 4)
        func status(_ id: String) -> MeterModelBoard.Status? { board.rows.first { $0.id == id }?.status }

        #expect(board.rows.count == engineIds.count + specs.count)
        #expect(board.rows.map(\.id) == ["a-best", "a-second", "a-third", "saturating",
                                         "a-new", "a-silent", "a-net", "a-broken", "linear-recent", "recent-rate"])
        #expect(status("a-best") == .ranked(typicalMiss: 1, cycles: 17))
        #expect(status("saturating") == .ranked(typicalMiss: 2.5, cycles: 17))
        #expect(status("linear-recent") == .wellBehind(typicalMiss: 3, cycles: 17))
        #expect(status("recent-rate") == .wellBehind(typicalMiss: 9, cycles: 17))
        #expect(status("a-new") == .scoring(done: 3, total: 17, eta: 74))
        #expect(status("a-silent") == .scoring(done: 0, total: 17, eta: nil))
        #expect(status("a-net") == .downloading(fraction: nil))
        #expect(status("a-broken") == .unavailable("no forecast this cycle"))
        #expect(board.rows.filter(\.isPick).map(\.id) == ["a-best"])
        // The pick and the next four by rank: one of them well behind, as
        // fewer than four others are ranked ahead of it.
        #expect(board.rows.filter(\.drawnByDefault).map(\.id) == ["a-best", "a-second", "a-third", "saturating",
                                                                   "linear-recent"])
        #expect(board.spanCycles == 17 && board.cutFraction == 0.4)
        #expect(board.progress == .init(done: 3, total: 17, eta: 74))
        #expect(board.rows.first { $0.id == "linear-recent" }?.name == BurnTrajectory.displayName("linear-recent"))

        // The grader is through: a model with nothing graded declined every cycle.
        let through = UsageIntelligenceEngine.board(
            windowKey: "five_hour", weekly: false, ranking: ranking, current: ranking, engineIds: engineIds,
            specs: specs, complexity: [:], selected: "a-best", shown: "a-best", cutFraction: 0.4, canRunArena: true,
            weightsPresent: { _ in true }, liveFailure: { _ in nil }, progress: nil, gradedThrough: true, drawLimit: 4)
        #expect(through.rows.first { $0.id == "a-silent" }?.status
                == .unavailable(UsageIntelligenceEngine.boardNoForecastsReason))
        #expect(through.progress == nil)

        // No account to run the arena on; a window with too few cycles.
        let thin = Self.rank(Self.records("linear-recent", 0..<3) { _, _ in 1 })
        let none = UsageIntelligenceEngine.board(
            windowKey: "five_hour", weekly: false, ranking: thin, current: thin, engineIds: engineIds,
            specs: specs, complexity: [:], selected: nil, shown: "linear-recent", cutFraction: nil, canRunArena: false,
            weightsPresent: { _ in true }, liveFailure: { _ in nil }, progress: nil, gradedThrough: false, drawLimit: 4)
        #expect(none.rows.first { $0.id == "a-best" }?.status
                == .unavailable(UsageIntelligenceEngine.boardNeedsAccountReason))
        #expect(none.rows.first { $0.id == "linear-recent" }?.status
                == .unavailable(UsageIntelligenceEngine.boardThinHistoryReason))
        #expect(none.rows.filter(\.isPick).map(\.id) == ["linear-recent"])
    }
}

/// The grader in the background: no pruning, re-grades, and the engine's
/// methods graded the same way.
@Suite("Runtime: the unified grader", .serialized)
struct RuntimeUnifiedGraderTests {

    typealias Fixtures = RuntimeEngineTests
    static let cuts = EngineSelfEval.rlCutFractions.count

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

    /// Each engine method's record on cycles `range`, graded as the refit
    /// would have graded it (current inputs, so it does not grade again):
    /// `linearRecentMiss` points off for `linear-recent`, `otherMiss` for the
    /// rest.
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
                                                 periodKey: period, predicted: 50 + miss, truth: 50,
                                                 inputs: RateLimitRoster.engineInputs(method)))
                }
            }
        }
        try ctx.save()
    }

    static func periods(_ container: ModelContainer, method: String) throws -> Set<String> {
        Set(try Fixtures.arenaRows(container, method: method).map(\.periodKey))
    }

    /// Nothing is pruned: a model ten points off on every cycle is graded on
    /// every cycle in depth, like the best, and on each one that completes.
    @Test func everyModelIsGradedOnEveryCycle() async throws {
        Turncoat.turnsAt = .max
        let container = try Fixtures.seeded(cycles: Self.cycles)
        try Self.engineRecord(container, 0...Self.cycles - 1, linearRecentMiss: 0, otherMiss: 0,
                              methods: ["linear-recent"])
        let rt = Fixtures.runtime(container, roster: [Fixtures.oracle, Fixtures.peeker, Self.turncoat])
        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Self.earlier)
        for m in ["test-oracle", "test-peeker", "test-turncoat"] {
            #expect(try Self.periods(container, method: m).count == 32, "\(m)")
            #expect(try Fixtures.arenaRows(container, method: m).count == 32 * Self.cuts, "\(m)")
        }
        let next = Self.reset(32).addingTimeInterval(1800)
        let second = await rt.scorer.pass(accounts: [Fixtures.account], now: next)
        #expect(second.cycles == 1)
        #expect(second.forecasts == 3 * Self.cuts)
        #expect(try Self.periods(container, method: "test-turncoat").count == 33)
        #expect(await rt.scorer.pass(accounts: [Fixtures.account], now: next).forecasts == 0)
        // Through the depth: the engine may stop waiting on the grader.
        #expect(rt.progress.isGradedThrough(account: Fixtures.account))
    }

    /// A model behind for months, whose habits the user then grows into: it
    /// was graded on every cycle all along, and once the cycles it reads
    /// well outweigh the others over the shared span, the record picks it.
    @Test func aModelThatStartsWinningBecomesThePick() async throws {
        Turncoat.turnsAt = ArenaTime.millis(Self.reset(20))
        let container = try Fixtures.seeded(cycles: Self.cycles)
        try Self.engineRecord(container, 0...31, linearRecentMiss: 0, otherMiss: 5)
        try Self.engineRecord(container, 32...Self.cycles - 1, linearRecentMiss: 5, otherMiss: 5)
        let engine = await Fixtures.engine(container)
        let rt = Fixtures.runtime(container, roster: [Self.turncoat], engine: engine)
        await engine.adopt(arena: rt.link)

        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Self.earlier)
        #expect(try Self.periods(container, method: "test-turncoat").count == 32)
        await engine.recompute(now: Self.earlier)
        #expect(await engine.resolvedMethod(windowKey: "five_hour").selected == "linear-recent")

        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(try Self.periods(container, method: "test-turncoat").count == Self.cycles)
        await engine.recompute(now: Fixtures.now)
        #expect(await engine.resolvedMethod(windowKey: "five_hour").selected == "test-turncoat")
    }

    /// A port's version moves: every grade it has is graded again, in place
    /// (same rows, new inputs), and the engine's copy follows.
    @Test func aVersionBumpGradesAgainInPlace() async throws {
        let container = try Fixtures.seeded(cycles: 12)
        let engine = await Fixtures.engine(container)
        await engine.recompute(now: Fixtures.now)
        let first = Fixtures.runtime(container, roster: [Fixtures.peeker], engine: engine)
        let r1 = await first.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(r1.outcomes == 12 * Self.cuts)
        let before = try Fixtures.arenaRows(container, method: "test-peeker")
        #expect(Set(before.compactMap(\.inputs)) == ["m1.p0.h0"])

        var bumped = Fixtures.peeker
        bumped.version = 2
        let second = Fixtures.runtime(container, roster: [bumped], engine: engine)
        let r2 = await second.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(r2.outcomes == 12 * Self.cuts)
        #expect(r2.regraded == 12 * Self.cuts)
        let after = try Fixtures.arenaRows(container, method: "test-peeker")
        #expect(after.count == before.count)
        #expect(Set(after.compactMap(\.inputs)) == ["m2.p0.h0"])
        // Nothing left to grade under the new version.
        #expect(await second.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now).outcomes == 0)

        // Prices recomputed: the spend reader again; a meter-only model not.
        var config = Fixtures.noSleep()
        config.gradeInputs = ArenaGradeInputs(pricing: "9", history: "0")
        let meterOnly = ArenaModelSpec(name: "naive-flat", targets: Fixtures.meters, complexity: 1) {
            NaiveFlat(context: $0)
        }
        let third = Fixtures.runtime(container, roster: [bumped, meterOnly], config: config, engine: engine)
        let r3 = await third.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(r3.regraded == 12 * Self.cuts)
        #expect(Set(try Fixtures.arenaRows(container, method: "test-peeker").compactMap(\.inputs)) == ["m2.p9.h0"])
        #expect(Set(try Fixtures.arenaRows(container, method: "naive-flat").compactMap(\.inputs)) == ["m1"])
        let r4 = await third.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        #expect(r4.outcomes == 0)
    }

    /// The engine's methods are graded at the same cuts of the same cycles,
    /// into the same rows, as the arena's; a stale engine grade (an older
    /// version of the method) is graded again by the refit.
    @Test func theEnginesMethodsAreGradedLikeTheOthers() async throws {
        let container = try Fixtures.seeded(cycles: 12)
        let engine = await Fixtures.engine(container)
        let rt = Fixtures.runtime(container, roster: [Fixtures.peeker], engine: engine)
        await engine.adopt(arena: rt.link)
        _ = await engine.backfillRateLimitRecordIfNeeded(now: Fixtures.now, pause: .zero)
        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        let all = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
            .filter { $0.surface.hasPrefix("rl-five_hour") }
        func grid(_ method: String) -> Set<String> {
            Set(all.filter { $0.method == method }.map { "\($0.bucket)@\($0.periodKey)" })
        }
        let arena = grid("test-peeker")
        #expect(arena.count == 12 * Self.cuts)
        for m in RateLimitRoster.engineIds where m != DiurnalBurnModel.methodId {
            #expect(grid(m) == arena, "\(m) graded on the arena's grid")
        }
        #expect(all.allSatisfy { EngineSelfEval.isCurrentRLBucket($0.bucket) })
        #expect(Set(all.filter { RateLimitRoster.engineIds.contains($0.method) }.compactMap(\.inputs)) == ["m1"])

        // An engine grade from an older version of its method.
        let ctx = ModelContext(container)
        let fetched = try ctx.fetch(FetchDescriptor<EngineEvalOutcome>())
        let row = try #require(fetched.first { $0.method == "linear-recent" && $0.surface.hasPrefix("rl-five_hour") })
        let key = row.key, predicted = row.predicted
        row.inputs = "m0"
        row.predicted = predicted + 40
        try ctx.save()
        let fresh = await Fixtures.engine(container)
        await fresh.recompute(now: Fixtures.now)
        let byKey = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>(
            predicate: #Predicate { $0.key == key }))
        let regraded = try #require(byKey.first)
        #expect(regraded.inputs == "m1")
        #expect(regraded.predicted == predicted)
    }

    /// Selection keeps reading the old grades across a bucket bump until the
    /// new grading ranks the same models, then retires the old rows.
    @Test func theOldGradesBridgeTheBumpThenRetire() async throws {
        let container = try Fixtures.seeded(cycles: 12)
        // The previous grading's record: the peeker one point off, every
        // engine method ten.
        let ctx = ModelContext(container)
        let surface = EngineScope.account(Fixtures.account).qualify(EngineSelfEval.rlSurface("five_hour"))
        let prev = EngineSelfEval.previousRLGrading
        for c in 0..<12 {
            let period = EngineSelfEval.periodKeyRL(Self.resetOf(c, of: 12))
            for m in RateLimitRoster.engineIds + ["test-peeker"] {
                for cf in prev.cuts {
                    ctx.insert(EngineEvalOutcome(surface: surface, method: m, bucket: prev.bucket(cf), periodKey: period,
                                                 predicted: m == "test-peeker" ? 51 : 60, truth: 50))
                }
            }
        }
        try ctx.save()
        let engine = await Fixtures.engine(container)
        let rt = Fixtures.runtime(container, roster: [Fixtures.peeker], engine: engine)
        await engine.adopt(arena: rt.link)
        // The engine grades its own methods anew on the refit; the arena
        // model has nothing under the new grading yet: the old grades pick.
        await engine.recompute(now: Fixtures.now)
        #expect(await engine.resolvedMethod(windowKey: "five_hour").selected == "test-peeker")
        #expect(await engine.meterModelBoard(windowKey: "five_hour").rows.first?.id == "test-peeker")

        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        await engine.recompute(now: Fixtures.now)
        let acc = try #require(await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("five_hour")))
        #expect(acc.stat("test-peeker").map(\.periods) == 12)
        // The old rows go once nothing reads them.
        var left = Int.max
        for _ in 0..<200 {
            left = try ModelContext(container).fetchCount(FetchDescriptor<EngineEvalOutcome>(
                predicate: #Predicate { $0.bucket.contains("|v2") }))
            if left == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(left == 0)
    }

    /// `RuntimeEngineTests.seeded`'s reset for cycle `c` of `cycles`.
    static func resetOf(_ c: Int, of cycles: Int) -> Date {
        let liveStart = Fixtures.now.addingTimeInterval(-2 * 3600)
        return liveStart.addingTimeInterval(-Double(cycles - c) * (Fixtures.fiveHours + 3600) + Fixtures.fiveHours)
    }

    /// The board from a running engine: every model, the pick first among
    /// the drawn, and no progress once the grader is through.
    @Test func theEnginesBoard() async throws {
        let container = try Fixtures.seeded(cycles: 12)
        let engine = await Fixtures.engine(container)
        let rt = Fixtures.runtime(container, roster: [Fixtures.oracle, Fixtures.peeker], engine: engine)
        await engine.adopt(arena: rt.link)
        _ = await rt.scorer.pass(accounts: [Fixtures.account], now: Fixtures.now)
        await engine.recompute(now: Fixtures.now)
        let board = await engine.meterModelBoard(windowKey: "five_hour")
        #expect(Set(board.rows.map(\.id)) == Set(RateLimitRoster.engineIds + ["test-oracle", "test-peeker"]))
        let pick = try #require(board.rows.first { $0.isPick })
        #expect(pick.drawnByDefault)
        #expect(board.rows.filter(\.drawnByDefault).count <= 5)
        #expect(board.progress == nil)
        #expect(board.spanCycles > 0)
        // The oracle sees the future: ranked first, and picked. Until its
        // live projection lands the dashboard shows a stand-in, and the
        // board marks that one as on the dashboard.
        #expect(board.rows.first?.id == "test-oracle")
        let m = await engine.resolvedMethod(windowKey: "five_hour")
        #expect(m.selected == "test-oracle")
        #expect(pick.id == m.resolved)
        #expect(board.rows.first { $0.id == "test-oracle" }?.drawnByDefault == true)
        // The sheet's numbers are the board's.
        let acc = try #require(await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("five_hour")))
        for row in board.rows {
            if case let .ranked(miss, _) = row.status { #expect(acc.stat(row.id)?.typicalAbsError == miss) }
        }
    }
}
