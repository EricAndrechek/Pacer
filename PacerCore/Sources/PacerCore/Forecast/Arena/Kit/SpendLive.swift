import Foundation

// `kit/spend.py`, the live meter as the arena replays it
// (`LiveMeter.estimate` → `LiveMeterValue.shownPercent`, #318): `_Reading`,
// `_same_cycle`, `LiveValue`, `_Spend`, `_held_tick`, `_carry`, `_tenths`,
// `live_detail`, `live_value`. `port-live-meter` reads it.
//
// The app has its own `LiveMeter`; this is the arena's restatement of it
// over an `ArenaHistory`, kept beside the conversion it reads so the
// forecaster and its reference agree on the same rows.

extension KitSpend {
    struct LiveReading {
        let t: Millis
        let p: Double
        let reset: Millis?
    }

    /// `_same_cycle` (`LiveMeter.sameCycle`): never across a reset that had
    /// passed by the later reading; never from a nil reset to an anchored one.
    static func sameCycle(_ a: LiveReading, _ b: LiveReading, _ duration: Millis) -> Bool {
        if let ar = a.reset, ar <= b.t { return false }
        if let ar = a.reset, let br = b.reset { return abs(Double(br - ar)) < Double(duration) / 2 }
        return a.reset == nil && b.reset == nil
    }

    /// Everything `LiveMeter.value` computes; `shown` is what a surface shows.
    public struct LiveValue: Sendable {
        public let shown: Double
        /// Whole points: reading + floor(carry + converted spend).
        public let percent: Double
        /// Before flooring.
        public let exact: Double
        public let reading: Double
        public let readingT: Millis
        public let anchorT: Millis
        /// Converted spend since the anchor (Σ rate × $).
        public let added: Double
        public let spendUSD: Double
        public let carry: Double
        public let restarted: Bool
        public var isEstimate: Bool { restarted || added > 0 }
    }

    /// `_Spend`: converted points and dollars per row, cumulative, for range
    /// sums.
    struct LiveSpend {
        let t: [Millis]
        let pts: [Double]
        let usd: [Double]

        init(_ led: Ledger, rates: [Double], counted: [Bool]) {
            t = led.t
            var p = [0.0], u = [0.0]
            p.reserveCapacity(led.t.count + 1); u.reserveCapacity(led.t.count + 1)
            var sp = 0.0, su = 0.0
            for i in 0..<led.fam.count {
                let f = led.fam[i], c = led.unitCost[i]
                let ok = counted[f] && c > 0
                sp += ok ? rates[f] * c : 0
                su += ok ? c : 0
                p.append(sp); u.append(su)
            }
            pts = p; usd = u
        }

        @inline(__always)
        func upper(_ x: Millis) -> Int {
            var lo = 0, hi = t.count
            while lo < hi { let mid = (lo + hi) >> 1; if t[mid] <= x { lo = mid + 1 } else { hi = mid } }
            return lo
        }

        /// Σ rate × $ over (t0, t1].
        func points(_ t0: Millis, _ t1: Millis) -> Double { pts[upper(t1)] - pts[upper(t0)] }
        func dollars(_ t0: Millis, _ t1: Millis) -> Double { usd[upper(t1)] - usd[upper(t0)] }
    }

    /// `_held_tick` (`LiveMeter.heldTick`): the latest reading held at the
    /// value of the reading that last moved while the spend since implies 2+
    /// points, within ten minutes of it: that tick (the server has not
    /// recalculated).
    static func heldTick(_ readings: [LiveReading], _ duration: Millis, _ spend: LiveSpend) -> (LiveReading, Double)? {
        guard let last = readings.last, last.p < 100 else { return nil }
        var tick = readings.count - 1
        while tick > 0 {
            let prev = readings[tick - 1], r = readings[tick]
            if prev.p == last.p && sameCycle(prev, r, duration) && r.t - prev.t <= maxPairGapMs { tick -= 1 } else { break }
        }
        let start = readings[tick]
        if tick >= readings.count - 1 || last.t - start.t > maxServerLagMs { return nil }
        let implied = spend.points(start.t, last.t)
        return implied + floorTolerance >= staleHeldPoints ? (start, implied) : nil
    }

