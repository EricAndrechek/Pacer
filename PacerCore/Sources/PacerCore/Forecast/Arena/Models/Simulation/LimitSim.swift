import Foundation

/// `research/arena/models/g2-07-opus-limit/limitsim.py`: a level-aware
/// block-bootstrap simulation of a rate-limit meter to its reset.
///
/// It answers the limit call: will the meter reach 100 before it resets, and
/// when. Three things decide it, each learned from the account's own recent
/// readings (recency-weighted, shrunk to priors):
///
/// 1. **Burn.** The meter's own past burn on a regular step grid (hourly for
///    the weekly meters, 5 min for the five-hour one), from the cumulative
///    series that ignores re-bases and cycle resets (`kit.fm.series`).
///    Future steps are copied from the past in blocks (stationary bootstrap,
///    geometric block lengths) that start at the same local time of day;
///    the first block starts where the recent burn looks like now's. Steps
///    parked near the top or blocked at 100 are replaced by unconstrained
///    steps at the same time of day.
/// 2. **Behaviour near the limit.** Where the user stops short of 100: a
///    ceiling per path, drawn from the account's completed cycles (how high
///    each got, whether it parked there), and a leak per hour off a parked
///    ceiling.
/// 3. **Re-bases.** A per-step hazard from the history's own falls drops a
///    path to 0, after which it burns on.
///
/// Paths are integer meter values on the step grid, read at the request's
/// grid by linear interpolation. Names and order follow the Python.
enum LimitSim {
    static let minute: Millis = 60_000
    static let hour: Millis = 60 * minute
    static let day: Millis = 24 * hour

    static func windowMs(_ kind: String) -> Millis { kind == "five_hour" ? 5 * hour : 7 * day }

    /// `DEFAULTS`: per window kind. `model.toml`'s `[config]` is empty, so
    /// these are the model's settings.
    struct Config {
        var stepMin: Int
        var lookbackDays: Double
        var halfLifeDays: Double
        var blockMean: Double
        var lags: [Int]
        var bw: Double
        var bands: [Double]
        var parkFrom: Double
        var priorHours: Double
        var rebasePrior: Double
        var rebaseWeeksPrior: Double
        var minHistSteps: Int
        var intensitySigma: Double
        var zoneLo: Double
        var parkFrac: Double
        var ceilHalfLifeDays: Double
        var ceilPriorW100: Double
        var priorPark: [(Int, Double)]
        var leakPrior: Double
        var leakPriorHours: Double
        var lateH: Double
        var leakLatePrior: Double
        var leakLatePriorHours: Double
        var delayMinStayH: Double
        // Keys `meters.py` reads with a default that `DEFAULTS` does not set.
        var otherAccountWeight = 0.5
        var useCeilings = true
        var borrowScale = 0.5
        var delayTailMult = 0.5
        var coupleWeekly = true
        var recentAlpha = 0.0
        var recentHours = 72.0
        var recentMin = 0.15
        var recentMax = 3.0

        static let priorPark: [(Int, Double)] = [(95, 0.1), (97, 0.1), (99, 0.3)]

        static func defaults(_ kind: String) -> Config {
            switch kind {
            case "five_hour":
                Config(stepMin: 5, lookbackDays: 45, halfLifeDays: 14, blockMean: 18, lags: [1, 3, 12], bw: 0.6,
                       bands: [90, 95, 99], parkFrom: 101, priorHours: 2, rebasePrior: 0, rebaseWeeksPrior: 4,
                       minHistSteps: 36, intensitySigma: 0.4, zoneLo: 90, parkFrac: 0.12, ceilHalfLifeDays: 28,
                       ceilPriorW100: 0.5, priorPark: priorPark, leakPrior: 0.005, leakPriorHours: 48, lateH: 24,
                       leakLatePrior: 0.02, leakLatePriorHours: 24, delayMinStayH: 12)
            case "weekly_scoped":
                Config(stepMin: 60, lookbackDays: 60, halfLifeDays: 28, blockMean: 36, lags: [1, 3, 24], bw: 0.6,
                       bands: [90, 95, 99], parkFrom: 95, priorHours: 2, rebasePrior: 0.1, rebaseWeeksPrior: 4,
                       minHistSteps: 12, intensitySigma: 1.6, zoneLo: 90, parkFrac: 0.12, ceilHalfLifeDays: 28,
                       ceilPriorW100: 0.5, priorPark: priorPark, leakPrior: 0.005, leakPriorHours: 48, lateH: 24,
                       leakLatePrior: 0.02, leakLatePriorHours: 24, delayMinStayH: 12)
            default:          // seven_day
                Config(stepMin: 60, lookbackDays: 60, halfLifeDays: 28, blockMean: 36, lags: [1, 3, 24], bw: 0.6,
                       bands: [90, 95, 99], parkFrom: 95, priorHours: 2, rebasePrior: 0.1, rebaseWeeksPrior: 4,
                       minHistSteps: 12, intensitySigma: 1.2, zoneLo: 90, parkFrac: 0.12, ceilHalfLifeDays: 28,
                       ceilPriorW100: 0.5, priorPark: priorPark, leakPrior: 0.005, leakPriorHours: 48, lateH: 24,
                       leakLatePrior: 0.02, leakLatePriorHours: 24, delayMinStayH: 12)
            }
        }

