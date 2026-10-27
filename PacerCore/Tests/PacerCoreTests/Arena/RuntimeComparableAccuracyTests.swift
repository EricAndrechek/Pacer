import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The compare sheet's numbers over one span (`EngineSelfEval
/// .comparableAccuracy`): the engine's methods are scored over every cycle
/// the store holds and the arena models over the newest few dozen, so each
/// shown over its own record compared different cycles. Every number, drawn
/// rows and "More models" alike, now covers the span selection compares on.
@Suite("Arena runtime: the compare sheet's numbers over one span", .serialized)
struct RuntimeComparableAccuracyTests {

    static let surface = "rl-five_hour"

    /// Cycle `p` of a synthetic five-hour history, oldest first.
    static func periodKey(_ p: Int) -> String {
        EngineSelfEval.periodKeyRL(Date(timeIntervalSince1970: 1_800_000_000 + Double(p) * 5 * 3600))
    }

    /// One record per cut in `cuts` for each cycle in `periods`, missing by
    /// `miss(p)` points.
    static func records(_ method: String, _ periods: Range<Int>, cuts: [Double] = [0.5],
                        miss: (Int) -> Double) -> [EngineSelfEval.Record] {
        periods.flatMap { p in
            cuts.map { cut in
                EngineSelfEval.Record(method: method, bucket: EngineSelfEval.rlBucket(cut), periodKey: periodKey(p),
                                      predicted: 50 + miss(p), truth: 50)
            }
        }
    }

    /// What selection ranks each method by over `rows` (`bestMethod`'s inner
    /// statistic), by hand.
    static func selectionErrors(_ rows: [EngineSelfEval.Record], weekly: Bool = false,
                                phase: EngineSelfEval.SelectionPhase? = nil) -> [String: Double] {
        Dictionary(grouping: rows, by: \.method).mapValues {
            EngineSelfEval.typicalError(EngineSelfEval.phaseErrors($0, phase), weekly: weekly)
        }
    }

