import Accelerate
import Foundation

/// `research/arena/kit/fm/backends.py`: one adapter per pretrained
/// forecaster behind one call (`FMBackend.quantiles(context [B, V, T],
/// horizon, past_cov, known_cov) -> (levels, q [B, V, H, Q])`, sorted along
/// Q), looked up by the `backend` name a model's config gives
/// (`get_backend`), loaded once per process per weights id
/// (`weights.cached`).
///
/// Each network family registers its own factory from its own file
/// (`timestralFactory` in `Timestral/`, `timesfmFactory` in `TimesFM/`,
/// `chronosFactory` in `Chronos/`), so adding a family never edits another's.
///
/// Loading is a memory map plus a few hundred pointer lookups, so the
/// network for an id is built once and shared by every model and every
/// thread that names it (`TimestralNetwork` is thread-safe). The cache keeps
/// every network it has loaded for the process's life: their weights are
/// file-backed pages the system reclaims under pressure and re-reads on use.
public enum FMBackends {
    /// Timestral's context cap in the arena's backend (`max_context`).
    public static let timestralMaxContext = 32_768

    /// Builds a family's backend for a weights id (`BACKENDS[name](spec)`).
    public typealias Factory = @Sendable (_ weights: String, _ services: ArenaServices) throws -> any FMBackend

    /// `BACKENDS`: every ported backend by its config name.
    public static let factories: [String: Factory] = timestralFactory
        .merging(timesfmFactory) { a, _ in a }
        .merging(chronosFactory) { a, _ in a }

    final class BackendCache: @unchecked Sendable {
        let lock = NSLock()
        var byKey: [String: any FMBackend] = [:]
    }

    static let backends = BackendCache()

    /// `get_backend(name, spec)`: the loaded backend, once per process. The
    /// lock is held while a network loads so two models naming the same
    /// weights never load it twice (it is not the Timestral cache's lock,
    /// which a factory may take).
    public static func backend(_ name: String, weights: String, services: ArenaServices) throws -> any FMBackend {
        guard let make = factories[name] else {
            throw ArenaError.invalid("unknown kit.fm backend \(name); known: \(factories.keys.sorted())")
        }
        let key = "\(name)|\(weights)"
        backends.lock.lock()
        defer { backends.lock.unlock() }
        if let b = backends.byKey[key] { return b }
        let b = try make(weights, services)
        backends.byKey[key] = b
        return b
    }

    /// `Backend.quantiles`' shared preparation for a backend that does not do
    /// its own: the context (and covariates) cut to `maxContext`, NaN gaps
    /// filled when the network cannot take them (`fill_gaps`), covariates
    /// dropped when it cannot use them.
    public static func prepare(context: [[[Double]]], pastCov: [[[Double]]]?, knownCov: [[[Double]]]?,
                               maxContext: Int, nanOK: Bool, covariates: Bool)
        -> (context: [[[Double]]], pastCov: [[[Double]]]?, knownCov: [[[Double]]]?) {
        var ctx = context
        var past = pastCov, known = knownCov
        if let t = ctx.first?.first?.count, t > maxContext {
            ctx = ctx.map { $0.map { Array($0.suffix(maxContext)) } }
            past = past?.map { $0.map { Array($0.suffix(maxContext)) } }
            known = known?.map { $0.map { Array($0.dropFirst(t - maxContext)) } }
        }
        if !nanOK { ctx = ctx.map { $0.map(FMSeries.fillGaps) } }
        if !covariates { past = nil; known = nil }
        return (ctx, past, known)
    }

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

    /// Accelerate's BLAS threading, process-wide (`BLASSetThreading`): the
    /// arena pins torch to a few threads; a background backfill may want one
    /// thread so it never competes with the app's foreground for cores.
    /// Returns false when the call was refused.
    @discardableResult
    public static func setBLASThreading(singleThreaded: Bool) -> Bool {
        BLASSetThreading(singleThreaded ? BLAS_THREADING_SINGLE_THREADED : BLAS_THREADING_MULTI_THREADED) == 0
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

/// `kit/fm/backends.py` `Backend`: a pretrained forecaster behind the
/// arena's one call. Implementations are thread-safe (one instance per
/// weights id serves every model and thread in the process).
public protocol FMBackend: AnyObject, Sendable {
    /// `Backend.quantiles`: `context` `[B][V][T]` (NaN = missing), `pastCov`
    /// `[B][Cp][T]`, `knownCov` `[B][Ck][T + H]` → levels and `[B][V][H][Q]`,
    /// sorted along Q (`fix_crossing`).
    func quantiles(context: [[[Double]]], horizon: Int, pastCov: [[[Double]]]?,
                   knownCov: [[[Double]]]?) throws -> FMBackends.Quantiles
}

public extension FMBackend {
    func quantiles(context: [[[Double]]], horizon: Int) throws -> FMBackends.Quantiles {
        try quantiles(context: context, horizon: horizon, pastCov: nil, knownCov: nil)
    }
}
