import Foundation
import Testing
@testable import PacerCore

/// `kit/ml/combine.py` in Swift (`KitMLCombine`): the pieces on their own.
@Suite struct CombineKitTests {
    @Test func kindsAndCounts() {
        #expect(KitMLCombine.kindOf(.meterFiveHour, cap: nil) == "five_hour")
        #expect(KitMLCombine.kindOf(.meterScoped, cap: "Fable") == "weekly_scoped:Fable")
        #expect(KitMLCombine.counts([0.5, 0.5], 200) == [100, 100])
        #expect(KitMLCombine.counts([1.0 / 3, 1.0 / 3, 1.0 / 3], 200) == [67, 67, 66])
        #expect(KitMLCombine.counts([0.0, 0.004, 0.996], 200) == [0, 1, 199])
        // np.unique(np.linspace(0, 29, 16).round()): half to even at 15.47 → 15.
        #expect(KitMLCombine.linspaceIndices(30, 16) == [0, 2, 4, 6, 8, 10, 12, 14, 15, 17, 19, 21, 23, 25, 27, 29])
    }

    /// The exact simplex minimum of the mixture objective is no worse than
    /// any point of a fine grid, and meets the KKT conditions.
    @Test func quadraticSimplexMinimumIsTheMinimum() {
        var rng = ArenaRNG(seed: 11)
        for trial in 0..<20 {
            let k = 3
            // Sorted samples of three children at 12 columns, and a truth.
            let m = 20, e = 12
            let X = (0..<k).map { c -> [[Double]] in
                let cols = (0..<e).map { _ in (0..<m).map { _ in rng.normal() * Double(c + 1) + Double(c) }.sorted() }
                return (0..<m).map { r in (0..<e).map { cols[$0][r] } }
            }
            let y = (0..<e).map { _ in rng.normal() }
            var a = [Double](repeating: 0, count: k)
            var D = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
            for i in 0..<k {
                a[i] = KitMLCombine.meanAbs(X[i], y)
                D[i][i] = 2 * KitMLCombine.mean(KitMLCombine.halfGini(X[i]))
                for j in 0..<k where j != i { D[i][j] = KitMLCombine.meanPairAbs(X[i], X[j]) }
            }
            let scale = a.reduce(0, +) / Double(k), shrink = trial % 2 == 0 ? 0.05 : 0.0
            func f(_ w: [Double]) -> Double {
                var q = 0.0
                for i in 0..<k { for j in 0..<k { q += w[i] * w[j] * D[i][j] } }
                let pen = w.map { ($0 - 1.0 / Double(k)) * ($0 - 1.0 / Double(k)) }.reduce(0, +)
                return (zip(a, w).map(*).reduce(0, +) - 0.5 * q) / scale + shrink * pen
            }
            let w = KitMLCombine.simplexMinQuadratic(a: a, D: D, scale: scale, shrink: shrink)
            #expect(abs(w.reduce(0, +) - 1) < 1e-12 && w.allSatisfy { $0 >= 0 })
            let fw = f(w)
            var best = Double.infinity
            for i in 0...100 { for j in 0...(100 - i) {
                best = min(best, f([Double(i) / 100, Double(j) / 100, Double(100 - i - j) / 100]))
            } }
            #expect(fw <= best + 1e-12, "trial \(trial): \(fw) vs grid \(best)")
            // The generic minimizer agrees.
            let g = KitMLCombine.simplexMin(k, f)
            #expect(f(g) >= fw - 1e-12 && f(g) - fw < 1e-6, "trial \(trial)")
        }
    }

    /// E|X − Y| from sorted columns by the merge equals every pair.
    @Test func pairAbsSumIsEveryPair() {
        let a: [Double] = [-1, 0.5, 2, 2, 7], b: [Double] = [0, 2, 3]
        var brute = 0.0
        for x in a { for y in b { brute += abs(x - y) } }
        #expect(abs(KitMLCombine.pairAbsSum(a, b) - brute) < 1e-12)
        #expect(abs(KitMLCombine.pairAbsSum([3, 1, 2], [2, 0]) - 8) < 1e-12)      // unsorted input
    }

