import Foundation

// The conversion's fit from per-hour sums, the fast path behind `fitOnDay`.
//
// The Python refits from the interval rows of each 14-day span. A cut of
// spend-decay fits once per local day its past cuts touch (up to 120), and
// consecutive spans share 13 of their 14 days, so row by row the same
// intervals are summed a hundred times over. Every quantity the fit reads is
// a sum over rows: the NNLS needs only XᵀX and Xᵀy, the pooled rate Σy and
// ΣX, the gates Σy and ΣX per family, and the app's R² sums rise, spend and
// prediction per local hour (prediction = spend · rates, so the per-hour
// spend per family is enough). So each meter's intervals are summed once per
// cut into local-hour buckets, and each day's fit adds 336 buckets instead of
// thousands of rows. It agrees with the row-by-row fit (`fit(_:own:...)`) to
// rounding (the sums are re-associated); `KitFitTests` checks it does.
//
// A bucket holds the intervals whose later reading falls in (hour start,
// hour end], so a span (day − 14 d, day] between two local midnights is whole
// buckets. The app's R² groups by [hour start, hour end) instead; the two
// differ only for an interval ending exactly on the hour, which each bucket
// keeps apart ("boundary") and hands to the next hour's group.

extension KitSpend {
    struct HourTable: Sendable {
        let account: String
        /// Bucket index (floor((t1 + offset − 1) / hour)) of slot 0.
        let base: Millis
        let slots: Int
        var nI: [Int], yI: [Double], sI: [Double]      // interior: count, Σ rise, Σ spend [slots × 5]
        var nB: [Int], yB: [Double], sB: [Double]      // ending exactly on the hour
        var gram: [Double]                             // Σ x_f x_g, f <= g [slots × 15]
        var xy: [Double]                               // Σ x_f · rise [slots × 5]
        var yy: [Double]                               // Σ rise²

        static let pairs: [(Int, Int)] = (0..<5).flatMap { f in (f..<5).map { (f, $0) } }
        static func pairIndex(_ f: Int, _ g: Int) -> Int {
            let (a, b) = f <= g ? (f, g) : (g, f)
            return a * 5 - a * (a - 1) / 2 + (b - a)
        }
    }

    static func hourTable(_ history: ArenaHistory, account: String, windowKind: String, scopeModel: String?,
                          offsetMs: Millis) -> HourTable? {
        history.memo.value("kit.spend.hours|\(account)|\(windowKind)|\(scopeModel ?? "")|\(offsetMs)") {
            let iv = intervals(history, account: account, windowKind: windowKind, scopeModel: scopeModel)
            guard iv.count > 0 else { return KitBox<HourTable?>(nil) }
            var lo = Millis.max, hi = Millis.min
            for t in iv.t1 {
                let b = floorDiv(t + offsetMs - 1, hourMs)
                lo = min(lo, b); hi = max(hi, b)
            }
            let slots = Int(hi - lo + 1)
            var h = HourTable(account: account, base: lo, slots: slots,
                              nI: .init(repeating: 0, count: slots), yI: .init(repeating: 0, count: slots),
                              sI: .init(repeating: 0, count: slots * 5),
                              nB: .init(repeating: 0, count: slots), yB: .init(repeating: 0, count: slots),
                              sB: .init(repeating: 0, count: slots * 5),
                              gram: .init(repeating: 0, count: slots * 15), xy: .init(repeating: 0, count: slots * 5),
                              yy: .init(repeating: 0, count: slots))
            for i in 0..<iv.count {
                let t = iv.t1[i] + offsetMs
                let s = Int(floorDiv(t - 1, hourMs) - lo)
                let y = iv.rise[i]
                let boundary = t - floorDiv(t, hourMs) * hourMs == 0
                if boundary { h.nB[s] += 1; h.yB[s] += y } else { h.nI[s] += 1; h.yI[s] += y }
                for f in 0..<5 {
                    let x = iv.spend[i * 5 + f]
                    if boundary { h.sB[s * 5 + f] += x } else { h.sI[s * 5 + f] += x }
                    h.xy[s * 5 + f] += x * y
                }
                for (p, (f, g)) in HourTable.pairs.enumerated() { h.gram[s * 15 + p] += iv.spend[i * 5 + f] * iv.spend[i * 5 + g] }
                h.yy[s] += y * y
            }
            return KitBox<HourTable?>(h)
        }.value
    }

