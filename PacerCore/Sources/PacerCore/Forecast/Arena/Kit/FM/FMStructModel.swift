import Foundation

/// `research/arena/kit/fm/struct_model.py` `StructModel`: structural meter
/// models (`models/struct-*`): spend paths from a child spend model, turned
/// into meter paths by the account's own spend-to-meter conversion.
///
/// For each meter target (account, window, the cycle's reset):
///
/// 1. `KitSpend.fitConversion`: meter points per API-equivalent dollar, per
///    model family, fitted on the 14 days before today (no peeking);
/// 2. the start: `KitSpend.liveValue` (the latest reading plus the converted
///    spend since it), else the latest reading of this cycle;
/// 3. ONE child call per forecast: hourly spend for each (account, family)
///    with points per dollar, to the latest reset. When the fit is weak
///    (`weak = "ratio"`), the rate is the account's total rise over its total
///    spend in the same 14 days, the same for every family (for a scoped
///    cap, that cap's family);
/// 4. meter path = start + Σ_family points_per_usd × cumulative spend, read
///    at the grid (spend spread evenly within each hour), capped at 100. With
///    `spend_by = "total"` (the default) the account's whole spend at one
///    rate (the families' rates weighted by last week's spend mix).
///
/// No conversion (nothing to fit) or a failed child: the meter now, flat.
///
/// The child is the arena's `ctx.model(child)` asked for `spend.hourly`
/// targets, which the contract's meter-only requests cannot carry; so the
/// child (`FMSpendModel`, from the registry spec the config names) is built
/// and asked here, on this model's own history, with its own seed. The
/// struct's spec lists the child's weights, so the runner never runs it
/// before they are on the Mac.
public final class FMStructModel: ArenaModel {
    static let fitDays: Millis = 14

    let ctx: ArenaContext
    let cfg: ArenaConfig
    var history: ArenaHistory?
    private var conv: [String: (KitSpend.Conversion?, [String?: Double])] = [:]

    public init(context: ArenaContext) throws {
        ctx = context
        cfg = context.config
    }

    public func fit(_ history: ArenaHistory) { self.history = history }

    /// `(fit, rates to use)`: refit once per day, as the app does (the fit
    /// only reads days before today's).
    func conversion(_ history: ArenaHistory, account: String, wk: String, cap: String?)
        -> (KitSpend.Conversion?, [String?: Double]) {
        let key = "\(account)|\(wk)|\(cap ?? "")|\(FMSeries.floorDiv(history.now, FMSeries.dayMs))"
        if let hit = conv[key] { return hit }
        let c = KitSpend.fitConversion(history, account: account, windowKind: wk, scopeModel: cap)
        var rates: [String?: Double] = [:]
        for (f, v) in c?.pointsPerUSD ?? [:] where v > 0 { rates[f] = v }
        if (c == nil || c!.weak) && cfg.string("weak", "ratio") == "ratio" {
            let r = ratio(history, account: account, wk: wk, cap: cap)
            if !r.isEmpty { rates = r }
        }
        conv[key] = (c, rates)
        return (c, rates)
    }

