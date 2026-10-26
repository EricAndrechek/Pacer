import Foundation

// A small gradient-boosted-trees quantile regressor for `ml-gbm-quantile`,
// following LightGBM (4.x) for the parameters that model uses
// (`models/ml-gbm-quantile/model.py` `_params`): objective `quantile`,
// leaf-wise growth to `num_leaves`, `min_data_in_leaf`, L2 on the leaf gain,
// histogram split finding over features pre-binned to at most `max_bin`
// bins, bagging (`subsample` every `subsample_freq` rounds) and a feature
// subset per tree (`colsample_bytree`), all seeded from `random_state`.
// Pacer takes no C++ dependency, so this is a port of the algorithm, not a
// binding; it reproduces LightGBM's own choices where they decide the model:
//
// - **Bins** (`BinMapper::FindBin`): zero gets a bin of its own, the rest
//   greedily into bins of about equal count with bounds halfway between
//   distinct values; a feature with one bin, or none that leaves
//   `min_data_in_leaf` rows each side, is dropped (`feature_pre_filter`).
// - **Start** (`BoostFromScore`): the `alpha` quantile of the labels
//   (numpy's linear rule; LightGBM keeps labels as float32, and so does this).
// - **Gradients**: `1 − alpha` where the score is at or above the label,
//   `−alpha` below; hessians 1. A histogram therefore only needs, per bin,
//   how many rows fall in it and how many of those are below their label:
//   integer counts, and the gradient sums LightGBM adds up in doubles are
//   exact multiples of the two float32 gradients, so the gains here are the
//   same doubles LightGBM computes, whatever the summation order.
// - **Splits**: per feature the reverse scan over bins of
//   `FindBestThresholdSequentially`, gain `G²/(H+λ)` summed over both sides
//   minus the parent's, ties to the larger threshold, then the smaller
//   feature, then the lower leaf index; growth stops at no positive gain. A
//   feature with no positive-gain split at a node is not tried below it
//   (`is_splittable`): a heuristic of LightGBM's that changes which trees it
//   grows, kept because it does.
// - **Leaf values** (`RenewTreeOutput`): the quantile objective does not use
//   the Newton step: every leaf is renewed to LightGBM's `PercentileFun`
//   (numpy's linear quantile) of the residuals (label − score) of the in-bag rows in it, then shrunk by
//   the learning rate. The first tree carries the start value.
// - **Random streams**: LightGBM's `Random` (an LCG), the per-purpose seeds
//   it derives from `seed`, Bernoulli bagging per row in blocks of 1024 rows
//   with one generator each, `Random::Sample` for the per-tree features.
//
// What is left is float noise (none was found against LightGBM 4.7 on the
// fixtures: see `GBMParityTests`). Training cost is dominated by histogram
// building over the in-bag rows, once per tree for the smaller child of each
// split (the larger is the parent minus it, exactly, in integers).

public enum KitMLGBM {
    /// LightGBM's `kEpsilon` (a float literal) and `kZeroThreshold`.
    static let kEpsilon = Double(Float(1e-15))
    static let kZeroThreshold = Double(Float(1e-35))

    public struct Params: Sendable, Equatable {
        public var nEstimators = 150
        public var learningRate = 0.05
        public var numLeaves = 15
        public var minDataInLeaf = 20
        public var minSumHessianInLeaf = 1e-3
        public var baggingFraction = 0.8
        public var baggingFreq = 1
        public var featureFraction = 0.8
        public var lambdaL2 = 1.0
        public var maxBin = 63
        public var minDataInBin = 3
        /// `random_state` (`seed`): every other seed is derived from it.
        public var seed = 0
        public var featurePreFilter = true
        public init() {}
    }

    // MARK: - LightGBM's random numbers

    /// `LightGBM::Random`: `x = 214013 x + 2531011` on 32 bits.
    struct LGBRandom {
        var x: UInt32
        init(seed: Int32) { x = UInt32(bitPattern: seed) }

        mutating func randInt16() -> Int32 {
            x = 214_013 &* x &+ 2_531_011
            return Int32(truncatingIfNeeded: (x >> 16) & 0x7FFF)
        }

        mutating func randInt32() -> Int32 {
            x = 214_013 &* x &+ 2_531_011
            return Int32(truncatingIfNeeded: x & 0x7FFF_FFFF)
        }

        mutating func nextShort(_ lo: Int32, _ hi: Int32) -> Int32 { randInt16() % (hi - lo) + lo }
        mutating func nextInt(_ lo: Int32, _ hi: Int32) -> Int32 { randInt32() % (hi - lo) + lo }
        /// [0, 1), in steps of 1/32768.
        mutating func nextFloat() -> Float { Float(randInt16()) / 32768.0 }

