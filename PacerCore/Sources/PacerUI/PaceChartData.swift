import Foundation
import PacerCore

/// Builders that turn stored samples into a `PaceChartView.Data` actual line.
///
/// Three surfaces draw this chart — the dashboard card, the compare-models
/// modal, and the widget extension — and each used to carry its own copy of
/// "filter to the current cycle, sort, synthesize a `now` tail". The copies
/// drifted: the fixed-window ones filtered cycle membership through
/// `inCycle` (jitter-tolerant) while every scoped copy used `resetsAt ==`,
/// which matches roughly one row and collapses the scoped chart to a single
/// dot. One builder per source, shared by all three consumers, is what keeps
/// that from happening again.
///
/// The result is deliberately **projection-free**: the forecast overlay is
/// layered by each consumer via `withProjection`, so the share image (which
/// draws no forecast) and the live chart share this exact base.
public extension PaceChartView.Data {

    /// Current-cycle actual line for a fixed 5h/7d window from
    /// `RateLimitSample` rows. `samples` may be in any order and may span
    /// several cycles; the newest row picks the cycle.
    static func cycle(
        fixed samples: [RateLimitSample], duration: TimeInterval, now: Date
    ) -> PaceChartView.Data? {
        guard let latest = samples.max(by: { $0.sampledAt < $1.sampledAt }),
              let resets = latest.resetsAt else { return nil }
        return build(
            points: samples
                .inCycle(resetting: resets, duration: duration)
                .map { (time: $0.sampledAt, value: $0.usedPercentage) },
            latestUsed: latest.usedPercentage,
            resetsAt: resets, duration: duration, now: now)
    }

    /// Current-cycle actual line for one scoped `limits[]` window from
    /// `UsageLimitSample` rows. `row` is that identity's newest reading (the
    /// latest-batch row that defines the column); `history` is any bag of
    /// scoped rows — other identities and other cycles are filtered out here.
    static func cycle(
        scoped row: UsageLimitSample, history: [UsageLimitSample],
        duration: TimeInterval, now: Date
    ) -> PaceChartView.Data? {
        guard let resets = row.resetsAt else { return nil }
        return build(
            points: history
                .inCycle(identity: row.identity, resetting: resets, duration: duration)
                .map { (time: $0.sampledAt, value: $0.percent) },
            latestUsed: row.percent,
            resetsAt: resets, duration: duration, now: now)
    }

    /// The value-typed builders. Identical maths, taking the four scalars the
    /// line actually plots rather than `@Model` rows — so the caller can load
    /// its series on a background context instead of the main actor. See
    /// `LimitSamplePoint`.
    static func cycle(
        fixed points: [LimitSamplePoint], duration: TimeInterval, now: Date
    ) -> PaceChartView.Data? {
        guard let latest = points.max(by: { $0.sampledAt < $1.sampledAt }),
              let resets = latest.resetsAt else { return nil }
        return build(
            points: points
                .inCycle(resetting: resets, duration: duration)
                .map { (time: $0.sampledAt, value: $0.usedPercentage) },
            latestUsed: latest.usedPercentage,
            resetsAt: resets, duration: duration, now: now)
    }

    static func cycle(
        scoped row: ScopedWindowRow, history: [ScopedSamplePoint],
        duration: TimeInterval, now: Date
    ) -> PaceChartView.Data? {
        guard let resets = row.resetsAt else { return nil }
        return build(
            points: history
                .inCycle(identity: row.identity, resetting: resets, duration: duration)
                .map { (time: $0.sampledAt, value: $0.percent) },
            latestUsed: row.percent,
            resetsAt: resets, duration: duration, now: now)
    }

