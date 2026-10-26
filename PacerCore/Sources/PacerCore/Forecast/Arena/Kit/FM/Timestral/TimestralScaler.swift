import Foundation

/// `scaler.py`: causal per-patch mean/std scaling with an asinh squash.
///
/// Each patch is normalized with the mean and std of every observed value up
/// to the end of that patch, so the context never sees future statistics.
/// Forecasts come back in the normalized (asinh) space of the last context
/// patch and are inverted with `sinh`. The statistics are float64 and the
/// transforms float32, exactly where the Python computes in each (its
/// `to(torch.float64)` / `_fp32_io`), so the network sees the same inputs.
enum TimestralScaler {
    static let floatEps = Float.ulpOfOne               // torch.finfo(float32).eps
    static let tiny64 = Double.leastNormalMagnitude    // torch.finfo(float64).tiny

    /// `compute_causal_statistics` then `causal_patch_loc_scale` for one row:
    /// per-step float32 `loc` and `scale`, each the causal statistics at its
    /// patch's last step.
    static func causalPatchLocScale(_ data: UnsafePointer<Float>, _ observed: UnsafePointer<Bool>, t: Int,
                                    patchSize ps: Int, minimumScale: Double,
                                    loc: UnsafeMutablePointer<Float>, scale: UnsafeMutablePointer<Float>) {
        // Running sums in float64, as torch.cumsum does them (sequentially).
        var cumW = 0.0, cumX = 0.0, m2 = 0.0, prevMean = 0.0
        for i in 0..<t {
            let w: Double = observed[i] ? 1 : 0
            let x = Double(data[i])
            cumW += w
            cumX += w * x
            let denom = max(cumW, 1.0)
            let mean = cumX / denom
            let shifted = i == 0 ? 0.0 : prevMean
            m2 += (x - shifted) * (x - mean) * w
            let variance = m2 / max(denom - 1.0, 1.0)
            let s = max(variance.squareRoot(), minimumScale)
            prevMean = mean
            if i % ps == ps - 1 {
                let lf = Float(mean), sf = Float(s)
                for j in (i - ps + 1)...i { loc[j] = lf; scale[j] = sf }
            }
        }
    }

    /// `asinh((data - loc) / scale)` on observed positions; unobserved become 0.
    @inline(__always)
    static func affineAsinh(_ x: Float, loc: Float, scale: Float, observed: Bool, useAsinh: Bool) -> Float {
        guard observed else { return 0 }
        let s = (x - loc) / max(scale, floatEps)
        return useAsinh ? asinhf(s) : s
    }

    /// `sinh(x) * scale + loc`, float32.
    @inline(__always)
    static func invertAffineAsinh(_ x: Float, loc: Float, scale: Float, useAsinh: Bool) -> Float {
        (useAsinh ? sinhf(x) : x) * scale + loc
    }

    /// `clamp_nonfinite` over one quantile vector: +/-inf (a sinh overflow)
    /// to the nearest finite value; a vector with nothing finite becomes 0.
    /// NaN is left as is so real instability still surfaces.
    static func clampNonfinite(_ v: UnsafeMutablePointer<Float>, _ q: Int) {
        var hasInf = false
        for i in 0..<q where v[i].isInfinite { hasInf = true; break }
        guard hasInf else { return }
        var hi = -Float.infinity, lo = Float.infinity
        for i in 0..<q where v[i].isFinite { hi = max(hi, v[i]); lo = min(lo, v[i]) }
        for i in 0..<q {
            if v[i] == .infinity { v[i] = hi } else if v[i] == -.infinity { v[i] = lo }
            if v[i].isInfinite { v[i] = 0 }
        }
    }

    struct Welford { var w: Double; var mean: Double; var m2: Double }

    /// `welford_combine`, element-wise; `(0, 0, 0)` is the identity (up to
    /// rounding, which the scan below reproduces).
    @inline(__always)
    static func combine(_ a: Welford, _ b: Welford) -> Welford {
        let w = a.w + b.w
        let wSafe = max(w, tiny64)
        let delta = b.mean - a.mean
        var mean = a.mean + delta * b.w / wSafe
        var m2 = a.m2 + b.m2 + delta * delta * a.w * b.w / wSafe
        if w == 0 { mean = 0; m2 = 0 }
        return Welford(w: w, mean: mean, m2: m2)
    }