        /// `meters._cfg`: the defaults, updated by `[config.<kind>]`.
        static func resolved(_ kind: String, _ cfg: ArenaConfig) -> Config {
            var c = defaults(kind)
            let t = cfg.table(kind)
            if t.values.isEmpty { return c }
            c.stepMin = t.int("step_min", c.stepMin)
            c.lookbackDays = t.double("lookback_days", c.lookbackDays)
            c.halfLifeDays = t.double("half_life_days", c.halfLifeDays)
            c.blockMean = t.double("block_mean", c.blockMean)
            c.lags = t.doubles("lags", c.lags.map(Double.init)).map { Int($0) }
            c.bw = t.double("bw", c.bw)
            c.bands = t.doubles("bands", c.bands)
            c.parkFrom = t.double("park_from", c.parkFrom)
            c.priorHours = t.double("prior_hours", c.priorHours)
            c.rebasePrior = t.double("rebase_prior", c.rebasePrior)
            c.rebaseWeeksPrior = t.double("rebase_weeks_prior", c.rebaseWeeksPrior)
            c.minHistSteps = t.int("min_hist_steps", c.minHistSteps)
            c.intensitySigma = t.double("intensity_sigma", c.intensitySigma)
            c.zoneLo = t.double("zone_lo", c.zoneLo)
            c.parkFrac = t.double("park_frac", c.parkFrac)
            c.ceilHalfLifeDays = t.double("ceil_half_life_days", c.ceilHalfLifeDays)
            c.ceilPriorW100 = t.double("ceil_prior_w100", c.ceilPriorW100)
            let pp = t.table("prior_park")
            if !pp.values.isEmpty {
                c.priorPark = pp.values.compactMap { k, v in Int(k).flatMap { kk in v.double.map { (kk, $0) } } }
                    .sorted { $0.0 < $1.0 }
            }
            c.leakPrior = t.double("leak_prior", c.leakPrior)
            c.leakPriorHours = t.double("leak_prior_hours", c.leakPriorHours)
            c.lateH = t.double("late_h", c.lateH)
            c.leakLatePrior = t.double("leak_late_prior", c.leakLatePrior)
            c.leakLatePriorHours = t.double("leak_late_prior_hours", c.leakLatePriorHours)
            c.delayMinStayH = t.double("delay_min_stay_h", c.delayMinStayH)
            c.otherAccountWeight = t.double("other_account_weight", c.otherAccountWeight)
            c.useCeilings = t.bool("use_ceilings", c.useCeilings)
            c.borrowScale = t.double("borrow_scale", c.borrowScale)
            c.delayTailMult = t.double("delay_tail_mult", c.delayTailMult)
            c.coupleWeekly = t.bool("couple_weekly", c.coupleWeekly)
            c.recentAlpha = t.double("recent_alpha", c.recentAlpha)
            c.recentHours = t.double("recent_hours", c.recentHours)
            c.recentMin = t.double("recent_min", c.recentMin)
            c.recentMax = t.double("recent_max", c.recentMax)
            return c
        }
    }

    /// One meter on a regular step grid ending at now (oldest first).
    struct StepHist {
        var tEnd: [Millis]
        /// Burn within the step (>= 0).
        var burn: [Double]
        /// The meter as read at the step's start (0 when idle).
        var level: [Double]
        /// Local step-of-day of the step end.
        var tod: [Int]
        /// now - tEnd, in days.
        var ageDays: [Double]
        /// A reading within the step or just before it.
        var covered: [Bool]

