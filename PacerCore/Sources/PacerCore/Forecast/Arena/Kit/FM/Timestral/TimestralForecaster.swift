import Foundation

/// `forecaster.py` `TimestralForecaster`: block-autoregressive quantile
/// forecasting around a `TimestralNetwork`, with the clampsym test-time
/// augmentation (both options on by default, as the arena ran it):
///
/// - symmetric averaging forecasts the context and its negation (every
///   covariate row negated too), reflects the second forecast back
///   (`-Q(1 - p)`), and averages the two. The two passes run as one batch of
///   twice the series here; rows of different series never interact, so it
///   is the same computation as two calls;
/// - non-negative clipping clamps the forecast at 0 for every series whose
///   observed context is entirely non-negative.
///
/// Horizons longer than one decode block are forecast block by block,
/// feeding each block's median back as context. Categorical covariates
/// (target encoding) are not ported: no arena model passes them.
public final class TimestralForecaster: @unchecked Sendable {
    public let network: TimestralNetwork
    public let maxContext: Int
    public let perShotHorizonPatches: Int
    public let quantileRealCapK: Double
    public let extremeValueThreshold: Double

    public init(network: TimestralNetwork, maxContext: Int? = nil, perShotHorizonPatches: Int = 32,
                quantileRealCapK: Double = 1e4, extremeValueThreshold: Double = 1e30) {
        self.network = network
        self.maxContext = maxContext ?? network.config.context_length
        self.perShotHorizonPatches = min(max(perShotHorizonPatches, 1), network.config.block_size)
        self.quantileRealCapK = quantileRealCapK
        self.extremeValueThreshold = extremeValueThreshold
    }

    public var config: TimestralConfig { network.config }
    public var quantileLevels: [Double] { config.quantile_knots }
    var patchSize: Int { config.patch_size }

    /// `(B, V, H, Q)` quantiles, row-major.
    public struct Quantiles: Sendable {
        public let b: Int, v: Int, h: Int, q: Int
        public var values: [Float]
        public subscript(_ bi: Int, _ vi: Int, _ hi: Int, _ qi: Int) -> Float {
            values[((bi * v + vi) * h + hi) * q + qi]
        }
        /// `[H][Q]` for one series and variate.
        public func curve(_ bi: Int, _ vi: Int) -> [[Float]] {
            (0..<h).map { hi in Array(values[(((bi * v + vi) * h + hi) * q)..<(((bi * v + vi) * h + hi + 1) * q)]) }
        }
    }

