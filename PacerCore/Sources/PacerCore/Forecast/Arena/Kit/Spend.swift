import Foundation

// `research/arena/kit/spend.py`, in Swift: spend and the meter readings as of
// a moment, the helpers behind every model that turns spend into meter
// points. Every function takes an `ArenaHistory` and uses only what it holds
// (rows known by `history.now`), so nothing here can leak the future.
//
// Names and order follow the Python, so the two can be read side by side:
// `_readings` → `readings`, `past_cycles` → `pastCycles`, `_ledger` →
// `ledger`, and so on. Everything derived is memoized on `history.memo` (the
// Python's `_memo`): one cut, shared by every model run on it, derives each
// value once.
//
// One difference by design: the arena prices turns here (`price_turns`,
// `PriceCache`, the rates known at now). The Swift kit never prices: the
// spend rows arrive priced (`ArenaSpendRow.costUSD`, the fixtures' pseudo-
// turns, or the app's `TokenSample` rows priced by `PriceLedger`), and a row
// with no known price adds nothing (nil, never 0: AGENTS.md, cost
// silent-zero).

public enum KitSpend {
    public static let families = arenaFamilies

    public static let hourMs: Millis = ArenaTime.hour
    public static let dayMs: Millis = ArenaTime.day

    // SpendMeterFit, as the earlier (unpublished) lab replayed it.
    /// Trailing whole days per fit.
    public static let spanDays: Millis = 14
    /// The account's own intervals needed to fit on them alone.
    public static let minOwn = 100
    /// `LiveMeter.minFitRise`: below this a fit is weak.
    public static let minRise = 20.0
    /// `LiveMeter.minFitR2`.
    public static let minR2 = 0.5
    /// USD: below this there is nothing to fit.
    public static let minPooledSpend = 1.0
    /// USD: a family that spent less keeps the pooled rate.
    public static let minFamilySpend = 1.0
    /// `SpendMeterFitter.maxPairGap`.
    public static let maxPairGapMs: Millis = ArenaTime.hour

    // LiveMeter (#318).
    public static let maxReadingAgeMs: Millis = ArenaTime.hour
    public static let carryLookbackMs: Millis = ArenaTime.hour
    public static let carryPosition = 0.25
    public static let carryMovedWeight = 0.5
    public static let staleHeldPoints = 2.0
    public static let maxServerLagMs: Millis = 10 * ArenaTime.minute
    public static let floorTolerance = 1e-9

    /// `arena.snapshot.cycles.window_ms`.
    public static func windowMs(_ windowKind: String) -> Millis {
        switch windowKind {
        case "five_hour", "session": 5 * ArenaTime.hour
        case "seven_day", "weekly_all", "weekly_scoped": 7 * ArenaTime.day
        default: preconditionFailure("unknown window kind \(windowKind)")
        }
    }

    /// `FAMILIES.index`, with anything unknown counted as "other".
    @inline(__always)
    static func familyIndex(_ family: String) -> Int {
        switch family {
        case "fable": 0
        case "opus": 1
        case "sonnet": 2
        case "haiku": 3
        default: 4
        }
    }

    /// `_cap_family`: the family a per-model cap counts
    /// (`SpendMeterFitter.capCounts`): the Fable weekly cap arrives as
    /// "Fable" and only Fable spend moves it. Nil when the cap names no
    /// family we know (every family counts).
    static func capFamily(_ scopeModel: String?) -> String? {
        guard let s0 = scopeModel, !s0.isEmpty else { return nil }
        let s = s0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return families.dropLast().first { s.contains($0) }
    }

    /// `_counted`: which family columns can move this meter.
    static func counted(_ scopeModel: String?) -> [Bool] {
        guard let fam = capFamily(scopeModel) else { return Array(repeating: true, count: families.count) }
        return families.map { $0 == fam }
    }

    // MARK: - Spend

    /// `_Ledger`: one account's spend rows as cumulative sums by family, for
    /// O(log n) range sums over (t0, t1] by `tEvent`. Unpriced rows add no
    /// spend (but their tokens count).
    public struct Ledger: Sendable {
        /// `tEvent`, sorted.
        public let t: [Millis]
        /// `[(n + 1) × families]` cumulative USD, row-major.
        let cost: [Double]
        /// `[(n + 1) × families]` cumulative tokens, row-major.
        let tokens: [Double]
        /// Family index per row.
        public let fam: [Int]
        /// USD per row (0 when unpriced).
        public let unitCost: [Double]

