import Foundation

// `analog.py`'s day-activity model (`hourly_increments`,
// `meter_daymodel_paths`): the whole weekly path (`block_share` 1), and the
// five-hour fallback when the analogs are too few (effective sample size
// under `min_ess`, or no complete past cycle). A simulation: it matches the
// arena within Monte-Carlo bounds, never draw for draw (different random
// streams).
//
// Not ported, because no shipped config reaches them: the day-block
// bootstrap (`meter_block_paths`, `block_method = "bootstrap"`) and the
// turn-day activity (`turn_day_activity`): every meter config sets
// `use_turns = false`, so the model reads no turns.

extension Analog {
    /// `_SHAPE`: the default diurnal shape of meter increments (share per
    /// local hour), normalized; used until the account has its own days.
    static let shape: [Double] = {
        let s: [Double] = [0.17, 0.16, 0.14, 0.12, 0.14, 0.25, 0.45, 0.45, 0.48, 0.50, 0.53, 0.54,
                           0.57, 0.54, 0.53, 0.52, 0.51, 0.47, 0.42, 0.37, 0.33, 0.27, 0.24, 0.20]
        let total = s.reduce(0, +)
        return s.map { $0 / total }
    }()

    /// `hourly_increments`: `[days][24]` increments of the meter over each
    /// whole local hour of the last `days` local days (the day holding now
    /// last, partial), NaN where the hour crosses a reset, has no reading on
    /// either side, ends after now, or starts over an hour before the first
    /// reading. A fall within a cycle (a re-base) counts as 0, not usage.
    static func hourlyIncrements(_ series: KitSpend.MeterSeries, now: Millis, W: Millis, tz: Millis,
                                 days: Int) -> (starts: [Millis], inc: [[Double]])? {
        var t = [Millis](), u = [Double](), reset = [Millis]()
        for i in 0..<series.count where series.active[i] && series.t[i] <= now {
            t.append(series.t[i]); u.append(series.p[i]); reset.append(series.reset[i])
        }
        guard t.count >= 2 else { return nil }
        let day0 = KitSpend.floorDiv(now + tz, DAY) * DAY - tz     // start of today's local day (UTC ms)
        let starts = (0..<days).map { day0 - Millis(days - 1 - $0) * DAY }
        let half = Double(W) / 2
        let firstMinusHour = t[0] - HOUR
        var inc: [[Double]] = []
        inc.reserveCapacity(days)
        for s in starts {
            var lvl = [Double](repeating: .nan, count: 25)
            var rs = [Millis](repeating: -1, count: 25)
            for k in 0...24 {
                let i = upper(t, s + Millis(k) * HOUR) - 1
                if i >= 0 { lvl[k] = u[i]; rs[k] = reset[i] }
            }
            var row = [Double](repeating: .nan, count: 24)
            for k in 0..<24 {
                var v = lvl[k + 1] - lvl[k]
                if !(Double(abs(rs[k + 1] - rs[k])) < half) { v = .nan }
                if v.isFinite && v < 0 { v = 0 }
                if !(s + Millis(k + 1) * HOUR <= now) { v = .nan }
                if !(s + Millis(k) * HOUR >= firstMinusHour) { v = .nan }
                row[k] = v
            }
            inc.append(row)
        }
        return (starts, inc)
    }