        /// `Random::Sample(N, K)`: K of 0..<N, ascending.
        mutating func sample(_ n: Int, _ k: Int) -> [Int] {
            if k > n || k <= 0 { return [] }
            if k == n { return Array(0..<n) }
            var ret: [Int] = []
            ret.reserveCapacity(k)
            if k > 1 && Double(k) > Double(n) / log2(Double(k)) {
                for i in 0..<n {
                    let prob = Double(k - ret.count) / Double(n - i)
                    if Double(nextFloat()) < prob { ret.append(i) }
                }
            } else {
                var set = Set<Int>()
                for r in (n - k)..<n {
                    let v = Int(nextInt(0, Int32(r + 1)))
                    if !set.insert(v).inserted { set.insert(r) }
                }
                ret = set.sorted()
            }
            return ret
        }
    }

    /// The seeds `Config::Set` derives from `seed`, in its order.
    struct Seeds {
        var dataRandom: Int32, bagging: Int32, drop: Int32, featureFraction: Int32, objective: Int32, extra: Int32
        init(_ seed: Int) {
            var r = LGBRandom(seed: Int32(truncatingIfNeeded: seed))
            let m = Int32(Int16.max)
            dataRandom = r.nextShort(0, m)
            bagging = r.nextShort(0, m)
            drop = r.nextShort(0, m)
            featureFraction = r.nextShort(0, m)
            objective = r.nextShort(0, m)
            extra = r.nextShort(0, m)
        }
    }

    // MARK: - Bins (BinMapper::FindBin, numerical, no missing values)

    /// `Common::GetDoubleUpperBound`.
    @inline(__always) static func upperBound(_ a: Double) -> Double { a.nextUp }
    /// `Common::CheckDoubleEqualOrdered`: b within one ulp above a.
    @inline(__always) static func equalOrdered(_ a: Double, _ b: Double) -> Bool { b <= a.nextUp }

    static func greedyFindBin(_ dv: ArraySlice<Double>, _ counts: ArraySlice<Int>, maxBin maxBinIn: Int,
                              totalCnt: Int, minDataInBin: Int) -> [Double] {
        let dv = Array(dv), counts = Array(counts)
        let nd = dv.count
        var bounds: [Double] = []
        if nd <= maxBinIn {
            var cur = 0
            for i in 0..<(nd - 1) {
                cur += counts[i]
                if cur >= minDataInBin {
                    let val = upperBound((dv[i] + dv[i + 1]) / 2.0)
                    if bounds.isEmpty || !equalOrdered(bounds[bounds.count - 1], val) {
                        bounds.append(val)
                        cur = 0
                    }
                }
            }
            bounds.append(.infinity)
            return bounds
        }
        var maxBin = maxBinIn
        if minDataInBin > 0 {
            maxBin = min(maxBin, totalCnt / minDataInBin)
            maxBin = max(maxBin, 1)
        }
        var meanBinSize = Double(totalCnt) / Double(maxBin)
        var restBinCnt = maxBin
        var restSampleCnt = totalCnt
        var isBig = [Bool](repeating: false, count: nd)
        for i in 0..<nd where Double(counts[i]) >= meanBinSize {
            isBig[i] = true
            restBinCnt -= 1
            restSampleCnt -= counts[i]
        }
        meanBinSize = Double(restSampleCnt) / Double(restBinCnt)
        var upper = [Double](repeating: .infinity, count: maxBin)
        var lower = [Double](repeating: .infinity, count: maxBin)
        var binCnt = 0
        lower[0] = dv[0]
        var cur = 0
        for i in 0..<(nd - 1) {
            if !isBig[i] { restSampleCnt -= counts[i] }
            cur += counts[i]
            if isBig[i] || Double(cur) >= meanBinSize
                || (isBig[i + 1] && Double(cur) >= max(1.0, meanBinSize * Double(Float(0.5)))) {
                upper[binCnt] = dv[i]
                binCnt += 1
                lower[binCnt] = dv[i + 1]
                if binCnt >= maxBin - 1 { break }
                cur = 0
                if !isBig[i] {
                    restBinCnt -= 1
                    meanBinSize = Double(restSampleCnt) / Double(restBinCnt)
                }
            }
        }
        binCnt += 1
        for i in 0..<(binCnt - 1) {
            let val = upperBound((upper[i] + lower[i + 1]) / 2.0)
            if bounds.isEmpty || !equalOrdered(bounds[bounds.count - 1], val) { bounds.append(val) }
        }
        bounds.append(.infinity)
        return bounds
    }

