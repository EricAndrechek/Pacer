import Foundation

/// `timesfm_2p5_torch.TimesFM_2p5_200M_torch` (`compile` and its
/// `_compiled_decode`) with `timesfm_2p5_base.TimesFM_2p5.forecast`: the
/// forecasting flags around the network, as the arena's backend sets them.
///
/// Per series: pad (front, masked) or cut to `max_context`; normalize by the
/// whole context's mean and deviation (`normalize_inputs`); decode it and its
/// negation (`force_flip_invariance`: the two answers averaged, quantiles
/// mirrored, so TimesFM(−x) = −TimesFM(x)); the continuous quantile head's
/// spreads around the decoded median (`use_continuous_quantile_head`, when
/// the horizon fits it); quantiles uncrossed outward from the median
/// (`fix_quantile_crossing`); renormalized; clamped at 0 when the context is
/// (`infer_is_positive`). The original and the flipped series run as one
/// batch through the network, which the Python decodes one after the other:
/// the same arithmetic per row.
public final class TimesFMForecaster: @unchecked Sendable {
    public let network: TimesFMNetwork

    public init(network: TimesFMNetwork) { self.network = network }

    public var config: TimesFMConfig { network.config }

    /// `configs.ForecastConfig` (the fields 2.5 reads).
    public struct ForecastConfig: Sendable, Equatable {
        public var maxContext = 0
        public var maxHorizon = 0
        public var normalizeInputs = false
        public var perCoreBatchSize = 1
        public var useContinuousQuantileHead = false
        public var forceFlipInvariance = true
        public var inferIsPositive = true
        public var fixQuantileCrossing = false
        public init(maxContext: Int = 0, maxHorizon: Int = 0, normalizeInputs: Bool = false, perCoreBatchSize: Int = 1,
                    useContinuousQuantileHead: Bool = false, forceFlipInvariance: Bool = true,
                    inferIsPositive: Bool = true, fixQuantileCrossing: Bool = false) {
            self.maxContext = maxContext; self.maxHorizon = maxHorizon; self.normalizeInputs = normalizeInputs
            self.perCoreBatchSize = perCoreBatchSize; self.useContinuousQuantileHead = useContinuousQuantileHead
            self.forceFlipInvariance = forceFlipInvariance; self.inferIsPositive = inferIsPositive
            self.fixQuantileCrossing = fixQuantileCrossing
        }
    }

    /// `compile`'s checks: context and horizon rounded up to whole patches,
    /// their sum within the context limit, the continuous head only to its
    /// length.
    public func compiled(_ fc: ForecastConfig) throws -> ForecastConfig {
        var fc = fc
        let p = config.inputPatchLen, o = config.outputPatchLen
        fc.maxContext = (fc.maxContext + p - 1) / p * p
        fc.maxHorizon = (fc.maxHorizon + o - 1) / o * o
        guard fc.maxContext + fc.maxHorizon <= config.contextLimit else {
            throw ArenaError.invalid("TimesFM: context + horizon \(fc.maxContext) + \(fc.maxHorizon) > \(config.contextLimit)")
        }
        guard !(fc.useContinuousQuantileHead && fc.maxHorizon > config.outputQuantileLen) else {
            throw ArenaError.invalid("TimesFM: continuous quantile head past \(config.outputQuantileLen)")
        }
        return fc
    }

    /// `[rows][horizon][q]` (q = mean + 9 quantiles), float32.
    public struct Output: Sendable {
        public let rows: Int, horizon: Int, q: Int
        public var values: [Float]
        public func at(_ r: Int, _ t: Int, _ k: Int) -> Float { values[(r * horizon + t) * q + k] }
    }

    /// `forecast(horizon, inputs)` after `compile(fc)`: every input series
    /// (float32, as the arena hands them over) to `horizon` steps.
    public func forecast(horizon: Int, inputs: [[Float]], config fc0: ForecastConfig) throws -> Output {
        let fc = try compiled(fc0)
        guard horizon <= fc.maxHorizon else {
            throw ArenaError.invalid("TimesFM: horizon \(horizon) > max horizon \(fc.maxHorizon)")
        }
        let context = fc.maxContext, rows = inputs.count
        var values = [Float](), masks = [Bool]()
        values.reserveCapacity(rows * context); masks.reserveCapacity(rows * context)
        for each in inputs {
            let value = Self.linearInterpolation(Self.stripLeadingNaNs(each))
            if value.count >= context {
                values.append(contentsOf: value.suffix(context))
                masks.append(contentsOf: repeatElement(false, count: context))
            } else {
                let w = value.count
                values.append(contentsOf: repeatElement(0, count: context - w)); values.append(contentsOf: value)
                masks.append(contentsOf: repeatElement(true, count: context - w))
                masks.append(contentsOf: repeatElement(false, count: w))
            }
        }
        return try compiledDecode(horizon: horizon, inputs: values, masks: masks, rows: rows, context: context, fc: fc)
    }