        var count: Int { burn.count }
        var burnSum: Double { burn.reduce(0, +) }
    }

    /// `step_history`.
    static func stepHistory(times: [Millis], cum: [Double], util: [Double], active: [Bool], now: Millis,
                            step: Millis, lookback: Millis, tzMs: Millis, stale: Millis) -> StepHist {
        let n = Int(lookback / step)
        let spd = Int(day / step)
        // Edges oldest first; `i` is the last reading at or before each (a merge walk, the edges ascend).
        var ok = [Bool](repeating: false, count: n + 1)
        var c = [Double](repeating: 0, count: n + 1)
        var lv = [Double](repeating: 0, count: n + 1)
        var fresh = [Bool](repeating: false, count: n + 1)
        var edge = [Millis](repeating: 0, count: n + 1)
        var i = -1
        for k in 0...n {
            let t = now - step * Millis(n - k)
            edge[k] = t
            while i + 1 < times.count && times[i + 1] <= t { i += 1 }
            if i >= 0 {
                ok[k] = true
                c[k] = cum[i]
                lv[k] = active[i] ? util[i] : 0
                fresh[k] = t - times[i] <= stale
            }
        }
        var h = StepHist(tEnd: [], burn: [], level: [], tod: [], ageDays: [], covered: [])
        h.tEnd.reserveCapacity(n); h.burn.reserveCapacity(n); h.level.reserveCapacity(n)
        h.tod.reserveCapacity(n); h.ageDays.reserveCapacity(n); h.covered.reserveCapacity(n)
        for k in 0..<n where ok[k] {          // the step's start is known
            let te = edge[k + 1]
            h.tEnd.append(te)
            h.burn.append(max(c[k + 1] - c[k], 0))
            h.level.append(lv[k])
            h.tod.append(Int(SimRandom.pmod(te + tzMs, day) / step) % spd)
            h.ageDays.append(Double(now - te) / Double(day))
            h.covered.append(fresh[k + 1] || fresh[k])
        }
        return h
    }

    @inline(__always) static func recency(_ ageDays: Double, _ halfLife: Double) -> Double {
        pow(0.5, max(ageDays, 0) / max(halfLife, 1e-6))
    }

    /// 0 = below the first band edge, k = in [bands[k-1], bands[k]), bands.count + 1 = at 100.
    @inline(__always) static func bandIndex(_ level: Double, _ bands: [Double]) -> Int {
        level >= 100 ? bands.count + 1 : SimArrays.searchRight(bands, level)
    }

    struct Behaviour {
        /// Per band (0...bands.count): the chance an active step stays active.
        var keep: [Double]
        var rebasePerStep: Double
        var rebaseTo: Double
    }

    /// `learn_behaviour`: pool the given meters' histories (each with a
    /// weight: the account's own 1, others less) into per-band keep
    /// probabilities and a re-base hazard.
    static func learnBehaviour(_ hists: [(StepHist, Double)], bands: [Double], halfLife: Double, priorHours: Double,
                               step: Millis, rebasePriorPerWeek: Double, rebaseWeeksPrior: Double,
                               falls: [[Millis]]) -> Behaviour {
        let nb = bands.count + 1
        var act = [Double](repeating: 0, count: nb + 1)
        var wsum = act
        for (h, wt) in hists where h.count > 0 {
            for k in 0..<h.count {
                let w = recency(h.ageDays[k], halfLife) * wt * (h.covered[k] ? 1 : 0)
                let b = bandIndex(h.level[k], bands)
                guard b <= nb else { continue }
                if h.burn[k] > 0 { act[b] += w }
                wsum[b] += w
            }
        }
        let base = wsum[0] > 0 ? act[0] / wsum[0] : 0
        var keep = [Double](repeating: 1, count: nb)
        let hoursPerStep = Double(step) / Double(hour)
        if base > 0 {
            for k in 1..<nb {
                // Pseudo-observations at the unconstrained rate (keep = 1).
                let pw = priorHours / hoursPerStep
                let rate = (act[k] + pw * base) / (wsum[k] + pw)
                keep[k] = min(max(rate / base, 0), 1)
            }
        }
        // Re-base hazard: falls per week of observed meter, recency-weighted.
        var nFall = 0.0, weeks = 0.0
        for ((h, wt), ft) in zip(hists, falls) where h.count > 0 {
            var ws = 0.0
            for a in h.ageDays { ws += recency(a, halfLife) * wt }
            weeks += ws * Double(step) / Double(7 * day)
            let last = h.tEnd[h.count - 1]
            for t in ft { nFall += recency(Double(last - t) / Double(day), halfLife) * wt }
        }
        let perWeek = (nFall + rebasePriorPerWeek * rebaseWeeksPrior) / (weeks + rebaseWeeksPrior)
        let perStep = 1 - exp(-perWeek * Double(step) / Double(7 * day))
        return Behaviour(keep: keep, rebasePerStep: perStep, rebaseTo: 0)
    }

