import Foundation

/// Non-negative least squares: minimise ‖Ax − b‖ subject to x ≥ 0.
///
/// Lawson and Hanson's active-set method (*Solving Least Squares Problems*,
/// 1974, ch. 23), the algorithm behind `scipy.optimize.nnls`. The research
/// harness fits the spend → meter conversion with scipy, so the same
/// algorithm here is what lets the two be compared on the same rows (#317).
///
/// Sized for that fit: hundreds to a few thousand rows and at most ~16
/// columns. Every inner solve is a fresh Householder QR of the passive
/// columns, O(m·k²) and microseconds at this size. The normal equations
/// would be shorter to write, but they square the condition number, and
/// spend columns are collinear by nature: two models used in the same
/// session spend in the same hours.
///
/// Columns are scaled to unit length before solving and the answer scaled
/// back. A positive column scale does not change the non-negative solution,
/// but it puts every column on one footing for the tolerance: an intercept
/// column of ones and a column of hourly dollars differ by orders of
/// magnitude otherwise.
public enum NNLS {

    public struct Solution: Sendable, Equatable {
        /// One coefficient per column of `A`, each ≥ 0.
        public let x: [Double]
        /// ‖Ax − b‖ at `x`.
        public let residualNorm: Double
        /// Inner least-squares solves taken.
        public let iterations: Int
        /// False when the iteration cap stopped it first. `x` is still
        /// feasible then, just not proven optimal.
        public let converged: Bool
    }

    /// `rows[i]` is row i of `A`; every row must have the same length.
    /// `maxIterations` defaults to scipy's 3 × columns.
    public static func solve(rows: [[Double]], b: [Double], maxIterations: Int? = nil) -> Solution {
        let m = rows.count
        let n = rows.first?.count ?? 0
        precondition(b.count == m, "NNLS: \(m) rows but \(b.count) targets")
        guard m > 0, n > 0 else {
            return Solution(x: Array(repeating: 0, count: n),
                            residualNorm: norm(b), iterations: 0, converged: true)
        }

        // Column-major and scaled. A zero column keeps scale 0 and never
        // enters the passive set: its gradient is always 0.
        var cols = Array(repeating: Array(repeating: 0.0, count: m), count: n)
        for i in 0..<m {
            precondition(rows[i].count == n, "NNLS: ragged row \(i)")
            for j in 0..<n { cols[j][i] = rows[i][j] }
        }
        var scale = Array(repeating: 0.0, count: n)
        for j in 0..<n {
            let s = norm(cols[j])
            scale[j] = s
            if s > 0 { for i in 0..<m { cols[j][i] /= s } }
        }

        // scipy's tolerance, on the scaled matrix: every column has unit
        // 2-norm, so its 1-norm is at most √m.
        let tol = 10 * Double.ulpOfOne * Double(max(m, n)) * Double(m).squareRoot()
        let cap = maxIterations ?? 3 * n

        var x = Array(repeating: 0.0, count: n)
        var passive = Array(repeating: false, count: n)
        var iterations = 0
        var converged = true

        outer: while true {
            let residual = residualOf(cols, x, b)
            var w = (0..<n).map { dot(cols[$0], residual) }
            // A column that just came back non-positive is set aside until x
            // moves — re-adding it would loop. Lawson–Hanson's own guard.
            var rejected = Array(repeating: false, count: n)
            var added = false
            while !added {
                var best = -1
                var bestW = tol
                for j in 0..<n where !passive[j] && !rejected[j] && scale[j] > 0 && w[j] > bestW {
                    best = j
                    bestW = w[j]
                }
                guard best >= 0 else { break outer }
                passive[best] = true

                // Inner loop: solve on the passive set; step back toward the
                // last feasible x whenever a coefficient goes non-positive.
                var z = Array(repeating: 0.0, count: n)
                var firstSolve = true
                while true {
                    iterations += 1
                    if iterations > cap { converged = false; break outer }
                    let p = (0..<n).filter { passive[$0] }
                    let zp = leastSquares(columns: p.map { cols[$0] }, b: b)
                    z = Array(repeating: 0.0, count: n)
                    for (k, j) in p.enumerated() { z[j] = zp[k] }

                    if firstSolve && z[best] <= 0 {
                        // The column that entered cannot take a positive
                        // weight: numerically it adds nothing. Reject it and
                        // try the next-best gradient with x unchanged.
                        passive[best] = false
                        rejected[best] = true
                        w[best] = 0
                        break
                    }
                    firstSolve = false
                    if p.allSatisfy({ z[$0] > 0 }) {
                        x = z
                        added = true
                        break
                    }
                    var alpha = Double.infinity
                    for j in p where z[j] <= 0 {
                        let denom = x[j] - z[j]
                        if denom > 0 { alpha = min(alpha, x[j] / denom) }
                    }
                    if !alpha.isFinite { alpha = 0 }
                    for j in 0..<n { x[j] += alpha * (z[j] - x[j]) }
                    for j in p where x[j] <= tol {
                        x[j] = 0
                        passive[j] = false
                    }
                }
            }
        }

        let unscaled = (0..<n).map { scale[$0] > 0 ? max(0, x[$0]) / scale[$0] : 0 }
        return Solution(x: unscaled, residualNorm: norm(residualOf(cols, x, b)),
                        iterations: iterations, converged: converged)
    }

