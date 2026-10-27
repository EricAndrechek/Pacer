import Foundation
import Testing
@testable import PacerCore

/// The Swift GBM against LightGBM 4.7 itself (`ml-gbm-lightgbm-ref.json`):
/// small synthetic matrices (a dense column, a mostly-zero one, a signed
/// one, few distinct values, a constant one LightGBM drops, a rare one its
/// pre-filter drops), boosters fitted with `ml-gbm-quantile`'s parameters
/// (five-hour and weekly variants, its seven levels), and LightGBM's first
/// trees (split features, thresholds, leaf values) and predictions.
/// Made by a short script with the arena's own environment (`uv run`,
/// lightgbm 4.7): `make(rng, n, 8)` rows, `LGBMRegressor(objective=
/// "quantile", alpha=a, **_params)`, `booster_.dump_model()`.
@Suite struct GBMParityTests {
    struct Ref: Decodable {
        let lightgbm: String
        let cases: [Case]
        struct Case: Decodable {
            let name: String
            let weekly: Bool
            let seed: Int
            let X: [[Double]]
            let y: [Double]
            let X_test: [[Double]]
            let levels: [Double]
            let boosters: [Booster]
        }
        struct Booster: Decodable {
            let alpha: Double
            let n_trees: Int
            let trees: [Tree]
            let pred_train_every: Int
            let pred_train: [Double]
            let pred_test: [Double]
        }
        struct Tree: Decodable {
            let feature: [Int]
            let threshold: [Double]
            let leaf_value: [Double]
            let num_leaves: Int
        }
    }

    static func params(weekly: Bool, seed: Int) -> KitMLGBM.Params {
        var p = KitMLGBM.Params()
        p.numLeaves = weekly ? 7 : 15
        p.minDataInLeaf = weekly ? 10 : 20
        p.seed = seed
        return p
    }

    /// Pre-order (node, left subtree, right subtree), as the dump walks it.
    static func preorder(_ t: KitMLGBM.Tree) -> (features: [Int], thresholds: [Double]) {
        var f: [Int] = [], th: [Double] = []
        func walk(_ node: Int32) {
            guard node >= 0 else { return }
            let i = Int(node)
            f.append(Int(t.feature[i])); th.append(t.threshold[i])
            walk(t.left[i]); walk(t.right[i])
        }
        if t.numLeaves > 1 { walk(0) }
        return (f, th)
    }

    @Test func treesAndPredictionsMatchLightGBM() throws {
        let ref = try JSONDecoder().decode(Ref.self, from: Data(contentsOf: ArenaFixtures.url("ml-gbm-lightgbm-ref")))
        var report: [String] = []
        for c in ref.cases {
            let nf = c.X[0].count
            let p = Self.params(weekly: c.weekly, seed: c.seed)
            let ds = KitMLGBM.Dataset(x: c.X.flatMap { $0 }, n: c.X.count, nFeatures: nf, params: p)
            // LightGBM's `Dataset.feature_num_bin` on these matrices (0: dropped).
            let lgbBins: [String: [Int]] = ["five": [63, 63, 63, 5, 0, 63, 0, 63], "weekly": [63, 38, 63, 5, 0, 63, 2, 58],
                                            "big": [63, 63, 63, 5, 0, 63, 2, 63]]
            let bins = (0..<nf).map { f in ds.used.firstIndex(of: f).map { ds.numBin[$0] } ?? 0 }
            #expect(lgbBins[c.name] == nil || bins == lgbBins[c.name]!, "\(c.name) bins \(bins)")
            for b in c.boosters {
                let mine = KitMLGBM.trainQuantile(ds, y: c.y, alpha: b.alpha, params: p)
                #expect(mine.trees.count == b.n_trees, "\(c.name) a=\(b.alpha): \(mine.trees.count) trees vs \(b.n_trees)")
                var treesEqual = 0
                for (i, rt) in b.trees.enumerated() where i < mine.trees.count {
                    let t = mine.trees[i]
                    let (f, th) = Self.preorder(t)
                    let same = t.numLeaves == rt.num_leaves && f == rt.feature
                        && zip(th, rt.threshold).allSatisfy { abs($0 - $1) <= 1e-12 * max(1, abs($1)) }
                        && zip(t.leafValue, rt.leaf_value).allSatisfy { abs($0 - $1) <= 1e-9 }
                    if same { treesEqual += 1 }
                    else if treesEqual == i {
                        report.append("\(c.name) a=\(b.alpha) tree \(i) differs: leaves \(t.numLeaves)/\(rt.num_leaves) "
                                      + "f \(f) vs \(rt.feature) th \(th) vs \(rt.threshold) leaf \(t.leafValue) vs \(rt.leaf_value)")
                    }
                }
                let train = stride(from: 0, to: c.X.count, by: b.pred_train_every).map { mine.predict(c.X[$0]) }
                let test = c.X_test.map { mine.predict($0) }
                let dTrain = zip(train, b.pred_train).map { abs($0 - $1) }
                let dTest = zip(test, b.pred_test).map { abs($0 - $1) }
                report.append(String(format: "%@ a=%.2f: first %d/%d trees equal; |d| train max %.2e mean %.2e, test max %.2e mean %.2e",
                                     c.name, b.alpha, treesEqual, b.trees.count, dTrain.max() ?? 0,
                                     dTrain.reduce(0, +) / Double(dTrain.count), dTest.max() ?? 0,
                                     dTest.reduce(0, +) / Double(dTest.count)))
                #expect(treesEqual == b.trees.count, "\(c.name) a=\(b.alpha)")
                #expect((dTest.max() ?? 0) < 1e-6, "\(c.name) a=\(b.alpha) test max \(dTest.max() ?? 0)")
                #expect((dTrain.max() ?? 0) < 1e-6, "\(c.name) a=\(b.alpha) train max \(dTrain.max() ?? 0)")
            }
        }
        print("GBM vs LightGBM \(ref.lightgbm):\n" + report.joined(separator: "\n"))
    }