    /// `meter_daymodel_paths`: each future local day is active or idle (a
    /// two-state chain by weekday type, estimated from the account's own
    /// days and shrunk toward priors); an active day's increments come from
    /// the account's own active days pooled with a wide lognormal prior
    /// (whose weight fades as own days accumulate), spread over the hours by
    /// one of its own day shapes or the default diurnal shape. The rest of
    /// today continues today's state. `[nPaths][grid.count]`.
    static func meterDaymodelPaths(_ series: KitSpend.MeterSeries, _ q: MeterQuery, _ grid: [Millis], W: Millis,
                                   tz: Millis, nPaths: Int, rng: inout ArenaRNG, _ cfg: ArenaConfig,
                                   log: ((String) -> Void)? = nil) -> [[Double]] {
        let days = cfg.int("block_days", 60)
        var starts: [Millis], inc: [[Double]]
        if let hi = hourlyIncrements(series, now: q.now, W: W, tz: tz, days: days) {
            (starts, inc) = hi
        } else {
            starts = [KitSpend.floorDiv(q.now + tz, DAY) * DAY - tz]
            inc = [[Double](repeating: .nan, count: 24)]
        }
        let nDays = inc.count
        let nk = inc.map { $0.reduce(0) { $1.isFinite ? $0 + 1 : $0 } }
        let tot = (0..<nDays).map { d in
            inc[d].reduce(0.0) { $1.isFinite ? $0 + $1 : $0 } * 24.0 / Double(max(nk[d], 1))
        }
        let wk = starts.map { localDow($0 + 12 * HOUR, tz) >= 5 }
        let thr = cfg.double("active_pts", 2.0)
        var histOk = nk.map { $0 >= 6 }
        histOk[nDays - 1] = false                              // today is handled separately
        // --- the activity chain: P(active | weekday type, previous day's state)
        let priorP = [false: cfg.double("prior_p_weekday", 0.7), true: cfg.double("prior_p_weekend", 0.35)]
        let n0 = cfg.double("prior_days", 4.0)
        let act = tot.map { $0 >= thr }
        // No turn days (use_turns = false): the chain reads the meter's own days.
        let chainOk = histOk, actChain = act
        var pBase: [Bool: Double] = [:]
        for k in [false, true] {
            var num = 0.0, den = 0.0
            for d in 0..<nDays where chainOk[d] && wk[d] == k {
                den += 1
                if actChain[d] { num += 1 }
            }
            pBase[k] = (num + n0 * priorP[k]!) / (den + n0)
        }
        // persistence multipliers (prior 1.25 after an active day, 0.6 after an idle one)
        var mult = [true: cfg.double("mult_after_active", 1.25), false: cfg.double("mult_after_idle", 0.6)]
        if chainOk.filter({ $0 }).count >= 6 {
            let idx = chainOk.indices.filter { chainOk[$0] }
            var prevAct: [Bool] = [], curAct: [Bool] = [], curP: [Double] = []
            for i in idx.dropFirst() where chainOk[i - 1] {
                prevAct.append(actChain[i - 1]); curAct.append(actChain[i]); curP.append(pBase[wk[i]]!)
            }
            for s in [true, false] {
                let m = prevAct.indices.filter { prevAct[$0] == s }
                if !m.isEmpty {
                    let ca = Double(m.filter { curAct[$0] }.count)
                    let cp = m.reduce(0.0) { $0 + curP[$1] }
                    let mean = cp / Double(m.count)
                    mult[s] = (ca + n0 * mult[s]! * mean) / (cp + n0 * mean)
                }
            }
        }
        // --- active-day totals: the account's own pool + a prior
        let own = (0..<nDays).filter { histOk[$0] && act[$0] }
        let ownTot = own.map { tot[$0] }
        let ownRows = own.map { inc[$0].map { $0.isFinite ? $0 : 0 } }
        let recDays = cfg.double("block_recency_days", 21) * Double(DAY)
        var rec = own.map { exp(Double(-(q.now - starts[$0])) / recDays) }
        let nOwn = ownTot.count
        let nPrior = cfg.double("prior_total_n", 3.0)
        let wPrior = nPrior / (Double(nOwn) + nPrior)
        var m0 = cfg.double("prior_total_median", 12.0)
        let s0 = cfg.double("prior_total_sigma", 0.9)
        // this cycle's own pace nudges the prior median (geometric blend)
        let rDay = q.rates.isEmpty ? 0 : max(q.rates[q.rates.count - 1], 0)
        let paceQ = 0.5 * rDay + 0.5 * q.u / max(q.e, Double(DAY)) * Double(DAY)
        if paceQ > 0 { m0 = exp(0.5 * Foundation.log(m0) + 0.5 * Foundation.log(max(paceQ, 1.0))) }
        // own-day draw weights: recency × a mild preference for days whose
        // total matched this cycle's pace
        let bwTot = cfg.double("block_bw_total", 1.0)
        if nOwn > 0 && paceQ > 0 {
            rec = zip(rec, ownTot).map { $0 * gauss(log1p($1) - log1p(paceQ), bwTot) }
            if rec.reduce(0, +) <= 0 { rec = [Double](repeating: 1, count: nOwn) }
        }
        // --- today's state
        let today = inc[nDays - 1]
        let todaySum = today.contains(where: \.isFinite) ? today.reduce(0.0) { $1.isFinite ? $0 + $1 : $0 } : 0
        let todayActive = todaySum >= 1.0 || (!q.rates.isEmpty && q.rates[0] > 0)
        let hourNow = localHour(q.now, tz)
        let h0 = Int(hourNow)
        let nH = Int((q.remaining / Double(HOUR)).rounded(.up)) + 2
        let tgrid = grid.map { (Double($0) - Double(q.now)) / Double(HOUR) }
        let wkNow = localDow(q.now, tz) >= 5
        let shapeTotal = shape.reduce(0, +)
        let restOfToday = h0 < 23 ? shape[(h0 + 1)...].reduce(0, +) / shapeTotal : 0

        /// 24 hourly increments of one active day.
        func drawDay(_ rng: inout ArenaRNG) -> [Double] {
            if nOwn > 0 && rng.uniform() >= wPrior {
                return ownRows[sampleIdx(&rng, rec, 1)[0]]
            }
            let total = m0 * exp(s0 * rng.normal())
            var sh = shape
            if nOwn > 0 && rng.uniform() < 0.5 {
                let row = ownRows[sampleIdx(&rng, rec, 1)[0]]
                let rs = row.reduce(0, +)
                if rs > 0 { sh = row.map { $0 / rs } }
            }
            return sh.map { total * $0 }
        }

        let kk = tgrid.map { min(max(Int($0.rounded(.down)), 0), nH - 1) }
        var out: [[Double]] = []
        out.reserveCapacity(nPaths)
        var cum = [Double](repeating: 0, count: nH + 1)
        for _ in 0..<nPaths {
            for k in cum.indices { cum[k] = 0 }
            var levelSoFar = 0.0
            var k = 0, hr = h0, d = 0
            var state = todayActive
            var wkd = wkNow
            var day: [Double]? = nil
            if state {
                day = drawDay(&rng)
            } else {
                // may still start later today: a hazard over the remaining hours
                let pToday = h0 < 23 ? pBase[wkd]! * mult[false]! * restOfToday : 0
                if rng.uniform() < pToday { day = drawDay(&rng); state = true }
            }
            var first = true
            while k < nH {
                if hr >= 24 {
                    hr -= 24; d += 1
                    // The weekday of now + d days (not of that day's start): the Python's, kept for parity.
                    wkd = localDow(q.now + Millis(d) * DAY, tz) >= 5
                    let prev = state
                    state = rng.uniform() < min(0.98, pBase[wkd]! * mult[prev]!)
                    day = state ? drawDay(&rng) : nil
                    first = false
                }
                if let day {
                    var v = day[hr]
                    if first && hr == h0 { v *= 1.0 - (hourNow - Double(h0)) }
                    levelSoFar += v
                }
                cum[k + 1] = levelSoFar
                k += 1; hr += 1
            }
            out.append((0..<grid.count).map { j in
                let a = tgrid[j] - Double(kk[j])
                return level(q.u, (cum[kk[j]] * (1 - a) + cum[kk[j] + 1] * a + 1e-9).rounded(.down))
            })
        }
        log?("daymodel: own_active=\(nOwn) w_prior=\(wPrior) m0=\(m0) p_base={wd:\(pBase[false]!),we:\(pBase[true]!)} "
             + "mult={a:\(mult[true]!),i:\(mult[false]!)} today_active=\(todayActive)")
        return out
    }
}