    /// `forecast`: `context` `[B][V][T]` (NaN marks a missing value),
    /// `pastCovariates` `[B][Cp][T]`, `knownCovariates` `[B][Ck][T + H]`.
    public func forecast(context: [[[Float]]], predictionLength: Int, pastCovariates: [[[Float]]]? = nil,
                         knownCovariates: [[[Float]]]? = nil, symmetricAveraging: Bool = true,
                         clipNonnegative: Bool = true) throws -> Quantiles {
        guard predictionLength >= 1 else { throw ArenaError.invalid("prediction_length must be >= 1") }
        guard let b0 = context.first, let v0 = b0.first?.count, !b0.isEmpty else {
            throw ArenaError.invalid("empty context")
        }
        let b = context.count, v = b0.count, t = v0
        // `_as_context`: NaN -> unobserved, value 0.
        var inputs = [Float](), mask = [Bool]()
        inputs.reserveCapacity(b * v * t); mask.reserveCapacity(b * v * t)
        for series in context {
            guard series.count == v else { throw ArenaError.invalid("ragged context") }
            for row in series {
                guard row.count == t else { throw ArenaError.invalid("ragged context") }
                for x in row { let ok = x.isFinite; mask.append(ok); inputs.append(ok ? x : 0) }
            }
        }
        let past = try covariates(pastCovariates, b: b, length: t, name: "past_covariates")
        let known = try covariates(knownCovariates, b: b, length: t + predictionLength, name: "known_covariates")
        if known != nil && !config.supports_known_covariates {
            throw ArenaError.invalid("this checkpoint cannot condition on known-future covariates")
        }
        if (past != nil || known != nil) && !config.covariate_enabled {
            throw ArenaError.invalid("this checkpoint was not trained with covariates")
        }
        let nq = config.num_quantiles
        let h = predictionLength
        var out: [Float]
        if symmetricAveraging {
            let levels = quantileLevels
            guard zip(levels, levels.reversed()).allSatisfy({ abs($0 + $1 - 1.0) < 1e-9 }) else {
                throw ArenaError.invalid("symmetric averaging needs quantile levels symmetric about 0.5")
            }
            // The mirrored pass forecasts -context with every covariate row
            // negated; both run as one batch of 2B series.
            let both = try forecastRaw(inputs: inputs + inputs.map { -$0 }, mask: mask + mask, b: 2 * b, v: v, t: t,
                                       h: h, past: past.map { ($0.values + $0.values.map { -$0 }, $0.c) },
                                       known: known.map { ($0.values + $0.values.map { -$0 }, $0.c) })
            let half = b * v * h * nq
            out = [Float](repeating: 0, count: half)
            for i in 0..<(b * v * h) {
                for k in 0..<nq {
                    out[i * nq + k] = 0.5 * (both[i * nq + k] + (-both[half + i * nq + (nq - 1 - k)]))
                }
            }
        } else {
            out = try forecastRaw(inputs: inputs, mask: mask, b: b, v: v, t: t, h: h, past: past, known: known)
        }
        if clipNonnegative {
            // `nonnegative_context`: some value observed, none negative.
            for bi in 0..<b {
                for vi in 0..<v {
                    let base = (bi * v + vi) * t
                    var any = false, nonneg = true
                    for i in 0..<t where mask[base + i] { any = true; if !(inputs[base + i] >= 0) { nonneg = false } }
                    guard any && nonneg else { continue }
                    let ob = (bi * v + vi) * h * nq
                    for i in 0..<(h * nq) { out[ob + i] = max(out[ob + i], 0) }
                }
            }
        }
        return Quantiles(b: b, v: v, h: h, q: nq, values: out)
    }

    private func covariates(_ x: [[[Float]]]?, b: Int, length: Int, name: String) throws -> (values: [Float], c: Int)? {
        guard let x else { return nil }
        guard x.count == b else { throw ArenaError.invalid("\(name) must be (B=\(b), C, \(length))") }
        let c = x[0].count
        guard c > 0 else { return nil }
        var out = [Float]()
        out.reserveCapacity(b * c * length)
        for series in x {
            guard series.count == c else { throw ArenaError.invalid("\(name): ragged") }
            for row in series {
                guard row.count == length else { throw ArenaError.invalid("\(name) must be (B=\(b), C, \(length))") }
                out.append(contentsOf: row)
            }
        }
        return (out, c)
    }

