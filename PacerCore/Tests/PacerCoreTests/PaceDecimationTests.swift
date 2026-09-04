import Foundation
import Testing
@testable import PacerUI
@testable import PacerCore

/// A 7-day rate-limit cycle at roughly a sample a minute is ~10,000 points,
/// drawn into a column a few hundred pixels wide. Handing all of them to Swift
/// Charts cost 2.3 s of main thread on first render and 110–330 ms on every
/// re-render; the data preparation was under 50 ms throughout, which is why
/// optimising the fetch did not help.
@Suite("Chart series decimation")
struct PaceDecimationTests {

    private typealias Point = PaceChartView.Data.Point

    private func series(_ values: [(Double, Double)]) -> [Point] {
        values.map { Point(time: Date(timeIntervalSinceReferenceDate: $0.0), value: $0.1) }
    }

    @Test func aSeriesUnderTheCapIsUntouched() {
        let points = series((0..<50).map { (Double($0), Double($0)) })
        #expect(PaceChartView.Data.decimate(points, to: 400) == points)
    }

    @Test func aLongSeriesIsCappedAndKeepsBothEnds() {
        let points = series((0..<10_000).map { (Double($0), Double($0) / 100) })
        let out = PaceChartView.Data.decimate(points, to: 400)
        #expect(out.count <= 402)          // cap, plus the two forced endpoints
        #expect(out.first == points.first)
        #expect(out.last == points.last)
    }

    /// Time must never go backwards, or the line draws over itself.
    @Test func outputStaysInTimeOrder() {
        let points = series((0..<5_000).map { (Double($0), Double.random(in: 0...100)) })
        let out = PaceChartView.Data.decimate(points, to: 400)
        #expect(zip(out, out.dropFirst()).allSatisfy { $0.time <= $1.time })
    }

    /// The reason this is min/max per bucket rather than every-nth. A
    /// rate-limit line is a staircase with a vertical cliff at each reset;
    /// plain decimation lands on neither side of the cliff and rounds it off.
    @Test func aResetCliffSurvives() {
        var values = (0..<5_000).map { (Double($0), Double($0) / 50) }
        // 100% then straight back to 0 — the reset.
        values[2_500] = (2_500, 100)
        values[2_501] = (2_501, 0)
        let out = PaceChartView.Data.decimate(series(values), to: 400)
        #expect(out.contains { $0.value == 100 })
        #expect(out.contains { $0.value == 0 })
    }

    /// A single spike in the middle of a flat line is exactly what every-nth
    /// decimation loses.
    @Test func anIsolatedSpikeSurvives() {
        var values = (0..<5_000).map { (Double($0), 10.0) }
        values[3_333] = (3_333, 99)
        let out = PaceChartView.Data.decimate(series(values), to: 400)
        #expect(out.contains { $0.value == 99 })
    }
}
