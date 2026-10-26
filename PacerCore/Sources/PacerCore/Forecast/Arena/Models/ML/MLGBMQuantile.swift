import Foundation

/// `models/ml-gbm-quantile/model.py`: quantile gradient-boosted trees of the
/// meter's remaining rise.
///
/// Training (at the first forecast, from the history only): every past
/// cutoff on a fixed lattice where a cycle of the window kind was active, on
/// every visible account, described by the as-of features of
/// `KitMLFeatures` and labelled with the rise to several leads (fractions of
/// the time then left to the reset) already known at `now`
/// (`KitMLWalkforward`). The (cutoff, lead) pairs are stacked with the
/// lead's own features, and one booster per quantile level is fitted on
/// them: `KitMLGBM`, which follows LightGBM's algorithm for these parameters
/// (the Python uses LightGBM itself; Pacer takes no C++ dependency).
///
/// Calibration: quantile boosters fitted in-sample are too narrow out of
/// sample (neighbouring cutoffs of one cycle are near copies), so the spread
/// of each level around the median is rescaled by the factor that minimizes
/// its pinball loss out of fold, folds of whole cycles in time blocks
/// (`calibrate_folds`), shrunk toward a prior per level.
///
/// Forecast: the boosters' quantiles at 15 anchor leads, rescaled, sorted
/// (no crossing), made non-decreasing in lead and bounded by the headroom,
/// then read on the grid (`KitMLPaths.riseForecast`: the quantiles the
/// Python's comonotone paths are drawn from).
public final class MLGBMQuantileModel: KitMLLearnedMeterModel {
    public override class var modelName: String { "ml-gbm-quantile" }
    /// `SCALES = np.linspace(0.5, 4.0, 36)` (numpy: 0.5 + i·0.1, the last exactly 4).
    public static let scales: [Double] = (0..<36).map { (i: Int) -> Double in
        let step: Double = 3.5 / 35.0
        return i == 35 ? 4.0 : Double(i) * step + 0.5
    }
    public static let defaultLevels: [Double] = [0.03, 0.1, 0.25, 0.5, 0.75, 0.9, 0.97]

    /// Trained boosters per level and the out-of-fold spread scale.
    public struct State: Sendable {
        public var levels: [Double]
        public var boosters: [KitMLGBM.Booster]
        public var scale: [Double]
    }

    /// Fit the boosters of every fold and level at once, in parallel. Each
    /// is independent and deterministic, so the result is the same either way.
    public var parallel = true

    /// `pinball`: mean pinball loss of `q` at level `a` (numpy's mean).
    static func pinball(_ y: [Double], _ q: [Double], _ a: Double) -> Double {
        KitMLData.npMean(zip(y, q).map { yv, qv in
            let d = yv - qv
            return KitMLFeatures.pmax(a * d, (a - 1) * d)
        })
    }

    /// `_params`: LightGBM's settings for this kind.
    public func params(_ kind: String) -> KitMLGBM.Params {
        let weekly = kind != "five_hour"
        var p = KitMLGBM.Params()
        p.nEstimators = cfg.int("n_estimators", 150)
        p.learningRate = cfg.double("learning_rate", 0.05)
        p.numLeaves = cfg.int(weekly ? "weekly_num_leaves" : "num_leaves", weekly ? 7 : 15)
        p.minDataInLeaf = cfg.int(weekly ? "weekly_min_child_samples" : "min_child_samples", weekly ? 10 : 20)
        p.baggingFraction = 0.8; p.baggingFreq = 1; p.featureFraction = 0.8; p.lambdaL2 = 1.0
        p.maxBin = 63
        p.seed = Int(ctx.seed % (1 << 31))
        return p
    }

    /// `_fit` for several row sets at once: one booster per (set, level),
    /// `[set][level]`. A set is a list of stacked-row indices into `x`/`y`.
    func fit(sets: [[Int]], x: [Double], y: [Double], width: Int, levels: [Double],
             params p: KitMLGBM.Params) -> [[KitMLGBM.Booster]] {
        let datasets = sets.map { rows -> (KitMLGBM.Dataset, [Double]) in
            var xs: [Double] = []
            xs.reserveCapacity(rows.count * width)
            x.withUnsafeBufferPointer { xp in
                for i in rows { xs.append(contentsOf: UnsafeBufferPointer(start: xp.baseAddress! + i * width, count: width)) }
            }
            return (KitMLGBM.Dataset(x: xs, n: rows.count, nFeatures: width, params: p), rows.map { y[$0] })
        }
        let jobs = sets.indices.flatMap { s in levels.indices.map { (s, $0) } }
        let out = UnsafeMutableBufferPointer<KitMLGBM.Booster?>.allocate(capacity: jobs.count)
        out.initialize(repeating: nil)
        defer { out.deinitialize(); out.deallocate() }
        let slots = KitBox(out), data = KitBox(datasets)
        let work = { (i: Int) in
            let (s, j) = jobs[i]
            slots.value[i] = KitMLGBM.trainQuantile(data.value[s].0, y: data.value[s].1, alpha: levels[j], params: p)
        }
        if parallel && jobs.count > 1 {
            DispatchQueue.concurrentPerform(iterations: jobs.count, execute: work)
        } else {
            for i in jobs.indices { work(i) }
        }
        return sets.indices.map { s in levels.indices.map { j in out[s * levels.count + j]! } }
    }

