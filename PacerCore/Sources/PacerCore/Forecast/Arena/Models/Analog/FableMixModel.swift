import Foundation

/// `models/g1-10-fable-mix/model.py`: a path-pool mixture over children.
/// For each target the paths of every child that answered are pooled in
/// fixed shares (`model.toml` `[config.shares."<target>"]`, renormalized
/// over the children that answered), each child's contribution drawn
/// without replacement from its own paths (a point forecast is repeated).
/// Nothing is learned, so it cannot overfit.
///
/// A child that answers with quantiles rather than paths (the analog
/// model's exact five-hour forecast, a deterministic port) contributes its
/// quantile curves at evenly spaced levels, `(i + 0.5) / k`: the same
/// distribution the arena's draw of `k` of its paths samples, without the
/// draw's noise.
final class FableMixModel: ArenaModel {
    let ctx: ArenaContext
    var rng: ArenaRNG
    let shares: ArenaConfig
    /// In `model.toml` order. The shares tables list their children in this
    /// order too, and that order decides who absorbs the rounding (the
    /// first): `ArenaConfig` is a dictionary, so the order comes from here.
    let children: [String]

    init(context: ArenaContext) {
        ctx = context
        rng = context.rng
        shares = context.config.table("shares")
        children = context.children
    }

    func fit(_ history: ArenaHistory) {}

    func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        var got: [String: ArenaForecast] = [:]
        for c in children {
            do {
                got[c] = try ctx.model(c).forecast(request)
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                ctx.log("child \(c) failed: \(String(describing: error).prefix(200))")
            }
        }
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets {
            let table = shares.table(tr.target.rawValue)
            var avail: [(child: String, forecast: ArenaTargetForecast, share: Double)] = children.compactMap { c in
                guard let s = table[c]?.double, s > 0, let tf = got[c]?.byKey[tr.key] else { return nil }
                return (c, tf, s)
            }
            if avail.isEmpty {
                // anything that answered
                guard let c = children.first(where: { got[$0]?.byKey[tr.key] != nil }),
                      let tf = got[c]?.byKey[tr.key] else { continue }
                avail = [(c, tf, 1.0)]
            }
            let tot = avail.reduce(0) { $0 + $1.share }
            let n = tr.nPaths
            var counts = avail.map { Int((Double(n) * $0.share / tot).rounded(.toNearestOrEven)) }
            // fix rounding so the counts sum to n
            counts[0] += n - counts.reduce(0, +)
            var P: [[Double]] = []
            P.reserveCapacity(n)
            for (i, part) in avail.enumerated() where counts[i] > 0 {
                P += Self.draw(part.forecast, counts[i], rng: &rng)
            }
            // Every target here is a meter: keep the pooled paths in [0, 100].
            P = P.map { $0.map { min(max($0, 0), 100) } }
            out[tr.key] = ArenaTargetForecast(paths: P)
        }
        return ArenaForecast(byKey: out)
    }

    /// `k` paths of one child: drawn without replacement from its own
    /// paths (with replacement when it has fewer than `k`), or its quantile
    /// curves at `k` evenly spaced levels.
    static func draw(_ tf: ArenaTargetForecast, _ k: Int, rng: inout ArenaRNG) -> [[Double]] {
        if let paths = tf.paths, !paths.isEmpty {
            if paths.count >= k {
                // A partial Fisher–Yates shuffle: k distinct indices.
                var idx = Array(paths.indices)
                for i in 0..<k {
                    let j = i + Int(rng.uniform() * Double(idx.count - i))
                    idx.swapAt(i, min(j, idx.count - 1))
                }
                return idx.prefix(k).map { paths[$0] }
            }
            return (0..<k).map { _ in paths[min(Int(rng.uniform() * Double(paths.count)), paths.count - 1)] }
        }
        // `tf.quantile(level)` per level, one grid column at a time (the
        // same interpolation, without rebuilding each column per level).
        guard let levels = tf.levels, let qs = tf.quantiles else { return [] }
        let G = tf.gridCount
        var out = [[Double]](repeating: [Double](repeating: 0, count: G), count: k)
        for j in 0..<G {
            let ys = qs.map { $0[j] }
            for i in 0..<k { out[i][j] = ArenaMath.interp((Double(i) + 0.5) / Double(k), xs: levels, ys: ys) }
        }
        return out
    }
}