    /// The owner's case in miniature: an engine method over 61 cycles, worse
    /// on the old ones; two arena models over the newest 24. The drawn rows
    /// and the listed ones are both measured over those 24, the numbers
    /// selection ranked, and the column says so.
    @Test func drawnAndListedRowsShareTheSpan() throws {
        let engine = Self.records("linear-recent", 0..<61) { $0 < 37 ? 6 : 2 }
        let arena = Self.records("arena-a", 37..<61) { _ in 1 } + Self.records("arena-b", 37..<61) { _ in 1.5 }
        let all = engine + arena
        let ids: Set<String> = ["arena-a", "arena-b"]

        let span = EngineSelfEval.arenaSpan(all, arenaIds: ids, weekly: false)
        #expect(span.start == Self.periodKey(37))
        let acc = EngineSelfEval.comparableAccuracy(surface: Self.surface, from: all, since: span.start)
        #expect(acc.span == .init(start: Self.periodKey(37), cycles: 24, isWholeRecord: false))

        // Over its own record the engine method read 6; over the span, 2.
        #expect(EngineSelfEval.accuracy(surface: Self.surface, from: all).stat("linear-recent")?.typicalAbsError == 6)
        let lr = try #require(acc.stat("linear-recent"))
        #expect(lr.typicalAbsError == 2)
        #expect(lr.periods == 61 && lr.spanPeriods == 24 && lr.shownPeriods == 24)

        // Every number is the one selection ranked.
        let ranked = Self.selectionErrors(EngineSelfEval.arenaComparable(all, arenaIds: ids, weekly: false))
        for (method, err) in ranked { #expect(acc.stat(method)?.typicalAbsError == err, "\(method)") }

        // The "More models" rows read the same accuracy: the same numbers.
        let specs = ["arena-a", "arena-b"].map {
            ArenaModelSpec(name: $0, targets: RuntimeEngineTests.meters) { RuntimeEngineTests.Peeker(context: $0) }
        }
        let listed = UsageIntelligenceEngine.arenaListing(
            specs: specs, accuracy: acc, weekly: false, pick: nil, drawn: [], liveFailure: { _ in nil },
            weightsPresent: { _ in true })
        #expect(listed.map(\.id) == ["arena-a", "arena-b"])
        #expect(listed.map(\.typicalAbsError) == [1, 1.5])
        #expect(listed.allSatisfy { $0.status == .recorded && $0.cycles == 24 })
        // Every row covers the span: none says how many cycles.
        #expect(["linear-recent", "arena-a", "arena-b"].allSatisfy { acc.partialCycles($0) == nil })
    }

    /// A clear loser stops being scored deeper, so its record is shorter: it
    /// does not narrow the span (selection leaves it out), and its row says
    /// how many cycles its number rests on. So does a model still filling in.
    @Test func aShorterRecordSaysHowManyCycles() {
        let engine = Self.records("linear-recent", 0..<61) { _ in 2 }
        let deep = Self.records("arena-a", 21..<61) { _ in 1 }
        let loser = Self.records("arena-loser", 37..<61) { _ in 10 }
        let filling = Self.records("arena-new", 58..<61) { _ in 0.5 }
        let all = engine + deep + loser + filling
        let ids: Set<String> = ["arena-a", "arena-loser", "arena-new"]
        #expect(EngineSelfEval.arenaLosers(all, arenaIds: ids, weekly: false) == ["arena-loser"])

        let span = EngineSelfEval.arenaSpan(all, arenaIds: ids, weekly: false)
        #expect(span.start == Self.periodKey(21))
        #expect(span.eligible == ["arena-a"])
        let acc = EngineSelfEval.comparableAccuracy(surface: Self.surface, from: all, since: span.start)
        #expect(acc.span?.cycles == 40)
        #expect(acc.partialCycles("linear-recent") == nil)
        #expect(acc.partialCycles("arena-a") == nil)
        #expect(acc.partialCycles("arena-loser") == 24)
        #expect(acc.partialCycles("arena-new") == 3)
        #expect(acc.stat("arena-loser")?.typicalAbsError == 10)

        // A cycle or two declined inside the span is not a shorter record.
        let gappy = Self.records("damped-acceleration", 0..<61) { _ in 3 }.filter { $0.periodKey != Self.periodKey(30) }
        let withGap = EngineSelfEval.comparableAccuracy(surface: Self.surface, from: all + gappy, since: span.start)
        #expect(withGap.stat("damped-acceleration")?.spanPeriods == 39)
        #expect(withGap.partialCycles("damped-acceleration") == nil)
    }

    /// The phase filter the drawn rows used is kept: the number is that half
    /// of the window's cuts over the span; the stage split and the counts
    /// cover every cut of the span.
    @Test func thePhaseFilterIsKept() throws {
        let cuts = [0.2, 0.3, 0.7, 0.8]
        let engine = Self.records("linear-recent", 0..<30, cuts: cuts) { $0 < 10 ? 20 : 4 }
            .map { r -> EngineSelfEval.Record in
                // Early calls miss by 4, late ones by 1, on the span's cycles.
                guard r.predicted == 54, let cut = EngineSelfEval.rlCutFraction(r.bucket), cut > 0.5 else { return r }
                return .init(method: r.method, bucket: r.bucket, periodKey: r.periodKey, predicted: 51, truth: 50)
            }
        let arena = Self.records("arena-a", 10..<30, cuts: cuts) { _ in 2 }
        let all = engine + arena
        let span = EngineSelfEval.arenaSpan(all, arenaIds: ["arena-a"], weekly: false)
        #expect(span.start == Self.periodKey(10))

        for phase in [EngineSelfEval.SelectionPhase.early, .late] {
            let acc = EngineSelfEval.comparableAccuracy(surface: Self.surface, from: all, phase: phase,
                                                        since: span.start)
            let lr = try #require(acc.stat("linear-recent"))
            #expect(lr.typicalAbsError == (phase == .early ? 4 : 1))
            let ranked = Self.selectionErrors(EngineSelfEval.arenaComparable(all, arenaIds: ["arena-a"], weekly: false),
                                              phase: phase)
            #expect(lr.typicalAbsError == ranked["linear-recent"])
            // Stages: every cut of the span, phase or not.
            #expect(lr.byStage.map(\.stage) == [.early, .middle, .late])
            #expect(lr.byStage.map(\.typicalAbsError) == [4, 1, 1])
            #expect(lr.byStage.map(\.scores).reduce(0, +) == 20 * cuts.count)
            #expect(lr.spanPeriods == 20 && lr.periods == 30)
        }
    }

    /// No arena model, none past its floor, or one scored back to the first
    /// cycle: the span is the whole record and every number is exactly what
    /// `accuracy` gave, as the sheet showed before.
    @Test func withoutANarrowerSpanTheNumbersAreUnchanged() {
        let engine = Self.records("linear-recent", 0..<30, cuts: [0.2, 0.7]) { Double($0 % 5) }
            + Self.records("saturating", 0..<30, cuts: [0.2, 0.7]) { Double($0 % 3) + 0.5 }
        let thin = Self.records("arena-thin", 28..<30) { _ in 0 }   // under the weekly floor
        let full = Self.records("arena-full", 0..<30) { _ in 1 }
        let cases: [([EngineSelfEval.Record], Set<String>)] = [
            (engine, []), (engine, ["arena-thin"]), (engine + thin, ["arena-thin"]), (engine + full, ["arena-full"]),
        ]
        for (rows, ids) in cases {
            for phase in [nil, EngineSelfEval.SelectionPhase.early] {
                let span = EngineSelfEval.arenaSpan(rows, arenaIds: ids, weekly: true)
                let plain = EngineSelfEval.accuracy(surface: Self.surface, from: rows, weekly: true, phase: phase)
                for whole in [nil, plain] {
                    let shown = EngineSelfEval.comparableAccuracy(surface: Self.surface, from: rows, weekly: true,
                                                                  phase: phase, since: span.start, whole: whole)
                    #expect(shown.span?.isWholeRecord == true)
                    #expect(shown.span?.cycles == 30)
                    #expect(shown.methods.count == plain.methods.count)
                    for m in plain.methods {
                        let s = shown.stat(m.method)
                        #expect(s?.typicalAbsError == m.typicalAbsError && s?.medianAbsPctError == m.medianAbsPctError)
                        #expect(s?.periods == m.periods && s?.byStage == m.byStage && s?.shownPeriods == m.periods)
                    }
                }
            }
        }
        // With no arena model at all, selection is untouched too.
        #expect(EngineSelfEval.arenaSpan(engine, arenaIds: [], weekly: false) == .init())
        #expect(EngineSelfEval.comparable(engine, span: .init(), arenaIds: []) == engine)
        // An empty record is an empty accuracy.
        #expect(EngineSelfEval.comparableAccuracy(surface: Self.surface, from: [], since: nil).methods.isEmpty)
    }

    /// A method whose record lies wholly before the span keeps its row, with
    /// no number over the span and no count.
    @Test func aRecordBeforeTheSpanHasNoNumber() throws {
        let rows = Self.records("linear-recent", 0..<40) { _ in 2 } + Self.records("retired", 0..<10) { _ in 1 }
            + Self.records("arena-a", 20..<40) { _ in 1 }
        let span = EngineSelfEval.arenaSpan(rows, arenaIds: ["arena-a"], weekly: false)
        let acc = EngineSelfEval.comparableAccuracy(surface: Self.surface, from: rows, since: span.start)
        let retired = try #require(acc.stat("retired"))
        #expect(!retired.typicalAbsError.isFinite)
        #expect(retired.periods == 10 && retired.spanPeriods == 0)
        #expect(acc.partialCycles("retired") == nil)
        #expect(acc.methods.last?.method == "retired")
    }

    /// Cheap enough for every refit: on a window's record with every model
    /// scored deep (tens of thousands of rows) the refit already derives the
    /// span and the whole-record accuracy; the sheet's numbers add one pass
    /// over the span, no more than the whole-record accuracy costs.
    @Test func itIsCheapOnADeepRecord() {
        let methods = (0..<6).map { "engine-\($0)" }
        let arena = (0..<24).map { "arena-\($0)" }
        let cuts = EngineSelfEval.rlCutFractions
        let rows = methods.flatMap { m in Self.records(m, 0..<400, cuts: cuts) { Double($0 % 7) } }
            + arena.flatMap { m in Self.records(m, 220..<400, cuts: cuts) { Double($0 % 5) } }
        let clock = ContinuousClock()
        var whole: EngineSelfEval.Accuracy?
        let wholeTook = clock.measure { whole = EngineSelfEval.accuracy(surface: Self.surface, from: rows) }
        let span = EngineSelfEval.arenaSpan(rows, arenaIds: Set(arena), weekly: false)
        var acc: EngineSelfEval.Accuracy?
        let took = clock.measure {
            acc = EngineSelfEval.comparableAccuracy(surface: Self.surface, from: rows, since: span.start, whole: whole)
        }
        #expect(acc?.span?.cycles == 180)
        #expect(acc?.methods.count == 30)
        #expect(took < max(wholeTook * 3, .milliseconds(50)),
                "span accuracy over \(rows.count) rows took \(took); the whole record's, \(wholeTook)")
    }

