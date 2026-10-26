import Foundation
@testable import PacerCore

/// A deterministic synthetic account for the analog model's long-history
/// tests: work sessions on most weekdays and some weekend days, a five-hour
/// meter that starts at the first use after an idle spell and resets five
/// hours later (its `resets_at` jittering by milliseconds per poll, as the
/// server's does), and a weekly meter. Polled every 2 minutes while a
/// five-hour cycle runs and every 10 minutes otherwise, like the app's
/// adaptive poller. No real usage: every number comes from `ArenaRNG`.
enum AnalogSynthetic {
    static let day = ArenaTime.day, hour = ArenaTime.hour, minute = ArenaTime.minute
    /// A Monday, 00:00 UTC.
    static let t0: Millis = 20_601 * ArenaTime.day

    /// `knownLag`: each row becomes known up to this long after its event
    /// (0: when it is written, as in the app).
    static func store(days: Int, seed: UInt64 = 7, knownLag: Millis = 0, tzMin: Int = -240,
                      account: String = "A1") -> ArenaHistoryStore {
        var rng = ArenaRNG(seed: seed)
        let tz = Millis(tzMin) * minute
        let end = t0 + Millis(days) * day
        // Work sessions: [start, end) with a rate in points per hour.
        var sessions: [(Millis, Millis, Double)] = []
        for d in 0..<days {
            let dayStart = t0 + Millis(d) * day - tz          // local midnight
            let dow = d % 7                                    // 0 = Monday
            let works = rng.uniform() < (dow >= 5 ? 0.35 : 0.85)
            guard works else { continue }
            var t = dayStart + Millis((7.5 + 2.5 * rng.uniform()) * Double(hour))
            for _ in 0..<(1 + Int(rng.uniform() * 3)) {
                let len = Millis((0.7 + 3.0 * rng.uniform()) * Double(hour))
                let rate = 14 * exp(0.6 * rng.normal())
                sessions.append((t, t + len, rate))
                t += len + Millis((0.5 + 3 * rng.uniform()) * Double(hour))
            }
        }
        var five: [ArenaReading] = [], week: [ArenaReading] = []
        func known(_ t: Millis, _ rng: inout ArenaRNG) -> Millis {
            knownLag > 0 ? t + Millis(rng.uniform() * Double(knownLag)) : t
        }
        var cycleReset: Millis? = nil, util = 0.0, used = 0.0
        var weekReset: Millis? = nil, weekUtil = 0.0
        var nextFive: Millis = t0, nextWeek: Millis = t0
        var si = 0
        var t = t0
        while t < end {
            while si < sessions.count && sessions[si].1 <= t { si += 1 }
            let inSession = si < sessions.count && sessions[si].0 <= t
            let use = inSession ? sessions[si].2 / 60 * (0.3 + 1.4 * rng.uniform()) : 0   // points this minute
            if let r = cycleReset, t >= r { cycleReset = nil; util = 0; used = 0 }
            if let r = weekReset, t >= r { weekReset = nil; weekUtil = 0 }
            if use > 0 {
                if cycleReset == nil { cycleReset = t + 5 * hour }
                if weekReset == nil { weekReset = t + 7 * day }
                used += use
                util = min(100, used.rounded(.down))
                weekUtil = min(100, weekUtil + use * 0.12)
            }
            if t >= nextFive {
                let jitter = Millis(rng.uniform() * 900) - 450
                five.append(ArenaReading(tEvent: t, tKnown: known(t, &rng), utilPct: cycleReset == nil ? 0 : util,
                                         resetsAt: cycleReset.map { $0 + jitter }, active: cycleReset != nil))
                nextFive = t + (cycleReset == nil ? 10 : 2) * minute
            }
            if t >= nextWeek {
                week.append(ArenaReading(tEvent: t, tKnown: known(t, &rng),
                                         utilPct: weekReset == nil ? 0 : weekUtil.rounded(.down),
                                         resetsAt: weekReset, active: weekReset != nil))
                nextWeek = t + 10 * minute
            }
            t += minute
        }
        // A per-model weekly cap ("Fable") that moves with the weekly meter, faster.
        let scoped = week.map { r in
            ArenaReading(tEvent: r.tEvent, tKnown: r.tKnown, utilPct: r.utilPct.map { min(100, ($0 * 1.6).rounded(.down)) },
                         resetsAt: r.resetsAt, active: r.active)
        }
        return ArenaHistoryStore(
            meters: [ArenaMeterID(account: account, windowKind: "five_hour"): five,
                     ArenaMeterID(account: account, windowKind: "seven_day"): week,
                     ArenaMeterID(account: account, windowKind: "weekly_scoped", scopeModel: "Fable"): scoped],
            spend: [:], tzOffsetMin: tzMin, dataStart: t0)
    }

    /// The backfill's cut points: `perCycle` evenly spaced times inside each
    /// five-hour cycle the store completed (its first reading to its reset).
    static func cuts(_ store: ArenaHistoryStore, account: String = "A1", perCycle: Int = 8) -> [Millis] {
        let latest = store.meters.values.compactMap { $0.last?.tKnown }.max() ?? 0
        let all = ArenaHistory(store: store, now: latest, accounts: [account])
        let cycles = KitSpend.pastCycles(all, account: account, windowKind: "five_hour")
        return cycles.flatMap { c -> [Millis] in
            guard let first = c.t.first else { return [] }
            return (0..<perCycle).map { k in first + (c.reset - first) * Millis(k) / Millis(perCycle) + 1 }
        }
    }
}
