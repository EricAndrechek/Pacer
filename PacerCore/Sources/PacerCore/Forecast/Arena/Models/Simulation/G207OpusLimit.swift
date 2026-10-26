import Foundation

/// g2-07-opus-limit (`research/arena/models/g2-07-opus-limit/model.py`,
/// `Model`): meters forecast for the limit call.
///
/// Every meter (five-hour, seven-day, scoped cap) is simulated to its reset
/// by `LimitSim`: the account's own burn, resampled in time-of-day-aligned
/// blocks, with the account's learned behaviour near 100 (rationing, parking
/// below the limit) and a learned re-base hazard. The chance of hitting the
/// limit, the time to it and the value at reset all come from those paths.
/// The model reads readings only (no spend).
final class G207OpusLimit: ArenaModel {
    static let name = "g2-07-opus-limit"

    let ctx: ArenaContext
    let cfg: ArenaConfig
    var history: ArenaHistory?

    init(context: ArenaContext) {
        ctx = context
        cfg = context.config
    }

    func fit(_ history: ArenaHistory) throws { self.history = history }

    func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let h = history else { throw ArenaError.invalid("\(Self.name): forecast before fit") }
        var out: [String: ArenaTargetForecast] = [:]
        var rng = ctx.rng
        defer { ctx.rng = rng }
        for tr in request.targets {
            do {
                try ctx.checkCancelled()
                out[tr.key] = ArenaTargetForecast(paths: try OpusLimitMeters.meterPaths(
                    h, now: request.now, tr, rng: &rng, cfg: cfg, memoPrefix: ctx.name))
            } catch ArenaError.cancelled {
                throw ArenaError.cancelled
            } catch {
                // Never fail the whole request (the Python's `except Exception`).
                ctx.log("\(tr.key): flat fallback after \(error)")
                out[tr.key] = ArenaTargetForecast(paths: OpusLimitMeters.flatPaths(h, now: request.now, tr))
            }
        }
        return ArenaForecast(byKey: out)
    }
}

/// `research/arena/models/g2-07-opus-limit/meters.py`: from the readings
/// known at now to meter paths, the glue between the request and `LimitSim`.
enum OpusLimitMeters {
    static func kind(_ target: ArenaTarget) -> String { target.windowKind }

    /// `meters._series` → `kit.fm.series.meter_series` (memoized on the cut by the kit).
    static func series(_ h: ArenaHistory, _ acct: String, _ kind: String, _ cap: String?, _ now: Millis) -> FMSeries.MeterSeries {
        FMSeries.meterSeries(h, account: acct, windowKind: kind, scopeModel: cap, now: now)
    }

    /// `current_level`: the meter now, from this cycle's latest reading.
    static func currentLevel(_ s: FMSeries.MeterSeries, _ resetAt: Millis?) -> Double {
        if let resetAt, let u = s.usedNow(resetAt) { return u }
        return 0
    }

    /// `stay_hours`: how long this cycle's meter has read u0 (since it last read lower).
    static func stayHours(_ s: FMSeries.MeterSeries, _ resetAt: Millis?, _ u0: Double, _ now: Millis) -> Double {
        guard let resetAt, u0 > 0 else { return 0 }
        var t: [Millis] = [], u: [Double] = []
        for i in 0..<s.count where s.inCycle(i, resetAt: resetAt) { t.append(s.times[i]); u.append(s.cycleUtil[i]) }
        guard !t.isEmpty else { return 0 }
        let i = (u.lastIndex { $0 < u0 }).map { $0 + 1 } ?? 0
        if i >= t.count { return 0 }
        return max(0, Double(now - t[i]) / Double(LimitSim.hour))
    }

    /// `weekly_block_until`: the seven-day reset when the account's seven-day
    /// meter reads 100 now (the account is blocked until then), else nil.
    static func weeklyBlockUntil(_ h: ArenaHistory, _ acct: String, _ now: Millis) -> Millis? {
        let s = series(h, acct, "seven_day", nil, now)
        guard s.count > 0, s.active[s.count - 1] else { return nil }
        let r = s.reset[s.count - 1]
        if r <= now || s.cycleUtil[s.count - 1] < 100 { return nil }
        return r
    }

    /// `idle_hours`: hours since this meter last rose (any cycle).
    static func idleHours(_ s: FMSeries.MeterSeries, _ now: Millis) -> Double {
        guard s.count >= 2 else { return 0 }
        guard let rose = (1..<s.count).last(where: { s.cum[$0] - s.cum[$0 - 1] > 0 }) else {
            return Double(now - s.times[0]) / Double(LimitSim.hour)
        }
        return max(0, Double(now - s.times[rose]) / Double(LimitSim.hour))
    }