    /// `_compiled_decode`.
    func compiledDecode(horizon: Int, inputs: [Float], masks: [Bool], rows: Int, context: Int,
                        fc: ForecastConfig) throws -> Output {
        let c = config, nq = c.numOutputs, mid = c.decodeIndex
        var x = inputs
        // is_positive: every context value (padding zeros included) >= 0.
        let isPositive = (0..<rows).map { r in fc.inferIsPositive && x[(r * context)..<((r + 1) * context)].allSatisfy { $0 >= 0 } }
        var mu = [Float](repeating: 0, count: rows), sigma = mu
        if fc.normalizeInputs {
            for r in 0..<rows {
                // torch.mean / torch.std (unbiased) over the padded context.
                let row = x[(r * context)..<((r + 1) * context)]
                let mean = row.reduce(0.0) { $0 + Double($1) } / Double(context)
                let ss = row.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
                mu[r] = Float(mean)
                sigma[r] = Float((ss / Double(max(context - 1, 1))).squareRoot())
                let s = TimesFMNetwork.guarded(sigma[r])
                for i in (r * context)..<((r + 1) * context) { x[i] = (x[i] - mu[r]) / s }
            }
        }
        // The flipped copy rides in the same batch: rows [0, R) as given,
        // [R, 2R) negated.
        let flip = fc.forceFlipInvariance
        let batch = flip ? x + x.map { -$0 } : x
        let batchMasks = flip ? masks + masks : masks
        let br = flip ? 2 * rows : rows
        let dec = try network.decode(horizon: fc.maxHorizon, inputs: batch, masks: batchMasks, rows: br, context: context,
                                     quantileSteps: fc.useContinuousQuantileHead ? fc.maxHorizon : 0)
        let o = c.outputPatchLen, qSteps = dec.qSteps
        let full = o * (1 + dec.steps)                                    // == max_horizon
        func fullAt(_ r: Int, _ t: Int, _ k: Int) -> Float {
            t < o ? dec.pf[(r * o + t) * nq + k] : dec.ar[((r * dec.steps * o) + (t - o)) * nq + k]
        }
        func qsAt(_ r: Int, _ t: Int, _ k: Int) -> Float { dec.qs[(r * qSteps + t) * nq + k] }
        // flip_quantile_fn: the mean stays, quantiles 1…9 reverse.
        @inline(__always) func mirrored(_ k: Int) -> Int { k == 0 ? 0 : nq - k }
        var out = [Float](repeating: 0, count: rows * horizon * nq)
        var ff = [Float](repeating: 0, count: full * nq)
        for r in 0..<rows {
            for t in 0..<full {
                for k in 0..<nq {
                    ff[t * nq + k] = flip ? (fullAt(r, t, k) - fullAt(rows + r, t, mirrored(k))) / 2 : fullAt(r, t, k)
                }
            }
            if fc.useContinuousQuantileHead {
                for t in 0..<min(fc.maxHorizon, full, qSteps) {
                    func qs(_ k: Int) -> Float { flip ? (qsAt(r, t, k) - qsAt(rows + r, t, mirrored(k))) / 2 : qsAt(r, t, k) }
                    let q5 = qs(mid), f5 = ff[t * nq + mid]
                    for k in [1, 2, 3, 4, 6, 7, 8, 9] { ff[t * nq + k] = qs(k) - q5 + f5 }
                }
            }
            for t in 0..<horizon {
                var row = Array(ff[(t * nq)..<((t + 1) * nq)])
                if fc.fixQuantileCrossing {
                    for i in [4, 3, 2, 1] { row[i] = row[i] < row[i + 1] ? row[i] : row[i + 1] }
                    for i in [6, 7, 8, 9] { row[i] = row[i] > row[i - 1] ? row[i] : row[i - 1] }
                }
                for k in 0..<nq {
                    var v = row[k]
                    if fc.normalizeInputs { v = v * sigma[r] + mu[r] }
                    if isPositive[r] { v = max(v, 0) }
                    out[(r * horizon + t) * nq + k] = v
                }
            }
        }
        return Output(rows: rows, horizon: horizon, q: nq, values: out)
    }

    /// `strip_leading_nans`.
    static func stripLeadingNaNs(_ x: [Float]) -> [Float] {
        guard let first = x.firstIndex(where: { !$0.isNaN }) else { return x }
        return Array(x[first...])
    }

    /// `linear_interpolation`: NaNs filled by `np.interp` over the finite
    /// values (constant past either end); all NaN becomes 0.
    static func linearInterpolation(_ x: [Float]) -> [Float] {
        guard x.contains(where: \.isNaN) else { return x }
        let filled = FMSeries.fillGaps(x.map { Double($0) })
        return filled.map { Float($0) }
    }
}
