import Foundation

// `research/arena/kit/ml/data.py`, in Swift: a history as arrays for the
// learned models, every lookup with an explicit `asof` that reads only rows
// known by then (a learned model trains on past moments inside its history,
// and a feature at a past moment must be what was known at it, not at now).
//
// What the app's history carries and the arena's does not, and back:
// - Spend arrives priced (`ArenaSpendRow.costUSD`, the port's pseudo-turns:
//   one per model family per five minutes), so `price_at_known_time` has
//   nothing to do; an unpriced row is NaN, as the Python's null cost.
// - No sessions, subagent flags or human prompts: the Python fills a turn
//   without a session as session 0 and without a flag as not a subagent, and
//   a history without prompts counts none; the features that read them are
//   computed the same way here (see `KitMLFeatures`).
// - The time zone is the store's one offset (the arena: each turn's own;
//   the pseudo-turns all carry the case's).
//
// Float sums use numpy's pairwise summation where the Python calls `np.sum`
// (`KitMLData.npSum`), so features match the Python bit for bit.

public enum KitMLData {
    public static let minMs: Millis = 60_000
    public static let hourMs: Millis = 60 * minMs
    public static let dayMs: Millis = 24 * hourMs
    public static let weekMs: Millis = 7 * dayMs

    public static let windowMs: [String: Millis] = ["five_hour": 5 * hourMs, "seven_day": weekMs,
                                                    "weekly_scoped": weekMs]
    public static let families = arenaFamilies

    /// `PHASE_U = np.linspace(0, 1, 41)` (numpy: i·step, the last exactly 1).
    public static let phaseU: [Double] = (0..<41).map { (i: Int) -> Double in i == 40 ? 1.0 : Double(i) * (1.0 / 40.0) }

    /// `model_family` → FAMILIES index (`replace_strict(..., default=other)`).
    static func familyIndex(_ f: String) -> Int8 { Int8(families.firstIndex(of: f) ?? 4) }

    /// `cap_family`: the family a per-model cap counts (Fable weekly →
    /// Fable turns), nil for an all-model meter or a cap that names none.
    public static func capFamily(_ cap: String?) -> Int8? {
        guard let cap else { return nil }
        return families.firstIndex(of: cap.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).map(Int8.init)
    }

    // MARK: - numpy / Python numerics

    /// `np.sum` of a float64 array: numpy's pairwise summation (blocks of 8
    /// accumulators up to 128 elements, halves above), which is what makes a
    /// feature's float match the Python's to the bit.
    public static func npSum(_ a: [Double]) -> Double {
        a.withUnsafeBufferPointer { npSum($0.baseAddress, $0.count) }
    }