    static func flatPaths(_ h: ArenaHistory, now: Millis, _ tr: ArenaTargetRequest) -> [[Double]] {
        let kind = kind(tr.target)
        let cap = tr.target == .meterScoped ? tr.cap : nil
        let s = series(h, tr.account, kind, cap, now)
        let u0 = currentLevel(s, tr.resetAt)
        return Array(repeating: Array(repeating: u0, count: tr.grid.count), count: max(tr.nPaths, 1))
    }

    /// What `meter_paths` learns from the history before it draws: the
    /// account's step history, behaviour, ceilings and the simulation's
    /// pools. Deterministic given the history cut, the meter and the config,
    /// so it lives on the cut's memo (shared by every target and every model
    /// run on that cut).
    struct Learned {
        let c: LimitSim.Config
        let step: Millis
        let tzMs: Millis
        let own: FMSeries.MeterSeries
        let ownH: LimitSim.StepHist
        let beh: LimitSim.Behaviour
        /// The learned keep per band, before the ceilings replace it with 1s.
        let keepLearned: [Double]
        let nFalls: Int
        let nTops: Int
        let ceilings: LimitSim.Ceilings?
        /// The history the simulation resamples (own, or a borrowed account's).
        let h: LimitSim.StepHist
        let borrowed: Bool
        let prepared: LimitSim.Prepared?
        let firstTod: Int
    }

    static func learn(_ hist: ArenaHistory, now: Millis, _ tr: ArenaTargetRequest, cfg: ArenaConfig,
                      memoPrefix: String) -> Learned {
        let kind = kind(tr.target)
        let cap = tr.target == .meterScoped ? tr.cap : nil
        let acct = tr.account
        let key = "\(memoPrefix)|learned|\(acct)|\(kind)|\(cap ?? "")|\(now)"
        return hist.memo.value(key) {
            let c = LimitSim.Config.resolved(kind, cfg)
            let step = Millis(c.stepMin) * LimitSim.minute
            let tzMs = Millis(hist.tzOffsetMin ?? 0) * LimitSim.minute
            let lookback = Millis(c.lookbackDays * Double(LimitSim.day))
            let stale = kind == "five_hour" ? 3 * step : 3 * LimitSim.hour
            let dur = LimitSim.windowMs(kind)
            let own = series(hist, acct, kind, cap, now)
            var hists: [(LimitSim.StepHist, Double)] = []
            var falls: [[Millis]] = []
            let ownH = LimitSim.stepHistory(times: own.times, cum: own.cum, util: own.cycleUtil, active: own.active,
                                            now: now, step: step, lookback: lookback, tzMs: tzMs, stale: stale)
            hists.append((ownH, 1))
            falls.append(LimitSim.findFalls(times: own.times, util: own.cycleUtil, active: own.active,
                                            reset: own.reset, duration: dur))
            let otherW = c.otherAccountWeight
            let others = otherW > 0 ? hist.accounts.filter { $0 != acct } : []
            var otherSeries: [FMSeries.MeterSeries] = []
            for a in others {
                let s = series(hist, a, kind, cap, now)
                if s.count < 2 { continue }
                otherSeries.append(s)
                hists.append((LimitSim.stepHistory(times: s.times, cum: s.cum, util: s.cycleUtil, active: s.active,
                                                   now: now, step: step, lookback: lookback, tzMs: tzMs, stale: stale),
                              otherW))
                falls.append(LimitSim.findFalls(times: s.times, util: s.cycleUtil, active: s.active, reset: s.reset,
                                                duration: dur))
            }
            var beh = LimitSim.learnBehaviour(hists, bands: c.bands, halfLife: c.halfLifeDays,
                                              priorHours: c.priorHours, step: step,
                                              rebasePriorPerWeek: c.rebasePrior, rebaseWeeksPrior: c.rebaseWeeksPrior,
                                              falls: falls)
            let keepLearned = beh.keep
            var nTops = 0
            var ceilings: LimitSim.Ceilings?
            if c.useCeilings {
                let parkMin = Millis(c.parkFrac * Double(dur))
                var tops = LimitSim.cycleTops(times: own.times, util: own.cycleUtil, active: own.active,
                                              reset: own.reset, duration: dur, now: now, zoneLo: c.zoneLo,
                                              parkMin: parkMin).map { ($0, 1.0) }
                nTops = tops.count
                if otherW > 0 {
                    // Every other account, as the Python asks again (not only the ones with 2+ readings).
                    for a in others {
                        let s = series(hist, a, kind, cap, now)
                        tops += LimitSim.cycleTops(times: s.times, util: s.cycleUtil, active: s.active, reset: s.reset,
                                                   duration: dur, now: now, zoneLo: c.zoneLo, parkMin: parkMin)
                            .map { ($0, otherW) }
                    }
                }
                ceilings = LimitSim.learnCeilings(tops, now: now, halfLifeDays: c.ceilHalfLifeDays, zoneLo: c.zoneLo,
                                                  priorW100: c.ceilPriorW100, leakPrior: c.leakPrior,
                                                  leakPriorHours: c.leakPriorHours, priorPark: c.priorPark,
                                                  lateH: c.lateH, leakLatePrior: c.leakLatePrior,
                                                  leakLatePriorHours: c.leakLatePriorHours)
                beh.keep = Array(repeating: 1, count: beh.keep.count)
            }
            var h = ownH
            var borrowed = false
            if ownH.count < c.minHistSteps || ownH.burnSum <= 0 {
                // Too little of this meter's own past: borrow another account's,
                // at a discount (a new account rarely carries a whole account's load).
                let best = hists.dropFirst().max { $0.0.burnSum < $1.0.burnSum }
                if let best, best.0.burnSum > 0, ownH.count < 2 || ownH.burnSum <= 0 {
                    h = best.0
                    h.burn = h.burn.map { $0 * c.borrowScale }
                    borrowed = true
                }
            }
            let spd = Int(LimitSim.day / step)
            let firstTod = Int(SimRandom.pmod(now + step + tzMs, LimitSim.day) / step) % spd
            let prepared = h.count >= 2 && h.burnSum > 0 ? LimitSim.prepare(h, firstTod: firstTod, step: step, cfg: c) : nil
            return Learned(c: c, step: step, tzMs: tzMs, own: own, ownH: ownH, beh: beh, keepLearned: keepLearned,
                           nFalls: falls[0].count, nTops: nTops, ceilings: ceilings, h: h,
                           borrowed: borrowed, prepared: prepared, firstTod: firstTod)
        }
    }

