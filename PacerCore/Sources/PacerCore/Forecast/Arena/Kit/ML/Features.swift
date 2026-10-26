import Foundation

// `research/arena/kit/ml/features.py`, in Swift: the as-of features of one
// meter at a moment `asof`, from rows known at `asof` only. Slow aggregates
// (the hour-of-week activity profile, the spend-to-meter ratio, pooled
// outcomes, the account count) are computed as of the start of `asof`'s UTC
// day or hour and cached there, as in the Python.
//
// Same groups, names, order and arithmetic as the Python (so the matrix is
// equal to its bit, `MLFeatureParityTests`), with one difference in input:
// Pacer's history has no sessions, subagent flags or human prompts. The
// Python reads a turn without a session as session 0 and without a flag as
// a main-agent turn, and a history without prompts as none; that is what is
// computed here (`sess_*` is 1 when any turn is in the window, `sub_share_60m`
// and `prompts_*` are 0). The model is trained on the user's own history,
// so a feature that is constant there is simply never split on.

public enum KitMLFeatures {
    public static let weekH = 168.0
    /// 1970-01-01 was a Thursday: shifting by 72 hours puts Monday 00:00 at slot 0.
    static let mondayShiftH = 72.0

    public typealias M = KitMLData
    static let minMs = M.minMs, hourMs = M.hourMs, dayMs = M.dayMs

    public static func lookbacks(_ kind: String) -> [Millis] {
        kind == "five_hour" ? [15 * minMs, 30 * minMs, hourMs, 2 * hourMs] : [3 * hourMs, 12 * hourMs, dayMs, 3 * dayMs]
    }

    public static func spendLookbacks(_ kind: String) -> [Millis] {
        kind == "five_hour" ? [15 * minMs, hourMs, 3 * hourMs] : [3 * hourMs, 12 * hourMs, 2 * dayMs]
    }

    public static func other(_ kind: String) -> String { kind == "seven_day" ? "five_hour" : "seven_day" }
    static func convCycles(_ kind: String) -> Int { kind == "five_hour" ? 12 : 3 }
    static let convMaxAge = 28 * M.dayMs
    static let profileDays: Millis = 28
    static let pastN = 8
    static let poolN = 40

    public static let featureNames: [String] = [
        // phase and the meter now
        "elapsed_frac", "remaining_h", "used_now", "headroom", "n_read", "since_last_h",
        // burn from readings
        "rate_0", "rate_1", "rate_2", "rate_3", "rate_cycle", "accel", "proj_cycle", "proj_rate1",
        "traj_25", "traj_50", "traj_75", "flat_share",
        // spend and its conversion
        "spend_0", "spend_1", "spend_2", "spend_cycle", "spend_since_read",
        "conv", "conv_rate_0", "conv_rate_1", "nowcast_gap", "conv_resid", "conv_proj",
        // hour-of-week profile
        "exp_spend_rem", "exp_active_rem", "exp_pts_rem", "act_frac_left", "active_now", "exp_spend_next_h",
        "hod_sin", "hod_cos", "dow_sin", "dow_cos",
        // previous cycles
        "n_past", "past_final_mean", "past_final_last", "past_hit", "past_phase_rise", "past_phase_rise_max",
        "pool_final_mean", "pool_phase_rise", "pool_hit",
        // cross-window
        "x_level", "x_elapsed", "x_rate",
        // activity
        "sess_15m", "sess_60m", "turns_15m", "sub_share_60m", "prompts_15m", "prompts_60m", "idle_h",
        // accounts
        "n_acct_7d", "n_acct_1h", "others_spend_1h",
        // family mix of the last 6 hours' spend
        "mix_fable", "mix_opus", "mix_sonnet", "mix_haiku",
    ]
    public static let leadNames = ["lead_frac", "lead_h", "lead_rate_proj", "lead_conv_proj", "lead_exp_pts",
                                   "lead_exp_active"]
    public static var nFeatures: Int { featureNames.count }

