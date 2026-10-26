import Foundation

/// `models/g1-01-sonnet-calibrate123/model.py`: a fixed-scale calibration of
/// `fm-timestral-123m-meter`. The child's intervals were too wide on the
/// visible tier (cover50 0.86 where 0.50 is nominal); every path is pulled
/// toward the child's median by a fixed factor,
/// `path = median + scale · (path − median)`, clipped to [0, 100]. No
/// backtests (the factor was set from the child's known bias).
///
/// A child that answers with quantiles gets the same map on its quantiles:
/// for scale > 0 it is monotone per grid time, so the mapped quantiles are
/// the quantiles of the mapped paths, and the median is the child's own.
public final class Calibrate123Model: ArenaModel {
    let ctx: ArenaContext
    public let child: String
    public let scale: Double

    public init(context: ArenaContext) {
        ctx = context
        child = context.config.string("child", "fm-timestral-123m-meter")
        scale = context.config.double("scale", 0.60)
    }

    public func fit(_ history: ArenaHistory) {}

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        let childFC: ArenaForecast
        do {
            childFC = try ctx.model(child).forecast(request)
        } catch ArenaError.cancelled {
            throw ArenaError.cancelled
        } catch {
            // As the Python: a failed child is an empty forecast.
            ctx.log("child failed: \(error)")
            return ArenaForecast(byKey: [:])
        }
        let s = scale
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets where FMMeterModel.windowFor[tr.target] != nil {
            guard let tf = childFC.byKey[tr.key] else { continue }
            if abs(s - 1.0) < 1e-6 { out[tr.key] = tf; continue }
            out[tr.key] = Self.scaled(tf, s)
        }
        return ArenaForecast(byKey: out)
    }

    /// `median + s · (x − median)`, clipped to [0, 100], per grid time.
    static func scaled(_ tf: ArenaTargetForecast, _ s: Double) -> ArenaTargetForecast {
        if let paths = tf.paths {
            let med = BandedEnsemble.medianColumns(paths)
            return ArenaTargetForecast(paths: paths.map { row in
                row.indices.map { min(max(med[$0] + s * (row[$0] - med[$0]), 0.0), 100.0) }
            }, extras: tf.extras)
        }
        guard let levels = tf.levels, let q = tf.quantiles else { return tf }
        let med = tf.median
        return ArenaTargetForecast(levels: levels, quantiles: q.map { row in
            row.indices.map { min(max(med[$0] + s * (row[$0] - med[$0]), 0.0), 100.0) }
        }, extras: tf.extras)
    }
}