    /// `_carry` (`LiveMeter.carry`): where inside its whole point the meter
    /// sat at the last reading, in [0, 1).
    static func carry(_ readings: [LiveReading], _ duration: Millis, _ spend: LiveSpend,
                      position: Double = carryPosition, movedWeight: Double = carryMovedWeight) -> Double {
        guard let lastP = readings.last?.p else { return 0 }
        var lo = 0.0, hi = 1.0
        for (i, r) in readings.enumerated() {
            let p = r.p
            var moved: Double?
            if i > 0 {
                let prev = readings[i - 1]
                let s = spend.points(prev.t, r.t)
                if sameCycle(prev, r, duration) && r.t - prev.t <= maxPairGapMs && p >= prev.p { moved = s * movedWeight }
            }
            if let m = moved, lo + m < p + 1, hi + m > p {
                (lo, hi) = (max(lo + m, p), min(hi + m, p + 1))
            } else {
                (lo, hi) = (p, p + 1)
            }
        }
        return min(max(0, lo + position * (hi - lo) - lastP), 1 - 1e-6)
    }

    /// `_tenths` (`PacerMeterFormat.tenths`): cut (never rounded up) to one
    /// decimal.
    static func tenths(_ v: Double) -> Double { (v * 10 + 1e-6).rounded(.down) / 10 }

    /// `live_detail`: `liveValue` with its parts. `rates` (points per USD per
    /// family) skips the fit and its weak-fit gate.
    public static func liveDetail(_ history: ArenaHistory, account: String, windowKind: String,
                                  scopeModel: String? = nil, rates given: [Double]? = nil) -> LiveValue? {
        var rates: [Double]
        if let given { rates = given } else {
            guard let d = fitDetails(history, account: account, windowKind: windowKind, scopeModel: scopeModel),
                  !d.conversion.weak else { return nil }
            rates = d.rates
        }
        let now = history.now
        let r = readings(history, account: account, windowKind: windowKind, scopeModel: scopeModel)
        var t: [Millis] = [], p: [Double] = [], reset: [Millis] = []
        for i in 0..<r.count where r.t[i] <= now { t.append(r.t[i]); p.append(r.p[i]); reset.append(r.reset[i]) }
        guard let latestT = t.last else { return nil }
        let duration = windowMs(windowKind)
        let lo = lowerIndex(t) { $0 >= latestT - carryLookbackMs }
        let hist = (lo..<t.count).map { LiveReading(t: t[$0], p: p[$0], reset: reset[$0] < 0 ? nil : reset[$0]) }
        let latest = hist[hist.count - 1]
        let spend = LiveSpend(ledger(history, account: account), rates: rates, counted: counted(scopeModel))

        let held = heldTick(hist, duration, spend)
        let anchor = held?.0 ?? latest
        let carry = carry(hist.filter { $0.t <= anchor.t }, duration, spend)

        // LiveMeter.value
        if now - anchor.t > maxReadingAgeMs { return nil }
        let from: Millis, base: Double, restarted: Bool
        if anchor.reset == nil || anchor.reset! > now {
            (from, base, restarted) = (anchor.t, anchor.p, false)
        } else if now >= anchor.reset! + duration {
            return nil
        } else {
            (from, base, restarted) = (max(anchor.reset!, anchor.t), 0, true)
        }
        let exact = spend.points(from, now)
        let usd = spend.dollars(from, now)
        let carried = restarted ? 0 : min(max(0, carry), 1 - 1e-6)
        let points = (carried + exact + floorTolerance).rounded(.down)
        let percent: Double, exactPct: Double
        if restarted {
            percent = min(100, max(0, points))
            exactPct = min(100, max(0, exact + floorTolerance))
        } else {
            percent = max(base, min(100, base + max(0, points)))
            exactPct = max(base, min(100, base + carried + max(0, exact) + floorTolerance))
        }
        let isEstimate = restarted || exact > 0
        let shown = isEstimate ? min(max(tenths(exactPct), percent), percent + 0.9) : percent
        return LiveValue(shown: shown, percent: percent, exact: exactPct, reading: latest.p, readingT: latest.t,
                         anchorT: anchor.t, added: exact, spendUSD: usd, carry: carried, restarted: restarted)
    }

    /// `live_value`: the latest reading plus the converted spend since it,
    /// to a tenth, never a full point above the whole points moved. Nil when
    /// the fit is weak or missing, there is no reading, the reading (or the
    /// held tick under it) is over an hour old, or more than one cycle has
    /// passed since its reset.
    public static func liveValue(_ history: ArenaHistory, account: String, windowKind: String,
                                 scopeModel: String? = nil) -> Double? {
        liveDetail(history, account: account, windowKind: windowKind, scopeModel: scopeModel)?.shown
    }
}