    /// `fit_on_day` from the hour tables: the same rows `_span_rows` picks
    /// (own when 100, else every visible account's), the same fit.
    static func fitFromHours(_ history: ArenaHistory, account: String, windowKind: String, scopeModel: String?,
                             dayStart: Millis, offsetMs: Millis) -> FitDetails? {
        let lo = dayStart - spanDays * dayMs
        // Span buckets [b0, b1]: (lo, dayStart] by t1.
        let b0 = floorDiv(lo + offsetMs, hourMs), b1 = floorDiv(dayStart + offsetMs, hourMs) - 1
        struct Part { let t: HourTable; let s0: Int; let s1: Int }   // slot range, inclusive; empty when s0 > s1
        func part(_ a: String) -> (Part, Int)? {
            guard let t = hourTable(history, account: a, windowKind: windowKind, scopeModel: scopeModel,
                                    offsetMs: offsetMs) else { return nil }
            let s0 = Int(max(b0 - t.base, 0)), s1 = Int(min(b1 - t.base, Millis(t.slots - 1)))
            var n = 0
            if s0 <= s1 { for s in s0...s1 { n += t.nI[s] + t.nB[s] } }
            return (Part(t: t, s0: s0, s1: s1), n)
        }
        var parts: [Part] = []
        var own = true
        let mine = part(account)
        if let (p, n) = mine, n >= minOwn {
            parts = [p]
        } else {
            let others = history.accounts.filter { $0 != account }.compactMap(part).filter { $0.1 > 0 }
            if others.isEmpty {
                if let (p, n) = mine, n > 0 { parts = [p] }
            } else {
                own = false
                if let (p, n) = mine, n > 0 { parts.append(p) }
                parts += others.map(\.0)
            }
        }
        let counted = counted(scopeModel)
        let cols = (0..<5).filter { counted[$0] }
        var n = 0, ySum = 0.0, yy = 0.0
        var spent = [Double](repeating: 0, count: 5)
        var gram = [Double](repeating: 0, count: 15), xy = [Double](repeating: 0, count: 5)
        for p in parts where p.s0 <= p.s1 {
            let t = p.t
            for s in p.s0...p.s1 {
                n += t.nI[s] + t.nB[s]
                ySum += t.yI[s] + t.yB[s]
                yy += t.yy[s]
                for f in 0..<5 {
                    spent[f] += t.sI[s * 5 + f] + t.sB[s * 5 + f]
                    xy[f] += t.xy[s * 5 + f]
                }
                for q in 0..<15 { gram[q] += t.gram[s * 15 + q] }
            }
        }
        if n == 0 { return nil }
        for f in 0..<5 where !counted[f] { spent[f] = 0 }
        let total = spent.reduce(0, +)
        if total <= minPooledSpend { return nil }
        let pooled = ySum / total
        let k = cols.count
        var G = [Double](repeating: 0, count: k * k)
        for a in 0..<k { for b in 0..<k { G[a * k + b] = gram[HourTable.pairIndex(cols[a], cols[b])] } }
        let sol = KitMath.nnlsGram(G, cols.map { xy[$0] }, rows: n)
        var coef = [Double](repeating: 0, count: 5)
        for (i, j) in cols.enumerated() { coef[j] = sol[i] }
        // Σ(y − Xc)² and Σ(y − ȳ)² from the sums: informational only
        // (`extra["r2_interval"]` in the Python), never a gate.
        var sse = yy
        for f in 0..<5 { sse -= 2 * coef[f] * xy[f] }
        for a in 0..<5 { for b in 0..<5 { sse += coef[a] * coef[b] * gram[HourTable.pairIndex(a, b)] } }
        let mean = ySum / Double(n)
        let ss = yy - Double(n) * mean * mean
        let r2Interval = ss > 0 ? 1 - sse / ss : 0
        let r2 = hourlyR2(parts.map { ($0.t, $0.s0, $0.s1) }, counted: counted, coef: coef)
        var reason: String?
        if ySum < minRise {
            reason = String(format: "rise %.1f < %.0f", ySum, minRise)
        } else if r2 < minR2 {
            reason = String(format: "R² %.2f < %g", r2, minR2)
        }
        let weak = reason != nil
        let rates: [Double] = (0..<5).map { f in
            guard counted[f] else { return 0 }
            if weak { return pooled }
            return spent[f] > minFamilySpend ? coef[f] : pooled
        }
        let conv = Conversion(pointsPerUSD: Dictionary(uniqueKeysWithValues: zip(families, rates)), weak: weak,
                              r2: r2, fittedThrough: dayStart)
        return FitDetails(conversion: conv, rates: rates, pooled: pooled, own: own, rise: ySum, weakReason: reason,
                          nnls: coef, spent: spent, r2Interval: r2Interval, nRows: n, dayStart: dayStart)
    }

    /// `hourly_r2` from hour tables: groups by (account, local hour), in
    /// (account, hour) order, over the active ones.
    static func hourlyR2(_ parts: [(HourTable, Int, Int)], counted: [Bool], coef: [Double]) -> Double {
        var ya: [Double] = [], pa: [Double] = []
        for (t, s0, s1) in parts.sorted(by: { $0.0.account < $1.0.account }) where s0 <= s1 {
            // Group of slot s: its interior plus the previous slot's boundary
            // rows; the last slot's boundary rows open one more hour.
            for s in s0...(s1 + 1) {
                var y = 0.0, sp = 0.0, p = 0.0
                if s > s0 { y += t.yB[s - 1] }
                if s <= s1 { y += t.yI[s] }
                for f in 0..<5 where counted[f] {
                    var x = 0.0
                    if s > s0 { x += t.sB[(s - 1) * 5 + f] }
                    if s <= s1 { x += t.sI[s * 5 + f] }
                    sp += x; p += x * coef[f]
                }
                let rows = (s > s0 ? t.nB[s - 1] : 0) + (s <= s1 ? t.nI[s] : 0)
                if rows > 0 && (y > 0 || sp > 0) { ya.append(y); pa.append(p) }
            }
        }
        if ya.isEmpty { return 0 }
        let mean = KitMath.sum(ya) / Double(ya.count)
        let ss = KitMath.sum(ya.map { ($0 - mean) * ($0 - mean) })
        guard ss > 0 else { return 0 }
        return 1 - KitMath.sum(zip(ya, pa).map { ($0 - $1) * ($0 - $1) }) / ss
    }
}