    /// Total rise / total spend over the fit's 14 days, per family.
    func ratio(_ history: ArenaHistory, account: String, wk: String, cap: String?) -> [String?: Double] {
        let hi = FMSeries.floorDiv(history.now, FMSeries.dayMs) * FMSeries.dayMs
        let lo = hi - Self.fitDays * FMSeries.dayMs
        let (s, k) = FMSeries.meterSeriesPrefix(history, account: account, windowKind: wk, scopeModel: cap, now: hi)
        guard k >= 2 else { return [:] }
        let rise = Self.interp(Double(hi), s.times, s.cum, k) - Self.interp(Double(lo), s.times, s.cum, k)
        // The turns known at the real now, in the 14 days before `hi` (`_AsOf`).
        let tf = FMSeries.TurnFrame(history, hours: Int(Self.fitDays) * 24, accounts: [account], now: hi)
        let fams: [String]
        if let c = cap?.lowercased(), KitSpend.families.contains(c) { fams = [c] }
        else { let have = Set(tf.families([account])); fams = KitSpend.families.filter { have.contains($0) } }
        let spend = fams.reduce(0.0) { $0 + tf.hourly([account], family: $1).reduce(0, +) }
        guard rise > 0, spend > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: fams.map { (Optional($0), rise / spend) })
    }

    /// `np.interp(x, times[:k], cum[:k])`, without copying either.
    static func interp(_ x: Double, _ times: [Millis], _ ys: [Double], _ k: Int) -> Double {
        if x <= Double(times[0]) { return ys[0] }
        if x >= Double(times[k - 1]) { return ys[k - 1] }
        var lo = 0, hi = k - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if Double(times[mid]) <= x { lo = mid } else { hi = mid } }
        let span = Double(times[hi] - times[lo])
        return span == 0 ? ys[lo] : ys[lo] + (x - Double(times[lo])) / span * (ys[hi] - ys[lo])
    }

    struct Plan {
        let tr: ArenaTargetRequest
        let start: Double
        let rates: [String?: Double]
        let hours: Int
    }

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let history else { throw ArenaError.invalid("forecast before fit") }
        let now = request.now
        var plans: [Plan] = []
        var need: [NeedKey: Int] = [:]
        for tr in request.targets {
            guard let wk = FMMeterModel.windowFor[tr.target] else { continue }
            try ctx.checkCancelled()
            let acct = tr.accounts[0]
            let cap = tr.target == .meterScoped ? tr.cap : nil
            let (s, k) = FMSeries.meterSeriesPrefix(history, account: acct, windowKind: wk, scopeModel: cap, now: now)
            let used = tr.resetAt.flatMap { s.usedNow($0, count: k) } ?? s.lastActiveUtil(count: k) ?? 0
            let (c, fitted) = conversion(history, account: acct, wk: wk, cap: cap)
            var rates = fitted
            var start: Double?
            if c != nil && cfg.string("start", "live") == "live" {
                start = KitSpend.liveValue(history, account: acct, windowKind: wk, scopeModel: cap)
            }
            let st = start.map { max($0, used) } ?? used
            let hours = max(1, Int((tr.grid.last! - now + FMSeries.hourMs - 1) / FMSeries.hourMs))
            // One family only (a scoped cap counts its own family): keep it by family.
            if rates.count > 1 && cfg.string("spend_by", "total") == "total" {
                rates = [nil: blend(history, account: acct, rates: rates)]
            }
            for f in rates.keys { need[NeedKey(account: acct, family: f)] = max(need[NeedKey(account: acct, family: f)] ?? 0, hours) }
            plans.append(Plan(tr: tr, start: st, rates: rates, hours: hours))
        }
        let spend = need.isEmpty ? [:] : child(history, now: now, need: need)
        var out: [String: ArenaTargetForecast] = [:]
        for p in plans { out[p.tr.key] = meter(now: now, p, spend: spend) }
        return ArenaForecast(byKey: out)
    }

    /// One rate for the account's total spend: the families' rates weighted
    /// by their share of its spend over the last week.
    func blend(_ history: ArenaHistory, account: String, rates: [String?: Double]) -> Double {
        let tf = FMSeries.TurnFrame(history, hours: 7 * 24, accounts: [account])
        var w: [String?: Double] = [:]
        for f in rates.keys { w[f] = tf.hourly([account], family: f).reduce(0, +) }
        let tot = w.values.reduce(0, +)
        if tot <= 0 { return rates.values.reduce(0, +) / Double(rates.count) }
        // The Python sums in the dict's (fit) order; the families' order here.
        return Self.ordered(rates.keys).reduce(0.0) { $0 + rates[$1]! * w[$1]! } / tot
    }

    struct NeedKey: Hashable { let account: String; let family: String? }

    static func key(_ acct: String, _ fam: String?) -> String { "spend.hourly:\(acct)" + (fam.map { ":\($0)" } ?? "") }

    /// Families in the arena's order, nil (the total) first.
    static func ordered<S: Sequence>(_ fams: S) -> [String?] where S.Element == String? {
        fams.sorted { a, b in
            (a.map { KitSpend.families.firstIndex(of: $0) ?? 99 } ?? -1, a ?? "")
                < (b.map { KitSpend.families.firstIndex(of: $0) ?? 99 } ?? -1, b ?? "")
        }
    }

    /// The child's paths per (account, family); empty when it fails (the
    /// meter is then flat, and the failure logged, as in the arena).
    func child(_ history: ArenaHistory, now: Millis, need: [NeedKey: Int]) -> [NeedKey: [[Double]]] {
        let name = cfg.string("child", "")
        do {
            guard let spec = ctx.runner.registry[name] else { throw ArenaError.unknownModel(name) }
            let model = try FMSpendModel(config: spec.config, services: ctx.services,
                                         seed: ArenaRunner.deriveSeed(ctx.seed, name, now))
            model.fit(history)
            let nPaths = cfg.int("child_paths", 200)
            let sortedNeed = need.sorted { ($0.key.account, $0.key.family ?? "") < ($1.key.account, $1.key.family ?? "") }
            let trs = sortedNeed.map { kv in
                FMSpendModel.HourlyTarget(key: Self.key(kv.key.account, kv.key.family), accounts: [kv.key.account],
                                          family: kv.key.family,
                                          grid: (1...kv.value).map { now + FMSeries.hourMs * Millis($0) }, nPaths: nPaths)
            }
            let fc = try model.hourly(trs, now: now)
            var out: [NeedKey: [[Double]]] = [:]
            for k in need.keys { if let p = fc[Self.key(k.account, k.family)] { out[k] = p } }
            return out
        } catch {
            ctx.log("child \(name) failed: \(error)")
            return [:]
        }
    }

    func meter(now: Millis, _ p: Plan, spend: [NeedKey: [[Double]]]) -> ArenaTargetForecast {
        let grid = p.tr.grid
        let acct = p.tr.accounts[0]
        let fams = Self.ordered(p.rates.keys).compactMap { f in spend[NeedKey(account: acct, family: f)].map { (f, $0) } }
        guard !fams.isEmpty, p.start < 100 else { return .point(grid.map { _ in min(p.start, 100) }) }
        let n = min(fams.map(\.1.count).min()!, p.tr.nPaths)
        let tRel = (0...p.hours).map { Double(FMSeries.hourMs) * Double($0) }
        let gRel = grid.map { Double($0 - now) }
        var total = [[Double]](repeating: [Double](repeating: 0, count: grid.count), count: n)
        let comonotone = cfg.string("family_dependence", "comonotone") == "comonotone"
        for (fam, paths) in fams {
            var pp = paths.map { Array($0.prefix(p.hours)).map { max($0, 0) } }
            if comonotone {
                // Paired by rank: a heavy hour is heavy for every family.
                let sums = pp.map { $0.reduce(0, +) }
                pp = pp.indices.sorted { sums[$0] < sums[$1] }.map { pp[$0] }
            }
            // `np.linspace(0, len-1, n).round()`: n paths spread evenly over them.
            let m = pp.count
            pp = (0..<n).map { i in
                let x = n == 1 ? 0 : (i == n - 1 ? Double(m - 1) : Double(i) * (Double(m - 1) / Double(n - 1)))
                return pp[Int(x.rounded(.toNearestOrEven))]
            }
            let rate = p.rates[fam]!
            for i in 0..<n {
                var cum = [0.0]
                cum.reserveCapacity(p.hours + 1)
                for x in pp[i] { cum.append(cum.last! + x) }
                while cum.count < p.hours + 1 { cum.append(cum.last!) }
                let at = FMPaths.interpTimes(tRel, gRel, cum.map { [$0] })
                for j in 0..<grid.count { total[i][j] += rate * at[j][0] }
            }
        }
        if comonotone { FMPaths.shuffle(&total, rng: &ctx.rng) }
        return ArenaTargetForecast(paths: FMPaths.monotoneMeter(total.map { $0.map { p.start + $0 } }, floor: p.start))
    }
}