    /// Feature indices (`F[...]`), checked against `featureNames` in tests.
    public enum F {
        public static let elapsedFrac = 0, remainingH = 1, usedNow = 2, headroom = 3, nRead = 4, sinceLastH = 5
        public static let rate0 = 6, rateCycle = 10, accel = 11, projCycle = 12, projRate1 = 13
        public static let traj25 = 14, traj50 = 15, traj75 = 16, flatShare = 17
        public static let spend0 = 18, spendCycle = 21, spendSinceRead = 22
        public static let conv = 23, convRate0 = 24, convRate1 = 25, nowcastGap = 26, convResid = 27, convProj = 28
        public static let expSpendRem = 29, expActiveRem = 30, expPtsRem = 31, actFracLeft = 32, activeNow = 33
        public static let expSpendNextH = 34, hodSin = 35, hodCos = 36, dowSin = 37, dowCos = 38
        public static let nPast = 39, pastFinalMean = 40, pastFinalLast = 41, pastHit = 42, pastPhaseRise = 43
        public static let pastPhaseRiseMax = 44, poolFinalMean = 45, poolPhaseRise = 46, poolHit = 47
        public static let xLevel = 48, xElapsed = 49, xRate = 50
        public static let sess15m = 51, sess60m = 52, turns15m = 53, subShare60m = 54, prompts15m = 55
        public static let prompts60m = 56, idleH = 57
        public static let nAcct7d = 58, nAcct1h = 59, othersSpend1h = 60
        public static let mixFable = 61
    }

    /// `_fin`: finite, else the fill.
    @inline(__always) static func fin(_ v: Double, _ fill: Double = 0) -> Double { v.isFinite ? v : fill }
    /// Python's `max(a, b)` / `min(a, b)` (the first unless the second is
    /// strictly beyond it: keeps −0.0 and NaN where Python keeps them).
    @inline(__always) static func pmax(_ a: Double, _ b: Double) -> Double { b > a ? b : a }
    @inline(__always) static func pmin(_ a: Double, _ b: Double) -> Double { b < a ? b : a }

    /// An account's hour-of-week profile as of a moment (`Profile`): mean
    /// USD per local hour slot, and the share of weeks with any turn in it.
    public struct Profile: Sendable {
        public let usd: [Double]
        public let active: [Double]
        public let tzMs: Millis
        let cu: [Double], ca: [Double]

        init(usd: [Double], active: [Double], tzMin: Double) {
            self.usd = usd; self.active = active
            tzMs = Millis((fin(tzMin) * Double(minMs)).rounded(.toNearestOrEven))
            var c = [0.0], s = 0.0
            for x in usd { s += x; c.append(s) }
            cu = c
            c = [0.0]; s = 0
            for x in active { s += x; c.append(s) }
            ca = c
        }

        @inline(__always) func hours(_ t: Double) -> Double { (t + Double(tzMs)) / Double(hourMs) - mondayShiftH }

        @inline(__always) func cum(_ x: Double, _ p: [Double], _ c: [Double]) -> Double {
            let (w, r) = M.pyDivmod(x, weekH)
            let k = min(Int(r), 167)
            return w * c[168] + c[k] + (r - Double(k)) * p[k]
        }

        /// (expected USD, expected active hours) over [t0, t1].
        public func integral(_ t0: Double, _ t1: Double) -> (Double, Double) {
            if t1 <= t0 { return (0, 0) }
            let a = hours(t0), b = hours(t1)
            return (cum(b, usd, cu) - cum(a, usd, cu), cum(b, active, ca) - cum(a, active, ca))
        }

        public func slot(_ t: Double) -> Int { Int(M.pyMod(hours(t), weekH)) }
    }

    /// Features for one window kind over an `AsOfData` (`FeatureBuilder`),
    /// with caches keyed by as-of buckets, so one builder serves the
    /// walk-forward rows and the live row. Single-threaded.
    public final class FeatureBuilder {
        public let data: M.AsOfData
        public let kind: String
        struct ProfileKey: Hashable { var account: String; var day: Millis; var fam: Int8? }
        struct ConvKey: Hashable { var account: String; var kind: String; var cap: String?; var day: Millis }
        struct PoolKey: Hashable { var hour: Millis; var cap: String? }
        var profiles: [ProfileKey: Profile] = [:]
        var convs: [ConvKey: Double] = [:]
        var convSums: [ConvKey: (Double, Double)] = [:]
        var pools: [PoolKey: (fin: [Double], phase: [[Double]])] = [:]
        var accts: [Millis: Double] = [:]

        public init(data: M.AsOfData, kind: String) { self.data = data; self.kind = kind }