    static func findBinWithZeroAsOneBin(_ dv: [Double], _ counts: [Int], maxBin: Int, totalSampleCnt: Int,
                                        minDataInBin: Int) -> [Double] {
        let nd = dv.count
        var leftCntData = 0, cntZero = 0, rightCntData = 0
        for i in 0..<nd {
            if dv[i] <= -kZeroThreshold { leftCntData += counts[i] }
            else if dv[i] > kZeroThreshold { rightCntData += counts[i] }
            else { cntZero += counts[i] }
        }
        var leftCnt = -1
        for i in 0..<nd where dv[i] > -kZeroThreshold { leftCnt = i; break }
        if leftCnt < 0 { leftCnt = nd }
        var bounds: [Double] = []
        if leftCnt > 0 && maxBin > 1 {
            var leftMaxBin = Int(Double(leftCntData) / Double(totalSampleCnt - cntZero) * Double(maxBin - 1))
            leftMaxBin = max(1, leftMaxBin)
            bounds = greedyFindBin(dv[0..<leftCnt], counts[0..<leftCnt], maxBin: leftMaxBin, totalCnt: leftCntData,
                                   minDataInBin: minDataInBin)
            if !bounds.isEmpty { bounds[bounds.count - 1] = -kZeroThreshold }
        }
        var rightStart = -1
        for i in leftCnt..<nd where dv[i] > kZeroThreshold { rightStart = i; break }
        let rightMaxBin = maxBin - 1 - bounds.count
        if rightStart >= 0 && rightMaxBin > 0 {
            let rb = greedyFindBin(dv[rightStart...], counts[rightStart...], maxBin: rightMaxBin,
                                   totalCnt: rightCntData, minDataInBin: minDataInBin)
            bounds.append(kZeroThreshold)
            bounds.append(contentsOf: rb)
        } else {
            bounds.append(.infinity)
        }
        return bounds
    }

    /// One feature's bin bounds from its non-zero values (zeros, |v| ≤
    /// 1e-35, are only counted), or nil when LightGBM would drop it.
    static func findBin(nonZero values: [Double], totalSampleCnt: Int, maxBin: Int, minDataInBin: Int,
                        minSplitData: Int, preFilter: Bool) -> [Double]? {
        let vals = values.sorted()
        let zeroCnt = totalSampleCnt - vals.count
        var dv: [Double] = [], counts: [Int] = []
        if vals.isEmpty || (vals[0] > 0 && zeroCnt > 0) { dv.append(0); counts.append(zeroCnt) }
        if !vals.isEmpty { dv.append(vals[0]); counts.append(1) }
        if vals.count > 1 {
            for i in 1..<vals.count {
                if !equalOrdered(vals[i - 1], vals[i]) {
                    if vals[i - 1] < 0 && vals[i] > 0 { dv.append(0); counts.append(zeroCnt) }
                    dv.append(vals[i]); counts.append(1)
                } else {
                    dv[dv.count - 1] = vals[i]     // the larger value
                    counts[counts.count - 1] += 1
                }
            }
        }
        if let last = vals.last, last < 0, zeroCnt > 0 { dv.append(0); counts.append(zeroCnt) }
        let bounds = findBinWithZeroAsOneBin(dv, counts, maxBin: maxBin, totalSampleCnt: totalSampleCnt,
                                             minDataInBin: minDataInBin)
        let numBin = bounds.count
        if numBin <= 1 { return nil }
        if preFilter {
            var cntInBin = [Int](repeating: 0, count: numBin)
            var b = 0
            for i in dv.indices {
                while dv[i] > bounds[b] && b < numBin - 1 { b += 1 }
                cntInBin[b] += counts[i]
            }
            // NeedFilter: no cut leaves `minSplitData` on both sides.
            var sumLeft = 0, splittable = false
            for i in 0..<(numBin - 1) {
                sumLeft += cntInBin[i]
                if sumLeft >= minSplitData && totalSampleCnt - sumLeft >= minSplitData { splittable = true; break }
            }
            if !splittable { return nil }
        }
        return bounds
    }

    /// `BinMapper::ValueToBin`: the first bin whose upper bound is ≥ value.
    @inline(__always) static func valueToBin(_ value: Double, _ bounds: [Double]) -> Int {
        let v = value.isNaN ? 0 : value
        var l = 0, r = bounds.count - 1
        while l < r {
            let m = (r + l - 1) / 2
            if v <= bounds[m] { r = m } else { l = m + 1 }
        }
        return l
    }

    // MARK: - Dataset

