import Foundation

// Small numerics the simulation ports share: numpy's draws that `ArenaRNG`
// does not have (gamma, exponential, weighted and without-replacement
// choice) and Python's rounding. Draw for draw these are not numpy's (the
// streams differ anyway, `ArenaRNG`); each matches its numpy counterpart in
// distribution, which is what the Monte-Carlo parity checks.
enum SimRandom {
    /// `Generator.gamma(shape, scale)`. Shape 1 (g2-08's `gamma_shape`) is
    /// the exponential, drawn directly; otherwise Marsaglia–Tsang, with the
    /// `shape < 1` boost.
    static func gamma(_ shape: Double, scale: Double, rng: inout ArenaRNG) -> Double {
        if shape == 1 { return -log(max(1 - rng.uniform(), .leastNonzeroMagnitude)) * scale }
        if shape < 1 {
            let u = max(rng.uniform(), .leastNonzeroMagnitude)
            return gamma(shape + 1, scale: scale, rng: &rng) * pow(u, 1 / shape)
        }
        let d = shape - 1.0 / 3.0
        let c = 1 / (9 * d).squareRoot()
        while true {
            var x = 0.0, v = 0.0
            repeat { x = rng.normal(); v = 1 + c * x } while v <= 0
            v = v * v * v
            let u = rng.uniform()
            if u < 1 - 0.0331 * x * x * x * x { return d * v * scale }
            if log(max(u, .leastNonzeroMagnitude)) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v * scale }
        }
    }

    /// `Generator.exponential(mean)`.
    static func exponential(_ mean: Double, rng: inout ArenaRNG) -> Double {
        -log(max(1 - rng.uniform(), .leastNonzeroMagnitude)) * mean
    }

    /// Python's `round()` and numpy's `np.round`: half to even.
    static func pyRound(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

    /// Python's `%` for a positive modulus (never negative).
    @inline(__always) static func pmod(_ a: Millis, _ m: Millis) -> Millis {
        let r = a % m
        return r < 0 ? r + m : r
    }

    /// Python's `//` (floor division) for a positive divisor.
    @inline(__always) static func floorDiv(_ a: Millis, _ m: Millis) -> Millis {
        let q = a / m
        return (a % m != 0 && (a < 0) != (m < 0)) ? q - 1 : q
    }

    /// `rng.choice(n, size, replace=False)`: a uniform subset, in draw order
    /// (partial Fisher–Yates).
    static func choiceWithoutReplacement(_ n: Int, _ k: Int, rng: inout ArenaRNG) -> [Int] {
        var pool = Array(0..<n)
        var out: [Int] = []
        out.reserveCapacity(k)
        for i in 0..<min(k, n) {
            let j = i + Int(rng.uniform() * Double(n - i))
            pool.swapAt(i, min(j, n - 1))
            out.append(pool[i])
        }
        return out
    }

    /// `rng.choice(n, size, replace=True)`: uniform indices.
    @inline(__always) static func uniformIndex(_ n: Int, rng: inout ArenaRNG) -> Int {
        min(Int(rng.uniform() * Double(n)), n - 1)
    }
}

/// `rng.choice(values, p=weights)`: a discrete distribution over indices,
/// drawn by inverse CDF (numpy's own method for `choice` with `p`).
struct SimDiscrete {
    let cdf: [Double]

    /// Weights need not be normalized; all-zero or empty weights draw
    /// uniformly (never hit by the ports, which normalize positive weights).
    init(weights: [Double]) {
        var c = [Double](repeating: 0, count: weights.count)
        var s = 0.0
        for i in weights.indices { s += max(weights[i], 0); c[i] = s }
        if s > 0 { for i in c.indices { c[i] /= s } } else { for i in c.indices { c[i] = Double(i + 1) / Double(c.count) } }
        if !c.isEmpty { c[c.count - 1] = 1 }
        cdf = c
    }

    var count: Int { cdf.count }

    /// The first index whose cumulative weight exceeds a uniform draw.
    @inline(__always) func draw(_ rng: inout ArenaRNG) -> Int {
        let u = rng.uniform()
        var lo = 0, hi = cdf.count - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if cdf[mid] > u { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

enum SimArrays {
    /// `np.searchsorted(xs, x, side="right")` over ascending `xs`.
    @inline(__always) static func searchRight<T: Comparable>(_ xs: [T], _ x: T) -> Int {
        var lo = 0, hi = xs.count
        while lo < hi { let mid = (lo + hi) >> 1; if xs[mid] <= x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// `np.searchsorted(xs, x, side="left")` over ascending `xs`.
    @inline(__always) static func searchLeft<T: Comparable>(_ xs: [T], _ x: T) -> Int {
        var lo = 0, hi = xs.count
        while lo < hi { let mid = (lo + hi) >> 1; if xs[mid] < x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// `np.maximum.accumulate(np.clip(path, lo, hi))` in place.
    static func clipRunningMax(_ path: inout [Double], lo: Double, hi: Double) {
        var m = -Double.infinity
        for j in path.indices {
            let v = min(max(path[j], lo), hi)
            m = max(m, v)
            path[j] = m
        }
    }
}

/// A memo value that may be nil. `ArenaMemo.value` must never be given an
/// Optional `T`: its lookup `values[key] as? T` succeeds on a missing key
/// when `T` is Optional (a nil `Any?` casts to `T?`), so it would return nil
/// without ever computing. Boxing makes `T` a plain struct.
struct SimBox<T> {
    let value: T
}