    /// `_forecast_raw`: one pass, `(B, V, T)` inputs to `(B, V, H, Q)`
    /// raw-space quantiles (flat).
    func forecastRaw(inputs: [Float], mask: [Bool], b: Int, v: Int, t: Int, h: Int,
                     past: (values: [Float], c: Int)?, known: (values: [Float], c: Int)?) throws -> [Float] {
        let ps = patchSize, nq = config.num_quantiles
        let nPast = past?.c ?? 0, nKnown = known?.c ?? 0
        let vAll = v + nPast + nKnown
        let horizon = (h + ps - 1) / ps * ps
        // `_assemble_rows`: targets forward-filled, covariates NaN -> 0.
        var rowsT: [[Float]] = [], masksT: [[Bool]] = []
        var roles: [Int] = []
        for bi in 0..<b {
            for vi in 0..<v {
                let base = (bi * v + vi) * t
                rowsT.append(Self.ffill(Array(inputs[base..<(base + t)]), Array(mask[base..<(base + t)])))
                masksT.append(Array(mask[base..<(base + t)]))
                if bi == 0 { roles.append(TimestralNetwork.roleTarget) }
            }
            if let past {
                for ci in 0..<past.c {
                    let row = Array(past.values[((bi * past.c + ci) * t)..<((bi * past.c + ci + 1) * t)])
                    rowsT.append(row.map { $0.isNaN ? 0 : $0 }); masksT.append(row.map { !$0.isNaN })
                    if bi == 0 { roles.append(TimestralNetwork.rolePastCov) }
                }
            }
            if let known {
                let kl = t + h
                for ci in 0..<known.c {
                    let row = Array(known.values[((bi * known.c + ci) * kl)..<((bi * known.c + ci) * kl + t)])
                    rowsT.append(row.map { $0.isNaN ? 0 : $0 }); masksT.append(row.map { !$0.isNaN })
                    if bi == 0 { roles.append(TimestralNetwork.roleKnownCov) }
                }
            }
        }
        // Crop to max_context, then left-pad to a multiple of the patch size.
        var tt = t
        if tt > maxContext {
            rowsT = rowsT.map { Array($0.suffix(maxContext)) }; masksT = masksT.map { Array($0.suffix(maxContext)) }
            tt = maxContext
        }
        let pad = tt % ps == 0 ? 0 : ps - tt % ps
        let tp = tt + pad
        var rows = [Float](), rmask = [Bool]()
        rows.reserveCapacity(b * vAll * tp); rmask.reserveCapacity(b * vAll * tp)
        for (r, m) in zip(rowsT, masksT) {
            rows.append(contentsOf: repeatElement(0, count: pad)); rows.append(contentsOf: r)
            rmask.append(contentsOf: repeatElement(false, count: pad)); rmask.append(contentsOf: m)
        }
        let nRows = b * vAll
        var roleIds: [Int]?, kf: [Float]?, kfm: [Bool]?
        if nPast > 0 || nKnown > 0 {
            roleIds = (0..<b).flatMap { _ in roles }
            if let known {
                var f = [Float](repeating: 0, count: nRows * horizon), fm = [Bool](repeating: false, count: nRows * horizon)
                let kl = t + h, k0 = v + nPast
                for bi in 0..<b {
                    for ci in 0..<known.c {
                        let src = (bi * known.c + ci) * kl + t
                        let dst = (bi * vAll + k0 + ci) * horizon
                        for i in 0..<h {
                            let x = known.values[src + i]
                            f[dst + i] = x.isNaN ? 0 : x; fm[dst + i] = !x.isNaN
                        }
                    }
                }
                kf = f; kfm = fm
            }
        }
        let decoded = try blockARDecode(rows, rmask, rows: nRows, perSeries: vAll, t: tp, h: h, roleIds: roleIds,
                                        knownFuture: kf, knownFutureMask: kfm, horizon: horizon)
        // Keep the target rows, then cap them (`_cap_quantiles`).
        var out = [Float](repeating: 0, count: b * v * h * nq)
        let k = Float(quantileRealCapK)
        rows.withUnsafeBufferPointer { rb in
            rmask.withUnsafeBufferPointer { mb in
                var loc = [Float](repeating: 0, count: tp), scale = loc
                for bi in 0..<b {
                    for vi in 0..<v {
                        let r = bi * vAll + vi
                        var hiV = -Float.infinity, loV = Float.infinity
                        for i in 0..<tp where mb[r * tp + i] { hiV = max(hiV, rb[r * tp + i]); loV = min(loV, rb[r * tp + i]) }
                        if hiV == -.infinity { hiV = 0 }
                        if loV == .infinity { loV = 0 }
                        loc.withUnsafeMutableBufferPointer { lb in
                            scale.withUnsafeMutableBufferPointer { sb in
                                TimestralScaler.causalPatchLocScale(rb.baseAddress! + r * tp, mb.baseAddress! + r * tp,
                                                                    t: tp, patchSize: ps, minimumScale: config.minimum_scale,
                                                                    loc: lb.baseAddress!, scale: sb.baseAddress!)
                            }
                        }
                        let anchor = scale[tp - 1] * k
                        let lo = loV - anchor, hi = hiV + anchor
                        let src = r * h * nq, dst = (bi * v + vi) * h * nq
                        for i in 0..<(h * nq) {
                            out[dst + i] = quantileRealCapK > 0 ? min(max(decoded[src + i], lo), hi) : decoded[src + i]
                        }
                    }
                }
            }
        }
        if out.contains(where: { $0.isNaN }) {
            throw ArenaError.invalid("forecast produced \(out.lazy.filter { $0.isNaN }.count) NaN values; the input is degenerate")
        }
        return out
    }

