import Foundation

/// A child's sample paths: its own, or comonotone ones from its quantiles
/// (a Swift port may answer in quantiles; the Python's `.paths` always
/// exist, `TargetForecast.from_quantiles` making them the same way).
private func childPaths(_ f: ArenaTargetForecast, _ n: Int, _ rng: inout ArenaRNG) -> [[Double]] {
    f.paths ?? f.samplePaths(max(n, 1), rng: &rng)
}

/// g2-08-fable-burst-mix (`research/arena/models/g2-08-fable-burst-mix/model.py`):
/// a linear pool of the burst-process model and a pretrained forecaster on
/// the cumulative burn (`fm-timestral-123m-meter`).
///
/// The two make different mistakes: the burst model knows whether the user
/// is working and how long spells last, the pretrained forecaster
/// extrapolates the recent slope with a well-shaped band. Pooling their paths
/// (a mixture of ensembles is a mixture of their paths) gives a forecast
/// whose CRPS is usually below both. Within the first `head_min` minutes every
/// path is pinned to the burst model's (its integer start is the better
/// next-reading guess).
final class G208FableBurstMix: ArenaModel {
    static let name = "g2-08-fable-burst-mix"
    static let burst = "g2-08-fable-burst"

    let ctx: ArenaContext
    let cfg: ArenaConfig
    let weights: [String: Double]

    init(context: ArenaContext) {
        ctx = context
        cfg = context.config
        weights = cfg.table("weights").values.compactMapValues(\.double)
    }

    func fit(_ history: ArenaHistory) throws {}

    func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        var got: [String: [String: ArenaTargetForecast]] = [:]
        for name in ctx.children {
            do {
                got[name] = try ctx.model(name).forecast(request).byKey
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                ctx.log("child \(name) failed: \(error)")
                got[name] = [:]
            }
        }
        var rng = ctx.rng
        defer { ctx.rng = rng }
        var out: [String: ArenaTargetForecast] = [:]
        let head = cfg.double("head_min", 3) * 60_000
        for tr in request.targets where tr.target == .meterFiveHour {
            let parts: [(String, [[Double]], Double)] = ctx.children.compactMap { n in
                guard let f = got[n]?[tr.key], let w = weights[n], w > 0 else { return nil }
                return (n, childPaths(f, tr.nPaths, &rng), w)
            }
            if parts.isEmpty { continue }
            let tot = parts.map(\.2).reduce(0, +)
            let P = tr.nPaths
            var paths: [[Double]] = []
            var acc = 0
            for (i, (_, ps, w)) in parts.enumerated() {
                let m = i == parts.count - 1 ? P - acc : Int(SimRandom.pyRound(Double(P) * w / tot))
                acc += m
                if m <= 0 { continue }
                let k = ps.count
                var idx: [Int]
                if k > m {
                    // Evenly spaced paths (`np.linspace(0, k - 1, m).round()`, unique).
                    idx = (0..<m).map { j in
                        Int(SimRandom.pyRound(m == 1 ? 0 : Double(j) * Double(k - 1) / Double(m - 1)))
                    }
                    idx = Array(Set(idx)).sorted()
                } else {
                    idx = Array(0..<k)
                }
                if idx.count < m { idx = (0..<m).map { idx.isEmpty ? 0 : idx[$0 % idx.count] } }   // np.resize: tile
                paths += idx.map { ps[$0] }
            }
            // The dense head follows the burst model: its start is the next reading's best guess.
            if let base = got[Self.burst]?[tr.key] {
                let b = childPaths(base, tr.nPaths, &rng)
                let hm = tr.grid.map { Double($0 - request.now) <= head }
                if !b.isEmpty && hm.contains(true) {
                    for i in paths.indices {
                        let bp = b[i % b.count]
                        for j in tr.grid.indices where hm[j] { paths[i][j] = bp[j] }
                    }
                }
            }
            for i in paths.indices { SimArrays.clipRunningMax(&paths[i], lo: 0, hi: 100) }
            out[tr.key] = ArenaTargetForecast(paths: paths)
        }
        return ArenaForecast(byKey: out)
    }
}

/// g2-07-opus-pool (`research/arena/models/g2-07-opus-pool/model.py`): the
/// limit simulator pooled with a pretrained meter model.
///
/// `g2-07-opus-limit` calls the limit well where the account's own habits
/// decide it (parking short of 100, re-bases, how long an idle account stays
/// idle); `fm-timestral-5m-meter` reads the recent shape of the meter well.
/// Their paths are pooled per target: a share `fm_weight` of the request's
/// paths comes from the pretrained model, the rest from the simulator. If a
/// child fails, the other's paths stand alone.
final class G207OpusPool: ArenaModel {
    static let name = "g2-07-opus-pool"

    let ctx: ArenaContext
    let cfg: ArenaConfig
    let sim: String
    let fm: String

    init(context: ArenaContext) {
        ctx = context
        cfg = context.config
        sim = cfg.string("sim", "g2-07-opus-limit")
        fm = cfg.string("fm", "fm-timestral-5m-meter")
    }

    func fit(_ history: ArenaHistory) throws {}

    private func child(_ name: String, _ request: ArenaRequest) throws -> [String: ArenaTargetForecast] {
        do {
            return try ctx.model(name).forecast(request).byKey
        } catch ArenaError.cancelled {
            throw ArenaError.cancelled
        } catch {
            // One child down is not the forecast down.
            ctx.log("\(name) failed: \(error)")
            return [:]
        }
    }

    func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        let trs = request.targets
        if trs.isEmpty { return ArenaForecast(byKey: [:]) }
        let a = try child(sim, request)
        let b = try child(fm, request)
        let weights = cfg.table("fm_weight")
        var rng = ctx.rng
        defer { ctx.rng = rng }
        var out: [String: ArenaTargetForecast] = [:]
        for tr in trs {
            let pa = a[tr.key], pb = b[tr.key]
            if pa == nil && pb == nil { continue }
            guard let pa, let pb else {
                out[tr.key] = ArenaTargetForecast(paths: childPaths((pa ?? pb)!, tr.nPaths, &rng))
                continue
            }
            let n = tr.nPaths
            let w = weights.double(tr.target.windowKind, 0.5)
            let k = Int(SimRandom.pyRound(w * Double(n)))
            let A = childPaths(pa, n, &rng), B = childPaths(pb, n, &rng)
            func pick(_ count: Int, _ size: Int) -> [Int] {
                guard size > 0 else { return [] }
                return count < size
                    ? (0..<size).map { _ in SimRandom.uniformIndex(count, rng: &rng) }
                    : SimRandom.choiceWithoutReplacement(count, size, rng: &rng)
            }
            let ia = pick(A.count, n - k), ib = pick(B.count, k)
            out[tr.key] = ArenaTargetForecast(paths: ia.map { A[$0] } + ib.map { B[$0] })
        }
        return ArenaForecast(byKey: out)
    }
}
