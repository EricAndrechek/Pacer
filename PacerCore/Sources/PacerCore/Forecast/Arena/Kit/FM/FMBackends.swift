import Foundation

/// `research/arena/kit/fm/backends.py`, the Timestral part: one loaded network
/// per weights id per process (`weights.cached`), and `quantiles(context [B,
/// V, T], horizon, past_cov, known_cov) -> (levels, q [B, V, H, Q])`, sorted
/// along Q.
///
/// Loading is a memory map plus a few hundred pointer lookups, so the
/// network for an id is built once and shared by every model and every
/// thread that names it (`TimestralNetwork` is thread-safe). The cache keeps
/// every network it has loaded for the process's life: their weights are
/// file-backed pages the system reclaims under pressure and re-reads on use.
public enum FMBackends {
    /// Timestral's context cap in the arena's backend (`max_context`).
    public static let timestralMaxContext = 32_768

    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var byID: [String: TimestralForecaster] = [:]
    }

    static let cache = Cache()

    /// The forecaster for a weights id from its local folder.
    public static func timestral(_ id: String, directory: URL) throws -> TimestralForecaster {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let f = cache.byID[id] { return f }
        let f = TimestralForecaster(network: try TimestralNetwork(directory: directory))
        cache.byID[id] = f
        return f
    }

    /// The forecaster for a weights id, through the services' weight lookup.
    public static func timestral(_ id: String, services: ArenaServices) throws -> TimestralForecaster {
        cache.lock.lock()
        let hit = cache.byID[id]
        cache.lock.unlock()
        if let hit { return hit }
        guard let dir = services.weights(id) else { throw ArenaError.weightsUnavailable(id) }
        return try timestral(id, directory: dir)
    }

    /// `B × V × H × Q` quantiles in Double, sorted along Q (`fix_crossing`).
    public struct Quantiles: Sendable {
        public let levels: [Double]
        public let b: Int, v: Int, h: Int, q: Int
        public let values: [Double]
        /// `[H][Q]` for one series and variate.
        public func curve(_ bi: Int = 0, _ vi: Int = 0) -> [[Double]] {
            (0..<h).map { hi in
                let o = ((bi * v + vi) * h + hi) * q
                return Array(values[o..<(o + q)])
            }
        }
    }

    /// `Backend.quantiles` for Timestral: `context` `[B][V][T]` (NaN =
    /// missing), `pastCov` `[B][Cp][T]`, `knownCov` `[B][Ck][T + H]`. The
    /// context is cut to the backend's cap and handed to the network in
    /// float32, as the arena's backend does (`ctx.astype(np.float32)`).
    public static func quantiles(_ fc: TimestralForecaster, context: [[[Double]]], horizon: Int,
                                 pastCov: [[[Double]]]? = nil, knownCov: [[[Double]]]? = nil) throws -> Quantiles {
        var ctx = context
        var past = pastCov, known = knownCov
        if let t = ctx.first?.first?.count, t > timestralMaxContext {
            ctx = ctx.map { $0.map { Array($0.suffix(timestralMaxContext)) } }
            past = past?.map { $0.map { Array($0.suffix(timestralMaxContext)) } }
            known = known?.map { $0.map { Array($0.dropFirst(t - timestralMaxContext)) } }
        }
        func f32(_ x: [[[Double]]]?) -> [[[Float]]]? { x?.map { $0.map { $0.map { Float($0) } } } }
        let pastF = past.flatMap { $0.first?.isEmpty == false ? f32($0) : nil }
        let knownF = known.flatMap { $0.first?.isEmpty == false ? f32($0) : nil }
        let out = try fc.forecast(context: f32(ctx)!, predictionLength: horizon, pastCovariates: pastF,
                                  knownCovariates: knownF)
        var values = [Double](repeating: 0, count: out.values.count)
        let nq = out.q
        for i in 0..<(out.values.count / nq) {
            let row = out.values[(i * nq)..<((i + 1) * nq)].map(Double.init).sorted()
            for k in 0..<nq { values[i * nq + k] = row[k] }
        }
        return Quantiles(levels: fc.quantileLevels, b: out.b, v: out.v, h: out.h, q: nq, values: values)
    }
}