    /// `_block_ar_decode`: decode block by block in the packed `(R, T)`
    /// layout; returns `(R, H, Q)`. After each block the context grows by
    /// the block's feedback: targets their median, known-future covariates
    /// their real future, past-only covariates a blank.
    func blockARDecode(_ inputs: [Float], _ mask: [Bool], rows: Int, perSeries: Int, t: Int, h: Int, roleIds: [Int]?,
                       knownFuture: [Float]?, knownFutureMask: [Bool]?, horizon: Int) throws -> [Float] {
        let ps = patchSize, nq = config.num_quantiles, mi = config.median_index
        // Rows of one series share a group (`arange(b).repeat_interleave(v)`).
        let groupIds = (0..<rows).map { $0 / max(perSeries, 1) }
        let knownRows = roleIds?.map { $0 == TimestralNetwork.roleKnownCov }
        let pastRows = roleIds?.map { $0 != TimestralNetwork.roleTarget && $0 != TimestralNetwork.roleKnownCov }
        let targetRows = roleIds?.map { $0 == TimestralNetwork.roleTarget }

        var context = inputs, cmask = mask, ct = t
        var blocks: [[Float]] = []
        var remaining = (h + ps - 1) / ps
        var offset = 0
        while remaining > 0 {
            let block = min(perShotHorizonPatches, remaining)
            let blen = block * ps
            var kfB: [Float]?, kfmB: [Bool]?
            if let kf = knownFuture, let kfm = knownFutureMask {
                var a = [Float](), m = [Bool]()
                for r in 0..<rows {
                    a.append(contentsOf: kf[(r * horizon + offset)..<(r * horizon + offset + blen)])
                    m.append(contentsOf: kfm[(r * horizon + offset)..<(r * horizon + offset + blen)])
                }
                kfB = a; kfmB = m
            }
            var q = network.predictBlock(inputs: context, observed: cmask, rows: rows, groupIds: groupIds,
                                         horizonPatches: block, roleIds: roleIds, knownFuture: kfB, knownFutureMask: kfmB)
            refineBlock(&q, context: context, mask: cmask, rows: rows, t: ct, targetRows: targetRows)
            blocks.append(q)
            remaining -= block
            offset += blen
            if remaining <= 0 { break }
            // Feedback: the median (extreme values zeroed), or the covariate's own.
            var nc = [Float](), nm = [Bool]()
            nc.reserveCapacity(rows * (ct + blen)); nm.reserveCapacity(rows * (ct + blen))
            let thr = Float(extremeValueThreshold)
            for r in 0..<rows {
                nc.append(contentsOf: context[(r * ct)..<((r + 1) * ct)]); nm.append(contentsOf: cmask[(r * ct)..<((r + 1) * ct)])
                for i in 0..<blen {
                    var fb = q[(r * blen + i) * nq + mi]
                    if !(fb.isFinite && abs(fb) < thr) { fb = 0 }
                    var fm = true
                    if let kr = knownRows, kr[r], let a = kfB, let m = kfmB { fb = a[r * blen + i]; fm = m[r * blen + i] }
                    if let pr = pastRows, pr[r] { fb = 0; fm = false }
                    nc.append(fb); nm.append(fm)
                }
            }
            ct += blen
            context = nc; cmask = nm
            if ct > maxContext {
                let keep = max(ps, (maxContext / ps) * ps)
                var kc = [Float](), km = [Bool]()
                for r in 0..<rows {
                    kc.append(contentsOf: context[(r * ct + ct - keep)..<((r + 1) * ct)])
                    km.append(contentsOf: cmask[(r * ct + ct - keep)..<((r + 1) * ct)])
                }
                context = kc; cmask = km; ct = keep
            }
        }
        // Concatenate the blocks along time and keep the first H steps.
        var out = [Float](repeating: 0, count: rows * h * nq)
        for r in 0..<rows {
            var step = 0
            for blk in blocks {
                let bl = blk.count / (rows * nq)
                for i in 0..<bl where step < h {
                    for k in 0..<nq { out[(r * h + step) * nq + k] = blk[(r * bl + i) * nq + k] }
                    step += 1
                }
            }
        }
        return out
    }