    /// Features binned once, shared by every booster trained on the same
    /// rows (the levels of one fit). Row-major input, `n × nFeatures`.
    public final class Dataset: @unchecked Sendable {
        public let n: Int
        public let nFeatures: Int
        /// Original column of each kept (inner) feature, ascending.
        let used: [Int]
        let bounds: [[Double]]
        let numBin: [Int]
        /// `bins[k * n + i]`: inner feature k of row i.
        let bins: [UInt8]
        /// Per inner feature, its first slot in a leaf histogram: one UInt64
        /// per bin, rows in the low 32 bits and rows below their label in the
        /// high 32 (one add per row and feature builds both).
        let histOffset: [Int]
        let histSize: Int
        /// LightGBM's `most_freq_bin_`: the fullest bin when it holds at
        /// least 70 % of the rows, else the bin of 0. When it is not bin 0,
        /// LightGBM does not store it and rebuilds its sums from the leaf's
        /// (`FixHistogram`), which is where hessians stop being integers.
        let mostFreqBin: [Int]

        public init(x: [Double], n: Int, nFeatures: Int, params p: Params) {
            precondition(x.count == n * nFeatures)
            precondition(p.maxBin <= 256, "bins are bytes")
            self.n = n; self.nFeatures = nFeatures
            var used: [Int] = [], bounds: [[Double]] = []
            var col = [Double](); col.reserveCapacity(n)
            for f in 0..<nFeatures {
                col.removeAll(keepingCapacity: true)
                for i in 0..<n {
                    let v = x[i * nFeatures + f]
                    if abs(v) > kZeroThreshold || v.isNaN { if !v.isNaN { col.append(v) } }
                }
                // Every row is in the bin sample (LightGBM samples
                // `bin_construct_sample_cnt` = 200000 rows), so the
                // pre-filter count is `min_data_in_leaf` itself.
                if let b = findBin(nonZero: col, totalSampleCnt: n, maxBin: p.maxBin, minDataInBin: p.minDataInBin,
                                   minSplitData: p.minDataInLeaf, preFilter: p.featurePreFilter) {
                    used.append(f); bounds.append(b)
                }
            }
            self.used = used; self.bounds = bounds
            numBin = bounds.map(\.count)
            var off: [Int] = [], s = 0
            for nb in numBin { off.append(s); s += nb }
            histOffset = off; histSize = s
            var bins = [UInt8](repeating: 0, count: used.count * n)
            for (k, f) in used.enumerated() {
                let b = bounds[k]
                for i in 0..<n { bins[k * n + i] = UInt8(valueToBin(x[i * nFeatures + f], b)) }
            }
            self.bins = bins
            var mfb: [Int] = []
            for k in used.indices {
                var cnt = [Int](repeating: 0, count: numBin[k])
                for i in 0..<n { cnt[Int(bins[k * n + i])] += 1 }
                var arg = 0
                for b in 1..<cnt.count where cnt[b] > cnt[arg] { arg = b }
                let zeroBin = valueToBin(0, bounds[k])
                if arg != zeroBin && Double(cnt[arg]) / Double(n) < 0.7 { arg = zeroBin }
                mfb.append(arg)
            }
            mostFreqBin = mfb
        }

        public var usedFeatures: [Int] { used }
    }

    // MARK: - Trees

    public struct Tree: Sendable {
        /// Internal node i: original feature, its bin threshold and real
        /// threshold (`value <= threshold` goes left), children (`>= 0` an
        /// internal node, `< 0` the leaf `~child`).
        public var feature: [Int32] = []
        var featureInner: [Int32] = []
        var thresholdBin: [Int32] = []
        public var threshold: [Double] = []
        /// The split's gain over its parent (LightGBM's `split_gain`).
        public var splitGain: [Double] = []
        public var left: [Int32] = []
        public var right: [Int32] = []
        public var leafValue: [Double] = [0]
        var leafParent: [Int32] = [-1]
        public var numLeaves: Int { leafValue.count }

        static func constant(_ v: Double) -> Tree { var t = Tree(); t.leafValue = [v]; return t }

        /// `Tree::Split`: leaf `leaf` becomes internal node `numLeaves - 1`,
        /// its rows to `leaf` (left) and a new leaf (right).
        mutating func split(leaf: Int, inner: Int, feature f: Int, thresholdBin: Int, threshold: Double,
                            gain: Double = 0) -> Int {
            let node = Int32(numLeaves - 1)
            let parent = leafParent[leaf]
            if parent >= 0 {
                if left[Int(parent)] == ~Int32(leaf) { left[Int(parent)] = node } else { right[Int(parent)] = node }
            }
            feature.append(Int32(f)); featureInner.append(Int32(inner))
            self.thresholdBin.append(Int32(thresholdBin)); self.threshold.append(threshold)
            splitGain.append(gain)
            left.append(~Int32(leaf)); right.append(~Int32(numLeaves))
            leafParent[leaf] = node
            leafParent.append(node)
            leafValue.append(0)
            return numLeaves - 1
        }