    /// `find_falls`: re-bases, a reading at least `minDrop` below the
    /// previous one of the same cycle (same reset within half a window).
    /// Only the times are used.
    static func findFalls(times: [Millis], util: [Double], active: [Bool], reset: [Millis], duration: Millis,
                          minDrop: Double = 10) -> [Millis] {
        guard times.count >= 2 else { return [] }
        var out: [Millis] = []
        for i in 1..<times.count where active[i] && active[i - 1]
            && Double(abs(reset[i] - reset[i - 1])) < Double(duration) / 2 && util[i - 1] - util[i] >= minDrop {
            out.append(times[i])
        }
        return out
    }

    /// What `simulate` builds from the history before its first draw: the
    /// candidate pools per step of day and the first block's weights. A pure
    /// function of the history, the meter now and the config, so a memo on
    /// the history cut can keep it.
    struct Prepared {
        let n: Int
        let free: [Bool]
        let jump: [SimDiscrete]            // per tod, over `jumpIdx`
        let jumpIdx: [[Int]]
        let freePool: [SimDiscrete]
        let freeIdx: [[Int]]
        let first: SimDiscrete
        let firstIdx: [Int]
    }

    static func prepare(_ h: StepHist, firstTod: Int, step: Millis, cfg: Config) -> Prepared {
        let n = h.count
        let spd = Int(day / step)
        let wRec = h.ageDays.map { recency($0, cfg.halfLifeDays) }
        let free = (0..<n).map { h.level[$0] < min(cfg.parkFrom, 100) && h.level[$0] < 100 }
        var pools = [[Int]](repeating: [], count: spd)
        var freeIdx = [[Int]](repeating: [], count: spd)
        for k in 0..<n {
            pools[h.tod[k]].append(k)
            if free[k] { freeIdx[h.tod[k]].append(k) }
        }
        let all = Array(0..<n)
        var freePool: [SimDiscrete] = []
        var jump: [SimDiscrete] = []
        var jumpIdx: [[Int]] = []
        for d in 0..<spd {
            if freeIdx[d].isEmpty { freeIdx[d] = pools[d].isEmpty ? all : pools[d] }
            freePool.append(SimDiscrete(weights: freeIdx[d].map { wRec[$0] }))
            let ji = pools[d].isEmpty ? all : pools[d]
            jumpIdx.append(ji)
            jump.append(SimDiscrete(weights: ji.map { wRec[$0] }))
        }
        // Similarity of the state before each candidate start to now's.
        let lags = cfg.lags
        let maxLag = lags.max() ?? 1
        var csum = [Double](repeating: 0, count: n + 1)
        for k in 0..<n { csum[k + 1] = csum[k] + h.burn[k] }
        func recent(_ kEnd: Int, _ lag: Int) -> Double { csum[kEnd] - csum[max(kEnd - lag, 0)] }
        let nowFeat = lags.map { recent(n, $0) }
        var firstIdx = pools[firstTod].filter { $0 >= maxLag }
        if firstIdx.isEmpty { firstIdx = pools[firstTod].isEmpty ? all : pools[firstTod] }
        let bw2 = cfg.bw * cfg.bw
        var wFirst = firstIdx.map { k -> Double in
            var d2 = 0.0
            for (li, lag) in lags.enumerated() {
                let d = log1p(recent(k, lag)) - log1p(nowFeat[li])
                d2 += d * d
            }
            return wRec[k] * exp(-0.5 * d2 / bw2)
        }
        let s = wFirst.reduce(0, +)
        if !wFirst.allSatisfy(\.isFinite) || !(s > 0) { wFirst = firstIdx.map { wRec[$0] } }
        return Prepared(n: n, free: free, jump: jump, jumpIdx: jumpIdx, freePool: freePool, freeIdx: freeIdx,
                        first: SimDiscrete(weights: wFirst), firstIdx: firstIdx)
    }

