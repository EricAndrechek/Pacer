import Foundation

/// `pipeline.py` `Chronos2Pipeline.predict_quantiles` on a `(B, V, T)`
/// tensor, the one input form the arena's `Chronos2Backend` uses without
/// covariates (licence and provenance: `ChronosConfig.swift`), plus that
/// backend's own steps around it (`ArenaChronos`).
///
/// The tensor goes through `preprocess.from_tensor` and `Chronos2Dataset`
/// in TEST mode: each series is one group of its variates, the last
/// `context_length` steps are kept, and series are batched until a batch
/// holds 256 rows; one forward pass per batch covers up to
/// `max_output_patches` patches. Longer horizons (upstream's autoregressive
/// unrolling over nine quantile paths) are not ported: the meter models'
/// horizons stop at the reset, at most 672 steps against the 1024 one pass
/// covers, so they never reach it; asking for more throws.
public final class ChronosPipeline: @unchecked Sendable {
    public let network: ChronosNetwork
    /// `predict(batch_size=256)`: rows (targets) per forward pass.
    public let batchSize: Int

    public init(network: ChronosNetwork, batchSize: Int = 256) {
        self.network = network
        self.batchSize = batchSize
    }

    public var config: ChronosConfig { network.config }
    /// `Chronos2Pipeline.quantiles`: the levels the model was trained on.
    public var quantileLevels: [Double] { config.chronos_config.quantiles }

    /// `(B, V, H, Q)` quantiles, row-major, at `quantileLevels`.
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

    /// `predict_quantiles(context, prediction_length, quantile_levels=self.quantiles)`:
    /// `context` `[B][V][T]` (NaN = missing), every variate a target.
    public func predictQuantiles(context: [[[Float]]], predictionLength h: Int) throws -> Quantiles {
        guard h >= 1 else { throw ArenaError.invalid("prediction_length must be >= 1") }
        guard let v = context.first?.count, v >= 1, let t = context.first?.first?.count, t >= 1 else {
            throw ArenaError.invalid("empty context")
        }
        let ps = config.chronos_config.output_patch_size
        let nOut = (h + ps - 1) / ps
        guard nOut <= config.chronos_config.max_output_patches else {
            throw ArenaError.invalid("Chronos-2: a horizon of \(h) steps needs the long-horizon unrolling, which is not ported "
                                     + "(one pass covers \(config.model_prediction_length))")
        }
        for series in context {
            guard series.count == v, series.allSatisfy({ $0.count == t }) else { throw ArenaError.invalid("ragged context") }
        }
        let nq = config.num_quantiles
        let b = context.count
        // `_construct_slice` (TEST): the last `context_length` steps.
        let tt = min(t, config.chronos_config.context_length)
        var out = [Float](repeating: 0, count: b * v * h * nq)
        // `_generate_sequential_batches`: whole series until the batch holds `batchSize` rows.
        var first = 0
        while first < b {
            var series: [Int] = []
            var rowsInBatch = 0
            while first + series.count < b && rowsInBatch < batchSize {
                series.append(first + series.count)
                rowsInBatch += v
            }
            var flat = [Float]()
            flat.reserveCapacity(rowsInBatch * tt)
            var groups: [Int] = []
            for (g, bi) in series.enumerated() {
                for row in context[bi] { flat.append(contentsOf: row.suffix(tt)) }
                groups.append(contentsOf: repeatElement(g, count: v))
            }
            let pred = network.forward(context: flat, rows: rowsInBatch, t: tt, groupIds: groups, numOutputPatches: nOut)
            // `[..., :prediction_length]`, then "... q h -> ... h q".
            let hp = nOut * ps
            for (g, bi) in series.enumerated() {
                for vi in 0..<v {
                    let r = g * v + vi
                    let dst = (bi * v + vi) * h * nq
                    for hi in 0..<h {
                        for qi in 0..<nq { out[dst + hi * nq + qi] = pred[(r * nq + qi) * hp + hi] }
                    }
                }
            }
            first += series.count
        }
        return Quantiles(b: b, v: v, h: h, q: nq, values: out)
    }
}

/// The arena's `Chronos2Backend` (`kit/fm/backends.py`) around the pipeline,
/// without covariates: the context cut to `maxContext`, handed over in
/// float32 (`ctx.astype(np.float32)`), and the quantiles sorted along Q
/// (`Backend.quantiles` → `fix_crossing`), in float64. One loaded network per
/// weights id per process (`weights.cached`), shared by every model and
/// thread that names it.
public enum ArenaChronos {
    /// `Chronos2Backend.max_context`.
    public static let maxContext = 8192

    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var byID: [String: ChronosPipeline] = [:]
    }

    static let cache = Cache()

    /// The pipeline for a weights id from its local folder (loaded once).
    public static func pipeline(_ id: String, directory: URL) throws -> ChronosPipeline {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let p = cache.byID[id] { return p }
        let p = ChronosPipeline(network: try ChronosNetwork(directory: directory))
        cache.byID[id] = p
        return p
    }

    /// The pipeline for a weights id, through the services' weight lookup.
    public static func pipeline(_ id: String, services: ArenaServices) throws -> ChronosPipeline {
        cache.lock.lock()
        let hit = cache.byID[id]
        cache.lock.unlock()
        if let hit { return hit }
        guard let dir = services.weights(id) else { throw ArenaError.weightsUnavailable(id) }
        return try pipeline(id, directory: dir)
    }

    /// `Backend.quantiles` for Chronos-2 without covariates: `context`
    /// `[B][V][T]` (NaN = missing) → `B × V × H × Q`, sorted along Q.
    public static func quantiles(_ p: ChronosPipeline, context: [[[Double]]], horizon: Int) throws -> FMBackends.Quantiles {
        let ctx: [[[Float]]] = context.map { $0.map { $0.suffix(maxContext).map(Float.init) } }
        let out = try p.predictQuantiles(context: ctx, predictionLength: horizon)
        let nq = out.q
        var values = [Double](repeating: 0, count: out.values.count)
        var row = [Double](repeating: 0, count: nq)
        for i in 0..<(out.values.count / nq) {
            for k in 0..<nq { row[k] = Double(out.values[i * nq + k]) }
            row.sort()
            for k in 0..<nq { values[i * nq + k] = row[k] }
        }
        return FMBackends.Quantiles(levels: p.quantileLevels, b: out.b, v: out.v, h: out.h, q: nq, values: values)
    }
}