    // MARK: - Linear algebra

    /// Unconstrained least squares on `columns` (each of length m) by
    /// Householder QR. A column that is numerically dependent on the ones
    /// before it gets coefficient 0, which the caller then drops from the
    /// passive set.
    static func leastSquares(columns: [[Double]], b: [Double]) -> [Double] {
        let k = columns.count
        guard k > 0 else { return [] }
        let m = b.count
        var r = columns
        var qtb = b
        var diag = Array(repeating: 0.0, count: k)

        for j in 0..<min(k, m) {
            var sigma = 0.0
            for i in j..<m { sigma += r[j][i] * r[j][i] }
            let colNorm = sigma.squareRoot()
            guard colNorm > 0 else { diag[j] = 0; continue }
            let alpha = r[j][j] > 0 ? -colNorm : colNorm
            // v = x − αe₁, stored in place of column j's lower part.
            r[j][j] -= alpha
            var vv = 0.0
            for i in j..<m { vv += r[j][i] * r[j][i] }
            diag[j] = alpha
            guard vv > 0 else { continue }
            for c in (j + 1)..<k {
                var s = 0.0
                for i in j..<m { s += r[j][i] * r[c][i] }
                let f = 2 * s / vv
                for i in j..<m { r[c][i] -= f * r[j][i] }
            }
            var s = 0.0
            for i in j..<m { s += r[j][i] * qtb[i] }
            let f = 2 * s / vv
            for i in j..<m { qtb[i] -= f * r[j][i] }
        }

        // Back-substitute R z = Qᵀb, with R's diagonal in `diag` and its
        // strict upper triangle in r[c][j] for c > j.
        let biggest = diag.map(abs).max() ?? 0
        let floor = biggest * 1e-12
        var z = Array(repeating: 0.0, count: k)
        for j in stride(from: min(k, m) - 1, through: 0, by: -1) {
            guard abs(diag[j]) > floor else { z[j] = 0; continue }
            var s = qtb[j]
            for c in (j + 1)..<k { s -= r[c][j] * z[c] }
            z[j] = s / diag[j]
        }
        return z
    }

    private static func residualOf(_ cols: [[Double]], _ x: [Double], _ b: [Double]) -> [Double] {
        var r = b
        for (j, col) in cols.enumerated() where x[j] != 0 {
            let xj = x[j]
            for i in 0..<r.count { r[i] -= xj * col[i] }
        }
        return r
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    private static func norm(_ a: [Double]) -> Double {
        dot(a, a).squareRoot()
    }
}