    /// `simulate`: paths on the step grid, times `[H + 1]` (now first) and
    /// values `[nPaths][H + 1]`.
    static func simulate(_ h: StepHist, prepared: () -> Prepared, beh: Behaviour, u0: Double, now: Millis,
                         reset: Millis, step: Millis, tzMs: Millis, nPaths: Int, rng: inout ArenaRNG, cfg: Config,
                         ceil ceilIn: [Double]?, leakPerStep: [Double], delay: [Int]?) -> (times: [Millis], vals: [[Double]]) {
        let H = max(1, Int((Double(reset - now) / Double(step)).rounded(.up)))
        let times = (0...H).map { now + step * Millis($0) }
        if u0 >= 100 {
            return (times, Array(repeating: Array(repeating: 100, count: H + 1), count: nPaths))
        }
        let n = h.count
        if n < 2 || h.burnSum <= 0 {
            return (times, Array(repeating: Array(repeating: u0, count: H + 1), count: nPaths))
        }
        let spd = Int(day / step)
        let p = prepared()
        let pJump = 1 / max(cfg.blockMean, 1)
        let keep = beh.keep
        let nb = keep.count
        var ptr = (0..<nPaths).map { _ in p.firstIdx[p.first.draw(&rng)] }
        var u = [Double](repeating: u0, count: nPaths)
        let sig = cfg.intensitySigma
        var fac: [Double]? = sig > 0 ? (0..<nPaths).map { _ in exp(sig * rng.normal() - 0.5 * sig * sig) } : nil
        // Nowcast of how busy this account is (off in every shipped config).
        if cfg.recentAlpha > 0 {
            let lRec = max(1, Int(cfg.recentHours * Double(hour) / Double(step)))
            if n > lRec {
                let recentRate = h.burn[(n - lRec)...].reduce(0, +) / Double(lRec)
                var num = 0.0, den = 0.0
                for k in 0..<n where p.free[k] {
                    let w = recency(h.ageDays[k], cfg.halfLifeDays)
                    num += h.burn[k] * w; den += w
                }
                let baseRate = num / max(den, 1e-9)
                if baseRate > 0 {
                    let ratio = (recentRate + 0.1 * baseRate) / (1.1 * baseRate)
                    let sc = min(max(pow(ratio, cfg.recentAlpha), cfg.recentMin), cfg.recentMax)
                    fac = (fac ?? Array(repeating: 1, count: nPaths)).map { $0 * sc }
                }
            }
        }
        var ceil = ceilIn
        var carry = [Double](repeating: 0, count: nPaths)
        var out = [[Double]](repeating: [Double](repeating: u0, count: H + 1), count: nPaths)
        for j in 0..<H {
            let d = Int(SimRandom.pmod(times[j + 1] + tzMs, day) / step) % spd
            let lps = ceil != nil && j < leakPerStep.count ? leakPerStep[j] : 0
            for i in 0..<nPaths {
                if j > 0 {
                    var nxt = ptr[i] + 1
                    var jm = rng.uniform() < pJump || nxt >= n || h.tod[min(nxt, n - 1)] != d
                    if let delay, delay[i] == j { jm = true }          // resuming after the idle stretch: a fresh block
                    if jm { nxt = p.jumpIdx[d][p.jump[d].draw(&rng)] }
                    ptr[i] = nxt
                }
                var b = h.burn[ptr[i]]
                if let delay, delay[i] > j { b = 0 }
                // A step parked near the top says how the user behaves there,
                // not how much they use the account: an unconstrained step at
                // the same time of day instead. (As in the Python this runs
                // after the delay's zero, so a parked step can still burn
                // during a delay; kept for parity.)
                if !p.free[ptr[i]] { b = h.burn[p.freeIdx[d][p.freePool[d].draw(&rng)]] }
                if let f = fac {
                    // A path-level intensity, applied to whole points with the remainder carried.
                    let x = b * f[i] + carry[i]
                    b = x.rounded(.down)
                    carry[i] = x - b
                }
                // Behaviour near the limit.
                let band = min(bandIndex(u[i], cfg.bands), nb - 1)
                if b > 0 && rng.uniform() >= keep[band] { b = 0 }
                // Re-base.
                if beh.rebasePerStep > 0 && rng.uniform() < beh.rebasePerStep { u[i] = beh.rebaseTo }
                if ceil != nil {
                    if lps > 0 && ceil![i] < 100 && u[i] >= ceil![i] && rng.uniform() < lps { ceil![i] = 100 }
                    u[i] = min(u[i] + b, max(ceil![i], u[i]))
                    u[i] = min(u[i], 100)
                } else {
                    u[i] = min(u[i] + b, 100)
                }
                out[i][j + 1] = u[i]
            }
        }
        return (times, out)
    }

