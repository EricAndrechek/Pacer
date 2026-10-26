import Foundation

// The kit functions the simulation ports call, in one place: `kit/spend.py`
// (`meter_series`, `fit_details`, `spent_between`) for g2-08-fable-burst and
// `kit/fm/series.py` (`meter_series`) for g2-07-opus-limit. Each seam keeps
// the Python name so the models read like their Python, and calls the kit's
// Swift port once it is on this branch.

/// One meter's readings known by now, sorted by (t_event, util), as the
/// models read them: `t`, `p` (util %), `reset` (-1 when idle), `active`.
struct SimMeterReadings {
    var t: [Millis] = []
    var p: [Double] = []
    var reset: [Millis] = []
    var active: [Bool] = []

    /// `kit.spend.meter_series`: readings with a known util; active when the
    /// state is active and the reset known.
    static func spendMeterSeries(_ h: ArenaHistory, account: String, windowKind: String,
                                 scopeModel: String? = nil) -> SimMeterReadings {
        var out = SimMeterReadings()
        // `ArenaHistory.readings` is already in (t_event, util) order.
        for r in h.readings(account: account, windowKind: windowKind, scopeModel: scopeModel) {
            guard let u = r.utilPct, !u.isNaN else { continue }
            out.t.append(r.tEvent); out.p.append(u)
            out.reset.append(r.resetsAt ?? -1)
            out.active.append(r.active && r.resetsAt != nil)
        }
        return out
    }
}

/// What g2-08 reads of `kit.spend.fit_details`.
struct SimFitDetails {
    var rates: [Double]
    var pooled: Double
    var rise: Double
    var weak: Bool
}

enum SimSpendFit {
    /// False until the seams below call the spend kit's port: tests skip the
    /// cases whose reference added live spend.
    static let conversionPorted = false

    /// `kit.spend.fit_details(history, account, window_kind)`.
    static func fitDetails(_ h: ArenaHistory, account: String, windowKind: String) -> SimFitDetails? {
        // Seam: the spend kit's port (builder B) provides the fit; until it
        // is merged there is no conversion, so no live spend is added.
        nil
    }

    /// `kit.spend.spent_between(history, account, t0, t1)[0]`: USD per
    /// family over (t0, t1] by t_event, `arenaFamilies` order.
    static func spentBetween(_ h: ArenaHistory, account: String, _ t0: Millis, _ t1: Millis) -> [Double] {
        var out = [Double](repeating: 0, count: arenaFamilies.count)
        for r in h.spend(account: account) where r.tEvent > t0 && r.tEvent <= t1 {
            let f = arenaFamilies.firstIndex(of: r.family) ?? arenaFamilies.count - 1
            out[f] += r.costUSD ?? 0
        }
        return out
    }
}

/// `kit.fm.series.MeterSeries`: one meter's readings known at now, in event
/// order, with the cumulative burn that ignores cycle resets and re-bases.
struct SimFMMeterSeries {
    var times: [Millis] = []
    var cum: [Double] = []
    var cycleUtil: [Double] = []
    var reset: [Millis] = []
    var active: [Bool] = []
    var duration: Millis

    var count: Int { times.count }

    func inCycle(_ i: Int, _ resetAt: Millis) -> Bool {
        active[i] && Double(abs(reset[i] - resetAt)) < Double(duration) / 2
    }

    /// `used_now`: the latest reading of the cycle resetting at `resetAt`,
    /// as read (it can be below an earlier one: a re-base).
    func usedNow(_ resetAt: Millis) -> Double? {
        var i = times.count - 1
        while i >= 0 { if inCycle(i, resetAt) { return cycleUtil[i] }; i -= 1 }
        return nil
    }

    /// `kit.fm.series.meter_series(readings, account, kind, cap, now)`.
    static func meterSeries(_ h: ArenaHistory, account: String, windowKind: String, scopeModel: String?,
                            now: Millis) -> SimFMMeterSeries {
        let dur: Millis = windowKind == "five_hour" ? 5 * ArenaTime.hour : 7 * ArenaTime.day
        var s = SimFMMeterSeries(duration: dur)
        var prevReset: Millis?          // the latest active reading's reset
        var prevU = 0.0                 // and its util
        var c = 0.0
        for r in h.readings(account: account, windowKind: windowKind, scopeModel: scopeModel) where r.tEvent <= now {
            guard let u0 = r.utilPct, !u0.isNaN else { continue }
            let a = r.active && r.resetsAt != nil
            let reset = r.resetsAt ?? -1
            let u = a ? u0 : 0
            if a {
                let new = prevReset.map { Double(abs(reset - $0)) >= Double(dur) / 2 } ?? true
                c += max(new ? u : u - prevU, 0)
                prevReset = reset; prevU = u
            }
            s.times.append(r.tEvent); s.cum.append(c); s.cycleUtil.append(u)
            s.reset.append(reset); s.active.append(a)
        }
        return s
    }
}
