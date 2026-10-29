import Foundation

/// `kit/fm/backends.py` `TimestralBackend`: Timestral behind the arena's one
/// call. The forecaster comes from `FMBackends.timestral` (one per weights id
/// per process) and the call is `FMBackends.quantiles`, unchanged, so a model
/// reaching Timestral through the backend table gets exactly what a direct
/// call does.
public final class TimestralBackend: FMBackend {
    public let fc: TimestralForecaster

    public init(_ fc: TimestralForecaster) { self.fc = fc }

    public func quantiles(context: [[[Double]]], horizon: Int, pastCov: [[[Double]]]?,
                          knownCov: [[[Double]]]?) throws -> FMBackends.Quantiles {
        try FMBackends.quantiles(fc, context: context, horizon: horizon, pastCov: pastCov, knownCov: knownCov)
    }
}

extension FMBackends {
    /// `"timestral"` in `FMBackends.factories`.
    static let timestralFactory: [String: Factory] = [
        "timestral": { id, services in TimestralBackend(try FMBackends.timestral(id, services: services)) },
    ]
}
