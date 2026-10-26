import Foundation

/// g2-08-fable-burst (`research/arena/models/g2-08-fable-burst/model.py`,
/// `Model`): the five-hour meter as a simulated burst process.
///
/// The five-hour meter climbs only while the user works, and work comes in
/// bursts: spells of turns separated by idle gaps whose length is the single
/// best predictor of whether the meter moves again before the reset. So the
/// model simulates the activity process and lets the burn ride on it:
///
/// 1. **Activity.** The account's turn log in 5-minute bins (active = any
///    turn). Idle→active and active→idle hazards per bin by how long the
///    state has lasted (age buckets from the history's own runs, shrunk to
///    prior pseudo-counts) and by local hour of day. A share of the paths
///    copies its future activity from the account's own past instead
///    (analogs of the state now). The simulation starts in the state the
///    account is in now, with the age it has now.
/// 2. **Burn.** Each active bin burns `rate × noise` points; the per-path rate
///    is lognormal around a blend of the recent, the cycle's and the
///    long-run rate per active bin, with a regime share on the long-run rate
///    and a burst share several times faster.
/// 3. **Live start.** Readings are floored, so each path starts at the
///    reading plus a uniform sub-point offset plus the spend since it,
///    converted to points (`kit.spend`'s fit), and is floored again like the
///    server's next reading.
///
/// In the app the turn log is `ArenaSpendRow`s, one per family per 5-minute
/// bucket, exactly like the port fixtures' pseudo-turns: each row is one
/// "turn" at the bucket's last `tEvent`. At a cut on a 5-minute boundary
/// (or live, the current bucket built from the turns known now) the
/// 5-minute epoch bins the model reads (activity, hazards, hour-of-day,
/// analogs, active-bin counts), the time of the last turn and so the state
/// now are unchanged by that bucketing; only the length of a spell in
/// progress (counted in bins ending at now, not at the epoch) can come out
/// shorter. At a cut inside a bucket that bucket's row is not known yet
/// (it is known at its last turn), so up to 5 minutes of the latest
/// activity is missing and the state now can flip from active to idle:
/// backfill cuts belong on 5-minute boundaries. `SimulationBucketingTests`.
final class G208FableBurst: ArenaModel {
    static let name = "g2-08-fable-burst"
    static let minMs: Millis = 60_000
    static let hourMs: Millis = 3_600_000
    static let dayMs: Millis = 24 * hourMs
    static let window = "five_hour"
    static let windowMs: Millis = 5 * hourMs

    static let config: ArenaConfig = [
        "bin_min": 5,
        "sigma_rate": 0.45,
        "sigma_n": 1.5,
        "rate_mult": 1.0,
        "gamma_shape": 1.0,
        "recent_windows": [30, 90],
        "k_recent": 3.0,
        "prior_weight": 0.5,
        "hod_shrink_bins": 2000,
        "rate_floor": 0.3,
        "frailty_sd": 0.0,
        "analog_share": 0.7,
        "min_analogs": 20,
        "p_regime": 0.15,
        "tail_p": 0.08,
        "tail_mult": 4.0,
        "reset_tol_min": 15,
        "hod_off": true,
        "live_spend": true,
        "age_edges": [1, 2, 3, 4, 6, 9, 12, 18, 24, 36, 48, 72],
        "prior_h_on": [0.38, 0.26, 0.19, 0.16, 0.085, 0.06, 0.04, 0.026, 0.01, 0.012, 0.008, 0.004],
        "prior_h_off": [0.27, 0.22, 0.14, 0.13, 0.10, 0.085, 0.062, 0.058, 0.054, 0.045, 0.046, 0.044],
    ]

    /// Prior pseudo-exposure per age bucket, as a typical day spreads it
    /// (the model's own hard-coded shares, `_hazards`).
    static let priorExOnShare: [Double] = [0.03, 0.02, 0.015, 0.02, 0.02, 0.017, 0.027, 0.02, 0.037, 0.033, 0.055, 0.45]
    static let priorExOffShare: [Double] = [0.12, 0.09, 0.07, 0.11, 0.12, 0.09, 0.13, 0.09, 0.1, 0.055, 0.055, 0.03]