    @Test func exactMixtureIsEachChildsShare() {
        let lo = ArenaTargetForecast(levels: [0, 1], quantiles: [[0, 0], [10, 10]])
        let hi = ArenaTargetForecast(levels: [0, 1], quantiles: [[50, 50], [60, 60]])
        let P = KitMLCombine.poolMixtureExact([lo, hi], [0.25, 0.75], 8)
        #expect(P.count == 8)
        // 2 of the low child at levels .25, .75; 6 of the high one at (j + .5) / 6.
        let highs: [Double] = (0..<6).map { (j: Int) -> Double in 50.0 + 10.0 * (Double(j) + 0.5) / 6.0 }
        let want: [Double] = [2.5, 7.5] + highs
        #expect(zip(P.map { $0[0] }, want).allSatisfy { abs($0 - $1) < 1e-12 })
        var rng = ArenaRNG(seed: 5)
        let drawn = KitMLCombine.poolMixture([[[1], [2], [3], [4]], [[9], [8]]], [0.5, 0.5], 4, rng: &rng)
        #expect(drawn.count == 4 && drawn.filter { $0[0] > 5 }.count == 2)
    }

    /// The ledger scores a forecast on the readings that came after its
    /// origin, in its cycle, known now; a child with lower losses gets more
    /// weight.
    @Test func ledgerScoresAndWeights() {
        let reset: Millis = 10 * ArenaTime.hour
        let origin: Millis = 6 * ArenaTime.hour
        var rows: [ArenaReading] = []
        for i in 0..<40 {
            let t = origin - ArenaTime.hour + Millis(i) * 5 * ArenaTime.minute
            rows.append(ArenaReading(tEvent: t, tKnown: t, utilPct: Double(i), resetsAt: reset, active: true))
        }
        let meter = ArenaMeterID(account: "A", windowKind: "five_hour")
        let store = ArenaHistoryStore(meters: [meter: rows], spend: [:], tzOffsetMin: 0, dataStart: 0)
        let now = origin + 2 * ArenaTime.hour
        let h = ArenaHistory(store: store, now: now, accounts: ["A"])
        let grid = [origin + ArenaTime.hour, origin + 2 * ArenaTime.hour, reset]
        let tr = ArenaTargetRequest(key: "meter.five_hour:A", target: .meterFiveHour, accounts: ["A"], grid: grid,
                                    resetAt: reset)
        let req = ArenaRequest(now: origin, accounts: ["A"], targets: [tr])
        let ledger = KitMLCombine.Ledger(m: 4, maxEvals: 16)
        // The truth rises 12 points an hour from 12 at the origin.
        ledger.add("good", req, ArenaForecast(byKey: [tr.key: .point([24, 36, 60])]))
        ledger.add("bad", req, ArenaForecast(byKey: [tr.key: .point([12, 12, 12])]))
        ledger.score(h)
        let g = ledger.scored("five_hour", before: now)
        #expect(g.count == 1)
        // Readings after the origin up to now: 24 of them, thinned to 16.
        #expect(g[0].times.count == 16 && g[0].times.allSatisfy { $0 > origin && $0 <= now })
        #expect(g[0].coverage() == 0.5)
        let w = KitMLCombine.ewaWeights(g, ["good", "bad"])
        #expect(w[0] > w[1])
        // Before its first grid time the good child is held at 24 while the
        // truth climbs from 13, so it does not take everything.
        let s = KitMLCombine.stackWeights(g, ["good", "bad"])
        #expect(s[0] > 0.7 && abs(s[0] + s[1] - 1) < 1e-12)
        // The newest reading known at a time, idle and tie rules.
        #expect(KitMLCombine.levelAt(rows, asof: origin) == 12)
        #expect(KitMLCombine.levelAt(rows, asof: reset + 1) == 0)
    }
}