    /// GBM_TREES=<case>,<alpha>,<path of all_trees.py output>: the first tree
    /// that differs from LightGBM's, printed side by side.
    @Test func debugFirstDifference() throws {
        guard let spec = ProcessInfo.processInfo.environment["GBM_TREES"] else { return }
        let parts = spec.split(separator: ",")
        let ci = Int(parts[0])!, alpha = Double(parts[1])!
        struct T: Decodable { let feature: [Int]; let threshold: [Double]; let gain: [Double]; let count: [Int]; let leaf_value: [Double] }
        let lgb = try JSONDecoder().decode([T].self, from: Data(contentsOf: URL(fileURLWithPath: String(parts[2]))))
        let ref = try JSONDecoder().decode(Ref.self, from: Data(contentsOf: ArenaFixtures.url("ml-gbm-lightgbm-ref")))
        let c = ref.cases[ci]
        let p = Self.params(weekly: c.weekly, seed: c.seed)
        let ds = KitMLGBM.Dataset(x: c.X.flatMap { $0 }, n: c.X.count, nFeatures: c.X[0].count, params: p)
        let b = KitMLGBM.trainQuantile(ds, y: c.y, alpha: alpha, params: p)
        for (i, t) in b.trees.enumerated() {
            let (f, th) = Self.preorder(t)
            var g: [Float] = []
            func walk(_ node: Int32) { guard node >= 0 else { return }; g.append(Float(t.splitGain[Int(node)])); walk(t.left[Int(node)]); walk(t.right[Int(node)]) }
            if t.numLeaves > 1 { walk(0) }
            let r = lgb[i]
            let same = f == r.feature && zip(th, r.threshold).allSatisfy { abs($0 - $1) <= 1e-9 * max(1, abs($1)) }
                && zip(t.leafValue, r.leaf_value).allSatisfy { abs($0 - $1) <= 1e-9 }
            if !same {
                print("tree \(i) differs\n mine f \(f)\n lgb  f \(r.feature)\n mine g \(g)\n lgb  g \(r.gain.map { Float($0) })\n lgb n \(r.count)\n mine th \(th)\n lgb  th \(r.threshold)\n mine v \(t.leafValue)\n lgb  v \(r.leaf_value)")
                return
            }
        }
        print("all \(b.trees.count) trees equal")
    }

    @Test func lightgbmRandomStreams() {
        // LightGBM's Random(seed=42): the first NextShort draws seed the
        // per-purpose generators; Sample is ascending and sized K.
        var r = KitMLGBM.LGBRandom(seed: 1)
        let a = r.randInt16(), b = r.randInt16()
        #expect(a == 41 && b == 18467)          // MSVC rand() with seed 1
        var s = KitMLGBM.LGBRandom(seed: 3)
        let pick = s.sample(70, 56)
        #expect(pick.count <= 56 && pick == pick.sorted())
    }
}