    // MARK: The engine

    /// The whole path: the engine scores every completed cycle, the arena
    /// scorer only the newest eight. The sheet's accuracy is measured over
    /// those eight, and the drawn rows and the listed ones read it.
    @Test func theEnginesSheetNumbersShareTheArenasSpan() async throws {
        let container = try RuntimeEngineTests.seeded(cycles: 12)
        let engine = await RuntimeEngineTests.engine(container)
        var config = RuntimeEngineTests.noSleep()
        config.sessionCycleCap = 8
        let rt = RuntimeEngineTests.runtime(container, roster: [RuntimeEngineTests.oracle, RuntimeEngineTests.peeker],
                                            config: config, engine: engine)
        await engine.adopt(arena: rt.link)
        await engine.recompute(now: RuntimeEngineTests.now)
        // Before the arena has a record: the whole record, as before.
        let before = try #require(await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("five_hour")))
        #expect(before.span?.isWholeRecord == true)

        _ = await rt.scorer.pass(accounts: [RuntimeEngineTests.account], now: RuntimeEngineTests.now)
        await engine.recompute(now: RuntimeEngineTests.now)
        let acc = try #require(await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("five_hour")))
        #expect(acc.span?.isWholeRecord == false)
        #expect(acc.span?.cycles == 8)
        let lr = try #require(acc.stat("linear-recent"))
        #expect(lr.spanPeriods == 8 && lr.periods > 8)
        #expect(acc.stat("test-oracle")?.shownPeriods == 8)

        // Drawn rows: the trajectories carry the span's numbers.
        let drawn = await engine.rateLimitTrajectories(windowKey: "five_hour")
        for t in drawn where acc.stat(t.modelId) != nil {
            #expect(t.typicalAbsError == acc.stat(t.modelId)?.typicalAbsError, "\(t.modelId)")
        }
        // "More models" rows: the same.
        let listed = await engine.arenaModelList(windowKey: "five_hour", weights: { _ in nil })
        for l in listed where l.status == .recorded {
            #expect(l.typicalAbsError == acc.stat(l.id)?.typicalAbsError, "\(l.id)")
        }
        #expect(!listed.isEmpty)
    }
}