        @inline(__always) func leaf(row x: UnsafePointer<Double>) -> Int {
            if numLeaves <= 1 { return 0 }
            var node: Int32 = 0
            while node >= 0 {
                let i = Int(node)
                node = x[Int(feature[i])] <= threshold[i] ? left[i] : right[i]
            }
            return Int(~node)
        }

        @inline(__always) func leaf(binned ds: Dataset, row: Int) -> Int {
            if numLeaves <= 1 { return 0 }
            var node: Int32 = 0
            while node >= 0 {
                let i = Int(node)
                let k = Int(featureInner[i])
                node = Int32(ds.bins[k * ds.n + row]) <= thresholdBin[i] ? left[i] : right[i]
            }
            return Int(~node)
        }
    }

    public struct Booster: Sendable {
        public var trees: [Tree]
        public var nFeatures: Int

        /// The raw score of one row (`nFeatures` values): the trees' sum.
        public func predict(_ row: [Double]) -> Double {
            precondition(row.count == nFeatures)
            return row.withUnsafeBufferPointer { p in
                var s = 0.0
                for t in trees { s += t.leafValue[t.leaf(row: p.baseAddress!)] }
                return s
            }
        }

        /// One row at `x[0..<nFeatures]`.
        @inline(__always) public func predict(_ x: UnsafePointer<Double>) -> Double {
            var s = 0.0
            for t in trees { s += t.leafValue[t.leaf(row: x)] }
            return s
        }

        /// Row-major `n × nFeatures`.
        public func predict(rows x: [Double]) -> [Double] {
            let n = nFeatures == 0 ? 0 : x.count / nFeatures
            return x.withUnsafeBufferPointer { p in
                (0..<n).map { i in
                    var s = 0.0
                    let r = p.baseAddress! + i * nFeatures
                    for t in trees { s += t.leafValue[t.leaf(row: r)] }
                    return s
                }
            }
        }
    }

    // MARK: - Percentiles

    /// LightGBM's `PercentileFun` (4.x): numpy's default quantile (linear,
    /// type 7) read from the descending order statistics,
    /// `d[p] − (d[p] − d[p+1])·bias` at `(1 − alpha)·(n − 1)`; in doubles
    /// for the leaf renewal. (Measured against LightGBM 4.7: the start value
    /// and every renewed leaf equal `np.quantile` of the labels/residuals.)
    static func percentile(_ v: inout [Double], alpha: Float) -> Double {
        let n = v.count
        if n <= 1 { return v.first ?? 0 }
        let floatPos = (1.0 - Double(alpha)) * Double(n - 1)
        let pos = Int(floatPos)
        v.sort(by: >)
        if pos >= n - 1 { return v[n - 1] }
        let bias = floatPos - Double(pos)
        let v1 = v[pos], v2 = v[pos + 1]
        return v1 - (v1 - v2) * bias
    }

    /// The same on float32 labels (`BoostFromScore`), rounded as LightGBM
    /// rounds it (the difference in float32, the result cast to float32).
    static func percentileFloat(_ v: [Float], alpha: Float) -> Float {
        let n = v.count
        if n == 0 { return 0 }
        if n <= 1 { return v[0] }
        let floatPos = (1.0 - Double(alpha)) * Double(n - 1)
        let pos = Int(floatPos)
        let d = v.sorted(by: >)
        if pos >= n - 1 { return d[n - 1] }
        let bias = floatPos - Double(pos)
        let v1 = d[pos], v2 = d[pos + 1]
        return Float(Double(v1) - Double(v1 - v2) * bias)
    }

    // MARK: - Training

    struct SplitInfo {
        var gain = -Double.infinity
        var inner = -1
        var thresholdBin = 0
        var leftCount = 0
        var leftG = 0.0, leftH = 0.0
        var rightCount = 0
        var rightG = 0.0, rightH = 0.0
    }

    /// One quantile booster on `ds` (labels `y`, one per row).
    public static func trainQuantile(_ ds: Dataset, y: [Double], alpha: Double, params p: Params) -> Booster {
        trainQuantile(ds, y: y, alpha: alpha, params: p, trace: nil)
    }

