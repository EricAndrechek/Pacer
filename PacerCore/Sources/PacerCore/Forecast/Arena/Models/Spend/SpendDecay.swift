import Foundation

/// `models/spend-decay-30m/model.py` (the same code as `-1h`, `-6h`, `-1d`;
/// only `model.toml` differs, transcribed in `SpendModels.swift`).
///
/// Recent converted burn, fading: the lab's best five-hour candidates
/// (tokc-decay / tokm-decay). At `now`, for one meter (account, window, cap):
///
///     now_value = latest reading + k · spend since it
///     burn      = k · spend over the last `lookback` (at most the cycle so far) / that time
///     ratio     = clip(latest reading / (k · spend from the cycle's start to that reading), 0.25, 4)
///     value(ℓ)  = now_value + burn · ratio · τ · (1 − e^(−ℓ/τ))       ℓ = time ahead
///
/// kept between the latest reading and 100. `k` is the spend-to-meter
/// conversion (`KitSpend.fitDetails`: points per dollar per model family,
/// refit daily on the 14 days before the day; a weak fit falls back to one
/// pooled factor). τ is learned walk-forward per account and half of the
/// window from past cycles cut at 5 %, 10 %, … 95 %; the spread comes from
/// the same cuts' errors at the same phase.
///
/// The Python draws its paths (`rng`); this port answers with the exact
/// quantiles of the distribution those draws sample (`KitDetQ.spendDecay`,
/// the arena's `kit/detq.py`), so it reproduces the reference to float
/// precision instead of within Monte-Carlo error.
public final class SpendDecayModel: ArenaModel {
    static let minMs: Millis = 60_000
    public static let tausH: [Double] = [0.5, 1, 2, 4, 8, 16, 48]
    /// `np.round(np.arange(0.05, 0.951, 0.05), 2)`: where past cycles are cut.
    public static let phases: [Double] = (1...19).map { Double($0 * 5) / 100 }
    /// `np.linspace(0.05, 1.0, 20)`, transcribed bit for bit (numpy's
    /// `start + i · step` leaves a few of them an ulp off the decimal).
    public static let fracs: [Double] = [
        0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.39999999999999997, 0.44999999999999996, 0.49999999999999994,
        0.5499999999999999, 0.6, 0.65, 0.7, 0.75, 0.7999999999999999, 0.85, 0.9, 0.95, 1.0,
    ]
    static let minCases = 16
    static let minSpreadCases = 8

    public let lookback: Millis
    public let maxDays: Int
    public let defaultTau: [String: Double]
    public let phaseBand: Double
    let ctx: ArenaContext
    public private(set) var history: ArenaHistory?
    private var cases: [String: CaseTable?] = [:]

    public init(context: ArenaContext) {
        let cfg = context.config
        lookback = Millis(cfg.int("lookback_min", 30)) * Self.minMs
        maxDays = cfg.int("case_days", 60)
        let tauTable = cfg.table("default_tau_h")
        defaultTau = tauTable.values.compactMapValues(\.double)
        phaseBand = cfg.double("phase_band", 0.10)
        ctx = context
    }

