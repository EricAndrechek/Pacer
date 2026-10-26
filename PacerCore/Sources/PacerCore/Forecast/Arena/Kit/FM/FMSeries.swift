import Foundation

// `research/arena/kit/fm/series.py`, the meter half (and the hourly helpers
// the spend half builds on): series a pretrained forecaster can read, built
// from an `ArenaHistory` only (rows known by `history.now`), so nothing here
// can see the future.
//
// **Meters: cumulative burn.** A meter resets every cycle, which a generic
// forecaster reads as a crash. The series it gets instead is the meter's burn
// summed across cycles and never reset: each reading adds how far it rose
// from the previous reading of its cycle, and the first reading of a cycle
// adds its whole value (the meter started that cycle at 0). Cycles follow the
// one rule (`RateLimitCycle.contains`): a reading belongs to the cycle of the
// last active reading when their resets are within half a window. Idle rows
// add nothing. A meter can FALL inside a cycle under the same reset (the
// allowance was re-based): a fall adds nothing, and burn counts again from
// the lower value. There is no running maximum anywhere.
//
// **Resampling.** `resampleLast` puts the irregular readings on a regular
// grid ending exactly at `now`: each grid time takes the last reading at or
// before it, or NaN when that reading is older than `staleMs` (a gap is
// unknown, not flat).

public enum FMSeries {
    public static let minMs: Millis = 60_000
    public static let hourMs: Millis = 3_600_000
    public static let dayMs: Millis = 24 * hourMs
    public static let staleMs: Millis = 2 * hourMs

    /// `arena.snapshot.cycles.WINDOW_MS`.
    public static func windowMs(_ windowKind: String) -> Millis {
        switch windowKind {
        case "five_hour", "session": 5 * hourMs
        default: 7 * dayMs   // seven_day, weekly_all, weekly_scoped
        }
    }

    // MARK: - Meters

    /// One meter's readings known at now, in event order (`MeterSeries`).
    public struct MeterSeries: Sendable {
        /// `t_event`, epoch ms.
        public let times: [Millis]
        /// Cumulative burn after each reading.
        public let cum: [Double]
        /// The reading's util as read (0 when idle).
        public let cycleUtil: [Double]
        /// The reading's reset, -1 when it has none.
        public let reset: [Millis]
        public let active: [Bool]
        public let duration: Millis

        public var count: Int { times.count }
        public var isEmpty: Bool { times.isEmpty }

        public func inCycle(_ i: Int, resetAt: Millis) -> Bool {
            active[i] && abs(Double(reset[i] - resetAt)) < Double(duration) / 2
        }

        public func cycleMask(_ resetAt: Millis) -> [Bool] {
            (0..<count).map { inCycle($0, resetAt: resetAt) }
        }

        /// The meter now: the latest reading of the cycle resetting at
        /// `resetAt`, as read (it can be below an earlier one: a re-base).
        public func usedNow(_ resetAt: Millis) -> Double? {
            var i = count - 1
            while i >= 0 { if inCycle(i, resetAt: resetAt) { return cycleUtil[i] }; i -= 1 }
            return nil
        }

        /// The latest active reading's util (`s.cycle_util[s.active][-1]`).
        public var lastActiveUtil: Double? {
            var i = count - 1
            while i >= 0 { if active[i] { return cycleUtil[i] }; i -= 1 }
            return nil
        }

        public func last() -> (Millis, Double)? {
            guard let t = times.last, let c = cum.last else { return nil }
            return (t, c)
        }
    }

    /// `meter_series` over one meter's readings (already the meter's own,
    /// known at the history's now). `now`: drop readings after it.
    public static func meterSeries(_ readings: [ArenaReading], windowKind: String, now: Millis? = nil) -> MeterSeries {
        // `meter_frame`: sorted by (t_event, t_known), keeping the store's
        // order on a full tie (polars `maintain_order`); the store sorts by
        // (t_event, util), so re-sort only when a tie makes them differ.
        var rows = readings
        if zip(rows, rows.dropFirst()).contains(where: { ($0.tEvent, $0.tKnown) > ($1.tEvent, $1.tKnown) }) {
            rows = rows.enumerated().sorted { ($0.element.tEvent, $0.element.tKnown, $0.offset) < ($1.element.tEvent, $1.element.tKnown, $1.offset) }
                .map(\.element)
        }
        let dur = windowMs(windowKind)
        let half = Double(dur) / 2
        var t: [Millis] = [], r: [Millis] = [], a: [Bool] = [], u: [Double] = [], cum: [Double] = []
        t.reserveCapacity(rows.count); r.reserveCapacity(rows.count); a.reserveCapacity(rows.count)
        u.reserveCapacity(rows.count); cum.reserveCapacity(rows.count)
        // The latest ACTIVE reading before each row: idle rows in between do
        // not start a new cycle; only a reset half a window away does.
        var prevIdx = -1
        var running = 0.0
        for row in rows {
            if let now, row.tEvent > now { continue }
            guard let util = row.utilPct, !util.isNaN else { continue }
            // `meter_frame`'s active: state active AND a reset.
            let act = row.active && row.resetsAt != nil
            let reset = row.resetsAt ?? -1
            let val = act ? util : 0.0
            var inc = 0.0
            if act {
                let isNew = prevIdx < 0 || abs(Double(reset) - Double(r[prevIdx])) >= half
                // A fall inside a cycle is a re-base: it adds no burn, and the
                // rise after it counts from the lower value. Never a running max.
                inc = max(isNew ? val : val - u[prevIdx], 0.0)
            }
            running += inc
            t.append(row.tEvent); r.append(reset); a.append(act); u.append(val); cum.append(running)
            if act { prevIdx = t.count - 1 }
        }
        return MeterSeries(times: t, cum: cum, cycleUtil: u, reset: r, active: a, duration: dur)
    }