        static let empty = Ledger(t: [], cost: Array(repeating: 0, count: 5), tokens: Array(repeating: 0, count: 5),
                                  fam: [], unitCost: [])

        /// `searchsorted(t, x, "right")`: rows with `tEvent <= x`.
        @inline(__always)
        func upper(_ x: Millis) -> Int {
            var lo = 0, hi = t.count
            while lo < hi { let mid = (lo + hi) >> 1; if t[mid] <= x { lo = mid + 1 } else { hi = mid } }
            return lo
        }

        /// Per family over (t0, t1]: `[families]`.
        public func between(_ t0: Millis, _ t1: Millis, what: String = "spend") -> [Double] {
            let c = what == "spend" ? cost : tokens
            let i1 = upper(t1) * 5, i0 = upper(t0) * 5
            return (0..<5).map { c[i1 + $0] - c[i0 + $0] }
        }

        /// `between(...)[0] @ k`: the converted points over (t0, t1], summed
        /// in family order as numpy's dot does for five terms.
        public func converted(_ t0: Millis, _ t1: Millis, _ k: [Double]) -> Double {
            let i1 = upper(t1) * 5, i0 = upper(t0) * 5
            var s = 0.0
            for f in 0..<5 { s += (cost[i1 + f] - cost[i0 + f]) * k[f] }
            return s
        }
    }

    /// `_ledger`.
    public static func ledger(_ history: ArenaHistory, account: String) -> Ledger {
        history.memo.value("kit.spend.ledger|\(account)") {
            let rows = history.spend(account: account)
            if rows.isEmpty { return Ledger.empty }
            let n = rows.count
            var t = [Millis](); t.reserveCapacity(n)
            var fam = [Int](); fam.reserveCapacity(n)
            var unit = [Double](); unit.reserveCapacity(n)
            var C = [Double](repeating: 0, count: (n + 1) * 5)
            var K = [Double](repeating: 0, count: (n + 1) * 5)
            for (i, r) in rows.enumerated() {
                let f = familyIndex(r.family)
                var c = r.costUSD ?? 0
                if c.isNaN { c = 0 }
                t.append(r.tEvent); fam.append(f); unit.append(c)
                // np.add.at into row i + 1, then np.cumsum down the rows.
                let base = (i + 1) * 5, prev = i * 5
                for g in 0..<5 {
                    C[base + g] = C[prev + g] + (g == f ? c : 0)
                    K[base + g] = K[prev + g] + (g == f ? Double(r.tokens) : 0)
                }
            }
            return Ledger(t: t, cost: C, tokens: K, fam: fam, unitCost: unit)
        }
    }

    /// `spent_between`: USD (or tokens) per family over (t0, t1], by
    /// `tEvent`: `[families]`. O(log n).
    public static func spentBetween(_ history: ArenaHistory, account: String, _ t0: Millis, _ t1: Millis,
                                    what: String = "spend") -> [Double] {
        ledger(history, account: account).between(t0, t1, what: what)
    }

    // MARK: - Meter readings

    /// One meter's readings known by now with a value, sorted by
    /// (`tEvent`, util) so two readings at one instant telescope upward
    /// (`SpendMeterFitter.hourlyRise`): `t`, `p` (util %), `reset` (-1 when
    /// idle), `active` (state active and a reset set).
    public struct MeterSeries: Sendable {
        public let t: [Millis]
        public let p: [Double]
        public let reset: [Millis]
        public let active: [Bool]
        public var count: Int { t.count }
    }

    /// `_readings`.
    static func readings(_ history: ArenaHistory, account: String, windowKind: String,
                         scopeModel: String?) -> MeterSeries {
        history.memo.value("kit.spend.readings|\(account)|\(windowKind)|\(scopeModel ?? "")") {
            // The store keeps a meter's rows in (tEvent, util) order already
            // (nil util first, as polars sorts nulls); dropping the nil ones
            // leaves the Python's (t, p) order.
            let rows = history.readings(account: account, windowKind: windowKind, scopeModel: scopeModel)
            var t = [Millis](), p = [Double](), reset = [Millis](), active = [Bool]()
            t.reserveCapacity(rows.count); p.reserveCapacity(rows.count)
            reset.reserveCapacity(rows.count); active.reserveCapacity(rows.count)
            for r in rows {
                guard let u = r.utilPct else { continue }
                t.append(r.tEvent); p.append(u)
                reset.append(r.resetsAt ?? -1)
                active.append(r.active && r.resetsAt != nil)
            }
            return MeterSeries(t: t, p: p, reset: reset, active: active)
        }
    }