    /// `to_grid`: linear interpolation of every path at the grid times.
    static func toGrid(times: [Millis], vals: [[Double]], grid: [Millis]) -> [[Double]] {
        let t = times.map(Double.init)
        let idx = grid.map { g in min(max(SimArrays.searchRight(t, Double(g)) - 1, 0), t.count - 2) }
        let w = grid.indices.map { j in min(max((Double(grid[j]) - t[idx[j]]) / (t[idx[j] + 1] - t[idx[j]]), 0), 1) }
        return vals.map { v in grid.indices.map { j in v[idx[j]] * (1 - w[j]) + v[idx[j] + 1] * w[j] } }
    }

    // MARK: - Ceilings: where a user stops short of the limit

    struct CycleTop {
        /// When the cycle's top was reached (for recency).
        var tRef: Millis
        /// The highest reading of the cycle.
        var top: Double
        /// True: the user stopped there (or reached 100); false: censored.
        var observed: Bool
        /// Hours spent at the top with time still left (parked).
        var parkedHours: Double
        /// Parked first, then went on to 100.
        var leaked: Bool
        var parkStart: Millis = 0
        var parkEnd: Millis = 0
        var reset: Millis = 0
    }

    /// `cycle_tops`: per completed cycle of one meter (known at now), its top
    /// and whether the user stopped there by choice.
    static func cycleTops(times: [Millis], util: [Double], active: [Bool], reset: [Millis], duration: Millis,
                          now: Millis, zoneLo: Double, parkMin: Millis) -> [CycleTop] {
        var t: [Millis] = [], u: [Double] = [], r: [Millis] = []
        for i in times.indices where active[i] && reset[i] > 0 { t.append(times[i]); u.append(util[i]); r.append(reset[i]) }
        guard !t.isEmpty else { return [] }
        // Cycles by reset (half a window apart), anchored at each cycle's first
        // reset in reset order (the Python's stable argsort, then a walk). A
        // cycle is a run of the sorted resets from its anchor to the next, so
        // a reading's cycle depends on its reset alone: sort the resets once
        // (the server's jitter means they are never in order), find the
        // anchors, and place each reading by binary search, in time order.
        let rsAll = r.sorted()
        var anchors = [rsAll[0]]
        var firstOf = [0]                         // each cycle's first index in rsAll
        for j in 1..<rsAll.count where Double(rsAll[j] - anchors[anchors.count - 1]) >= Double(duration) / 2 {
            anchors.append(rsAll[j]); firstOf.append(j)
        }
        firstOf.append(rsAll.count)
        var members = [[Int]](repeating: [], count: anchors.count)
        for i in r.indices { members[SimArrays.searchRight(anchors, r[i]) - 1].append(i) }   // in time order
        var out: [CycleTop] = []
        for (k, sel) in members.enumerated() {
            // `sel` is in index order, and the series is in event order, so
            // this stable argsort by time is the identity unless it is not.
            let sorted = zip(sel, sel.dropFirst()).allSatisfy { t[$0] <= t[$1] }
            let ord = sorted ? sel : sel.sorted { (t[$0], $0) < (t[$1], $1) }
            let tk = ord.map { t[$0] }, uk = ord.map { u[$0] }
            // `int(np.median(resets))`: the truncated median, kept for parity.
            let rs = rsAll[firstOf[k]..<firstOf[k + 1]]
            let m = rs.startIndex + rs.count / 2
            let R = rs.count % 2 == 1 ? rs[m] : Millis((Double(rs[m - 1]) + Double(rs[m])) / 2)
            if R > now { continue }                   // the cycle in progress: not a past outcome
            let top = uk.max() ?? 0
            if top >= 100 {
                let i100 = uk.firstIndex { $0 >= 100 } ?? 0
                // Parked at 99 (or just below) for long before going over?
                var ph = 0.0
                var i99: Int?
                if i100 > 0 { i99 = uk[..<i100].firstIndex { $0 >= 99 } }
                if let i99 { ph = Double(tk[i100] - tk[i99]) / Double(hour) }
                let leaked = ph * Double(hour) >= Double(parkMin)
                let ps = leaked ? tk[i99 ?? 0] : 0
                out.append(CycleTop(tRef: tk[i100], top: 100, observed: true, parkedHours: ph, leaked: leaked,
                                    parkStart: ps, parkEnd: leaked ? tk[i100] : 0, reset: R))
                continue
            }
            let i0 = uk.firstIndex { $0 >= top - 1 } ?? 0
            let ph = Double(R - tk[i0]) / Double(hour)
            let parked = top >= zoneLo && R - tk[i0] >= parkMin
            out.append(CycleTop(tRef: tk[i0], top: top, observed: parked, parkedHours: parked ? ph : 0, leaked: false,
                                parkStart: parked ? tk[i0] : 0, parkEnd: parked ? R : 0, reset: R))
        }
        return out
    }

