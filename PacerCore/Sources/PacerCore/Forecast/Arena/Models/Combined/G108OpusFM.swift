import Foundation

/// `research/arena/models/g1-08-opus-fm/model.py`, the meter targets:
/// Timestral-123M on the meter's cumulative burn, quantile-recalibrated per
/// lead from self-backtests on the history (`MeterFM`, `FMCal`).
///
/// Its other targets (spend.hourly, tokens.hourly through Timestral-28M,
/// split.accounts, cycle.next_start) have no reader in the app and are not
/// ported, and neither is `meter_blend` (empty in its config: a blend with a
/// child lost to the FM alone).
public final class G108OpusFM: ArenaModel {
    let ctx: ArenaContext
    let cfg: ArenaConfig
    var history: ArenaHistory?
    let meters: MeterFM

    public init(context: ArenaContext) throws {
        ctx = context
        cfg = context.config
        if let blend = cfg["meter_blend"]?.table, !blend.values.isEmpty {
            throw ArenaError.invalid("g1-08 meter_blend is not ported")
        }
        meters = try MeterFM(cfg: cfg.table("meter"), context: context)
    }

    public func fit(_ history: ArenaHistory) { self.history = history }

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let history else { throw ArenaError.invalid("forecast before fit") }
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets where MeterFM.windowFor[tr.target] != nil {
            try ctx.checkCancelled()
            out[tr.key] = try meters.forecast(history, now: request.now, tr)
        }
        return ArenaForecast(byKey: out)
    }
}

/// `research/arena/models/g2-06-opus-fmgate2/model.py`, the meter targets:
/// g1-08-opus-fm's recalibrated Timestral meters run in process (its code,
/// not a child: the Python imports it so its self-backtests are not redone
/// per checkpoint; here they are shared with g1-08 on the same history cut
/// and memoized by content across cuts), then per window (`gate`): the
/// paths' spread shrunk around their median, gated by account state (an idle
/// or limit-blocked account's meter held at its reading until a resume time
/// drawn from its own past idle stretches), rounded to whole points.
///
/// Not ported: its next-start (g1-10-fable-analog, pushed past limit
/// blocks), split (g1-09-opus-split) and hourly spend parts.
public final class G206OpusFMGate2: ArenaModel {
    let ctx: ArenaContext
    let cfg: ArenaConfig
    var history: ArenaHistory?
    let fm: MeterFM
    private var book: Gate.TurnBook?

    public init(context: ArenaContext) throws {
        ctx = context
        cfg = context.config
        fm = try MeterFM(cfg: cfg.table("g108").table("meter"), context: context)
    }

    public func fit(_ history: ArenaHistory) {
        self.history = history
        book = nil
    }

    public func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let history else { throw ArenaError.invalid("forecast before fit") }
        let now = request.now
        let trs = request.targets.filter { MeterFM.windowFor[$0.target] != nil }
        var out: [String: ArenaTargetForecast] = [:]
        // The FM part answers every meter target or none: a failure in any
        // falls back to the flat meter for all (the Python's try around
        // `part.forecast`). Cancellation is not a failure.
        do {
            for tr in trs {
                try ctx.checkCancelled()
                out[tr.key] = try fm.forecast(history, now: now, tr)
            }
        } catch ArenaError.cancelled {
            throw ArenaError.cancelled
        } catch {
            ctx.log("fm failed: \(error)")
            out = [:]
        }
        for tr in trs {
            guard let tf = out[tr.key] else {
                out[tr.key] = KitBaselines.meterFlat(history, tr)
                continue
            }
            do {
                out[tr.key] = try meterPost(tr, tf, now: now, history: history)
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                // The Python keeps the FM's paths as they were.
                ctx.log("gate \(tr.key) failed: \(error)")
            }
        }
        return ArenaForecast(byKey: out)
    }

    /// The FM's answer as paths (`TargetForecast.paths`): a point forecast is
    /// one path repeated, as the Python's `point(values, n_paths)` is.
    static func paths(_ tf: ArenaTargetForecast, n: Int) -> [[Double]] {
        if let p = tf.paths { return p }
        let row = tf.median
        return [[Double]](repeating: row, count: max(n, 1))
    }

    /// `_meter_post`: shrink, gate, round.
    func meterPost(_ tr: ArenaTargetRequest, _ tf: ArenaTargetForecast, now: Millis,
                   history h: ArenaHistory) throws -> ArenaTargetForecast {
        guard let wk = MeterFM.windowFor[tr.target] else { return tf }
        let gcfg = cfg.table("gate").table(wk)
        var P = Self.paths(tf, n: tr.nPaths)
        let s = gcfg.double("shrink", 1.0)
        if s != 1.0 {
            let g = P.first?.count ?? 0
            let med = (0..<g).map { j in KitDetQ.median(P.map { $0[j] }) }
            P = P.map { row in row.indices.map { j in min(max(med[j] + s * (row[j] - med[j]), 0.0), 100.0) } }
        }
        guard gcfg.bool("on", false) else { return Self.rint(P, gcfg) }
        let acct = tr.accounts[0]
        let m = KitBaselines.meterNow(h, tr)
        guard let u0 = m.util.last else { return Self.rint(P, gcfg) }
        if book == nil { book = Gate.TurnBook(h) }
        let book = book!
        let fam = tr.target == .meterScoped ? Gate.capFamily(tr.cap) : nil
        let T = book.times(acct, family: fam).filter { $0 <= now }
        let d = Gate.idleMs(T, now)
        let blk = try gcfg.bool("blocking", true) ? Gate.blockedUntil(h, account: acct, now: now) : 0
        let n = P.count
        let minIdle = gcfg.double("min_idle_min", 5) * Gate.minMs
        if d < minIdle && blk <= now { return Self.rint(P, gcfg) }
        var tau: [Double]?
        if d >= minIdle {
            let tz = Double(KitSpend.tzOffsetMs(h, account: acct))
            tau = Gate.sampleResume(T, other: book.others(acct), now: now, d: d, tzMs: tz, n: n, rng: &ctx.rng,
                                    cfg: gcfg)
        }
        if tau == nil {
            if blk <= now { return Self.rint(P, gcfg) }
            tau = [Double](repeating: 0, count: n)
        }
        var t = tau!
        if blk > now { t = t.map { max($0, Double(blk - now)) } }
        // Python's round(): half to even.
        let k = Int((gcfg.double("keep", 0.1) * Double(n)).rounded(.toNearestOrEven))
        var idx = Array(0..<n)
        FMPaths.shuffle(&idx, rng: &ctx.rng)                                       // rng.permutation(n)
        var full = [Double](repeating: 0, count: n)
        for (r, i) in idx.enumerated() where r >= k { full[i] = t[r - k] }
        let gated = Gate.gatePaths(P, grid: tr.grid, now: now, u0: u0, tau: full, mode: gcfg.string("mode", "shift"))
        return Self.rint(gated, gcfg)
    }

    /// `_rint`: readings are whole points (rounded): a path that rose 0.4
    /// point still reads the same, so the mass goes where readings can be.
    static func rint(_ P: [[Double]], _ gcfg: ArenaConfig) -> ArenaTargetForecast {
        guard gcfg.bool("round", true) else { return ArenaTargetForecast(paths: P) }
        return ArenaTargetForecast(paths: P.map { $0.map { min(max($0.rounded(.toNearestOrEven), 0.0), 100.0) } })
    }
}
