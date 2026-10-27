import Foundation
import Testing
@testable import PacerCore

// TEMPORARY: DELETE ON MERGE with `feat/fm-unified-eval`, together with
// `MeterModelBoard+TodayAdapter.swift`, which this tests.

/// Today's data mapped into a `MeterModelBoard` (`MeterModelBoardAdapter`).
@Suite("Meter model board adapter")
struct MeterModelBoardAdapterTests {
    typealias Stat = EngineSelfEval.Accuracy.MethodStat

    static func stat(_ id: String, _ miss: Double, periods: Int = 30, first: String = "a") -> Stat {
        Stat(method: id, medianAbsPctError: 0, typicalAbsError: miss, periods: periods, spanPeriods: periods,
             firstPeriod: first)
    }

    static func listing(_ id: String, _ status: ArenaModelListing.Status, miss: Double? = nil) -> ArenaModelListing {
        ArenaModelListing(id: id, name: id, cycles: 0, typicalAbsError: miss, isPick: false, isDrawn: false,
                          status: status)
    }

    static func board(progress: ArenaScoringProgress? = nil) -> MeterModelBoard {
        let accuracy = EngineSelfEval.Accuracy(
            surface: "rl", methods: [stat("kalman-trend", 1.9, periods: 24), stat("linear-recent", 2.6, periods: 24),
                                     stat("arena-a", 1.8, periods: 24), stat("arena-y", 9.0, periods: 12, first: "m"),
                                     stat("arena-b", 2.0, periods: 3)],
            span: .init(start: "a", cycles: 24, isWholeRecord: false))
        return MeterModelBoardAdapter.board(
            windowKey: "five_hour", engineIds: ["kalman-trend", "linear-recent", "diurnal-rate"],
            listings: [listing("arena-a", .recorded, miss: 1.8), listing("arena-b", .scoring(cycles: 3, floor: 8)),
                       listing("arena-net", .downloading), listing("arena-x", .declined("no forecasts on your history")),
                       listing("arena-y", .recorded, miss: 9.0)],
            accuracy: accuracy, pick: "kalman-trend", complexities: ["diurnal-rate": 3], cutFraction: 0.4,
            progress: progress)
    }

    @Test func everyModelIsOneRowInTheBoardsOrder() {
        let b = Self.board()
        #expect(b.rows.map(\.id).prefix(5) == ["arena-a", "kalman-trend", "linear-recent", "arena-b", "arena-net"])
        #expect(Set(b.rows.map(\.id).dropFirst(5).prefix(2)) == ["diurnal-rate", "arena-x"])
        #expect(b.rows.last?.id == "arena-y")
        #expect(b.spanCycles == 24 && b.windowKey == "five_hour" && b.cutFraction == 0.4)
    }

    @Test func statusesMapFromTodaysData() {
        let b = Self.board()
        let status = Dictionary(uniqueKeysWithValues: b.rows.map { ($0.id, $0.status) })
        #expect(status["arena-a"] == .ranked(typicalMiss: 1.8, cycles: 24))
        #expect(status["kalman-trend"] == .ranked(typicalMiss: 1.9, cycles: 24))
        #expect(status["arena-b"] == .scoring(done: 3, total: 8, eta: nil))
        #expect(status["arena-net"] == .downloading(fraction: nil))
        #expect(status["arena-x"] == .unavailable("no forecasts on your history"))
        #expect(status["diurnal-rate"] == .unavailable(MeterModelBoardAdapter.noHistory))
        // Past half again the best plus a point; its record starts after the
        // span does, so it says how many cycles it rests on.
        #expect(status["arena-y"] == .wellBehind(typicalMiss: 9.0, cycles: 12))
    }

    @Test func thePickAndTheNextRankedAreDrawn() {
        let b = Self.board()
        #expect(b.rows.filter(\.isPick).map(\.id) == ["kalman-trend"])
        #expect(b.rows.filter(\.drawnByDefault).map(\.id) == ["arena-a", "kalman-trend", "linear-recent"])
    }

    @Test func progressOnlyWhileThereIsWork() {
        #expect(Self.board().progress == nil)
        let p = ArenaScoringProgress(phase: .cheap, cyclesDone: 31, cyclesTotal: 50, models: [], updatedAt: .now)
        #expect(Self.board(progress: p).progress == .init(done: 31, total: 50, eta: nil))
        let none = ArenaScoringProgress(phase: .cheap, cyclesDone: 0, cyclesTotal: 0, models: [], updatedAt: .now)
        #expect(Self.board(progress: none).progress == nil)
    }
}