    public func fit(_ history: ArenaHistory) {
        self.history = history
        cases.removeAll()
    }

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets {
            try ctx.checkCancelled()
            out[tr.key] = meter(tr)
        }
        return ArenaForecast(byKey: out)
    }

    /// `_meter`, answering with exact quantiles at `KitDetQ.forecastLevels`.
    func meter(_ tr: ArenaTargetRequest) -> ArenaTargetForecast {
        let p = parts(tr)
        return KitDetQ.spendDecayForecast(p, gridCount: tr.grid.count)
    }

    /// `kit/detq.spend_decay_parts`: everything `_meter` computes before it
    /// draws, as it computes it.
    public func parts(_ tr: ArenaTargetRequest) -> KitDetQ.SpendDecayParts {
        let h = history!
        let m = KitBaselines.meterNow(h, tr)
        let acct = tr.accounts[0]
        let dur = KitSpend.windowMs(m.windowKind)
        var out = KitDetQ.SpendDecayParts(kind: m.windowKind, latest: m.latest, latestT: m.latestT, start: m.start,
                                          reset: m.reset)
        guard let d = KitSpend.fitDetails(h, account: acct, windowKind: m.windowKind, scopeModel: m.scopeModel) else {
            out.mode = .flat
            return out
        }
        let k = d.rates
        let st = Self.state(h, acct, k, start: m.start, reset: m.reset, tLast: m.latestT, used: m.latest, now: h.now,
                            lookback: lookback)
        let uNow = Double(h.now - m.start) / Double(dur)
        let cases = caseTable(acct, m.windowKind, m.scopeModel)
        let weekly = m.windowKind != "five_hour"
        let tauI = pickTau(cases, acct, half: uNow >= 0.5, weekly: weekly, kind: m.windowKind)
        let tau = Self.tausH[tauI] * 3_600_000
        let lead = tr.grid.map { Double($0 - h.now) }
        let centre = Self.path(st, tau, lead)
        let pick = spreadCases(cases, acct, uNow: uNow, active: st.burn > 0)
        out.rates = k; out.weak = d.conversion.weak; out.r2 = d.conversion.r2; out.state = st; out.uNow = uNow
        out.tauH = Self.tausH[tauI]; out.centre = centre; out.nCases = cases?.count ?? 0
        guard let pick, let cases else {
            out.mode = .lognormal
            return out
        }
        let left = Double(max(m.reset - h.now, 1))
        let f = lead.map { min(max($0 / left, 0), 1) }
        let xs = [0.0] + Self.fracs
        out.errors = pick.map { i in
            let row = [0.0] + (0..<Self.fracs.count).map { j in cases.truth[i][j] - cases.centre[i][tauI][j] }
            return f.map { KitDetQ.npInterp($0, xs: xs, ys: row) }
        }
        out.picked = pick.count
        out.mode = .cases
        return out
    }

    /// `_pick_tau`: the τ whose error at reset was smallest over the past
    /// cuts of the same account and half (the median on the five-hour
    /// window, the mean on weekly ones, as in the lab), across every visible
    /// account when the account has fewer than 16; else the default.
    func pickTau(_ cases: CaseTable?, _ acct: String, half: Bool, weekly: Bool, kind: String) -> Int {
        if let cases {
            let same = cases.half.map { $0 == half }
            let ownSame = (0..<cases.count).map { same[$0] && cases.account[$0] == acct }
            for m in [ownSame, same] where m.filter({ $0 }).count >= Self.minCases {
                let rows = (0..<cases.count).filter { m[$0] }
                let score: [Double] = (0..<Self.tausH.count).map { t in
                    let col = rows.map { cases.ae[$0][t] }.filter { !$0.isNaN }
                    if col.isEmpty { return .nan }
                    // np.nanmean down axis 0 adds row by row; np.nanmedian
                    // is the middle (mean of the two middle) value.
                    return weekly ? col.reduce(0, +) / Double(col.count) : KitDetQ.median(col)
                }
                return KitDetQ.nanArgmin(score)
            }
        }
        let def = defaultTau[kind] ?? (kind == "five_hour" ? 2.0 : 16.0)
        var best = 0
        for (i, t) in Self.tausH.enumerated() where abs(t - def) < abs(Self.tausH[best] - def) { best = i }
        return best
    }

    /// `_spread_cases`: the past cuts whose errors make the paths, by these
    /// filters in order, the first holding 16: near ∧ own ∧ same burn; near
    /// ∧ same burn; near ∧ own; near; same half ∧ same burn; same half.
    func spreadCases(_ cases: CaseTable?, _ acct: String, uNow: Double, active: Bool) -> [Int]? {
        guard let cases else { return nil }
        let n = cases.count
        let near = (0..<n).map { abs(cases.phase[$0] - uNow) <= phaseBand + 1e-9 }
        let half = (0..<n).map { cases.half[$0] == (uNow >= 0.5) }
        let own = (0..<n).map { cases.account[$0] == acct }
        let act = (0..<n).map { cases.active[$0] == active }
        let masks: [[Bool]] = [
            (0..<n).map { near[$0] && own[$0] && act[$0] }, (0..<n).map { near[$0] && act[$0] },
            (0..<n).map { near[$0] && own[$0] }, near, (0..<n).map { half[$0] && act[$0] }, half,
        ]
        for m in masks where m.filter({ $0 }).count >= Self.minCases { return (0..<n).filter { m[$0] } }
        let m = near.filter { $0 }.count >= Self.minSpreadCases ? near : half
        return m.filter { $0 }.count >= Self.minSpreadCases ? (0..<n).filter { m[$0] } : nil
    }

    /// `_case_table`: past cuts of every visible account's cycles of this
    /// meter (the account first). The Python rebuilds it when a new cycle
    /// has reset or a new day's conversion applies; a Swift instance lives
    /// for one forecast, so it is built once per (account, meter) per
    /// instance, and shared across instances on one cut through the
    /// history's memo.
    func caseTable(_ acct: String, _ kind: String, _ cap: String?) -> CaseTable? {
        let key = "\(acct)|\(kind)|\(cap ?? "")"
        if let hit = cases[key] { return hit }
        let h = history!
        let accounts = [acct] + h.accounts.filter { $0 != acct }
        let table = h.memo.value("spend-decay.cases|\(key)|\(lookback)|\(maxDays)|\(accounts.joined(separator: "+"))") {
            let parts = accounts.compactMap { Self.buildCases(h, $0, kind, cap, lookback: lookback, maxDays: maxDays) }
            guard var t = parts.first else { return KitBox<CaseTable?>(nil) }
            for p in parts.dropFirst() { t.append(p) }
            return KitBox<CaseTable?>(t)
        }.value
        cases[key] = table
        return table
    }

    // MARK: - The forecast for one moment, and the past cuts it learns from

    /// `state`'s dict: now_value, burn (points per ms), ratio and the reading.
    public struct State: Sendable, Equatable {
        public let nowValue: Double
        public let burn: Double
        public let ratio: Double
        public let used: Double
    }

    /// `state`: for one cut.
    public static func state(_ h: ArenaHistory, _ acct: String, _ k: [Double], start: Millis, reset: Millis,
                             tLast: Millis, used: Double, now: Millis, lookback: Millis) -> State {
        let led = KitSpend.ledger(h, account: acct)
        func conv(_ t0: Millis, _ t1: Millis) -> Double { led.converted(t0, t1, k) }
        let nowValue = min(100.0, used + conv(tLast, now))
        let cyc = conv(start, tLast)
        let ratio = cyc > 1 ? min(max(used / cyc, 0.25), 4.0) : 1.0
        let span = min(lookback, now - start)
        let burn = span > 0 ? conv(now - span, now) / Double(span) : 0.0
        return State(nowValue: nowValue, burn: burn, ratio: ratio, used: used)
    }

    /// `path`: the centre at each lead (ms), kept in [used, 100].
    public static func path(_ st: State, _ tau: Double, _ lead: [Double]) -> [Double] {
        let a = st.burn * st.ratio * tau
        return lead.map { l in min(max(st.nowValue + a * (1.0 - exp(-l / tau)), st.used), 100.0) }
    }

    /// The table `build_cases` returns: one row per past cut.
    public struct CaseTable: Sendable {
        public var phase: [Double] = []
        public var half: [Bool] = []
        public var account: [String] = []
        public var active: [Bool] = []
        /// `[cuts][taus]`: |centre at reset − final|.
        public var ae: [[Double]] = []
        /// `[cuts][taus][fracs]`.
        public var centre: [[[Double]]] = []
        /// `[cuts][fracs]`.
        public var truth: [[Double]] = []
        public var count: Int { phase.count }

        mutating func append(_ o: CaseTable) {
            phase += o.phase; half += o.half; account += o.account; active += o.active
            ae += o.ae; centre += o.centre; truth += o.truth
        }
    }

    /// `build_cases`: every past cut of one account's cycles: phase, half,
    /// account, whether it was burning, the forecast's error at reset for
    /// each τ, and the forecast and the truth at FRACS of the time left.
    /// Each cut uses the conversion of its own day (no peeking past it) and
    /// only readings of its own cycle.
    public static func buildCases(_ h: ArenaHistory, _ acct: String, _ kind: String, _ cap: String?,
                                  lookback: Millis, maxDays: Int) -> CaseTable? {
        let cycles = KitSpend.pastCycles(h, account: acct, windowKind: kind, scopeModel: cap)
        if cycles.isEmpty { return nil }
        let dur = KitSpend.windowMs(kind)
        let lo = h.now - Millis(maxDays) * KitSpend.dayMs
        let completeBy = max(Double(15 * minMs), 0.05 * Double(dur))
        let today = KitSpend.localDayStart(h, account: acct)
        var rates: [Millis: [Double]?] = [:]
        var rows = CaseTable()
        let taus = tausH.map { $0 * 3_600_000 }
        for c in cycles {
            guard c.reset >= lo, let lastT = c.t.last, Double(lastT) >= Double(c.reset) - completeBy else {
                continue                      // too old, or its end was not seen
            }
            let final = c.util[c.util.count - 1]
            for u in phases {
                let cut = Millis(Double(c.start) + u * Double(dur))
                let j = upperBound(c.t, cut) - 1
                if j < 0 || cut - c.t[j] > KitSpend.hourMs { continue }  // no fresh reading of this cycle at the cut
                let day = min(KitSpend.localDayStart(h, account: acct, at: cut), today)
                let k: [Double]?
                if let hit = rates[day] { k = hit } else {
                    k = KitSpend.fitOnDay(h, account: acct, windowKind: kind, scopeModel: cap, dayStart: day)?.rates
                    rates[day] = .some(k)
                }
                guard let k else { continue }
                let used = c.util[j]
                let st = state(h, acct, k, start: c.start, reset: c.reset, tLast: c.t[j], used: used, now: cut,
                               lookback: lookback)
                let left = Double(c.reset - cut)
                let leads = fracs.map { $0 * left }
                var truth = leads.map { l -> Double in
                    // np.searchsorted(c.t, cut + FRACS·left, "right") − 1,
                    // comparing the int64 times as float64.
                    let at = Double(cut) + l
                    let idx = upperBoundD(c.t, at) - 1
                    return idx >= 0 ? c.util[idx] : used
                }
                truth[truth.count - 1] = final
                let cen = taus.map { path(st, $0, leads) }
                rows.phase.append(u)
                rows.half.append(u >= 0.5)
                rows.account.append(acct)
                rows.active.append(st.burn > 0)
                rows.ae.append(cen.map { abs($0[$0.count - 1] - final) })
                rows.centre.append(cen)
                rows.truth.append(truth)
            }
        }
        return rows.count == 0 ? nil : rows
    }

    /// `searchsorted(xs, x, "right")`.
    static func upperBound(_ xs: [Millis], _ x: Millis) -> Int {
        var lo = 0, hi = xs.count
        while lo < hi { let mid = (lo + hi) >> 1; if xs[mid] <= x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    static func upperBoundD(_ xs: [Millis], _ x: Double) -> Int {
        var lo = 0, hi = xs.count
        while lo < hi { let mid = (lo + hi) >> 1; if Double(xs[mid]) <= x { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}