    /// `meter_series`: one meter's readings known by now, sorted by
    /// (`tEvent`, util).
    public static func meterSeries(_ history: ArenaHistory, account: String, windowKind: String,
                                   scopeModel: String? = nil) -> MeterSeries {
        readings(history, account: account, windowKind: windowKind, scopeModel: scopeModel)
    }

    /// A cycle of one meter whose reset had passed by now.
    public struct PastCycle: Sendable {
        /// The median of its readings' resets, truncated (`int(np.median)`).
        public let reset: Millis
        /// `reset - window`.
        public let start: Millis
        /// Its readings' `tEvent`, ascending.
        public let t: [Millis]
        /// Util as read (it can fall: an allowance reset mid-cycle).
        public let util: [Double]
    }

    /// `past_cycles`: every cycle of one meter that had reset by now, oldest
    /// first: active readings grouped by reset within half a window
    /// (`RateLimitCycle.contains`, never `==`).
    public static func pastCycles(_ history: ArenaHistory, account: String, windowKind: String,
                                  scopeModel: String? = nil) -> [PastCycle] {
        history.memo.value("kit.spend.past_cycles|\(account)|\(windowKind)|\(scopeModel ?? "")") {
            pastCyclesFast(readings(history, account: account, windowKind: windowKind, scopeModel: scopeModel),
                           windowKind: windowKind, now: history.now)
        }
    }

    /// The Python's algorithm as written (argsort every active reading by
    /// reset, split at gaps of half a window, sort each group by time): the
    /// reference `pastCyclesFast` is checked against.
    static func pastCyclesBySort(_ r: MeterSeries, windowKind: String, now: Millis) -> [PastCycle] {
        var t = [Millis](), p = [Double](), reset = [Millis]()
        for i in 0..<r.count where r.active[i] { t.append(r.t[i]); p.append(r.p[i]); reset.append(r.reset[i]) }
        if t.isEmpty { return [] }
        let dur = windowMs(windowKind)
        let half = Double(dur) / 2
        // np.argsort(reset, kind="stable"), split where consecutive
        // resets differ by half a window or more.
        let o = reset.indices.sorted { reset[$0] != reset[$1] ? reset[$0] < reset[$1] : $0 < $1 }
        var groups: [[Int]] = [[o[0]]]
        for j in 1..<o.count {
            if Double(reset[o[j]] - reset[o[j - 1]]) >= half { groups.append([o[j]]) } else { groups[groups.count - 1].append(o[j]) }
        }
        var out: [PastCycle] = []
        for g in groups {
            let res = truncatedMedian(g.map { reset[$0] })
            if res > now { continue }
            // Stable by t within the group (ties keep reset order).
            let gi = g.indices.sorted { t[g[$0]] != t[g[$1]] ? t[g[$0]] < t[g[$1]] : $0 < $1 }.map { g[$0] }
            out.append(PastCycle(reset: res, start: res - dur, t: gi.map { t[$0] }, util: gi.map { p[$0] }))
        }
        // Python's sorted() is stable too.
        return out.enumerated().sorted { $0.element.reset != $1.element.reset ? $0.element.reset < $1.element.reset : $0.offset < $1.offset }
            .map(\.element)
    }