    /// The same line with a forecast overlay attached. Consumers build the
    /// projection themselves (from the live engine on the dashboard, from the
    /// exported snapshot in the widget) and layer it on the shared base.
    func withProjection(_ points: [Point], crossesFullAt: Date?) -> PaceChartView.Data {
        PaceChartView.Data(
            cycleStart: cycleStart, resetsAt: resetsAt, durationSeconds: durationSeconds,
            points: self.points, usedPct: usedPct,
            projection: points, projectionCrossesFullAt: crossesFullAt)
    }

    /// Clip to the cycle, sort ascending, and pin a tail at "now" so the line
    /// tracks to the current time even when the newest poll is a few minutes
    /// old. The tail is clamped to the reset: once `now > resetsAt` (cycle
    /// over, no fresh sample yet) a point at `now` would fall outside the
    /// chart's x domain.
    private static func build(
        points raw: [(time: Date, value: Double)], latestUsed: Double,
        resetsAt: Date, duration: TimeInterval, now: Date
    ) -> PaceChartView.Data {
        let cycleStart = resetsAt.addingTimeInterval(-duration)
        var points = raw
            .filter { $0.time >= cycleStart && $0.time <= now }
            .sorted { $0.time < $1.time }
            .map { Point(time: $0.time, value: $0.value) }
        points = decimate(points, to: plotPointCap)
        let tailTime = min(now, resetsAt)
        if points.last?.time != tailTime {
            points.append(Point(time: tailTime, value: latestUsed))
        }
        return PaceChartView.Data(
            cycleStart: cycleStart, resetsAt: resetsAt, durationSeconds: duration,
            points: points, usedPct: latestUsed)
    }

    /// How many points a line may carry into the chart.
    ///
    /// The polling cadence, not the chart, decided this before: a 7-day cycle
    /// at roughly a sample a minute is ~10,000 points, drawn into a column a
    /// few hundred points wide. The data preparation was never the problem —
    /// measured at under 50 ms — but handing Swift Charts ten thousand marks
    /// per column, three columns at a time, cost **2.3 seconds of main thread**
    /// on first render and 110–330 ms every time anything re-rendered.
    ///
    /// 400 is still more than one point per pixel at any width this card is
    /// laid out at, so the line is pixel-identical.
    static var plotPointCap: Int { 400 }

    /// Reduce a series to at most `cap` points without changing its shape.
    ///
    /// Min/max per time bucket rather than every-nth: a rate-limit line is a
    /// staircase with a vertical drop at each reset, and plain decimation
    /// eventually lands on neither side of a drop and rounds the corner off.
    /// Keeping both extremes of each bucket preserves the envelope — the
    /// steps, the spikes, and the cliff — at two points per bucket.
    ///
    /// The first and last points are always kept: the first anchors the line
    /// to the cycle start, and the last is where the "now" tail attaches.
    static func decimate(_ points: [Point], to cap: Int) -> [Point] {
        guard cap >= 4, points.count > cap,
              let first = points.first, let last = points.last else { return points }

        let buckets = cap / 2
        let start = first.time.timeIntervalSinceReferenceDate
        let span = max(last.time.timeIntervalSinceReferenceDate - start, .ulpOfOne)

        var out: [Point] = []
        out.reserveCapacity(cap + 2)
        var index = 0
        for bucket in 0..<buckets {
            let upper = start + span * Double(bucket + 1) / Double(buckets)
            var low: Point?
            var high: Point?
            while index < points.count {
                let p = points[index]
                let t = p.time.timeIntervalSinceReferenceDate
                if t >= upper && bucket < buckets - 1 { break }
                if low == nil || p.value < low!.value { low = p }
                if high == nil || p.value > high!.value { high = p }
                index += 1
            }
            guard let low, let high else { continue }
            // Emit in time order, or the line doubles back on itself.
            if low.time == high.time {
                out.append(low)
            } else if low.time < high.time {
                out.append(low); out.append(high)
            } else {
                out.append(high); out.append(low)
            }
        }

        if out.first?.time != first.time { out.insert(first, at: 0) }
        if out.last?.time != last.time { out.append(last) }
        return out
    }
}