    /// `meter_series(history.table("meter_readings"), account, window_kind,
    /// scope_model, now)`, memoized on the history cut (every model run on
    /// one cut shares it).
    public static func meterSeries(_ history: ArenaHistory, account: String, windowKind: String,
                                   scopeModel: String? = nil, now: Millis? = nil) -> MeterSeries {
        let id = ArenaMeterID(account: account, windowKind: windowKind, scopeModel: scopeModel)
        let key = "fm.meterSeries|\(account)|\(windowKind)|\(scopeModel ?? "")|\(now.map(String.init) ?? "-")"
        return history.memo.value(key) { meterSeries(history.readings(id), windowKind: windowKind, now: now) }
    }

    /// Each grid time takes the last value at or before it; NaN when there is
    /// none, or it is older than `staleMs`. `times` ascending.
    public static func resampleLast(times: [Millis], values: [Double], grid: [Millis],
                                    staleMs: Millis = FMSeries.staleMs) -> [Double] {
        var out = [Double](repeating: .nan, count: grid.count)
        guard !times.isEmpty else { return out }
        for (j, g) in grid.enumerated() {
            // searchsorted(times, g, side="right") - 1
            var lo = 0, hi = times.count
            while lo < hi { let mid = (lo + hi) / 2; if times[mid] <= g { lo = mid + 1 } else { hi = mid } }
            let i = lo - 1
            if i >= 0 && g - times[i] <= staleMs { out[j] = values[i] }
        }
        return out
    }

    /// n times ending exactly at now, `stepMs` apart (oldest first).
    public static func regularGrid(now: Millis, stepMs: Millis, n: Int) -> [Millis] {
        (0..<max(n, 0)).map { now - stepMs * Millis(n - 1 - $0) }
    }

    /// For models that cannot take NaN: inner gaps linear, leading gaps take
    /// the first value, trailing gaps the last. An all-NaN row becomes 0.
    public static func fillGaps(_ x: [Double]) -> [Double] {
        let okIdx = x.indices.filter { x[$0].isFinite }
        if okIdx.count == x.count { return x }
        if okIdx.isEmpty { return [Double](repeating: 0, count: x.count) }
        let xs = okIdx.map(Double.init), ys = okIdx.map { x[$0] }
        return x.indices.map { ArenaMath.interp(Double($0), xs: xs, ys: ys) }
    }

    // MARK: - Hourly series

    /// Bin index (0 = oldest) of each time among the `hours` hours ending at
    /// now, or -1 outside. Bin k from the end covers (now-(k+1)h, now-kh].
    public static func hourBins(_ tMs: [Millis], now: Millis, hours: Int) -> [Int] {
        tMs.map { t in
            let back = floorDiv(now - t, hourMs)
            return (t <= now && back < Millis(hours) && back >= 0) ? hours - 1 - Int(back) : -1
        }
    }

    /// Per-hour sums of `v` over the `hours` hours ending at now (NaN adds 0).
    public static func binSum(_ tMs: [Millis], _ v: [Double], now: Millis, hours: Int) -> [Double] {
        var out = [Double](repeating: 0, count: max(hours, 0))
        for (i, b) in hourBins(tMs, now: now, hours: hours).enumerated() where b >= 0 {
            if !v[i].isNaN { out[b] += v[i] }
        }
        return out
    }

    /// The meter at each hour's end (max over the accounts), NaN where no
    /// reading in the 2 h before; idle counts 0 (`meter_level_hourly`).
    public static func meterLevelHourly(_ history: ArenaHistory, accounts: [String], windowKind: String,
                                        now: Millis, hours: Int) -> [Double] {
        let since = now - Millis(hours + 3) * hourMs
        let ends = (0..<hours).map { now - hourMs * Millis(hours - 1 - $0) }
        var out = [Double](repeating: .nan, count: hours)
        for a in accounts {
            for id in history.meters(account: a) where id.windowKind == windowKind {
                let rows = history.readings(id).filter { $0.tEvent > since }
                guard !rows.isEmpty else { continue }
                let t = rows.map(\.tEvent)
                let u = rows.map { ($0.active && $0.resetsAt != nil) ? ($0.utilPct ?? 0) : 0 }
                let v = resampleLast(times: t, values: u, grid: ends)
                for k in 0..<hours {
                    if out[k].isNaN { out[k] = v[k] } else if !v[k].isNaN { out[k] = max(out[k], v[k]) }
                }
            }
        }
        return out
    }

    /// [4][n]: hour-of-day and day-of-week as sin/cos, local time, at the
    /// middle of each hour ending at `endsMs`.
    public static func calendar(_ endsMs: [Millis], tzOffsetMin: Int) -> [[Double]] {
        var rows = [[Double]](repeating: [], count: 4)
        for e in endsMs {
            let mid = e - hourMs / 2 + Millis(tzOffsetMin) * minMs
            let hod = Double(floorMod(mid, dayMs)) / Double(dayMs)
            // 1970-01-01 was a Thursday: Monday = 0.
            let dow = (Double(floorMod(floorDiv(mid, dayMs) + 3, 7)) + hod) / 7.0
            rows[0].append(sin(2 * .pi * hod)); rows[1].append(cos(2 * .pi * hod))
            rows[2].append(sin(2 * .pi * dow)); rows[3].append(cos(2 * .pi * dow))
        }
        return rows
    }

    /// numpy's `//` and `%` on int64 (floor, not truncation).
    @inlinable static func floorDiv(_ a: Millis, _ b: Millis) -> Millis {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    @inlinable static func floorMod(_ a: Millis, _ b: Millis) -> Millis {
        let m = a % b
        return (m != 0 && (m < 0) != (b < 0)) ? m + b : m
    }
}