    struct Ceilings {
        /// Candidate ceilings (ints, the last is 100).
        var levels: [Int]
        /// P(C = level | C >= level), per level (100: 1).
        var hazard: [Double]
        var leakPerHour: Double
        var leakLatePerHour: Double = 0
        var lateH: Double = 0
    }

    /// `learn_ceilings`.
    static func learnCeilings(_ tops: [(CycleTop, Double)], now: Millis, halfLifeDays: Double, zoneLo: Double,
                              priorW100: Double, leakPrior: Double, leakPriorHours: Double,
                              priorPark: [(Int, Double)], lateH: Double, leakLatePrior: Double,
                              leakLatePriorHours: Double) -> Ceilings {
        let lo = Int(zoneLo)
        let levels = Array(lo...100)
        var d = [Double](repeating: 0, count: levels.count)
        var n = d
        var leaks = 0.0, ph = 0.0, lateLeaks = 0.0, latePh = 0.0
        for (ct, wt) in tops {
            let w = wt * recency(Double(now - ct.tRef) / Double(day), halfLifeDays)
            let top = Int(SimRandom.pyRound(ct.top))
            if top < lo { continue }                  // never got near: says nothing about the ceiling
            for k in levels.indices where levels[k] <= top { n[k] += w }
            if ct.observed, let k = levels.firstIndex(of: top) { d[k] += w }
            if ct.parkedHours > 0 && lateH > 0 && ct.parkEnd > ct.parkStart {
                // Exposure split at `lateH` before the reset.
                let edge = Double(ct.reset) - lateH * Double(hour)
                let early = max(0, min(Double(ct.parkEnd), edge) - Double(ct.parkStart)) / Double(hour)
                let late = max(0, Double(ct.parkEnd) - max(Double(ct.parkStart), edge)) / Double(hour)
                ph += w * early
                latePh += w * late
                if ct.leaked {
                    if Double(ct.parkEnd) > edge { lateLeaks += w } else { leaks += w }
                }
            } else if ct.parkedHours > 0 {
                ph += w * ct.parkedHours
                if ct.leaked { leaks += w }
            }
        }
        d[d.count - 1] += priorW100
        for k in n.indices { n[k] += priorW100 }
        // Prior pseudo-cycles that parked at a few high levels: users of a
        // pacing app often stop short of the wall, and the time a meter has
        // already sat still near the top can only update a prior that allows it.
        for (lvl, w) in priorPark where lvl >= lo && lvl < 100 {
            for k in levels.indices where levels[k] <= lvl { n[k] += w }
            if let k = levels.firstIndex(of: lvl) { d[k] += w }
        }
        var hz = levels.indices.map { n[$0] > 0 ? d[$0] / n[$0] : 0 }
        hz[hz.count - 1] = 1
        let leak = (leaks + leakPrior * leakPriorHours) / (ph + leakPriorHours)
        let late = lateH > 0 ? (lateLeaks + leakLatePrior * leakLatePriorHours) / (latePh + leakLatePriorHours) : leak
        return Ceilings(levels: levels, hazard: hz, leakPerHour: leak, leakLatePerHour: late, lateH: lateH)
    }

