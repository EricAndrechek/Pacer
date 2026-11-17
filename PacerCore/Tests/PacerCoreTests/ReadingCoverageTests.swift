import Foundation
import Testing
@testable import PacerCore

/// One definition of when a window's readings show it continuously (#421).
@Suite("Reading coverage")
struct ReadingCoverageTests {

    struct R: Equatable {
        let at: Date
        let percent: Double
    }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func r(_ seconds: TimeInterval, _ percent: Double) -> R {
        R(at: t0.addingTimeInterval(seconds), percent: percent)
    }
    static func run(_ items: [R]) -> [R] {
        Array(ReadingCoverage.continuousRun(items, at: \.at))
    }

    /// Thirty minutes between polls is still continuous; a millisecond more
    /// is a gap, and the run starts after it.
    @Test func theRunStartsAfterTheLastGap() {
        let continuous = [Self.r(0, 1), Self.r(1800, 2), Self.r(3600, 3)]
        #expect(Self.run(continuous) == continuous)
        let gapped = [Self.r(0, 1), Self.r(1800.001, 2), Self.r(2100, 3)]
        #expect(Self.run(gapped) == [Self.r(1800.001, 2), Self.r(2100, 3)])
        #expect(ReadingCoverage.isGap(from: Self.t0, to: Self.t0.addingTimeInterval(1800)) == false)
        #expect(ReadingCoverage.isGap(from: Self.t0, to: Self.t0.addingTimeInterval(1800.001)))
    }

    /// Only the last gap matters: the run is what reaches the newest reading.
    @Test func onlyTheLastGapCuts() {
        let readings = [Self.r(0, 1), Self.r(7200, 2), Self.r(7500, 3), Self.r(20_000, 4), Self.r(20_300, 5)]
        #expect(Self.run(readings) == [Self.r(20_000, 4), Self.r(20_300, 5)])
        #expect(Self.run([Self.r(0, 1)]) == [Self.r(0, 1)])
        #expect(Self.run([]).isEmpty)
    }

    /// `ReadingFreshness` counts an account's cadence in the same polls.
    @Test func freshnessUsesTheSamePoll() {
        #expect(ReadingFreshness.pollBurst == ReadingCoverage.pollBurst)
    }
}