    /// `trace(iter, leaf, rows, features tried, best split)` after every
    /// split search below the root (tests only).
    static func trainQuantile(_ ds: Dataset, y: [Double], alpha: Double, params p: Params,
                              trace: ((Int, Int, Int, [Bool], SplitInfo, [UInt64], Double, Double) -> Void)?) -> Booster {
        let n = ds.n
        precondition(y.count == n)
        let alphaF = Float(alpha)
        let labelF = y.map { Float($0) }
        let label = labelF.map { Double($0) }
        let gPos = Double(Float(1) - alphaF), gNeg = Double(-alphaF)
        var start = Double(percentileFloat(labelF, alpha: alphaF))
        if !(abs(start) > kEpsilon) { start = 0 }
        var score = [Double](repeating: start, count: n)
        var trees: [Tree] = []
        guard n > 0 else { return Booster(trees: [.constant(start)], nFeatures: ds.nFeatures) }

        let seeds = Seeds(p.seed)
        var bagRands = (0..<((n + 1023) / 1024)).map { LGBRandom(seed: seeds.bagging &+ Int32($0)) }
        var colRand = LGBRandom(seed: seeds.featureFraction)
        let nInner = ds.used.count
        let useColSample = p.featureFraction < 1.0
        let usedCnt = max(Int((Double(nInner) * p.featureFraction + 0.5).rounded(.down)), min(2, nInner))
        var featureUsed = [Bool](repeating: true, count: nInner)
        func resetByTree() {
            guard useColSample else { return }
            for k in 0..<nInner { featureUsed[k] = false }
            for k in colRand.sample(nInner, usedCnt) { featureUsed[k] = true }
        }
        // `ColSampler::SetTrainingData` samples once before the first tree.
        resetByTree()

        let useBagging = p.baggingFraction < 1.0 && p.baggingFreq > 0
        var bagCount = useBagging ? Int(p.baggingFraction * Double(n)) : n
        var inBag = [Bool](repeating: true, count: n)
        var bag = [Int32](0..<Int32(n))
        var below = [UInt8](repeating: 0, count: n)
        var indices = [Int32](repeating: 0, count: n)
        var scratch = [Int32](repeating: 0, count: n)
        var hists = [[UInt64]](repeating: [UInt64](repeating: 0, count: ds.histSize), count: max(p.numLeaves, 1))
        var leafBegin = [Int](repeating: 0, count: p.numLeaves), leafCount = [Int](repeating: 0, count: p.numLeaves)
        var leafG = [Double](repeating: 0, count: p.numLeaves), leafH = [Double](repeating: 0, count: p.numLeaves)
        var best = [SplitInfo](repeating: SplitInfo(), count: p.numLeaves)
        // Per leaf and feature: whether that leaf had any split on it with
        // positive gain (`FeatureHistogram::is_splittable_`). LightGBM skips
        // a feature for both children of a leaf where it was not, so a
        // feature that could not split a node is never tried below it.
        var splittable = [[Bool]](repeating: [Bool](repeating: false, count: nInner), count: p.numLeaves)
        var allowed = [Bool](repeating: false, count: nInner)
        // The hessian LightGBM holds in each leaf's histogram for a feature's
        // most frequent bin when that is not bin 0 (see `mostFreqBin`).
        var mfbH = [[Double]](repeating: [Double](repeating: 0, count: nInner), count: p.numLeaves)
        func fixHistogram(_ leaf: Int, sumH: Double, used: [Bool]) {
            for k in 0..<nInner where used[k] && ds.mostFreqBin[k] > 0 {
                let off = ds.histOffset[k], mf = ds.mostFreqBin[k]
                var h = sumH
                for b in 0..<ds.numBin[k] where b != mf { h -= Double(hists[leaf][off + b] & 0xFFFF_FFFF) }
                mfbH[leaf][k] = h
            }
        }
        var resid: [Double] = []

        for iter in 0..<p.nEstimators {
            if useBagging && bagCount < n && iter % p.baggingFreq == 0 {
                bag.removeAll(keepingCapacity: true)
                for i in 0..<n {
                    let keep = Double(bagRands[i / 1024].nextFloat()) < p.baggingFraction
                    inBag[i] = keep
                    if keep { bag.append(Int32(i)) }
                }
                bagCount = bag.count
            }
            for i in 0..<n { below[i] = score[i] - label[i] >= 0 ? 0 : 1 }
            resetByTree()

            // Grow one tree on the bag, leaf-wise.
            var tree = Tree()
            let m = bag.count
            for j in 0..<m { indices[j] = bag[j] }
            for l in 0..<p.numLeaves { best[l] = SplitInfo() }
            leafBegin[0] = 0; leafCount[0] = m
            var g0 = 0.0
            for j in 0..<m { g0 += below[Int(indices[j])] == 1 ? gNeg : gPos }
            leafG[0] = g0; leafH[0] = Double(m)
            if m > 0 {
                buildHistogram(ds, indices: indices, begin: 0, count: m, below: below, used: featureUsed, into: &hists[0])
                fixHistogram(0, sumH: leafH[0], used: featureUsed)
                best[0] = findBestSplit(ds, hist: hists[0], mfbH: mfbH[0], sumG: leafG[0], sumH: leafH[0], count: m,
                                        used: featureUsed, splittable: &splittable[0], gPos: gPos, gNeg: gNeg, p: p)
            }
            for _ in 0..<(p.numLeaves - 1) {
                var bl = 0
                for l in 1..<tree.numLeaves where better(best[l], than: best[bl]) { bl = l }
                let s = best[bl]
                if !(s.gain > 0) { break }
                // Partition the leaf's rows, stable, left (bin <= threshold) first.
                let b0 = leafBegin[bl], cnt = leafCount[bl]
                let k = s.inner
                var nl = 0, nr = 0
                ds.bins.withUnsafeBufferPointer { bins in
                    let col = bins.baseAddress! + k * n
                    for j in b0..<(b0 + cnt) {
                        let r = indices[j]
                        if Int(col[Int(r)]) <= s.thresholdBin { indices[b0 + nl] = r; nl += 1 }
                        else { scratch[nr] = r; nr += 1 }
                    }
                }
                for j in 0..<nr { indices[b0 + nl + j] = scratch[j] }
                let f = ds.used[k]
                let rl = tree.split(leaf: bl, inner: k, feature: f, thresholdBin: s.thresholdBin,
                                    threshold: ds.bounds[k][s.thresholdBin], gain: s.gain)
                leafBegin[bl] = b0; leafCount[bl] = nl
                leafBegin[rl] = b0 + nl; leafCount[rl] = nr
                leafG[bl] = s.leftG; leafH[bl] = s.leftH
                leafG[rl] = s.rightG; leafH[rl] = s.rightH
                // The smaller child's histogram from its rows; the larger's by
                // subtraction from the parent's (exact: integer counts).
                let parentHist = hists[bl], parentMfbH = mfbH[bl]
                let (small, large) = s.leftCount < s.rightCount ? (bl, rl) : (rl, bl)
                buildHistogram(ds, indices: indices, begin: leafBegin[small], count: leafCount[small], below: below,
                               used: featureUsed, into: &hists[small])
                fixHistogram(small, sumH: leafH[small], used: featureUsed)
                hists[large] = parentHist
                subtract(&hists[large], hists[small], ds: ds, used: featureUsed)
                for k in 0..<nInner { mfbH[large][k] = parentMfbH[k] - mfbH[small][k] }
                if leafCount[bl] < 2 * p.minDataInLeaf && leafCount[rl] < 2 * p.minDataInLeaf {
                    best[bl] = SplitInfo(); best[rl] = SplitInfo()
                } else {
                    for k in 0..<nInner { allowed[k] = featureUsed[k] && splittable[bl][k] }
                    splittable[rl] = splittable[bl]
                    for l in [bl, rl] {
                        best[l] = findBestSplit(ds, hist: hists[l], mfbH: mfbH[l], sumG: leafG[l], sumH: leafH[l],
                                                count: leafCount[l],
                                                used: allowed, splittable: &splittable[l], gPos: gPos, gNeg: gNeg, p: p)
                        trace?(iter, l, leafCount[l], allowed, best[l], hists[l], leafG[l], leafH[l])
                    }
                }
            }

            if tree.numLeaves > 1 {
                // Renew each leaf to the percentile of its in-bag residuals,
                // then shrink and add to every row's score.
                for l in 0..<tree.numLeaves {
                    resid.removeAll(keepingCapacity: true)
                    for j in leafBegin[l]..<(leafBegin[l] + leafCount[l]) {
                        let r = Int(indices[j])
                        resid.append(label[r] - score[r])
                    }
                    tree.leafValue[l] = roundToZero(percentile(&resid, alpha: alphaF))
                }
                for l in 0..<tree.numLeaves { tree.leafValue[l] = roundToZero(tree.leafValue[l] * p.learningRate) }
                for l in 0..<tree.numLeaves {
                    let v = tree.leafValue[l]
                    for j in leafBegin[l]..<(leafBegin[l] + leafCount[l]) { score[Int(indices[j])] += v }
                }
                if m < n {
                    for i in 0..<n where !inBag[i] { score[i] += tree.leafValue[tree.leaf(binned: ds, row: i)] }
                }
                if iter == 0 && abs(start) > kEpsilon {
                    for l in 0..<tree.numLeaves { tree.leafValue[l] = roundToZero(tree.leafValue[l] + start) }
                }
                trees.append(tree)
            } else {
                // No split with positive gain: LightGBM stops here (a first
                // tree becomes the constant start).
                if trees.isEmpty { trees.append(.constant(start)) }
                break
            }
        }
        return Booster(trees: trees, nFeatures: ds.nFeatures)
    }