        /// The hour-of-week profile of the account's spend (one family's,
        /// for a per-model cap) over the trailing weeks, as of asof's day.
        public func profile(_ account: String, _ asof: Millis, fam: Int8?) -> Profile {
            let day = asof - M.floorMod(asof, dayMs)
            let key = ProfileKey(account: account, day: day, fam: fam)
            if let p = profiles[key] { return p }
            var usd = [Double](repeating: 0, count: 168), act = [Double](repeating: 0, count: 168)
            var tz = Double.nan
            if let T = data.turns[account] {
                tz = T.latestTz(day)
                var idx = T.window(day - profileDays * dayMs, day, day)
                if let fam { idx = idx.filter { T.fam[$0] == fam } }
                if !idx.isEmpty {
                    let tzm = Millis((fin(tz) * Double(minMs)).rounded(.toNearestOrEven))
                    let weeks = Double(profileDays) / 7.0
                    var sums = [Double](repeating: 0, count: 168)
                    var seen = Set<Millis>(), firstSlots = [Int](repeating: 0, count: 168)
                    for i in idx {
                        let hours = M.floorDiv(T.te[i] + tzm, hourMs)
                        let slot = Int(M.floorMod(hours - 72, 168))
                        let c = T.cost[i]
                        sums[slot] += c.isNaN ? 0 : c
                        if seen.insert(hours).inserted { firstSlots[slot] += 1 }
                    }
                    usd = sums.map { $0 / weeks }
                    act = firstSlots.map { Double($0) / weeks }
                }
            }
            let p = Profile(usd: usd, active: act.map { min($0, 1.0) }, tzMin: tz)
            profiles[key] = p
            return p
        }

        /// Meter points per USD from the series' last completed cycles known
        /// at the start of asof's day (pooled over every series of the kind
        /// when the account's own spend is too thin). NaN when nothing fits.
        public func conversion(_ s: M.MeterSeries, _ asof: Millis) -> Double {
            let day = asof - M.floorMod(asof, dayMs)
            let key = ConvKey(account: s.account, kind: s.windowKind, cap: s.cap, day: day)
            if let c = convs[key] { return c }
            var (pts, usd) = conversionSums(s, day)
            if usd < 1.0 || pts <= 0 {
                pts = 0; usd = 0
                for o in data.seriesOf(kind, s.cap) {
                    let (p, u) = conversionSums(o, day)
                    pts = pts + p; usd = usd + u
                }
            }
            let rho = usd >= 1.0 && pts > 0 ? pts / usd : .nan
            convs[key] = rho
            return rho
        }

        func conversionSums(_ s: M.MeterSeries, _ day: Millis) -> (Double, Double) {
            let key = ConvKey(account: s.account, kind: s.windowKind, cap: s.cap, day: day)
            if let c = convSums[key] { return c }
            var pts = 0.0, usd = 0.0
            if let T = data.turns[s.account] {
                for c in s.outcomes(day, last: convCycles(s.windowKind)) {
                    if c.reset < day - convMaxAge { continue }
                    pts += c.final
                    usd += T.spend(c.start, c.reset, day, fam: M.capFamily(s.cap))
                }
            }
            convSums[key] = (pts, usd)
            return (pts, usd)
        }

        /// (finals, phase rows) of the last POOL_N completed cycles over
        /// every account of this kind, as of the start of asof's hour.
        public func pool(_ asof: Millis, cap: String?) -> (fin: [Double], phase: [[Double]]) {
            let hour = asof - M.floorMod(asof, hourMs)
            let key = PoolKey(hour: hour, cap: cap)
            if let p = pools[key] { return p }
            var cyc: [M.PastCycle] = []
            for s in data.seriesOf(kind, cap) { cyc += s.outcomes(hour, last: poolN) }
            cyc = cyc.enumerated().sorted { ($0.element.reset, $0.offset) < ($1.element.reset, $1.offset) }.map(\.element)
            cyc = Array(cyc.suffix(poolN))
            let p = (cyc.map(\.final), cyc.map(\.phase))
            pools[key] = p
            return p
        }

        public func accountsInUse(_ asof: Millis) -> Double {
            let day = asof - M.floorMod(asof, dayMs)
            if let a = accts[day] { return a }
            var n = 0
            for a in data.turnAccounts where !data.turns[a]!.window(day - 7 * dayMs, day, day).isEmpty { n += 1 }
            accts[day] = Double(n)
            return Double(n)
        }

