import Foundation

/// `kit/fm/backends.py` `TimesFM25Backend`: TimesFM 2.5 (200M) behind the
/// arena's one call. Univariate (every series and variate on its own), no
/// covariates, no NaN (gaps filled first, `fill_gaps`), contexts cut to
/// 16 384 steps, nine quantiles 0.1…0.9.
///
/// Per call it compiles as the arena's `_compile` does: the context rounded
/// up to whole 32-step patches, the horizon to whole 128-step output
/// patches, inputs normalized, the continuous quantile head whenever the
/// horizon fits it (1024 steps), quantile crossing fixed. The network loads
/// once per weights id per process (`FMBackends.backend`).
public final class TimesFM25Backend: FMBackend {
    public static let name = "timesfm25"
    public static let maxContext = 16_384
    /// `np.round(np.arange(1, 10) / 10.0, 2)`.
    public static let levels = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]

    public let fc: TimesFMForecaster

    public init(_ fc: TimesFMForecaster) { self.fc = fc }

    public convenience init(directory: URL) throws {
        self.init(TimesFMForecaster(network: try TimesFMNetwork(directory: directory)))
    }

    /// `_compile(T, horizon, batch)`'s `ForecastConfig`.
    public func forecastConfig(contextLength t: Int, horizon: Int, batch: Int) -> TimesFMForecaster.ForecastConfig {
        let p = fc.config.inputPatchLen, o = fc.config.outputPatchLen
        let maxHorizon = (horizon + o - 1) / o * o
        return .init(maxContext: (t + p - 1) / p * p, maxHorizon: maxHorizon, normalizeInputs: true,
                     perCoreBatchSize: batch, useContinuousQuantileHead: maxHorizon <= fc.config.outputQuantileLen,
                     fixQuantileCrossing: true)
    }

    public func quantiles(context: [[[Double]]], horizon: Int, pastCov: [[[Double]]]?,
                          knownCov: [[[Double]]]?) throws -> FMBackends.Quantiles {
        let (ctx, _, _) = FMBackends.prepare(context: context, pastCov: pastCov, knownCov: knownCov,
                                             maxContext: Self.maxContext, nanOK: false, covariates: false)
        let b = ctx.count, v = ctx.first?.count ?? 0
        // `_univariate`: [B, V, T] as B·V series; `r.astype(np.float32)`.
        let rows = ctx.flatMap { $0 }.map { $0.map { Float($0) } }
        guard let t = rows.first?.count, t > 0, horizon > 0 else {
            throw ArenaError.invalid("TimesFM: empty context or horizon")
        }
        let cfg = forecastConfig(contextLength: t, horizon: horizon, batch: min(rows.count, 32))
        let out = try fc.forecast(horizon: horizon, inputs: rows, config: cfg)
        // `q[:, :horizon, 1:10]`, then `fix_crossing` (sorted along Q).
        let nq = Self.levels.count
        var values = [Double](repeating: 0, count: rows.count * horizon * nq)
        var row = [Double](repeating: 0, count: nq)
        for r in 0..<rows.count {
            for h in 0..<horizon {
                for k in 0..<nq { row[k] = Double(out.at(r, h, k + 1)) }
                row.sort()
                for k in 0..<nq { values[(r * horizon + h) * nq + k] = row[k] }
            }
        }
        return FMBackends.Quantiles(levels: Self.levels, b: b, v: v, h: horizon, q: nq, values: values)
    }
}

extension FMBackends {
    /// `"timesfm25"` in `FMBackends.factories`.
    static let timesfmFactory: [String: Factory] = [
        TimesFM25Backend.name: { id, services in
            guard let dir = services.weights(id) else { throw ArenaError.weightsUnavailable(id) }
            return try TimesFM25Backend(directory: dir)
        },
    ]
}