    @inline(__always) static func roundToZero(_ x: Double) -> Double { abs(x) <= kZeroThreshold ? 0 : x }

    /// `SplitInfo::operator>`: larger gain, then the smaller feature.
    @inline(__always) static func better(_ a: SplitInfo, than b: SplitInfo) -> Bool {
        if a.gain != b.gain { return a.gain > b.gain }
        let fa = a.inner < 0 ? Int.max : a.inner, fb = b.inner < 0 ? Int.max : b.inner
        return fa < fb
    }

    static func buildHistogram(_ ds: Dataset, indices: [Int32], begin: Int, count: Int, below: [UInt8], used: [Bool],
                               into hist: inout [UInt64]) {
        let n = ds.n
        hist.withUnsafeMutableBufferPointer { h in
            ds.bins.withUnsafeBufferPointer { bins in
                indices.withUnsafeBufferPointer { idx in
                    below.withUnsafeBufferPointer { bl in
                        for k in 0..<ds.used.count where used[k] {
                            let hp = h.baseAddress! + ds.histOffset[k]
                            hp.update(repeating: 0, count: ds.numBin[k])
                            let col = bins.baseAddress! + k * n
                            let ix = idx.baseAddress!, b = bl.baseAddress!
                            for j in begin..<(begin + count) {
                                let r = Int(ix[j])
                                hp[Int(col[r])] &+= 1 &+ (UInt64(b[r]) << 32)
                            }
                        }
                    }
                }
            }
        }
    }

