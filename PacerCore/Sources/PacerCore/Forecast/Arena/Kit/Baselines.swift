import Foundation

// `research/arena/kit/baselines.py`, the meter half: the cycle as known at
// now (`meter_now`), and the two rules every board has as a floor
// (`meter_flat`, `meter_linear`). The hourly spend/token baselines have no
// meter target and are not ported.

public enum KitBaselines {
    /// `WINDOW_OF`: the readings' window kind for each meter target.
    public static func windowOf(_ target: ArenaTarget) -> String { target.windowKind }

    /// One meter's cycle as known at now.
    public struct MeterNow: Sendable {
        public let windowKind: String
        public let scopeModel: String?
        /// Nominal start: reset − window.
        public let start: Millis
        public let reset: Millis
        /// This cycle's readings (`tEvent`, ascending) and their util as read
        /// (NaN where a row had none, as the Python's frame reads it).
        public let t: [Millis]
        public let util: [Double]

        public var latest: Double { util.last ?? 0 }
        public var latestT: Millis { t.last ?? start }
    }

    /// `meter_now`: the request's meter as known at now. The cycle comes
    /// from `KitSpend.currentCycle`; when that finds none (the history was
    /// cut after the cycle's readings, say) the request's own reset stands,
    /// with no readings (0 %).
    public static func meterNow(_ history: ArenaHistory, _ tr: ArenaTargetRequest) -> MeterNow {
        let kind = windowOf(tr.target)
        let cap = tr.target == .meterScoped ? tr.cap : nil
        if let c = KitSpend.currentCycle(history, account: tr.accounts[0], windowKind: kind, scopeModel: cap) {
            // As read, never a running maximum: a meter can fall within its
            // cycle under the same resets_at (an allowance reset mid-cycle
            // can take it from full to near zero), and what it reads now is
            // what persists.
            return MeterNow(windowKind: kind, scopeModel: cap, start: c.start, reset: c.reset,
                            t: c.rows.map(\.tEvent), util: c.rows.map { $0.utilPct ?? .nan })
        }
        let reset = tr.resetAt ?? tr.grid[tr.grid.count - 1]
        return MeterNow(windowKind: kind, scopeModel: cap, start: reset - KitSpend.windowMs(kind), reset: reset,
                        t: [], util: [])
    }

    /// `meter_flat`: persistence, the latest reading, flat to reset.
    public static func meterFlat(_ history: ArenaHistory, _ tr: ArenaTargetRequest) -> ArenaTargetForecast {
        let m = meterNow(history, tr)
        return .point(Array(repeating: m.latest, count: tr.grid.count))
    }

    /// `meter_linear`: the pace so far, extended: a straight line from 0 at
    /// the cycle's nominal start through the latest reading, to reset, never
    /// below the reading or above 100. With no time elapsed it is flat.
    public static func meterLinear(_ history: ArenaHistory, _ tr: ArenaTargetRequest) -> ArenaTargetForecast {
        let m = meterNow(history, tr)
        let elapsed = m.latestT - m.start
        let rate = elapsed > 0 ? m.latest / Double(elapsed) : 0
        // np.clip(x, lo, hi) = min(max(x, lo), hi).
        return .point(tr.grid.map { g in min(max(m.latest + rate * Double(g - m.latestT), m.latest), 100) })
    }
}