    let ctx: ArenaContext
    let cfg: ArenaConfig
    var history: ArenaHistory?
    let bin: Millis
    let edges: [Int]
    let priorOn: [Double]
    let priorOff: [Double]
    /// The age bucket of ages 0...edges.last (`_bucket`), so the chain looks
    /// a bucket up instead of searching the edges every bin of every path.
    let bucketOfAge: [Int]
    /// What the last forecast decided (`last_diag`), for tests.
    private(set) var lastDiag: [String: Double] = [:]

    init(context: ArenaContext) {
        ctx = context
        cfg = context.config
        bin = Millis(cfg.int("bin_min", 5)) * Self.minMs
        let edges = cfg.doubles("age_edges", [1, 2, 3, 4, 6, 9, 12, 18, 24, 36, 48, 72]).map { Int($0) }
        self.edges = edges
        priorOn = cfg.doubles("prior_h_on", [])
        priorOff = cfg.doubles("prior_h_off", [])
        let top = (edges.last ?? 1) + 1
        // Ages start at 1 (`_bucket` is never asked for 0, whose index -1 numpy
        // would read as the last bucket); clamped so a bug cannot index out.
        bucketOfAge = (0...top).map { age in max(SimArrays.searchRight(edges, age) - 1, 0) }
    }

    func fit(_ history: ArenaHistory) throws { self.history = history }

