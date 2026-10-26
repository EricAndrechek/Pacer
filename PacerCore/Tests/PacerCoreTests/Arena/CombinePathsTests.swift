import Foundation
import Testing
@testable import PacerCore

/// `kit/ml/paths.py` in Swift (`KitMLPaths`), on small tables computed by
/// hand from the Python's definitions.
@Suite struct CombinePathsTests {
    func close(_ a: [Double], _ b: [Double], _ tol: Double = 1e-12) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tol }
    }

    @Test func sortedSamplesReadsLevelsBetweenOrderStatistics() {
        let paths: [[Double]] = [[0, 10], [2, 30], [1, 20], [3, 40]]
        let s = KitMLPaths.sortedSamples(paths, m: 2)
        // levels .25, .75 → positions .5, 2.5 of the sorted columns.
        #expect(close(s[0], [0.5, 15]))
        #expect(close(s[1], [2.5, 35]))
        // Exactly m paths: all of them, sorted.
        #expect(KitMLPaths.sortedSamples(paths, m: 4) == [[0, 10], [1, 20], [2, 30], [3, 40]])
        // A quantile forecast is read at (i + 0.5) / m directly.
        let tf = ArenaTargetForecast(levels: [0, 1], quantiles: [[0, 0], [10, 100]])
        let q = KitMLPaths.sortedSamples(tf, m: 4)
        #expect(close(q.map { $0[0] }, [1.25, 3.75, 6.25, 8.75]))
        #expect(close(q.map { $0[1] }, [12.5, 37.5, 62.5, 87.5]))
    }

    @Test func crpsSortedIsTheEmpiricalCRPS() {
        // {0, 1} against 0: E|X − y| = .5, E|X − X'| / 2 = .25.
        #expect(close(KitMLPaths.crpsSorted([[0], [1]], [0]), [0.25]))
        // Brute force on a column of five samples.
        let xs: [Double] = [3, -1, 4, 1, 5]
        let y = 2.0
        let a = xs.map { abs($0 - y) }.reduce(0, +) / 5
        var pair = 0.0
        for u in xs { for v in xs { pair += abs(u - v) } }
        let brute = a - pair / 50
        let got = KitMLPaths.crpsSorted(xs.sorted().map { [$0] }, [y])
        #expect(close(got, [brute], 1e-12))
        #expect(close(KitMLPaths.crpsPaths(xs.map { [$0] }, [y]), [brute], 1e-12))
    }

    @Test func tidyAndTails() {
        let t = KitMLPaths.tidyRiseQuantiles([[1, 0.5, 3], [0, 2, 1]], headroom: 2.5)
        #expect(t == [[0, 0.5, 1], [1, 2, 2.5]])
        let (lv, q) = KitMLPaths.withTails([0.25, 0.75], t, headroom: 2.5)
        #expect(lv == [0, 0.25, 0.75, 1])
        #expect(q[0] == [0, 0, 0.25])
        #expect(q[3] == [1.5, 2.5, 2.5])
    }

    @Test func riseForecastIsTheDrawnPathsQuantiles() {
        let levels = [0.1, 0.5, 0.9]
        let q: [[Double]] = [[0, 1], [1, 3], [2, 6]]        // rises at anchor fracs .5 and 1
        let anchors = [0.5, 1.0]
        let fr = [0.0, 0.25, 0.5, 1.0]
        let det = KitMLPaths.riseForecast(levels: levels, q: q, anchorFracs: anchors, gridFracs: fr, used: 96)
        // Headroom 4 caps the top level's 6 at 4; lead 0 rises 0.
        #expect(det.quantile(0.5).first == 96)
        #expect(det.quantile(1.0).last == 100)
        var rng = ArenaRNG(seed: 3)
        let drawn = KitMLPaths.risePaths(levels: levels, q: q, anchorFracs: anchors, gridFracs: fr, used: 96,
                                         nPaths: 400, rng: &rng)
        let p = try! #require(drawn.paths)
        #expect(p.count == 400)
        #expect(p.allSatisfy { $0[0] == 96 && $0.allSatisfy { $0 >= 96 && $0 <= 100 } })
        // Comonotone: every path non-decreasing along the grid.
        #expect(p.allSatisfy { row in zip(row, row.dropFirst()).allSatisfy { $0 <= $1 } })
        let medDrawn = drawn.quantile(0.5)[3], medDet = det.quantile(0.5)[3]
        #expect(abs(medDrawn - medDet) < 0.25)
    }

    @Test func sampleRisePathsAnchorsAtUsed() {
        let s = KitMLPaths.sampleRisePaths([[1, 0.5], [3, 9]], anchorFracs: [0.5, 1], gridFracs: [0, 0.25, 1, 2],
                                           used: 95)
        #expect(close(s[0], [95, 95.5, 96, 96]))
        #expect(close(s[1], [95, 96.5, 100, 100]))
        #expect(close(KitMLPaths.gridFracs([10, 15, 20], now: 10, reset: 20), [0, 0.5, 1]))
    }
}