        /// One row of `featureNames`, or nil when no cycle is in progress.
        public func row(_ series: M.MeterSeries, _ asof: Millis, reset: Millis? = nil, st st0: M.CycleState? = nil) -> [Double]? {
            guard let st = st0 ?? series.stateAt(asof, reset: reset) else { return nil }
            let acct = series.account
            let D = st.duration, R = st.reset, S = st.start
            let rem = max(R - asof, 0), el = max(asof - S, 1)
            let remH = Double(rem) / Double(hourMs), elH = Double(el) / Double(hourMs)
            let used = st.used
            let head = pmax(100.0 - used, 0.0)
            var v = [Double](repeating: 0, count: featureNames.count)
            v[F.elapsedFrac] = pmin(Double(el) / Double(D), 1.0)
            v[F.remainingH] = remH
            v[F.usedNow] = used
            v[F.headroom] = head
            v[F.nRead] = log1p(Double(st.te.count))
            v[F.sinceLastH] = Double(asof - st.lastTe) / Double(hourMs)
            var rates: [Double] = []
            let lbs = lookbacks(kind)
            for (i, L) in lbs.enumerated() {
                let v0 = M.stepValue(st.te, st.util, asof - L, start: S)
                rates.append(pmax(used - v0, 0.0) / (Double(L) / Double(hourMs)))
                v[F.rate0 + i] = rates[i]
            }
            v[F.rateCycle] = used / pmax(elH, 1.0 / 60.0)
            v[F.accel] = rates[0] - rates[2]
            v[F.projCycle] = pmin(v[F.rateCycle] * remH, head)
            v[F.projRate1] = pmin(rates[1] * remH, head)
            for (j, q) in [0.25, 0.5, 0.75].enumerated() {
                v[F.traj25 + j] = M.stepValue(st.te, st.util, Double(S) + q * Double(el), start: S)
            }
            let spanStart = asof - lbs[2]
            var spanUtil: [Double] = []
            for (i, t) in st.te.enumerated() where t >= spanStart { spanUtil.append(st.util[i]) }
            if spanUtil.count > 2 {
                var flat = 0
                for i in 1..<spanUtil.count where spanUtil[i] - spanUtil[i - 1] <= 0 { flat += 1 }
                v[F.flatShare] = Double(flat) / Double(spanUtil.count - 1)
            }

            let T = data.turns[acct]
            let fam = M.capFamily(series.cap)
            var spends: [Double] = []
            for (i, L) in spendLookbacks(kind).enumerated() {
                spends.append(T.map { $0.spend(asof - L, asof, asof, fam: fam) / (Double(L) / Double(hourMs)) } ?? 0.0)
                v[F.spend0 + i] = spends[i]
            }
            let sc = T?.spend(S, asof, asof, fam: fam) ?? 0.0
            let ss = T?.spend(st.lastTe, asof, asof, fam: fam) ?? 0.0
            v[F.spendCycle] = sc
            v[F.spendSinceRead] = ss
            let rho = conversion(series, asof)
            let rho0 = fin(rho)
            v[F.conv] = rho0
            v[F.convRate0] = spends[0] * rho0
            v[F.convRate1] = spends[1] * rho0
            v[F.nowcastGap] = pmin(ss * rho0, head)
            v[F.convResid] = rho.isFinite ? used - sc * rho0 : 0.0
            v[F.convProj] = pmin(spends[1] * rho0 * remH, head)

            let prof = profile(acct, asof, fam: fam)
            let (erUsd, erAct) = prof.integral(Double(asof), Double(R))
            let (_, eeAct) = prof.integral(Double(S), Double(asof))
            v[F.expSpendRem] = erUsd
            v[F.expActiveRem] = erAct
            v[F.expPtsRem] = pmin(erUsd * rho0, 100.0)
            v[F.actFracLeft] = erAct + eeAct > 1e-9 ? erAct / (erAct + eeAct) : Double(rem) / Double(D)
            let slot = prof.slot(Double(asof))
            v[F.activeNow] = prof.active[slot]
            v[F.expSpendNextH] = prof.integral(Double(asof), Double(asof + hourMs)).0
            let hod = Double(slot % 24) + Double(M.floorMod(asof + prof.tzMs, hourMs)) / Double(hourMs)
            let dow = Double(slot / 24)
            v[F.hodSin] = sin(2 * Double.pi * hod / 24); v[F.hodCos] = cos(2 * Double.pi * hod / 24)
            v[F.dowSin] = sin(2 * Double.pi * dow / 7); v[F.dowCos] = cos(2 * Double.pi * dow / 7)

            let u = pmin(Double(el) / Double(D), 1.0)
            v[F.nPast] = log1p(Double(series.nOutcomes(asof)))
            let last = series.outcomes(asof, last: pastN)
            if !last.isEmpty {
                let fins = last.map(\.final)
                let ph = last.map { M.npInterp(u, xs: M.phaseU, ys: $0.phase) }
                let rise = zip(fins, ph).map { pmax($0 - $1, 0) }
                v[F.pastFinalMean] = M.npMean(fins)
                v[F.pastFinalLast] = fins[fins.count - 1]
                v[F.pastHit] = Double(fins.filter { $0 >= 99 }.count) / Double(fins.count)
                v[F.pastPhaseRise] = M.npMean(rise)
                v[F.pastPhaseRiseMax] = rise.max()!
            }
            let (pfin, pph) = pool(asof, cap: series.cap)
            if !pfin.isEmpty {
                let col = pph.map { M.npInterp(u, xs: M.phaseU, ys: $0) }
                v[F.poolFinalMean] = M.npMean(pfin)
                v[F.poolPhaseRise] = M.npMean(zip(pfin, col).map { pmax($0 - $1, 0) })
                v[F.poolHit] = Double(pfin.filter { $0 >= 99 }.count) / Double(pfin.count)
            }

            if let o = data.meter(acct, other(kind)) {
                let lvl = o.levelAt(asof)
                v[F.xLevel] = lvl.util
                v[F.xElapsed] = fin(lvl.elapsed, -1.0)
                if let ost = o.stateAt(asof) {
                    let L = lookbacks(other(kind))[1]
                    let x = ost.used - M.stepValue(ost.te, ost.util, asof - L, start: ost.start)
                    v[F.xRate] = pmax(x, 0) / (Double(L) / Double(hourMs))
                }
            }

            if let T {
                let i15 = T.window(asof - 15 * minMs, asof, asof)
                let i60 = T.window(asof - hourMs, asof, asof)
                // No sessions in the app's history: every turn is session 0.
                v[F.sess15m] = i15.isEmpty ? 0 : 1
                v[F.sess60m] = i60.isEmpty ? 0 : 1
                v[F.turns15m] = log1p(Double(i15.reduce(0) { $0 + T.turns[$1] }))
                v[F.subShare60m] = 0
                let b = M.searchRight(T.te, asof)
                let lo = max(0, b - 2000)
                var lastKnown: Int?
                if lo < b { for i in stride(from: b - 1, through: lo, by: -1) where T.tk[i] <= asof { lastKnown = i; break } }
                v[F.idleH] = lastKnown.map { pmin(Double(asof - T.te[$0]) / Double(hourMs), 48.0) } ?? 48.0
                let i6 = T.window(asof - 6 * hourMs, asof, asof)
                if !i6.isEmpty {
                    let c6 = i6.map { T.cost[$0].isNaN ? 0 : T.cost[$0] }
                    let tot = M.npSum(c6)
                    if tot > 0 {
                        for f in 0..<4 {
                            var sel: [Double] = []
                            for (j, i) in i6.enumerated() where T.fam[i] == Int8(f) { sel.append(c6[j]) }
                            v[F.mixFable + f] = M.npSum(sel) / tot
                        }
                    }
                }
            } else {
                v[F.idleH] = 48.0
            }
            v[F.prompts15m] = 0
            v[F.prompts60m] = 0

            v[F.nAcct7d] = accountsInUse(asof)
            var n1 = 0, others = 0.0
            for a in data.turnAccounts {
                let Ta = data.turns[a]!
                let i = Ta.window(asof - hourMs, asof, asof)
                if !i.isEmpty {
                    n1 += 1
                    if a != acct { others += M.npSum(i.map { Ta.cost[$0].isNaN ? 0 : Ta.cost[$0] }) }
                }
            }
            v[F.nAcct1h] = Double(n1)
            v[F.othersSpend1h] = others
            // np.nan_to_num(v, nan=0, posinf=0, neginf=0)
            for i in v.indices where !v[i].isFinite { v[i] = 0 }
            return v
        }

        /// Per-lead features for leads `fracs` of the time left to `reset`
        /// (`lead_rows`): `[fracs.count][leadNames.count]`.
        public func leadRows(_ row: [Double], _ series: M.MeterSeries, _ asof: Millis, reset: Millis,
                             fracs: [Double]) -> [[Double]] {
            let prof = profile(series.account, asof, fam: M.capFamily(series.cap))
            let remH = Double(max(reset - asof, 0)) / Double(hourMs)
            let rho = row[F.conv]
            return fracs.map { f in
                let leadH = f * remH
                let (usd, act) = prof.integral(Double(asof), Double(asof) + leadH * Double(hourMs))
                return [f, leadH, row[F.rate0 + 1] * leadH, row[F.convRate1] * leadH, pmin(usd * rho, 100.0), act]
            }
        }
    }
}
