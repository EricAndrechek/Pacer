import Foundation

// Ports of the shipping engine's own forecasters and the naive baselines (naive-flat, port-engine-*).
extension ArenaRegistry {
    static var portModels: [ArenaModelSpec] {
        let meters: Set<ArenaTarget> = [.meterFiveHour, .meterSevenDay, .meterScoped]
        return [
            // `models/naive-flat`: persistence, the floor of every board.
            ArenaModelSpec(name: "naive-flat", targets: meters, config: ["hours": 1], complexity: 1) {
                NaiveFlat(context: $0)
            },
            // `models/port-engine-*`: the app's methods as arena models, for
            // the ensembles that take them as children. Not selectable
            // (`ArenaRoster.nonSelectablePrefixes`): the engine already runs
            // these under their own ids.
            ArenaModelSpec(name: "port-engine-recent-rate", targets: meters,
                           config: ["method": "recent-rate"], complexity: 1) {
                try PortEngineModel(context: $0)
            },
            ArenaModelSpec(name: "port-engine-kalman-trend", targets: meters,
                           config: ["method": "kalman-trend"], complexity: 5) {
                try PortEngineModel(context: $0)
            },
        ]
    }
}

/// `kit/baselines.py`: the meter as known at now (`meter_now`), for the
/// baselines. Named apart from any `Kit` port of `kit/spend.current_cycle`
/// so the two can merge without a clash; they compute the same thing.
enum PortBaselines {
    /// `WINDOW_OF`, `window_ms`.
    static func windowMillis(_ kind: String) -> Millis {
        kind == "five_hour" ? 5 * ArenaTime.hour : 7 * ArenaTime.day
    }

    /// `MeterNow`: the request's meter's cycle as known at now. When no cycle
    /// is in progress the request's own reset stands, with no readings (0 %).
    struct MeterNow {
        let start: Millis
        let reset: Millis
        let t: [Millis]
        let util: [Double]
        var latest: Double { util.last ?? 0 }
        var latestT: Millis { t.last ?? start }
    }

    static func meterNow(_ history: ArenaHistory, _ tr: ArenaTargetRequest) -> MeterNow {
        let kind = tr.target.windowKind
        let cap = tr.target == .meterScoped ? tr.cap : nil
        let meter = ArenaMeterID(account: tr.accounts[0], windowKind: kind, scopeModel: cap)
        let readings = history.readings(meter)
        let duration = windowMillis(kind)
        if let c = ArenaRunner.cycleAt(readings, now: history.now) {
            // `kit/spend.current_cycle`: the cycle's active readings (reset
            // within half a window, `RateLimitCycle.contains`), in event order.
            // As read, never a running maximum: a meter can fall within its
            // cycle under the same reset, and what it reads now persists.
            var t: [Millis] = [], u: [Double] = []
            for r in readings where r.active && r.tEvent <= history.now {
                guard let reset = r.resetsAt, abs(reset - c.resetAt) * 2 < duration, let v = r.utilPct else { continue }
                t.append(r.tEvent); u.append(v)
            }
            return MeterNow(start: c.resetAt - duration, reset: c.resetAt, t: t, util: u)
        }
        let reset = tr.resetAt ?? tr.grid.last ?? history.now
        return MeterNow(start: reset - duration, reset: reset, t: [], util: [])
    }

    /// `meter_flat`: the latest reading, flat to the reset.
    static func meterFlat(_ history: ArenaHistory, _ tr: ArenaTargetRequest) -> ArenaTargetForecast {
        .point(Array(repeating: meterNow(history, tr).latest, count: tr.grid.count))
    }
}

/// `models/naive-flat/model.py`: the latest meter reading flat to the reset.
/// Only the meter targets are ported (`hours` configures spend persistence).
final class NaiveFlat: ArenaModel {
    let hours: Int
    var history: ArenaHistory?

    init(context: ArenaContext) {
        hours = context.config.int("hours", 1)
    }

    func fit(_ history: ArenaHistory) { self.history = history }

    func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let history else { throw ArenaError.invalid("naive-flat asked before fit") }
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets { out[tr.key] = PortBaselines.meterFlat(history, tr) }
        return ArenaForecast(byKey: out)
    }
}

