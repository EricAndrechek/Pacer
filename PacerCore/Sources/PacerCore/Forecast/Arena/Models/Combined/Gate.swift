import Foundation

/// `research/arena/models/g2-06-opus-fmgate2/gate.py`: account-state gating
/// of meter paths.
///
/// A meter only rises while its account is in use. Turns are known seconds
/// after they happen, so at `now` we know how long the account has been idle
/// (`d`), whether another account of the user is busy, and whether the
/// account is blocked (a window at 100 % until its reset). From the
/// account's own past idle stretches we draw, per path, when its use resumes
/// (`tau`): the residual of past idle stretches that had already lasted
/// about `d`, weighted by recency, local hour and whether another account was
/// busy then. A base model's path is then held at the current value until
/// `tau` and follows the base's own rise afterwards (time-shifted or
/// increment-cut, by config).
///
/// Turn times come from the history's spend rows (`ArenaSpendRow`, one per
/// model family per five minutes: the bucket's last turn), exactly the
/// pseudo-turns the parity fixtures carry; on the app's data an idle gap
/// shorter than a bucket can read shorter than the Python's real turns would.
public enum Gate {
    static let minMs: Double = 60_000
    static let hourMs: Double = 3_600_000
    static let dayMs: Double = 86_400_000

    static let familyOfCap: [(String, String)] = [("fable", "fable"), ("opus", "opus"), ("sonnet", "sonnet"),
                                                  ("haiku", "haiku")]

    /// `cap_family`: the model family a scoped cap's name names, if any.
    public static func capFamily(_ cap: String?) -> String? {
        guard let cap, !cap.isEmpty else { return nil }
        let c = cap.lowercased()
        return familyOfCap.first { c.contains($0.0) }?.1
    }

    /// `TurnBook`: turn times per account and family, from one history.
    public struct TurnBook: Sendable {
        let by: [String: [String: [Millis]]]

        public init(_ history: ArenaHistory) {
            var by: [String: [String: [Millis]]] = [:]
            for a in history.accounts {
                for row in history.spend(account: a) { by[a, default: [:]][row.family, default: []].append(row.tEvent) }
            }
            self.by = by.mapValues { $0.mapValues { $0.sorted() } }
        }

        /// One family's turns (nil: all of the account's), ascending.
        public func times(_ account: String, family: String? = nil) -> [Millis] {
            guard let fams = by[account] else { return [] }
            if let family { return fams[family] ?? [] }
            return fams.values.flatMap { $0 }.sorted()
        }

        /// Every other account's turns, ascending.
        public func others(_ account: String) -> [Millis] {
            by.filter { $0.key != account }.values.flatMap { $0.values.flatMap { $0 } }.sorted()
        }
    }

    /// `idle_ms`: time since the last turn at or before now (infinite with none).
    public static func idleMs(_ T: [Millis], _ now: Millis) -> Double {
        let i = FMCal.SelfBacktest.lastAtOrBefore(T, now)
        return i >= 0 ? Double(now - T[i]) : .infinity
    }

    /// `local_hour`.
    static func localHour(_ t: Double, _ tzMs: Double) -> Double {
        // numpy's float `%` takes the divisor's sign.
        let x = t + tzMs
        let m = x - (x / dayMs).rounded(.down) * dayMs
        return m / hourMs
    }

    /// The resume weights `sample_resume` draws from: the residuals of past
    /// gaps longer than `d` and their normalized weights; nil when there is
    /// too little to go on.
    public static func resumeTable(_ T: [Millis], other: [Millis], now: Millis, d: Double, tzMs: Double,
                                   cfg: ArenaConfig) -> (resid: [Double], p: [Double])? {
        guard T.count >= 20, d.isFinite else { return nil }
        var resid: [Double] = [], at: [Double] = []
        for i in 0..<(T.count - 1) {
            let gap = Double(T[i + 1] - T[i])
            if gap > d { resid.append(gap - d); at.append(Double(T[i]) + d) }
        }
        guard resid.count >= cfg.int("min_gaps", 8) else { return nil }
        let recency = cfg.double("recency_days", 30), bw = cfg.double("bw_hour", 2.5)
        let hNow = localHour(Double(now), tzMs)
        var w = [Double](repeating: 0, count: resid.count)
        for i in 0..<resid.count {
            let ageD = (Double(now) - at[i]) / dayMs
            var wi = exp(-max(ageD, 0) / recency)
            var hd = abs(localHour(at[i], tzMs) - hNow)
            hd = min(hd, 24 - hd)
            let z = hd / bw
            wi = wi * exp(-0.5 * (z * z))
            w[i] = wi
        }
        let otherWeight = cfg.double("other_weight", 3.0)
        if !other.isEmpty && otherWeight != 1.0 {
            let busyMs = cfg.double("other_busy_min", 10) * minMs
            let busyNow = idleMs(other, now) < busyMs
            for i in 0..<w.count {
                let j = FMCal.SelfBacktest.lastAtOrBefore(other, Millis(at[i].rounded(.down)))
                // np.searchsorted(other, at, "right") on float `at`: an int
                // turn time t <= at  <=>  t <= floor(at).
                let busyThen = j >= 0 && (at[i] - Double(other[max(j, 0)])) < busyMs
                w[i] *= (busyThen == busyNow) ? otherWeight : 1.0
            }
        }
        let total = KitMath.sum(w)
        guard total > 0, total.isFinite else { return nil }
        return (resid, w.map { $0 / total })
    }

