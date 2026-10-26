import Foundation

/// `kit/fm/backends.py` `Chronos2Backend`: Chronos-2 behind the arena's one
/// call, without covariates. The context is cut to `maxContext` (the shared
/// `Backend.quantiles` step), handed to the pipeline in float32
/// (`ctx.astype(np.float32)`), and the quantiles come back at the model's
/// own 21 levels, sorted along Q (`fix_crossing`) in float64.
///
/// Covariates are not ported: the arena's backend turns them into
/// `past_covariates` / `future_covariates` dicts, which no meter model
/// passes (`fm-chronos2-meter` forecasts the burn alone). A call with any
/// throws rather than silently forecasting without them.
public final class Chronos2Backend: FMBackend {
    /// `Chronos2Backend.max_context`.
    public static let maxContext = 8192

    public let pipeline: ChronosPipeline

    public init(_ pipeline: ChronosPipeline) { self.pipeline = pipeline }

    public var levels: [Double] { pipeline.quantileLevels }

    public func quantiles(context: [[[Double]]], horizon: Int, pastCov: [[[Double]]]?,
                          knownCov: [[[Double]]]?) throws -> FMBackends.Quantiles {
        // `has_cov`: some covariate row present (a `[B][0][T]` array is none).
        if pastCov?.contains(where: { !$0.isEmpty }) == true || knownCov?.contains(where: { !$0.isEmpty }) == true {
            throw ArenaError.invalid("Chronos-2 covariates are not ported")
        }
        let prepared = FMBackends.prepare(context: context, pastCov: nil, knownCov: nil, maxContext: Self.maxContext,
                                          nanOK: true, covariates: false)
        let ctx: [[[Float]]] = prepared.context.map { $0.map { $0.map(Float.init) } }
        let out = try pipeline.predictQuantiles(context: ctx, predictionLength: horizon)
        let nq = out.q
        var values = [Double](repeating: 0, count: out.values.count)
        var row = [Double](repeating: 0, count: nq)
        for i in 0..<(out.values.count / nq) {
            for k in 0..<nq { row[k] = Double(out.values[i * nq + k]) }
            row.sort()
            for k in 0..<nq { values[i * nq + k] = row[k] }
        }
        return FMBackends.Quantiles(levels: levels, b: out.b, v: out.v, h: out.h, q: nq, values: values)
    }

    // MARK: - One network per weights id per process

    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var byID: [String: ChronosPipeline] = [:]
    }

    static let cache = Cache()

    /// The pipeline for a weights id from its local folder, loaded once
    /// (a memory map of the 478 MB file and a few hundred pointer lookups;
    /// the pages are file-backed, so the system can drop and re-read them).
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
}

extension FMBackends {
    /// `"chronos2"` in `FMBackends.factories`.
    static let chronosFactory: [String: Factory] = [
        "chronos2": { id, services in Chronos2Backend(try Chronos2Backend.pipeline(id, services: services)) },
    ]
}