    /// `past_cycles` without sorting every reading by reset, the same
    /// cycles. A cycle's readings arrive in time order with resets that
    /// jitter by milliseconds, so one pass collects runs of nearby resets
    /// (within a minute of the run's first), and only the runs are sorted
    /// and merged: runs whose resets come within half a window of the
    /// group's largest are one cycle, exactly where the sorted resets have
    /// no gap of half a window. The median is a selection, not a sort.
    static func pastCyclesFast(_ r: MeterSeries, windowKind: String, now: Millis) -> [PastCycle] {
        let dur = windowMs(windowKind)
        let half = Double(dur) / 2
        let tol: Millis = min(ArenaTime.minute, dur / 4)
        struct Run { var lo: Millis; var hi: Millis; let anchor: Millis; var members: [Int] }
        var runs: [Run] = []
        for i in 0..<r.count where r.active[i] {
            let x = r.reset[i]
            if let last = runs.indices.last, abs(x - runs[last].anchor) < tol {
                runs[last].lo = min(runs[last].lo, x); runs[last].hi = max(runs[last].hi, x)
                runs[last].members.append(i)
            } else {
                runs.append(Run(lo: x, hi: x, anchor: x, members: [i]))
            }
        }
        if runs.isEmpty { return [] }
        let order = runs.indices.sorted { runs[$0].lo != runs[$1].lo ? runs[$0].lo < runs[$1].lo : $0 < $1 }
        var groups: [[Int]] = []
        var maxSoFar = Millis.min
        for k in order {
            if groups.isEmpty || Double(runs[k].lo - maxSoFar) >= half {
                groups.append([k]); maxSoFar = runs[k].hi
            } else {
                groups[groups.count - 1].append(k); maxSoFar = max(maxSoFar, runs[k].hi)
            }
        }
        var out: [PastCycle] = []
        out.reserveCapacity(groups.count)
        for g in groups {
            var members = g.count == 1 ? runs[g[0]].members : g.flatMap { runs[$0].members }
            var resets = members.map { r.reset[$0] }
            let res = selectMedian(&resets)
            if res > now { continue }
            // The Python's order: by time, ties by reset, then by position.
            var inOrder = true
            for j in 1..<max(members.count, 1) where r.t[members[j]] <= r.t[members[j - 1]] { inOrder = false; break }
            if !inOrder {
                members.sort { a, b in
                    r.t[a] != r.t[b] ? r.t[a] < r.t[b] : (r.reset[a] != r.reset[b] ? r.reset[a] < r.reset[b] : a < b)
                }
            }
            out.append(PastCycle(reset: res, start: res - dur, t: members.map { r.t[$0] }, util: members.map { r.p[$0] }))
        }
        return out
    }

    /// `int(np.median(xs))` by selection (quickselect), reordering `xs`.
    static func selectMedian(_ xs: inout [Millis]) -> Millis {
        let n = xs.count
        func select(_ k: Int) -> Millis {
            var lo = 0, hi = n - 1
            while lo < hi {
                let pivot = xs[(lo + hi) >> 1]
                var i = lo, j = hi
                while i <= j {
                    while xs[i] < pivot { i += 1 }
                    while xs[j] > pivot { j -= 1 }
                    if i <= j { xs.swapAt(i, j); i += 1; j -= 1 }
                }
                if k <= j { hi = j } else if k >= i { lo = i } else { return xs[k] }
            }
            return xs[k]
        }
        let upper = select(n / 2)
        if n % 2 == 1 { return upper }
        // The largest of the lower half: after selecting n/2, everything
        // left of it is <= it.
        var lowerMax = xs[0]
        for i in 0..<(n / 2) where xs[i] > lowerMax { lowerMax = xs[i] }
        return Millis((Double(lowerMax) + Double(upper)) / 2)
    }

    /// `int(np.median(xs))` for int64 epoch ms: the middle value, or the
    /// mean of the two middle ones in float64, truncated toward zero. Kept
    /// for parity (port-spec open question 6): it moves a cycle's phase by
    /// at most half a millisecond.
    static func truncatedMedian(_ xs: [Millis]) -> Millis {
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        let m = (Double(s[n / 2 - 1]) + Double(s[n / 2])) / 2
        return Millis(m)   // toward zero, as int()
    }

    /// Pairs of consecutive readings of one cycle (|Δreset| < half a window),
    /// under an hour apart, that did not fall, with what each family spent
    /// in between: the rows the conversion is fitted on.
    public struct Intervals: Sendable {
        /// Runs of rows per account, in row order (the Python's per-row
        /// `account` labels, without a string per row).
        public var accountRuns: [(account: String, count: Int)]
        public var t0: [Millis]
        public var t1: [Millis]
        public var rise: [Double]
        /// `[n × families]` USD over (t0, t1], row-major.
        public var spend: [Double]

        public var count: Int { t1.count }

        /// The Python's `account` column, one label per row.
        public var account: [String] { accountRuns.flatMap { repeatElement($0.account, count: $0.count) } }

        public static let empty = Intervals(accountRuns: [], t0: [], t1: [], rise: [], spend: [])

        /// `take(m)` for a contiguous range of a one-account set (the span
        /// filters are ranges: intervals are in reading order, so `t1`
        /// ascends).
        public func slice(_ r: Range<Int>) -> Intervals {
            precondition(accountRuns.count <= 1, "slice a one-account set")
            return Intervals(accountRuns: r.isEmpty ? [] : [(accountRuns[0].account, r.count)], t0: Array(t0[r]),
                             t1: Array(t1[r]), rise: Array(rise[r]),
                             spend: Array(spend[(r.lowerBound * 5)..<(r.upperBound * 5)]))
        }

        public mutating func append(_ o: Intervals) {
            accountRuns += o.accountRuns; t0 += o.t0; t1 += o.t1; rise += o.rise; spend += o.spend
        }