    /// `_refine_block`: move one decoded block from the anchor frame to the
    /// advancing refine frame it was trained in. The first horizon patch keeps
    /// the last context patch's frame; each later one is re-denormalized
    /// with `advancing_block_frames`. Covariate rows keep their quantiles.
    func refineBlock(_ q: inout [Float], context: [Float], mask: [Bool], rows: Int, t: Int, targetRows: [Bool]?) {
        let ps = patchSize, nq = config.num_quantiles, mi = config.median_index
        let steps = q.count / (rows * nq)
        let nPred = steps / ps
        guard nPred > 1 else { return }
        context.withUnsafeBufferPointer { cb in
            mask.withUnsafeBufferPointer { mb in
                var loc = [Float](repeating: 0, count: t), scale = loc
                for r in 0..<rows {
                    if let tr = targetRows, !tr[r] { continue }
                    loc.withUnsafeMutableBufferPointer { lb in
                        scale.withUnsafeMutableBufferPointer { sb in
                            TimestralScaler.causalPatchLocScale(cb.baseAddress! + r * t, mb.baseAddress! + r * t, t: t,
                                                                patchSize: ps, minimumScale: config.minimum_scale,
                                                                loc: lb.baseAddress!, scale: sb.baseAddress!)
                        }
                    }
                    let loc0 = loc[t - 1], scale0 = scale[t - 1]
                    let sinhMedian = (0..<(nPred * ps)).map { i in
                        (Double(q[(r * steps + i) * nq + mi]) - Double(loc0)) / Double(scale0)
                    }
                    let (locJ, scaleJ) = TimestralScaler.advancingBlockFrames(
                        context: cb.baseAddress! + r * t, observed: mb.baseAddress! + r * t, t: t,
                        sinhMedian: sinhMedian, nPred: nPred, patchSize: ps, minimumScale: config.minimum_scale)
                    q.withUnsafeMutableBufferPointer { qb in
                        for j in 0..<nPred {
                            let lj = j == 0 ? loc0 : Float(locJ[j]), sj = j == 0 ? scale0 : Float(scaleJ[j])
                            for i in 0..<ps {
                                let p = qb.baseAddress! + (r * steps + j * ps + i) * nq
                                for k in 0..<nq { p[k] = (p[k] - loc0) / scale0 * sj + lj }
                                TimestralScaler.clampNonfinite(p, nq)
                            }
                        }
                    }
                }
            }
        }
    }

    /// `ffill_with_mask` for one row: unobserved positions take the last
    /// observed value; leading ones take position 0's (0 when unobserved).
    static func ffill(_ x: [Float], _ m: [Bool]) -> [Float] {
        guard m.contains(false) else { return x }
        var out = x
        var last = 0
        for i in x.indices {
            if m[i] { last = i }
            out[i] = x[m[i] ? i : last]
            if out[i].isNaN { out[i] = 0 }
        }
        return out
    }
}