    /// `meter_paths`.
    static func meterPaths(_ hist: ArenaHistory, now: Millis, _ tr: ArenaTargetRequest, rng: inout ArenaRNG,
                           cfg: ArenaConfig, memoPrefix: String) throws -> [[Double]] {
        let kind = kind(tr.target)
        let acct = tr.account
        let nPaths = max(tr.nPaths, 1)
        let reset = tr.resetAt ?? tr.grid[tr.grid.count - 1]
        let L = learn(hist, now: now, tr, cfg: cfg, memoPrefix: memoPrefix)
        let c = L.c, step = L.step
        let u0 = currentLevel(L.own, tr.resetAt)
        var ceil: [Double]?
        var leakStep: [Double] = []
        if let ce = L.ceilings {
            let stay = stayHours(L.own, tr.resetAt, u0, now)
            let free = L.ownH.level.map { $0 < min(c.parkFrom, 100) }
            let post = LimitSim.ceilingPosterior(ce, uNow: u0, stayHours: stay) { hrs in
                LimitSim.zeroBurnSurvival(L.ownH, hours: hrs, step: step, halfLife: c.halfLifeDays, free: free)
            }
            let dist = SimDiscrete(weights: post.probs)
            ceil = (0..<nPaths).map { _ in Double(post.levels[dist.draw(&rng)]) }
            let H = max(1, Int((Double(reset - now) / Double(step)).rounded(.up)))
            leakStep = (1...H).map { k in
                let rH = Double(reset - (now + step * Millis(k))) / Double(LimitSim.hour)   // hours to reset at the step's end
                let lam = ce.lateH > 0 && rH <= ce.lateH ? ce.leakLatePerHour : ce.leakPerHour
                return 1 - exp(-lam * Double(step) / Double(LimitSim.hour))
            }
        }
        var delay: [Int]?
        if c.delayMinStayH > 0 && !L.borrowed {
            let idle = idleHours(L.own, now)
            if idle >= c.delayMinStayH {
                let freeH = L.h.level.map { $0 < min(c.parkFrom, 100) }
                let (lens, wts) = LimitSim.idleRuns(L.h, halfLife: c.halfLifeDays, free: freeH)
                delay = LimitSim.resumeDelay(lens: lens, w: wts, staySteps: idle * Double(LimitSim.hour) / Double(step),
                                             n: nPaths, rng: &rng, tailMult: c.delayTailMult)
            }
        }
        if kind != "seven_day" && c.coupleWeekly {
            // The account's seven-day limit reached blocks all use: this meter
            // holds until that limit resets (five-hour burn far lower, scoped
            // burn zero while the seven-day meter read 100).
            if let until = weeklyBlockUntil(hist, acct, now) {
                let k = Int((Double(until - now) / Double(step)).rounded(.up))
                delay = delay.map { $0.map { max($0, k) } } ?? Array(repeating: k, count: nPaths)
            }
        }
        let sim = LimitSim.simulate(L.h, prepared: { L.prepared! }, beh: L.beh, u0: u0, now: now, reset: reset,
                                    step: step, tzMs: L.tzMs, nPaths: nPaths, rng: &rng, cfg: c, ceil: ceil,
                                    leakPerStep: leakStep, delay: delay)
        return LimitSim.toGrid(times: sim.times, vals: sim.vals, grid: tr.grid)
    }
}