    static func subtract(_ a: inout [UInt64], _ b: [UInt64], ds: Dataset, used: [Bool]) {
        a.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                for k in 0..<ds.used.count where used[k] {
                    let off = ds.histOffset[k]
                    for s in off..<(off + ds.numBin[k]) { ap[s] &-= bp[s] }
                }
            }
        }
    }

    /// The best split of one leaf over the features in use
    /// (`FindBestThresholdSequentially`, reverse scan, no missing values).
    /// `splittable[k]` is set for every feature tried: whether any of its
    /// thresholds had positive gain. Features not tried keep their flag.
    static func findBestSplit(_ ds: Dataset, hist: [UInt64], mfbH: [Double], sumG: Double, sumH leafH: Double,
                              count: Int, used: [Bool],
                              splittable: inout [Bool], gPos: Double, gNeg: Double, p: Params) -> SplitInfo {
        var out = SplitInfo()
        // `FeatureHistogram::FindBestThreshold` hands the scan the leaf's
        // hessian plus 2·kEpsilon (the children's sums carry −kEpsilon each).
        // It moves gains by an ulp, which decides exact ties between features.
        let sumH = leafH + 2 * kEpsilon
        let l2 = p.lambdaL2
        let minGainShift = (sumG * sumG) / (sumH + l2) + 0.0
        let minData = p.minDataInLeaf, minHess = p.minSumHessianInLeaf
        for k in 0..<ds.used.count where used[k] {
            let off = ds.histOffset[k]
            var sumRG = 0.0, sumRH = kEpsilon, rc = 0
            var bestGain = -Double.infinity, bestThr = -1, bestLC = 0
            var bestLG = 0.0, bestLH = 0.0
            var isSplittable = false
            let mf = ds.mostFreqBin[k]
            var bin = ds.numBin[k] - 1
            while bin >= 1 {
                defer { bin -= 1 }
                let hv = hist[off + bin]
                let c = Int(hv & 0xFFFF_FFFF), nb = Int(hv >> 32)
                sumRG += Double(nb) * gNeg + Double(c - nb) * gPos
                sumRH += bin == mf ? mfbH[k] : Double(c)
                rc += c
                if rc < minData || sumRH < minHess { continue }
                let lc = count - rc
                if lc < minData { break }
                let sumLH = sumH - sumRH
                if sumLH < minHess { break }
                let sumLG = sumG - sumRG
                let gain = (sumLG * sumLG) / (sumLH + l2) + (sumRG * sumRG) / (sumRH + l2)
                if gain <= minGainShift { continue }
                isSplittable = true
                if gain > bestGain {
                    bestGain = gain; bestThr = bin - 1; bestLC = lc
                    bestLG = sumLG; bestLH = sumLH
                }
            }
            splittable[k] = isSplittable
            guard bestThr >= 0 else { continue }
            let g = bestGain - minGainShift
            if g > out.gain {
                out.gain = g; out.inner = k; out.thresholdBin = bestThr
                out.leftCount = bestLC; out.leftG = bestLG; out.leftH = bestLH - kEpsilon
                out.rightCount = count - bestLC; out.rightG = sumG - bestLG; out.rightH = sumH - bestLH - kEpsilon
            }
        }
        return out
    }
}
