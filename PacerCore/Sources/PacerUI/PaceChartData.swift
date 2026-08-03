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
        let tailTime = min(now, resetsAt)
        if points.last?.time != tailTime {
            points.append(Point(time: tailTime, value: latestUsed))
        }
        return PaceChartView.Data(
            cycleStart: cycleStart, resetsAt: resetsAt, durationSeconds: duration,
            points: points, usedPct: latestUsed)
    }
}