    public override func train(_ ts: KitMLWalkforward.TrainSet, kind: String) throws -> Any {
        let (X, y, r, width) = ts.stacked()
        let kw = params(kind)
        let levels = cfg.doubles("levels", Self.defaultLevels)
        // Out-of-fold scales, shrunk toward a prior (`default_scale`, one per
        // level) by `prior_cycles` pseudo-cycles; the prior alone when there
        // are too few cycles to fold.
        let prior = cfg.doubles("default_scale", [Double](repeating: 1.0, count: levels.count))
        let n0 = cfg.double("prior_cycles", 10)
        var scale = prior
        let k = cfg.int("calibrate_folds", 3)
        let nCyc = ts.count > 0 ? (ts.cycle.max() ?? -1) + 1 : 0
        let mid = levels.firstIndex(of: 0.5)
        var foldSets: [(train: [Int], test: [Int])] = []
        if k >= 2 && nCyc >= 3 * k {
            // Folds of whole cycles in time blocks (a cycle's cutoffs are near
            // copies of each other).
            var first = [Millis](repeating: .max, count: nCyc)
            for (i, c) in ts.cycle.enumerated() { first[c] = min(first[c], ts.reset[i]) }
            var rank = [Int](repeating: 0, count: nCyc)
            for (pos, c) in first.indices.sorted(by: { (first[$0], $0) < (first[$1], $1) }).enumerated() { rank[c] = pos }
            let fold = r.map { rank[ts.cycle[$0]] * k / nCyc }
            for f in 0..<k {
                let tr = fold.indices.filter { fold[$0] != f }, te = fold.indices.filter { fold[$0] == f }
                if tr.count < 50 || te.isEmpty { continue }
                foldSets.append((tr, te))
            }
        }
        // The final boosters and every fold's, fitted together.
        try ctx.checkCancelled()
        let fitted = fit(sets: [Array(y.indices)] + foldSets.map(\.train), x: X, y: y, width: width, levels: levels,
                         params: kw)
        if !foldSets.isEmpty {
            var oof = [[Double]](repeating: [Double](repeating: .nan, count: y.count), count: levels.count)
            X.withUnsafeBufferPointer { xp in
                for (fi, fs) in foldSets.enumerated() {
                    for (j, b) in fitted[fi + 1].enumerated() {
                        for i in fs.test { oof[j][i] = b.predict(xp.baseAddress! + i * width) }
                    }
                }
            }
            let ok = y.indices.filter { i in levels.indices.allSatisfy { oof[$0][i].isFinite } }
            if ok.count >= 50 {
                let med: [Double] = mid.map { m in ok.map { oof[m][$0] } }
                    ?? ok.map { i in KitDetQ.median(levels.indices.map { oof[$0][i] }) }
                let yy = ok.map { y[$0] }
                for (j, a) in levels.enumerated() where a != 0.5 {
                    let o = ok.map { oof[j][$0] }
                    let losses = Self.scales.map { s in
                        Self.pinball(yy, zip(med, o).map { m, q in m + s * (q - m) }, a)
                    }
                    var best = 0
                    for i in 1..<losses.count where losses[i] < losses[best] { best = i }
                    scale[j] = (Double(nCyc) * Self.scales[best] + n0 * prior[j]) / (Double(nCyc) + n0)
                }
            }
        }
        ctx.log("\(Self.modelName) \(kind): \(nCyc) cycles, spread scale "
                + zip(levels, scale).map { String(format: "%g:%.2f", $0, $1) }.joined(separator: " "))
        return State(levels: levels, boosters: fitted[0], scale: scale)
    }

    public override func predict(_ state: Any, row: [Double], leadX: [[Double]], fracs: [Double], gridFracs: [Double],
                                 used: Double) -> ArenaTargetForecast {
        let st = state as! State
        let rows = fracs.indices.map { row + leadX[$0] }
        var q = st.boosters.map { b in rows.map { b.predict($0) } }   // [levels][anchors]
        let med: [Double] = st.levels.firstIndex(of: 0.5).map { q[$0] }
            ?? fracs.indices.map { j in KitDetQ.median(q.map { $0[j] }) }
        for i in q.indices { for j in fracs.indices { q[i][j] = med[j] + st.scale[i] * (q[i][j] - med[j]) } }
        return KitMLPaths.riseForecast(levels: st.levels, q: q, anchorFracs: fracs, gridFracs: gridFracs, used: used)
    }
}