    func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets where tr.target == .meterFiveHour {
            do {
                out[tr.key] = try fiveHour(tr, now: request.now)
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                // Never sink the whole request (the Python's `except Exception`).
                ctx.log("\(tr.key): fallback after \(error)")
                out[tr.key] = flat(tr)
            }
        }
        return ArenaForecast(byKey: out)
    }

    // MARK: - Helpers

    private var h: ArenaHistory {
        get throws {
            guard let history else { throw ArenaError.invalid("\(Self.name): forecast before fit") }
            return history
        }
    }

    /// One memo key per model and account: the derived tables depend on the
    /// history cut (the memo's owner), the account and this model's config.
    private func key(_ what: String, _ account: String) -> String { "\(ctx.name)|\(what)|\(account)" }

    private func flat(_ tr: ArenaTargetRequest) -> ArenaTargetForecast {
        let r = (try? cycleReadings(tr.account, resetAt: tr.resetAt, now: tr.grid[0] - 1)) ?? ([], [])
        let u0 = r.1.last ?? 0
        return Self.repeated(min(u0, 100), count: tr.grid.count, paths: tr.nPaths)
    }

    /// `TargetForecast.point(values, n_paths)`: one value, every path.
    static func repeated(_ v: Double, count: Int, paths: Int) -> ArenaTargetForecast {
        ArenaTargetForecast(paths: Array(repeating: Array(repeating: v, count: count), count: max(paths, 1)))
    }

    /// One account's five-hour readings known by now (`_readings` →
    /// `kspend.meter_series`, memoized on the cut by the kit).
    private func readings(_ account: String) throws -> KitSpend.MeterSeries {
        KitSpend.meterSeries(try h, account: account, windowKind: Self.window)
    }

    /// This cycle's readings known by now (`_cycle_readings`): the trailing
    /// run of active readings whose reset is within `reset_tol_min` of the
    /// latest one. The server's reset jitters by milliseconds; a jump of more
    /// than that is a new cycle even when the half-window rule would merge
    /// the two (an allowance re-based while the old window still runs).
    private func cycleReadings(_ account: String, resetAt: Millis?, now: Millis) throws -> ([Millis], [Double]) {
        let r = try readings(account)
        var t: [Millis] = [], p: [Double] = [], rs: [Millis] = []
        for i in r.t.indices where r.active[i] && r.t[i] <= now {
            if let resetAt, !(Double(abs(r.reset[i] - resetAt)) < Double(Self.windowMs) / 2) { continue }
            t.append(r.t[i]); p.append(r.p[i]); rs.append(r.reset[i])
        }
        guard let lastReset = rs.last else { return (t, p) }
        let tol = cfg.double("reset_tol_min", 15) * Double(Self.minMs)
        if let far = rs.lastIndex(where: { Double(abs($0 - lastReset)) >= tol }) {
            t = Array(t[(far + 1)...]); p = Array(p[(far + 1)...])
        }
        return (t, p)
    }

    @inline(__always) private func bucket(_ age: Int) -> Int {
        age < bucketOfAge.count ? bucketOfAge[max(age, 0)] : edges.count - 1
    }

    private var tzMs: Millis {
        guard let tz = history?.tzOffsetMin else { return 0 }
        return Millis(tz) * Self.minMs
    }

    // MARK: - Activity

    struct Activity {
        /// Turn times (ms, sorted): one per spend row (a family's 5-minute
        /// bucket), or the times the meter rose when there are too few turns.
        let te: [Millis]
        let proxy: Bool
    }

    /// `_activity`: the account's turn times, falling back to the times the
    /// meter rose when it has fewer than 20 turns. A spend row stands for
    /// its bucket's turns at the bucket's last `tEvent`; the 20-turn floor
    /// counts the turns it summed (`turns`), so it means what the arena's
    /// count of raw turns meant (equal on the fixtures, one turn per row).
    func activity(_ account: String) throws -> Activity {
        let h = try h
        return try h.memo.value(key("turns", account)) {
            let rows = h.spend(account: account)
            var te: [Millis] = []
            te.reserveCapacity(rows.count)
            var nTurns = 0
            for r in rows where r.tEvent <= h.now {
                te.append(r.tEvent)
                nTurns += max(r.turns, 1)
            }
            te.sort()
            var proxy = false
            if nTurns < 20 {
                let r = try readings(account)
                var extra: [Millis] = []
                if r.t.count >= 2 {
                    for i in 1..<r.t.count where r.p[i] - r.p[i - 1] > 0
                        && Double(abs(r.reset[i] - r.reset[i - 1])) < Double(Self.windowMs) / 2 {
                        extra.append(r.t[i])
                    }
                }
                if !extra.isEmpty { te = (te + extra).sorted() }
                proxy = true
            }
            return Activity(te: te, proxy: proxy)
        }
    }

    /// The account's activity bins (`("bins", account)` in the Python cache).
    struct Bins {
        let active: [Bool]
        /// Bins already spent in the current state at each bin (1-based).
        let age: [Int32]
        /// Local hour of each bin's start.
        let hod: [UInt8]
        /// `log(age + 0.5)`, for the analog search.
        let logAge: [Double]
        let origin: Millis
    }

    struct Hazards {
        let hOn: [Double]
        let hOff: [Double]
        let hodOn: [Double]
        let hodOff: [Double]
        let bins: Bins?
    }

    /// `_hazards`: per-bin hazards by age bucket (idle→active, active→idle)
    /// and their hour-of-day multipliers, from the account's activity bins
    /// over the whole history, blended with the prior pseudo-counts.
    func hazards(_ account: String, now: Millis) throws -> Hazards {
        let h = try h
        let tz = tzMs
        return try h.memo.value(key("hazards", account)) {
            let te = try activity(account).te
            let nbk = edges.count
            var exOn = [Double](repeating: 0, count: nbk), evOn = exOn
            var exOff = exOn, evOff = exOn
            var hodOn = [Double](repeating: 1, count: 24), hodOff = hodOn
            var bins: Bins?
            if te.count >= 2 {
                var origin = te[0] - SimRandom.pmod(te[0], bin)
                var nb = Int(SimRandom.floorDiv(now - origin, bin)) + 1
                if nb > 2_000_000 {          // absurdly long history: keep the last ~7 years of bins
                    origin = now - (2_000_000 - 1) * bin
                    nb = 2_000_000
                }
                var b = [Bool](repeating: false, count: nb)
                for t in te {
                    let k = SimRandom.floorDiv(t - origin, bin)
                    if k >= 0 && k < nb { b[Int(k)] = true }
                }
                var ageAll = [Int32](repeating: 0, count: nb)
                var s = 0
                while s < nb {
                    var e = s + 1
                    while e < nb && b[e] == b[s] { e += 1 }
                    let len = e - s
                    for a in 1...len {
                        ageAll[s + a - 1] = Int32(a)
                        if b[s] { exOff[bucket(a)] += 1 } else { exOn[bucket(a)] += 1 }
                    }
                    if e < nb {
                        if b[s] { evOff[bucket(len)] += 1 } else { evOn[bucket(len)] += 1 }
                    }
                    s = e
                }
                // Hour-of-day modulation of idle->active: transitions per idle bin by local hour.
                var hod = [UInt8](repeating: 0, count: nb)
                var nIdle = [Double](repeating: 0, count: 24), nTr = nIdle, nAct = nIdle, nOff = nIdle
                var sumIdle = 0.0, sumTr = 0.0, sumAct = 0.0, sumOff = 0.0
                for i in 0..<nb {
                    let hr = Int(SimRandom.pmod(origin + bin * Millis(i) + tz, Self.dayMs) / Self.hourMs)
                    hod[i] = UInt8(hr)
                    if b[i] {
                        nAct[hr] += 1; sumAct += 1
                        if i + 1 < nb && !b[i + 1] { nOff[hr] += 1; sumOff += 1 }
                    } else {
                        nIdle[hr] += 1; sumIdle += 1
                        if i + 1 < nb && b[i + 1] { nTr[hr] += 1; sumTr += 1 }
                    }
                }
                let shrink = cfg.double("hod_shrink_bins", 2000) / 24.0
                let base = sumTr / max(sumIdle, 1)
                if base > 0 {
                    hodOn = (0..<24).map { min(max((nTr[$0] + shrink * base) / (nIdle[$0] + shrink) / base, 0.2), 3.0) }
                }
                // ... and of active->idle: spells end sooner at night.
                let baseOff = sumOff / max(sumAct, 1)
                if baseOff > 0 && cfg.bool("hod_off", true) {
                    hodOff = (0..<24).map { min(max((nOff[$0] + shrink * baseOff) / (nAct[$0] + shrink) / baseOff, 0.33), 3.0) }
                }
                bins = Bins(active: b, age: ageAll, hod: hod, logAge: ageAll.map { log(Double($0) + 0.5) }, origin: origin)
            }
            let pw = cfg.double("prior_weight", 0.5) * 288.0
            var hOn = [Double](repeating: 0, count: nbk), hOff = hOn
            for k in 0..<nbk {
                let pxOn = pw * Self.priorExOnShare[k], pxOff = pw * Self.priorExOffShare[k]
                hOn[k] = min(max((evOn[k] + pxOn * priorOn[k]) / (exOn[k] + pxOn), 0.002), 0.95)
                hOff[k] = min(max((evOff[k] + pxOff * priorOff[k]) / (exOff[k] + pxOff), 0.01), 0.95)
            }
            return Hazards(hOn: hOn, hOff: hOff, hodOn: hodOn, hodOff: hodOff, bins: bins)
        }
    }

    /// `_analog_activity`: future activity for `n` paths copied from the
    /// account's own past: bins in the same state with a similar age and
    /// local hour whose following `nBins` bins are all known. Tolerances
    /// widen until `min_analogs` candidates exist; nil when even the widest
    /// fail. Returns the chosen start bins (the copy reads `bins[k + 1 ...]`).
    private func analogStarts(_ bins: Bins?, active0: Bool, age0: Int, hod0: Int, nBins: Int, n: Int,
                              rng: inout ArenaRNG) -> [Int]? {
        guard let bins else { return nil }
        let nb = bins.active.count
        let last = nb - 1 - nBins          // the last start whose whole future is known
        if last < 10 { return nil }
        let la0 = log(Double(age0) + 0.5)
        let minN = cfg.int("min_analogs", 20)
        var cand: [Int]?
        var dh = [UInt8](repeating: 0, count: last + 1)
        var nSame = 0
        for k in 0...last {
            let d = abs(Int(bins.hod[k]) - hod0)
            dh[k] = UInt8(min(d, 24 - d))
            if bins.active[k] == active0 { nSame += 1 }
        }
        for (ageTol, hodTol) in [(0.6, 2), (1.0, 3), (1.5, 5), (2.5, 8), (9.0, 12)] {
            var m: [Int] = []
            bins.active.withUnsafeBufferPointer { act in
                bins.logAge.withUnsafeBufferPointer { la in
                    for k in 0...last where act[k] == active0 && Int(dh[k]) <= hodTol && abs(la[k] - la0) <= ageTol {
                        m.append(k)
                    }
                }
            }
            if m.count >= minN { cand = m; break }
        }
        if cand == nil, nSame >= 5 {
            cand = (0...last).filter { bins.active[$0] == active0 }
        }
        guard let cand else { return nil }
        return (0..<n).map { _ in cand[SimRandom.uniformIndex(cand.count, rng: &rng)] }
    }

    // MARK: - Rates

    /// `_long_run_rate`: points per active bin over the history: the total
    /// within-cycle rise of the meter over the number of active bins in the
    /// span where readings exist.
    func longRunRate(_ account: String, now: Millis) throws -> Double? {
        let h = try h
        return try h.memo.value(key("lr_rate", account)) { SimBox(value: try computeLongRunRate(account, now: now)) }.value
    }

    private func computeLongRunRate(_ account: String, now: Millis) throws -> Double? {
            let r = try readings(account)
            let te = try activity(account).te
            var t: [Millis] = [], p: [Double] = [], rs: [Millis] = []
            for i in r.t.indices where r.active[i] && r.t[i] <= now {
                t.append(r.t[i]); p.append(r.p[i]); rs.append(r.reset[i])
            }
            guard t.count >= 2 else { return nil }
            var rise = 0.0
            var nRose = 0
            for i in 1..<t.count {
                let same = Double(abs(rs[i] - rs[i - 1])) < Double(Self.windowMs) / 2
                let inc = same ? max(p[i] - p[i - 1], 0) : p[i]
                rise += inc
                if inc > 0 { nRose += 1 }
            }
            let nAct: Int
            if !te.isEmpty {
                // Distinct bins of the turns within [t0, tN] (te is sorted).
                let lo = SimArrays.searchLeft(te, t[0]), hi = SimArrays.searchRight(te, t[t.count - 1])
                var n = 0
                var prev: Millis?
                for i in lo..<max(lo, hi) {
                    let k = SimRandom.floorDiv(te[i], bin)
                    if k != prev { n += 1; prev = k }
                }
                nAct = max(n, 1)
            } else {
                nAct = max(nRose, 1)
            }
            return rise / Double(nAct)
    }

    /// `_conversion`: points per USD per family (`arenaFamilies` order), or nil.
    private func conversion(_ account: String) throws -> [Double]? {
        let h = try h
        return h.memo.value(key("conv", account)) { () -> SimBox<[Double]?> in
            guard let d = KitSpend.fitDetails(h, account: account, windowKind: Self.window),
                  d.rates.allSatisfy(\.isFinite), d.rise >= 5 else { return SimBox(value: nil) }
            if d.conversion.weak && d.pooled > 0 { return SimBox(value: Array(repeating: d.pooled, count: d.rates.count)) }
            return SimBox(value: d.rates)
        }.value
    }

    /// `_spend_points`: the spend over (t0, t1] converted to points. The
    /// conversion is asked for only when there is spend to convert: the
    /// Python fits it up front, but nothing spent converts to 0 whatever the
    /// rates, and the fit (14 days of reading intervals) is most of a cold
    /// forecast's cost.
    private func spendPoints(_ account: String, _ t0: Millis, _ t1: Millis) throws -> Double {
        guard t1 > t0, cfg.bool("live_spend", true) else { return 0 }
        let sp = KitSpend.spentBetween(try h, account: account, t0, t1)
        guard sp.contains(where: { $0 != 0 }), let rates = try conversion(account) else { return 0 }
        var s = 0.0
        for i in 0..<min(sp.count, rates.count) { s += sp[i] * rates[i] }
        return s
    }

    // MARK: - The forecast

    private func fiveHour(_ tr: ArenaTargetRequest, now: Millis) throws -> ArenaTargetForecast {
        let acct = tr.account
        let grid = tr.grid
        let nPaths = max(tr.nPaths, 1)
        let reset = tr.resetAt ?? grid[grid.count - 1]
        var start = reset - Self.windowMs
        let (tC, uC) = try cycleReadings(acct, resetAt: tr.resetAt, now: now)
        let u0: Double, t0: Millis
        if let lastU = uC.last, let lastT = tC.last {
            u0 = lastU; t0 = lastT
            start = max(start, tC[0] - 2 * Self.minMs)
        } else {
            u0 = 0; t0 = start
        }
        if u0 >= 100 { return Self.repeated(100, count: grid.count, paths: nPaths) }

        let act = try activity(acct)
        let te = act.te
        let hz = try hazards(acct, now: now)

        // --- state now -------------------------------------------------
        let nNow = SimArrays.searchRight(te, now)          // te[..<nNow] are <= now
        let idleMs: Millis = nNow > 0 ? now - te[nNow - 1] : 10 * Self.dayMs
        let active0: Bool
        let age0: Int
        if idleMs < bin {
            active0 = true
            // The length of the current spell in bins aligned to end at now
            // (bin 0 is the current one): the leading run of bins holding a
            // turn. te is sorted, so walking back visits bins in order.
            var run = 0
            var i = nNow - 1
            while i >= 0 {
                let k = Int(SimRandom.floorDiv(now - te[i], bin))
                if k < run { i -= 1; continue }
                if k == run { run += 1; i -= 1; continue }
                break
            }
            age0 = max(run, 1)
        } else {
            active0 = false
            age0 = max(Int(idleMs / bin), 1)
        }

        // --- rates -----------------------------------------------------
        var lr = try longRunRate(acct, now: now) ?? 1.0
        let floorRate = cfg.double("rate_floor", 0.3)
        if !lr.isFinite || lr <= 0 { lr = 1.0 }
        lr = max(lr, floorRate)
        // The readings lag the spend: converted spend since the last reading.
        var livePts = t0 < now ? try spendPoints(acct, t0, now) : 0
        livePts = min(max(livePts, 0), 100 - u0)
        let kRec = cfg.double("k_recent", 3.0)
        let eps = 0.15

        /// Distinct bins of the turns after `w0` (and by now).
        func activeBins(after w0: Millis) -> Int {
            var n = 0
            var prev: Millis?
            var i = nNow - 1
            while i >= 0 && te[i] > w0 {
                let k = SimRandom.floorDiv(te[i], bin)
                if k != prev { n += 1; prev = k }
                i -= 1
            }
            return n
        }

        /// (points per active bin over the last `minutes`, weight, active bins) from the readings.
        func windowRate(_ minutes: Double) -> (Double, Double, Int) {
            let w0 = max(now - Millis(minutes) * Self.minMs, start)
            var uW0 = 0.0
            if !tC.isEmpty {
                let i = SimArrays.searchRight(tC, w0) - 1
                uW0 = i >= 0 ? uC[i] : 0
            }
            let b = max(u0 - uW0, 0) + livePts
            let n = activeBins(after: w0)
            if n == 0 { return (lr, 0, 0) }
            return (b / Double(n), Double(n) / (Double(n) + kRec), n)
        }

        let windows = cfg.doubles("recent_windows", [30, 90])
        let ests = windows.map(windowRate)
        let nActRec = ests.map(\.2).max() ?? 0
        let rRec = ests.map(\.0).reduce(0, +) / Double(max(ests.count, 1))
        // Whole-cycle rate so far.
        let nActCyc = activeBins(after: start)
        let burnCyc = u0 + livePts
        let rCyc = nActCyc > 0 ? burnCyc / Double(nActCyc) : lr
        var logs: [Double] = []
        for (rW, wW, _) in ests {
            let wC = nActCyc > 0 ? (1 - wW) * Double(nActCyc) / (Double(nActCyc) + 2 * kRec) : 0
            let wL = 1 - wW - wC
            logs.append(wW * log(rW + eps) + wC * log(rCyc + eps) + wL * log(lr + eps))
        }
        let logR = logs.reduce(0, +) / Double(max(logs.count, 1))
        let rHat = max(exp(logR) - eps, floorRate * 0.5) * cfg.double("rate_mult", 1.0)

        // --- simulate ----------------------------------------------------
        let nBins = max(Int((Double(grid[grid.count - 1] - now) / Double(bin)).rounded(.up)), 1)
        var rng = ctx.rng
        defer { ctx.rng = rng }
        var sigma = cfg.double("sigma_rate", 0.55)
        // The rate is less certain when it rests on few active bins of evidence.
        let sigN = cfg.double("sigma_n", 0)
        if sigN > 0 { sigma = (sigma * sigma + sigN * sigN / Double(max(nActRec, 1))).squareRoot() }
        let pReg = cfg.double("p_regime", 0.15)
        let shape = cfg.double("gamma_shape", 1.5)
        let tailP = cfg.double("tail_p", 0.1)
        let tailMult = cfg.double("tail_mult", 2.5)
        var rate = [Double](repeating: 0, count: nPaths)
        for i in 0..<nPaths {
            let regime = rng.uniform() < pReg
            rate[i] = (regime ? lr : rHat) * exp(sigma * rng.normal() - 0.5 * sigma * sigma)
        }
        // A burst regime (subagent fan-out, a heavier model): a share of paths run several times faster.
        for i in 0..<nPaths where rng.uniform() < tailP { rate[i] *= tailMult }
        for i in 0..<nPaths { rate[i] = max(rate[i], 0) }
        let tz = tzMs
        // Frailty: a persistent per-path factor on the hazards (busy futures
        // vs quiet ones); off in the shipped config.
        let fs = cfg.double("frailty_sd", 0)
        let frail: [Double] = fs > 0 ? (0..<nPaths).map { _ in exp(fs * rng.normal()) } : Array(repeating: 1, count: nPaths)

        // Activity: a share of the paths copy the account's own past
        // (analogs of the state now), the rest run the hazard chain.
        let share = cfg.double("analog_share", 0.7)
        var nAn = Int(SimRandom.pyRound(share * Double(nPaths)))
        let hod0 = Int(SimRandom.pmod(now + tz, Self.dayMs) / Self.hourMs)
        let starts = nAn > 0
            ? analogStarts(hz.bins, active0: active0, age0: age0, hod0: hod0, nBins: nBins, n: nAn, rng: &rng)
            : nil
        nAn = starts?.count ?? 0
        // frac[i * nBins + j]: the share of bin j path i burns in.
        var frac = [Double](repeating: 0, count: nPaths * nBins)
        if let starts, let bins = hz.bins {
            for (i, k) in starts.enumerated() {
                for j in 0..<nBins where bins.active[k + 1 + j] { frac[i * nBins + j] = 1 }
            }
        }
        // The hazard chain, for the paths not copied. (The Python steps the
        // chain for every path and keeps the rows after the analogs; only
        // the kept rows are simulated here, an equal distribution.)
        if nAn < nPaths {
            let nCh = nPaths - nAn
            var isActive = [Bool](repeating: active0, count: nCh)
            var age = [Int](repeating: age0, count: nCh)
            for j in 0..<nBins {
                let tBin = now + Millis(j) * bin
                let hod = Int(SimRandom.pmod(tBin + tz, Self.dayMs) / Self.hourMs)
                let mOn = hz.hodOn[hod], mOff = hz.hodOff[hod]
                for c in 0..<nCh {
                    let i = nAn + c
                    let bk = bucket(age[c])
                    let u = rng.uniform()
                    let sw: Bool
                    if isActive[c] {
                        sw = u < min(hz.hOff[bk] * mOff / frail[i], 0.95)
                        // A bin that stays active burns fully, one that switches burns half.
                        frac[i * nBins + j] = sw ? 0.5 : 1.0
                    } else {
                        sw = u < min(hz.hOn[bk] * mOn * frail[i], 0.95)
                        frac[i * nBins + j] = sw ? 0.5 : 0.0
                    }
                    if sw { age[c] = 1; isActive[c].toggle() } else { age[c] += 1 }
                }
            }
        }
        // Burn: cumulative, per path, from bin 0 (the Python draws the gamma
        // noise for every bin; an idle bin multiplies it by 0, so only the
        // burning bins draw here).
        var burn = [Double](repeating: 0, count: nPaths * (nBins + 1))
        for i in 0..<nPaths {
            var c = 0.0
            let r = rate[i]
            for j in 0..<nBins {
                let f = frac[i * nBins + j]
                if f > 0 { c += f * r * SimRandom.gamma(shape, scale: 1 / shape, rng: &rng) }
                burn[i * (nBins + 1) + j + 1] = c
            }
        }
        // --- to the grid ---------------------------------------------------
        let binD = Double(bin)
        let tRel = (0...nBins).map { Double($0) * binD }
        let gIdx: [Int] = grid.map { g in
            min(max(SimArrays.searchRight(tRel, Double(g - now)) - 1, 0), nBins - 1)
        }
        let gW: [Double] = grid.indices.map { j in (Double(grid[j] - now) - tRel[gIdx[j]]) / binD }
        var paths = [[Double]]()
        paths.reserveCapacity(nPaths)
        for i in 0..<nPaths {
            let offset = rng.uniform()          // sub-point position of the true meter
            let row = i * (nBins + 1)
            var path = [Double](repeating: 0, count: grid.count)
            for j in grid.indices {
                let at = burn[row + gIdx[j]] * (1 - gW[j]) + burn[row + gIdx[j] + 1] * gW[j]
                path[j] = (u0 + offset + livePts + at + 1e-9).rounded(.down)
            }
            SimArrays.clipRunningMax(&path, lo: u0, hi: 100)
            paths.append(path)
        }
        lastDiag = ["u0": u0, "live": livePts, "act": active0 ? 1 : 0, "age": Double(age0), "r_hat": rHat,
                    "r_rec": rRec, "r_cyc": rCyc, "lr": lr, "n_rec": Double(nActRec), "proxy": act.proxy ? 1 : 0,
                    "lead_h": Double(grid[grid.count - 1] - now) / Double(Self.hourMs), "n_an": Double(nAn)]
        return ArenaTargetForecast(paths: paths)
    }
}