        public func spend(_ i: Int, _ f: Int) -> Double { spend[i * 5 + f] }
    }

    /// `intervals`: every interval of one account's meter known by now (any
    /// time).
    public static func intervals(_ history: ArenaHistory, account: String, windowKind: String,
                                 scopeModel: String? = nil) -> Intervals {
        history.memo.value("kit.spend.intervals|\(account)|\(windowKind)|\(scopeModel ?? "")") {
            let r = readings(history, account: account, windowKind: windowKind, scopeModel: scopeModel)
            if r.count < 2 { return Intervals.empty }
            let half = Double(windowMs(windowKind)) / 2
            let led = ledger(history, account: account)
            var out = Intervals.empty
            out.t0.reserveCapacity(r.count); out.t1.reserveCapacity(r.count); out.rise.reserveCapacity(r.count)
            out.spend.reserveCapacity(r.count * 5)
            // The ledger's (t0, t1] sums, with the binary search for t0 reused
            // from the previous interval's t1 (consecutive readings).
            var lastT: Millis = .min, lastIdx = 0
            for i in 0..<(r.count - 1) {
                let dt = r.t[i + 1] - r.t[i], rise = r.p[i + 1] - r.p[i]
                guard r.active[i], r.active[i + 1], abs(Double(r.reset[i + 1] - r.reset[i])) < half,
                      dt > 0, dt < maxPairGapMs, rise >= 0 else { continue }
                out.t0.append(r.t[i]); out.t1.append(r.t[i + 1]); out.rise.append(rise)
                let i0 = r.t[i] == lastT ? lastIdx : led.upper(r.t[i])
                let i1 = led.upper(r.t[i + 1])
                lastT = r.t[i + 1]; lastIdx = i1
                for f in 0..<5 { out.spend.append(led.cost[i1 * 5 + f] - led.cost[i0 * 5 + f]) }
            }
            if out.count > 0 { out.accountRuns = [(account, out.count)] }
            return out
        }
    }

    // MARK: - Local time

    /// `tz_offset_ms`: the device's UTC offset in ms (0, UTC, when nothing is
    /// known). The arena takes the latest known turn's offset; the store
    /// carries one offset (the app: the device clock at now; the fixtures:
    /// the case's), which is what every turn of a fixture carries. The
    /// Python's "0 before any turn is known" only bites where there is no
    /// spend, where nothing reads it (no spend: no conversion).
    public static func tzOffsetMs(_ history: ArenaHistory, account: String? = nil) -> Millis {
        Millis(history.tzOffsetMin ?? 0) * ArenaTime.minute
    }

    /// `local_day_start`: the start of the local day containing `at`
    /// (default now), by `tzOffsetMs`. The app's fit runs per local
    /// calendar day (`SpendMeterFitter.span(endingAtStartOf:)`).
    public static func localDayStart(_ history: ArenaHistory, account: String? = nil, at: Millis? = nil) -> Millis {
        let off = tzOffsetMs(history, account: account)
        let a = at ?? history.now
        return floorDiv(a + off, dayMs) * dayMs - off
    }

    @inline(__always)
    static func floorDiv(_ a: Millis, _ b: Millis) -> Millis {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    // MARK: - Cycles

    /// `current_cycle`: (start, reset, this cycle's readings) for the cycle
    /// active at now, from readings known by now; nil when the window is
    /// idle.
    ///
    /// The reset is the latest known reading's own reset (no median over
    /// later data: `ArenaRunner.cycleAt`, the arena's `MeterIndex.cycle_at`)
    /// and the start is reset − window. The readings are that cycle's rows
    /// (active, reset within half a window of it: `RateLimitCycle.contains`,
    /// never `==`) with `tEvent <= now`, in (`tEvent`, util) order, rows
    /// with no util included (as the Python's frame keeps them).
    public static func currentCycle(_ history: ArenaHistory, account: String, windowKind: String,
                                    scopeModel: String? = nil)
        -> (start: Millis, reset: Millis, rows: [ArenaReading])? {
        let all = history.readings(account: account, windowKind: windowKind, scopeModel: scopeModel)
        guard let c = ArenaRunner.cycleAt(all, now: history.now) else { return nil }
        let dur = windowMs(windowKind)
        let half = Double(dur) / 2
        let rows = all.filter { r in
            guard r.active, let rs = r.resetsAt else { return false }
            return abs(Double(rs - c.resetAt)) < half && r.tEvent <= history.now
        }
        return (c.resetAt - dur, c.resetAt, rows)
    }
}