    /// `sample_resume`: `n` waits (ms from now) until the account's next own
    /// turn, given it has been idle `d` ms: past residuals drawn by weight,
    /// jittered within their scale so ties don't stack exactly.
    public static func sampleResume(_ T: [Millis], other: [Millis], now: Millis, d: Double, tzMs: Double, n: Int,
                                    rng: inout ArenaRNG, cfg: ArenaConfig) -> [Double]? {
        guard let (resid, p) = resumeTable(T, other: other, now: now, d: d, tzMs: tzMs, cfg: cfg) else { return nil }
        var cum = [Double](repeating: 0, count: p.count)
        var s = 0.0
        for (i, x) in p.enumerated() { s += x; cum[i] = s }
        let jitter = cfg.double("jitter", 0.15)
        return (0..<n).map { _ in
            let u = rng.uniform() * s
            var lo = 0, hi = cum.count - 1
            while lo < hi { let mid = (lo + hi) >> 1; if cum[mid] <= u { lo = mid + 1 } else { hi = mid } }
            return resid[lo] * exp(rng.normal() * jitter)
        }
    }

    /// `blocked_until`: the latest reset among this account's windows that
    /// read ~100 % now (their latest reading, active, under two hours old,
    /// reset ahead); 0 when none blocks. Throws where the Python would (a
    /// latest active reading with no util), so the caller keeps its paths
    /// ungated as the Python's does.
    public static func blockedUntil(_ history: ArenaHistory, account: String, now: Millis,
                                    windows: [String] = ["five_hour", "seven_day"]) throws -> Millis {
        var out: Millis = 0
        for wk in windows {
            guard let last = history.readings(account: account, windowKind: wk).last(where: \.active) else { continue }
            guard let util = last.utilPct else { throw ArenaError.invalid("blocked_until: no util on the latest reading") }
            guard let rs = last.resetsAt, rs > now, now - last.tEvent <= 2 * ArenaTime.hour else { continue }
            if util >= 99.5 { out = max(out, rs) }
        }
        return out
    }

    /// `gate_paths`: hold each path at `u0` until `now + tau[i]`; afterwards
    /// follow the base. shift: the base's rise from now replayed `tau` later;
    /// cut: only the base's increments after `tau` count.
    public static func gatePaths(_ base: [[Double]], grid: [Millis], now: Millis, u0: Double, tau: [Double],
                                 mode: String = "shift") -> [[Double]] {
        let g = grid.map(Double.init)
        let gx = [Double(now)] + g
        return base.enumerated().map { i, P in
            let ti = tau[i % tau.count]
            if !ti.isFinite { return [Double](repeating: min(max(u0, 0), 100), count: P.count) }
            if ti <= 0 { return P.map { min(max($0, 0), 100) } }
            let D = P.map { max($0 - u0, 0.0) }
            let dx = [0.0] + D
            var vals: [Double]
            if mode == "shift" {
                // np.interp(g - ti, gx, dx, left=0.0)
                vals = g.map { x in
                    let xx = x - ti
                    return xx < gx[0] ? 0.0 : KitDetQ.npInterp(xx, xs: gx, ys: dx)
                }
            } else {
                let at = KitDetQ.npInterp(Double(now) + ti, xs: gx, ys: dx)
                vals = D.map { max($0 - at, 0.0) }
            }
            for j in 0..<g.count where g[j] < Double(now) + ti { vals[j] = 0.0 }
            return vals.map { min(max(u0 + $0, 0.0), 100.0) }
        }
    }
}