    /// `cumulative_welford`: the inclusive prefix scan (Hillis-Steele, the
    /// same merges in the same order as the Python, so the same rounding).
    static func cumulativeWelford(_ s: [Welford]) -> [Welford] {
        var cur = s
        let n = cur.count
        var d = 1
        let zero = Welford(w: 0, mean: 0, m2: 0)
        while d < n {
            var next = cur
            for i in 0..<n { next[i] = combine(i >= d ? cur[i - d] : zero, cur[i]) }
            cur = next
            d *= 2
        }
        return cur
    }

    /// `advancing_block_frames` for one row: per horizon patch, `(loc,
    /// scale)` in float64. Patch `j` is normalized with the statistics of the
    /// observed context plus the block's medians of patches `0..j-1`, each
    /// median denormalized in its own frame before it is folded in.
    static func advancingBlockFrames(context: UnsafePointer<Float>, observed: UnsafePointer<Bool>, t: Int,
                                     sinhMedian: [Double], nPred: Int, patchSize ps: Int,
                                     minimumScale: Double) -> (loc: [Double], scale: [Double]) {
        let lc = t / ps
        var states: [Welford] = []
        states.reserveCapacity(lc + nPred)
        for p in 0..<lc {
            var cnt = 0.0, sum = 0.0
            for i in 0..<ps where observed[p * ps + i] { cnt += 1; sum += Double(context[p * ps + i]) }
            let mean = sum / max(cnt, 1.0)
            var m2 = 0.0
            for i in 0..<ps where observed[p * ps + i] { let d = Double(context[p * ps + i]) - mean; m2 += d * d }
            states.append(cnt == 0 ? Welford(w: 0, mean: 0, m2: 0) : Welford(w: cnt, mean: mean, m2: m2))
        }
        // The blank horizon patches join the scan (their weight is 0), as in
        // the Python, which only changes how many passes the scan makes.
        for _ in 0..<nPred { states.append(Welford(w: 0, mean: 0, m2: 0)) }
        var st = cumulativeWelford(states)[lc - 1]
        let offset = st.mean   // medians are clamped relative to the context mean, so a large level survives
        let clip = Double(Float.greatestFiniteMagnitude).squareRoot() / 1e3
        var locs = [Double](), scales = [Double]()
        var folded = [Double](repeating: 0, count: ps)
        for h in 0..<nPred {
            let variance = max(st.m2 / max(st.w - 1.0, 1.0), 0.0)
            let scale = max(variance.squareRoot(), minimumScale)
            locs.append(st.mean)
            scales.append(scale)
            var sum = 0.0
            for i in 0..<ps {
                let v = min(max(sinhMedian[h * ps + i] * scale + st.mean - offset, -clip), clip) + offset
                folded[i] = v
                sum += v
            }
            let bMean = sum / Double(ps)
            var bM2 = 0.0
            for i in 0..<ps { let d = folded[i] - bMean; bM2 += d * d }
            st = combine(st, Welford(w: Double(ps), mean: bMean, m2: bM2))
        }
        return (locs, scales)
    }

    /// `instance_norm_stats` for one known-future covariate row: non-causal
    /// mean/std over observed positions (float32); rows whose observed
    /// values are all 0 or 1 (indicators) keep `loc 0, scale 1`.
    static func instanceNormStats(_ values: UnsafePointer<Float>, _ observed: UnsafePointer<Bool>, n: Int,
                                  minimumScale: Double) -> (loc: Float, scale: Float, isBinary: Bool) {
        var cnt: Float = 0, sum: Float = 0
        var zeroOne = true, any = false
        for i in 0..<n {
            if observed[i] { cnt += 1; sum += values[i]; any = true }
            if !(values[i] == 0 || values[i] == 1 || !observed[i]) { zeroOne = false }
        }
        let nn = max(cnt, 1)
        let loc = sum / nn
        var ss: Float = 0
        for i in 0..<n { let d = observed[i] ? (values[i] - loc) : 0; ss += d * d }
        let scale = max((ss / nn).squareRoot(), Float(minimumScale))
        let isBinary = zeroOne && any
        return isBinary ? (0, 1, true) : (loc, scale, false)
    }
}