    /// `zero_burn_survival`: the chance ordinary use leaves the meter
    /// unmoved for `hours`: the recency-weighted share of past windows that
    /// long with no burn.
    static func zeroBurnSurvival(_ h: StepHist, hours: Double, step: Millis, halfLife: Double, free: [Bool]) -> Double {
        let L = max(1, Int(SimRandom.pyRound(hours * Double(hour) / Double(step))))
        let n = h.count
        if n <= L { return 0 }
        var cs = [Double](repeating: 0, count: n + 1)
        var cf = [Int](repeating: 0, count: n + 1)
        for k in 0..<n { cs[k + 1] = cs[k] + h.burn[k]; cf[k + 1] = cf[k] + (free[k] ? 1 : 0) }
        var num = 0.0, den = 0.0
        for j in 0...(n - L) {            // windows [j, j + L)
            guard cf[j + L] - cf[j] >= L else { continue }
            let w = recency(h.ageDays[j + L - 1], halfLife)
            den += w
            if cs[j + L] - cs[j] <= 0 { num += w }
        }
        return den > 0 ? num / den : 0
    }

    /// `ceiling_posterior`: P(C = level | C >= u now, the meter has sat at u
    /// for `stayHours`), over levels >= u.
    static func ceilingPosterior(_ ce: Ceilings, uNow: Double, stayHours: Double,
                                 surv: (Double) -> Double) -> (levels: [Int], probs: [Double]) {
        let u = Int(SimRandom.pyRound(uNow))
        let m = ce.levels.indices.filter { ce.levels[$0] >= u }
        let lv = m.map { ce.levels[$0] }, hz = m.map { ce.hazard[$0] }
        if lv.isEmpty { return ([100], [1]) }
        var p = [Double](repeating: 0, count: lv.count)
        var s = 1.0
        for i in lv.indices { p[i] = s * hz[i]; s *= 1 - hz[i] }
        p[p.count - 1] += s
        if stayHours > 0 && lv[0] == u && u < 100 {
            // Ceilings above now would have moved the meter by now (unless the
            // user simply hasn't used it): weigh them by that chance.
            let k = surv(stayHours)
            for i in 1..<p.count { p[i] *= k }
        }
        let tot = p.reduce(0, +)
        if tot > 0 { return (lv, p.map { $0 / tot }) }
        var one = [Double](repeating: 0, count: lv.count); one[one.count - 1] = 1
        return (lv, one)
    }

    /// `idle_runs`: lengths (steps) of the past's maximal runs of zero burn
    /// in the unconstrained region, each with a recency weight (by its end).
    /// A run still going at now is not a finished length.
    static func idleRuns(_ h: StepHist, halfLife: Double, free: [Bool]) -> (lens: [Double], w: [Double]) {
        let n = h.count
        var lens: [Double] = [], ws: [Double] = []
        var k = 0
        while k < n {
            guard h.burn[k] <= 0 && free[k] else { k += 1; continue }
            var e = k + 1
            while e < n && h.burn[e] <= 0 && free[e] { e += 1 }
            if e < n {
                lens.append(Double(e - k))
                ws.append(recency(h.ageDays[e], halfLife))
            }
            k = e
        }
        return (lens, ws)
    }

    /// `resume_delay`: steps until a meter idle for `staySteps` moves again:
    /// the residual of past idle runs longer than the stay; an exponential
    /// tail when fewer than three are.
    static func resumeDelay(lens: [Double], w: [Double], staySteps: Double, n: Int, rng: inout ArenaRNG,
                            tailMult: Double = 0.5) -> [Int] {
        let m = lens.indices.filter { lens[$0] > staySteps }
        if m.count >= 3 {
            let dist = SimDiscrete(weights: m.map { w[$0] })
            return (0..<n).map { _ in
                let r = lens[m[dist.draw(&rng)]] - staySteps
                // A little jitter inside a run's step.
                return max(1, Int((r * (0.5 + rng.uniform())).rounded(.up)))
            }
        }
        let mean = max(staySteps * tailMult, 1)
        return (0..<n).map { _ in max(1, Int(SimRandom.exponential(mean, rng: &rng).rounded(.up))) }
    }
}