/// `kit/engine/model.py` `EngineModel` with a fixed `config.method`: the
/// app's own burn-trajectory method on the live cycle, drawn as the app
/// draws it (`displayed_path`: anchored, floored at the latest reading,
/// capped at 100, non-decreasing). A point forecast: the Python spreads
/// paths with the method's conformal residuals from a record it scores over
/// every completed cycle (`WindowEngine`), and that record is what the
/// engine itself keeps; a parent that needs a spread calibrates its own.
/// When the method declines, or no cycle is live, the meter is held where it
/// is, as the Python holds it.
final class PortEngineModel: ArenaModel {
    let method: String
    var history: ArenaHistory?
    /// `Params.rate_fetch_days`: the live read the app's refit makes.
    static let rateFetchDays: Millis = 32

    init(context: ArenaContext) throws {
        method = context.config.string("method", "rule")
        guard Self.model(method) != nil else {
            throw ArenaError.invalid("port-engine method \(method) is not ported (rule needs the full engine)")
        }
    }

    static func model(_ method: String) -> (any BurnTrajectory.Model)? {
        switch method {
        case "recent-rate": BurnTrajectory.RecentRate()
        case "kalman-trend": BurnTrajectory.KalmanTrend()
        case "linear-recent": BurnTrajectory.LinearRecent()
        case "recency-weighted": BurnTrajectory.RecencyWeighted()
        case "damped-acceleration": BurnTrajectory.DampedAcceleration()
        case "saturating": BurnTrajectory.Saturating()
        default: nil
        }
    }

    func fit(_ history: ArenaHistory) { self.history = history }

    func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
        guard let history else { throw ArenaError.invalid("\(method) asked before fit") }
        var out: [String: ArenaTargetForecast] = [:]
        for tr in request.targets { out[tr.key] = .point(path(history, tr)) }
        return ArenaForecast(byKey: out)
    }

    private func path(_ history: ArenaHistory, _ tr: ArenaTargetRequest) -> [Double] {
        let kind = tr.target.windowKind
        let duration = PortBaselines.windowMillis(kind)
        let meter = ArenaMeterID(account: tr.accounts[0], windowKind: kind,
                                 scopeModel: tr.target == .meterScoped ? tr.cap : nil)
        let now = history.now
        // `meter_arrays`: readings with a reset and a value, in time order,
        // from the live read only (`observe`).
        let from = now - Self.rateFetchDays * ArenaTime.day
        let rows = history.readings(meter).compactMap { r -> (at: Date, usedPercentage: Double, resetsAt: Date)? in
            guard r.tEvent >= from, r.tEvent <= now, let v = r.utilPct, let reset = r.resetsAt else { return nil }
            return (ArenaTime.date(r.tEvent), v, ArenaTime.date(reset))
        }
        let nowDate = ArenaTime.date(now)
        let (current, _) = BurnTrajectory.segment(samples: rows, duration: TimeInterval(duration) / 1000, now: nowDate)
        let sameCycle = current.map { c in
            c.resetsAt > nowDate && !c.samples.isEmpty
                && (tr.resetAt.map { abs(ArenaTime.millis(c.resetsAt) - $0) * 2 < duration } ?? true)
        } ?? false
        if sameCycle, let c = current, let proj = Self.model(method)?.fit(c) {
            // `displayed_path`.
            let anchor = max(0, c.usedNow - proj(c.now))
            var running = -Double.infinity
            return tr.grid.map { g in
                let v = min(100, max(c.usedNow, proj(ArenaTime.date(g)) + anchor))
                running = max(running, v)
                return running
            }
        }
        // Held: the method's live value when it declined this cycle, else the
        // latest reading of the requested cycle (`latest_in_cycle`).
        let base: Double
        if sameCycle, let c = current {
            base = c.usedNow
        } else {
            base = history.readings(meter).last { r in
                guard r.tEvent <= now, r.utilPct != nil, let reset = r.resetsAt else { return false }
                return tr.resetAt.map { abs(reset - $0) * 2 < duration } ?? true
            }?.utilPct ?? 0
        }
        return Array(repeating: base, count: tr.grid.count)
    }
}