    static func npSum(_ a: UnsafePointer<Double>?, _ n: Int) -> Double {
        guard let a, n > 0 else { return 0 }
        if n < 8 {
            var res = 0.0
            for i in 0..<n { res += a[i] }
            return res
        }
        if n <= 128 {
            var r = (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
            var i = 8
            while i < n - (n % 8) {
                r.0 += a[i]; r.1 += a[i + 1]; r.2 += a[i + 2]; r.3 += a[i + 3]
                r.4 += a[i + 4]; r.5 += a[i + 5]; r.6 += a[i + 6]; r.7 += a[i + 7]
                i += 8
            }
            var res = ((r.0 + r.1) + (r.2 + r.3)) + ((r.4 + r.5) + (r.6 + r.7))
            while i < n { res += a[i]; i += 1 }
            return res
        }
        var n2 = n / 2
        n2 -= n2 % 8
        return npSum(a, n2) + npSum(a + n2, n - n2)
    }

    /// `np.mean`: the pairwise sum over the count.
    public static func npMean(_ a: [Double]) -> Double { a.isEmpty ? .nan : npSum(a) / Double(a.count) }

    /// `np.interp` at one point, bit for bit as numpy computes it here:
    /// numpy's C `slope*(x - xp[j]) + fp[j]` is compiled with floating-point
    /// contraction (clang, arm64), so it is one fused multiply-add, and only
    /// the fma reproduces it (a plain multiply-add is an ulp off now and then,
    /// which `past_phase_rise` showed). Otherwise `KitDetQ.npInterp`.
    public static func npInterp(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        let n = xs.count
        if x > xs[n - 1] { return ys[n - 1] }
        if x < xs[0] { return ys[0] }
        if x == xs[n - 1] { return ys[n - 1] }
        var lo = 0, hi = n - 1
        while hi - lo > 1 { let mid = (lo + hi) >> 1; if xs[mid] <= x { lo = mid } else { hi = mid } }
        if xs[lo] == x { return ys[lo] }
        let slope = (ys[lo + 1] - ys[lo]) / (xs[lo + 1] - xs[lo])
        return ys[lo].addingProduct(slope, x - xs[lo])
    }

    /// Python's float `divmod(x, y)` (CPython `float_divmod`), y > 0.
    @inline(__always) public static func pyDivmod(_ x: Double, _ y: Double) -> (Double, Double) {
        var mod = fmod(x, y)
        var div = (x - mod) / y
        if mod != 0 {
            if (y < 0) != (mod < 0) { mod += y; div -= 1.0 }
        } else {
            mod = copysign(0.0, y)
        }
        var floordiv: Double
        if div != 0 {
            floordiv = div.rounded(.down)
            if div - floordiv > 0.5 { floordiv += 1.0 }
        } else {
            floordiv = copysign(0.0, x / y)
        }
        return (floordiv, mod)
    }

    /// Python's float `x % y` (`float_rem`), y > 0.
    @inline(__always) public static func pyMod(_ x: Double, _ y: Double) -> Double {
        var mod = fmod(x, y)
        if mod != 0 {
            if (y < 0) != (mod < 0) { mod += y }
        } else {
            mod = copysign(0.0, y)
        }
        return mod
    }

    /// Python's integer floor division and modulo.
    @inline(__always) public static func floorDiv(_ a: Millis, _ b: Millis) -> Millis {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }

    @inline(__always) public static func floorMod(_ a: Millis, _ b: Millis) -> Millis { a - floorDiv(a, b) * b }

    /// `np.searchsorted(a, v, side="left"|"right")` on an ascending array.
    @inline(__always) public static func searchLeft(_ a: [Millis], _ v: Millis) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) >> 1; if a[m] < v { lo = m + 1 } else { hi = m } }
        return lo
    }

    @inline(__always) public static func searchRight(_ a: [Millis], _ v: Millis) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) >> 1; if a[m] <= v { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// The same against a float key (numpy compares in float64).
    @inline(__always) public static func searchRight(_ a: [Millis], _ v: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) >> 1; if Double(a[m]) <= v { lo = m + 1 } else { hi = m } }
        return lo
    }

    // MARK: - Turns

    /// One account's spend rows, in (t_event, t_known) order (`TurnArrays`).
    public final class TurnArrays: Sendable {
        public let te: [Millis]
        public let tk: [Millis]
        /// USD; NaN when unpriced.
        public let cost: [Double]
        public let fam: [Int8]
        /// Turns each row stands for (a pseudo-turn sums several).
        public let turns: [Int]
        /// The UTC offset of every row (the store's), NaN when unknown.
        let tz: Double

        public init(rows: [ArenaSpendRow], tzOffsetMin: Int?) {
            let r = rows.enumerated().sorted { a, b in
                (a.element.tEvent, a.element.tKnown, a.offset) < (b.element.tEvent, b.element.tKnown, b.offset)
            }.map(\.element)
            te = r.map(\.tEvent); tk = r.map(\.tKnown)
            cost = r.map { $0.costUSD ?? .nan }
            fam = r.map { KitMLData.familyIndex($0.family) }
            turns = r.map(\.turns)
            tz = tzOffsetMin.map(Double.init) ?? .nan
        }

        public var count: Int { te.count }

        /// Indices of rows with t_event in (lo, hi] known at asof.
        public func window(_ lo: Millis, _ hi: Millis, _ asof: Millis) -> [Int] {
            let a = KitMLData.searchRight(te, lo), b = KitMLData.searchRight(te, hi)
            guard a < b else { return [] }
            var out: [Int] = []
            out.reserveCapacity(b - a)
            for i in a..<b where tk[i] <= asof { out.append(i) }
            return out
        }

        /// USD of rows with t_event in (lo, hi] known at asof (one family's
        /// only, given `fam`): `np.nansum` (pairwise, NaN as 0).
        public func spend(_ lo: Millis, _ hi: Millis, _ asof: Millis, fam f: Int8? = nil) -> Double {
            let a = KitMLData.searchRight(te, lo), b = KitMLData.searchRight(te, hi)
            guard a < b else { return 0 }
            var vals: [Double] = []
            vals.reserveCapacity(b - a)
            for i in a..<b where tk[i] <= asof && (f == nil || fam[i] == f!) {
                let c = cost[i]
                vals.append(c.isNaN ? 0 : c)
            }
            return KitMLData.npSum(vals)
        }

        /// `latest_tz`: the offset of the latest row known at asof among the
        /// 500 before it by event time; NaN when none.
        public func latestTz(_ asof: Millis) -> Double {
            let b = KitMLData.searchRight(te, asof)
            let lo = max(0, b - 500)
            guard tz.isFinite, lo < b else { return .nan }
            for i in stride(from: b - 1, through: lo, by: -1) where tk[i] <= asof { return tz }
            return .nan
        }
    }

    // MARK: - Meters

    /// The cycle in progress at `asof` as known at `asof` (`CycleState`).
    public struct CycleState: Sendable {
        public var reset: Millis
        public var start: Millis
        public var duration: Millis
        public var used: Double
        public var lastTe: Millis
        public var te: [Millis]
        public var util: [Double]
    }

    public struct PastCycle: Sendable {
        public var reset: Millis
        public var start: Millis
        public var idx: [Int]
        public var tkMax: Millis
        public var final: Double
        public var phase: [Double]
    }

    /// `CycleNow` of `arena.snapshot.cycles.MeterIndex.cycle_at`.
    public struct CycleNow: Sendable {
        public var resetAt: Millis
        public var start: Millis
        public var duration: Millis
        public var util: Double
        public var lastT: Millis
    }

    /// One meter (account × window × cap) from a history's readings
    /// (`MeterSeries`, on `MeterIndex`'s cycle rule).
    public final class MeterSeries: Sendable {
        public let account: String
        public let windowKind: String
        public let cap: String?
        public let duration: Millis
        public let te: [Millis]
        public let tk: [Millis]
        /// −1 when the reading has no reset.
        public let reset: [Millis]
        /// NaN when unknown.
        public let util: [Double]
        public let active: [Bool]
        /// Knowledge order (`MeterIndex`): t_known sorted, and for each
        /// prefix the newest reading by t_event (ties: the later-known).
        let kTk: [Millis]
        let kLatest: [Int]
        public let pastCycles: [PastCycle]
        let resets: [Millis], tkMaxs: [Millis], tkMins: [Millis]

        public init(readings: [ArenaReading], account: String, windowKind: String, cap: String?) {
            self.account = account; self.windowKind = windowKind; self.cap = cap
            let d = KitMLData.windowMs[windowKind] ?? KitMLData.weekMs
            duration = d
            // `meter_frame`: sorted by (t_event, t_known), stable.
            let r = readings.enumerated().sorted { a, b in
                (a.element.tEvent, a.element.tKnown, a.offset) < (b.element.tEvent, b.element.tKnown, b.offset)
            }.map(\.element)
            let te = r.map(\.tEvent), tk = r.map(\.tKnown)
            let reset = r.map { $0.resetsAt ?? -1 }
            let util = r.map { $0.utilPct ?? .nan }
            let active = r.map { $0.active && $0.resetsAt != nil }
            self.te = te; self.tk = tk; self.reset = reset; self.util = util; self.active = active
            // np.lexsort((te, tk)): by t_known, then t_event, stable.
            let order = r.indices.sorted { a, b in (r[a].tKnown, r[a].tEvent, a) < (r[b].tKnown, r[b].tEvent, b) }
            kTk = order.map { r[$0].tKnown }
            var latest: [Int] = []
            latest.reserveCapacity(order.count)
            var run = Millis.min, pos = 0
            for (j, o) in order.enumerated() {
                let t = r[o].tEvent
                if t >= run { pos = j }      // `te_sorted >= prev`: the later-known copy wins ties
                run = max(run, t)
                latest.append(order[pos])
            }
            kLatest = latest
            // `past_cycles`: active readings with a value, by reset, grouped
            // by the half-window rule anchored on each group's first reset.
            var act = r.indices.filter { active[$0] && util[$0].isFinite }
            act = act.enumerated().sorted { a, b in (reset[a.element], a.offset) < (reset[b.element], b.offset) }.map(\.element)
            var cycles: [PastCycle] = []
            if let first = act.first {
                var groups: [[Int]] = [], cur = [first], anchor = reset[first]
                for j in act.dropFirst() {
                    if Double(reset[j] - anchor) >= Double(d) / 2 {
                        groups.append(cur); cur = [j]; anchor = reset[j]
                    } else { cur.append(j) }
                }
                groups.append(cur)
                for g in groups {
                    let idx = g.sorted()
                    cycles.append(Self.pastCycle(reset[idx[0]], idx, te: te, util: util, tk: tk, duration: d))
                }
            }
            pastCycles = cycles
            resets = cycles.map(\.reset)
            tkMaxs = cycles.map(\.tkMax)
            tkMins = cycles.map { c in c.idx.map { tk[$0] }.min()! }
        }

        static func pastCycle(_ r: Millis, _ idx: [Int], te: [Millis], util: [Double], tk: [Millis],
                              duration: Millis) -> PastCycle {
            let s = r - duration
            let cte = idx.map { te[$0] }, cut = idx.map { util[$0] }
            let at = KitMLData.phaseU.map { Double(s) + $0 * Double(duration) }
            return PastCycle(reset: r, start: s, idx: idx, tkMax: idx.map { tk[$0] }.max()!, final: cut[cut.count - 1],
                             phase: KitMLData.stepAt(cte, cut, at, start: s))
        }

        public var count: Int { te.count }

        /// `MeterIndex.latest_known`: event-order index of the newest
        /// reading known at `now`.
        public func latestKnown(_ now: Millis) -> Int? {
            let i = KitMLData.searchRight(kTk, now) - 1
            return i < 0 ? nil : kLatest[i]
        }

        /// `MeterIndex.cycle_at`.
        public func cycleAt(_ now: Millis) -> CycleNow? {
            guard let i = latestKnown(now), active[i], reset[i] > now, te[i] <= now else { return nil }
            let r = reset[i]
            return CycleNow(resetAt: r, start: r - duration, duration: duration, util: util[i], lastT: te[i])
        }

        /// `cycle_readings`: readings of the cycle resetting at `reset`
        /// known at asof with t_event ≤ upto (default asof).
        public func cycleReadings(_ r: Millis, asof: Millis, upto: Millis? = nil) -> [Int] {
            let u = upto ?? asof
            let lo = KitMLData.searchLeft(te, r - duration - KitMLData.hourMs)
            let hi = KitMLData.searchRight(te, min(u, r))
            guard lo < hi else { return [] }
            let half = Double(duration) / 2
            var out: [Int] = []
            for i in lo..<hi where active[i] && tk[i] <= asof && abs(Double(reset[i] - r)) < half && util[i].isFinite {
                out.append(i)
            }
            return out
        }

        /// `state_at`: the active cycle at asof (`reset` given: that cycle).
        public func stateAt(_ asof: Millis, reset r0: Millis? = nil) -> CycleState? {
            var r = r0
            if r == nil {
                guard let c = cycleAt(asof) else { return nil }
                r = c.resetAt
            }
            let idx = cycleReadings(r!, asof: asof)
            guard let last = idx.last else { return nil }
            return CycleState(reset: r!, start: r! - duration, duration: duration, used: util[last], lastTe: te[last],
                              te: idx.map { te[$0] }, util: idx.map { util[$0] })
        }

        /// `outcomes`: cycles that had reset by asof − margin, as known at
        /// asof (a reading unknown then is left out); the `last` most recent.
        public func outcomes(_ asof: Millis, margin: Millis = 10 * KitMLData.minMs, last: Int? = nil) -> [PastCycle] {
            let k = KitMLData.searchRight(resets, asof - margin)
            var sel: [Int] = []
            for j in 0..<k where tkMins[j] <= asof { sel.append(j) }
            if let last { sel = Array(sel.suffix(last)) }
            return sel.map { j in
                let c = pastCycles[j]
                if tkMaxs[j] <= asof { return c }
                return Self.pastCycle(c.reset, c.idx.filter { tk[$0] <= asof }, te: te, util: util, tk: tk,
                                      duration: duration)
            }
        }

        public func nOutcomes(_ asof: Millis, margin: Millis = 10 * KitMLData.minMs) -> Int {
            let k = KitMLData.searchRight(resets, asof - margin)
            var n = 0
            for j in 0..<k where tkMins[j] <= asof { n += 1 }
            return n
        }

        /// `level_at`: (util, elapsed fraction, t_event) of the newest
        /// reading known at asof while its cycle is active; (0, NaN, nil)
        /// otherwise.
        public func levelAt(_ asof: Millis) -> (util: Double, elapsed: Double, t: Millis?) {
            guard let c = cycleAt(asof) else { return (0, .nan, nil) }
            return (c.util, Double(asof - c.start) / Double(c.duration), c.lastT)
        }
    }

    /// `_step_at`: the meter as a step function of its readings (0 before
    /// the first after the cycle start), read at each `at`.
    static func stepAt(_ te: [Millis], _ util: [Double], _ at: [Double], start: Millis) -> [Double] {
        at.map { a in
            if a < Double(start) { return 0 }
            let i = KitMLData.searchRight(te, a) - 1
            return i >= 0 ? util[i] : 0
        }
    }

    /// `step_value`.
    @inline(__always) public static func stepValue(_ te: [Millis], _ util: [Double], _ at: Double, start: Millis) -> Double {
        if at < Double(start) { return 0 }
        let i = searchRight(te, at) - 1
        return i >= 0 ? util[i] : 0
    }

    @inline(__always) public static func stepValue(_ te: [Millis], _ util: [Double], _ at: Millis, start: Millis) -> Double {
        if at < start { return 0 }
        let i = searchRight(te, at) - 1
        return i >= 0 ? util[i] : 0
    }

    // MARK: - Everything together

    public struct MeterKey: Hashable, Sendable {
        public var account: String
        public var windowKind: String
        public var cap: String?
    }

    /// A history's rows as arrays (`AsOfData`). `now` is the history's cut;
    /// every lookup still takes its own `asof <= now`.
    public final class AsOfData: Sendable {
        public let now: Millis
        public let accounts: [String]
        /// Accounts with spend, sorted (the Python's `turns` dict order:
        /// every sum over accounts runs in it).
        public let turnAccounts: [String]
        public let turns: [String: TurnArrays]
        public let meters: [MeterKey: MeterSeries]
        let meterOrder: [MeterKey]

        public init(history h: ArenaHistory) {
            now = h.now
            var turns: [String: TurnArrays] = [:]
            for a in h.accounts.sorted() {
                let rows = h.spend(account: a)
                if !rows.isEmpty { turns[a] = TurnArrays(rows: rows, tzOffsetMin: h.tzOffsetMin) }
            }
            self.turns = turns
            turnAccounts = turns.keys.sorted()
            var meters: [MeterKey: MeterSeries] = [:]
            for a in h.accounts {
                for id in h.meters(account: a) where KitMLData.windowMs[id.windowKind] != nil {
                    let cap = id.windowKind == "weekly_scoped" ? id.scopeModel : nil
                    if id.windowKind == "weekly_scoped" && cap == nil { continue }
                    let rs = h.readings(id)
                    if rs.isEmpty { continue }
                    let key = MeterKey(account: a, windowKind: id.windowKind, cap: cap)
                    meters[key] = MeterSeries(readings: rs, account: a, windowKind: id.windowKind, cap: cap)
                }
            }
            self.meters = meters
            meterOrder = meters.keys.sorted { ($0.account, $0.windowKind, $0.cap ?? "") < ($1.account, $1.windowKind, $1.cap ?? "") }
            accounts = Array(Set(h.accounts).union(turns.keys).union(meters.keys.map(\.account))).sorted()
        }

        /// Built once per history cut and shared by every learned model on it.
        public static func of(_ h: ArenaHistory) -> AsOfData {
            h.memo.value("kitml.asof") { AsOfData(history: h) }
        }

        public func meter(_ account: String, _ windowKind: String, _ cap: String? = nil) -> MeterSeries? {
            meters[MeterKey(account: account, windowKind: windowKind, cap: windowKind == "weekly_scoped" ? cap : nil)]
        }

        /// `series_of`: every series of a kind (and cap), by (account, kind, cap).
        public func seriesOf(_ windowKind: String, _ cap: String? = nil) -> [MeterSeries] {
            meterOrder.filter { $0.windowKind == windowKind && (windowKind != "weekly_scoped" || cap == nil || $0.cap == cap) }
                .compactMap { meters[$0] }
        }
    }
}
