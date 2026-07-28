import Foundation
import Testing
@testable import PacerCore
@testable import PacerUI

/// The scoped (`limits[]`) actual-usage line — cycle membership and the
/// chart-data builder behind every per-model pace column.
///
/// Reproduces the failure captured on 2026-07-28: a "Fable" weekly column
/// that plotted one dot at "now" instead of the cycle's curve, while the
/// 5-hour and 7-day columns beside it drew fine. Two independent causes,
/// one test suite:
///
///  1. **Exact-equality cycle membership.** The scoped path filtered
///     `resetsAt == resets`. The server re-serializes `resets_at` per
///     response and it jitters in the milliseconds, so of ~1,300 rows in the
///     live store's current cycle, exactly one matched.
///  2. **A flat row cap.** The scoped history query was capped at 600 rows
///     shared across every limit the account reports. At the real cadence
///     (~1 poll/min, one row per limit) that is about three hours — 2% of a
///     seven-day window — so even with membership fixed the line would have
///     drawn as a stub near "now".
@Suite struct ScopedCycleHistoryTests {

    private static let sevenDays: TimeInterval = 7 * 86400
    private static let fable = "weekly_scoped|Fable|"

    private func row(
        _ sampledAt: Date, pct: Double, resets: Date?, identity: String = fable
    ) -> UsageLimitSample {
        UsageLimitSample(
            sampledAt: sampledAt, identity: identity, kind: "weekly_scoped",
            group: "weekly", label: "Fable", percent: pct, resetsAt: resets,
            severity: "normal", isActive: true, modelDisplayName: "Fable", source: "oauth")
    }

    /// One realistic cycle: polled every 55 s with the `resets_at` jitter the
    /// server actually emits, climbing monotonically.
    private func jitteredCycle(
        resets: Date, elapsed: TimeInterval, identity: String = fable
    ) -> [UsageLimitSample] {
        let cycleStart = resets.addingTimeInterval(-Self.sevenDays)
        return stride(from: 0, to: elapsed, by: 55).enumerated().map { i, offset in
            // Deterministic ±0.5 s wobble, distinct on essentially every row.
            let jitter = Double((i &* 37) % 1000) / 1000.0 - 0.5
            return row(cycleStart.addingTimeInterval(offset),
                       pct: (offset / elapsed * 15).rounded(),
                       resets: resets.addingTimeInterval(jitter),
                       identity: identity)
        }
    }

    // MARK: - Cycle membership

    /// The core regression: sub-second reset jitter must not shrink a cycle.
    @Test func keepsJitteredRowsExactEqualityWouldDrop() {
        let resets = Date(timeIntervalSince1970: 2_000_000)
        let history = jitteredCycle(resets: resets, elapsed: 1.5 * 86400)
        let anchor = history.last!.resetsAt!

        // What the old filter saw: the rows sharing the newest millisecond.
        let exactMatches = history.filter { $0.resetsAt == anchor }
        #expect(exactMatches.count < 5)          // ~1 of ~2,300

        let kept = history.inCycle(identity: Self.fable, resetting: anchor, duration: Self.sevenDays)
        #expect(kept.count == history.count)     // all of them
    }

    /// Other identities' rows share the table (one row per limit per poll) and
    /// must never be interleaved into this window's line.
    @Test func dropsOtherIdentities() {
        let resets = Date(timeIntervalSince1970: 2_000_000)
        let mine = jitteredCycle(resets: resets, elapsed: 6 * 3600)
        let theirs = jitteredCycle(resets: resets, elapsed: 6 * 3600, identity: "weekly_all||")

        let kept = (mine + theirs).inCycle(
            identity: Self.fable, resetting: resets, duration: Self.sevenDays)
        #expect(kept.count == mine.count)
        #expect(kept.allSatisfy { $0.identity == Self.fable })
    }

    /// Same boundary rule as the fixed windows: the previous cycle's final
    /// reading is excluded, the post-reset `resets_at: null` idle rows are not.
    @Test func dropsPreviousCycleButKeepsNilResetIdleRows() {
        let prevReset = Date(timeIntervalSince1970: 3_000_000)
        let curReset = prevReset.addingTimeInterval(Self.sevenDays)
        let straggler = row(prevReset.addingTimeInterval(0.034), pct: 82, resets: prevReset)
        let idle = row(prevReset.addingTimeInterval(300), pct: 0, resets: nil)
        let fresh = row(prevReset.addingTimeInterval(3600), pct: 5, resets: curReset)

        let kept = [straggler, idle, fresh].inCycle(
            identity: Self.fable, resetting: curReset, duration: Self.sevenDays)
        #expect(kept.count == 2)
        #expect(!kept.contains { $0.percent == 82 })
    }

    /// The line is plotted in time order regardless of how rows arrive (the
    /// store hands them back newest-first).
    @Test func returnsAscendingByTime() {
        let resets = Date(timeIntervalSince1970: 4_000_000)
        let history = jitteredCycle(resets: resets, elapsed: 3600).reversed()
        let kept = Array(history).inCycle(
            identity: Self.fable, resetting: resets, duration: Self.sevenDays)
        #expect(kept == kept.sorted { $0.sampledAt < $1.sampledAt })
    }

    // MARK: - Chart data

    /// End to end: a realistic jittered cycle becomes a real curve, spanning
    /// cycle start → now, not a single point.
    @Test func scopedChartPlotsWholeCycle() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let elapsed = 1.55 * 86400
        let resets = now.addingTimeInterval(Self.sevenDays - elapsed)
        let history = jitteredCycle(resets: resets, elapsed: elapsed)
        let latest = history.last!

        let data = PaceChartView.Data.cycle(
            scoped: latest, history: history, duration: Self.sevenDays, now: now)
        let points = try! #require(data).points

        // Every reading, none dropped, plus the tail pinned to "now" (the last
        // poll landed a cadence-step short of it).
        #expect(points.count == history.count + 1)
        // Spans the elapsed cycle rather than clustering at the tail.
        let span = points.last!.time.timeIntervalSince(points.first!.time)
        #expect(span > elapsed - 120)
        #expect(points.first!.time >= data!.cycleStart)
        #expect(points.last!.time == now)        // pinned to now
        #expect(data!.usedPct == latest.percent)
    }

    /// A window with no reading yet has no line (and no synthesized dot).
    @Test func scopedChartNilWithoutReset() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let idle = row(now, pct: 0, resets: nil)
        #expect(PaceChartView.Data.cycle(
            scoped: idle, history: [idle], duration: Self.sevenDays, now: now) == nil)
    }

    /// The fixed 5h/7d builder shares the same code path — same clipping,
    /// same "now" tail — so the two window kinds can't drift apart again.
    @Test func fixedChartMatchesScopedShape() {
        let now = Date(timeIntervalSince1970: 6_000_000)
        let resets = now.addingTimeInterval(3600)
        let offsets: [TimeInterval] = Array(stride(from: -14340, to: 0, by: 300))
        let samples: [RateLimitSample] = offsets.enumerated().map { i, offset in
            let jitter: TimeInterval = Double((i &* 37) % 1000) / 1000.0 - 0.5
            let used: Double = (offset + 14400) / 3600 * 8
            return RateLimitSample(
                sampledAt: now.addingTimeInterval(offset), window: "five_hour",
                usedPercentage: used, resetsAt: resets.addingTimeInterval(jitter),
                source: "oauth")
        }
        let data = try! #require(PaceChartView.Data.cycle(
            fixed: samples.reversed(), duration: 5 * 3600, now: now))
        #expect(data.points.count == samples.count + 1)   // + the "now" tail
        #expect(data.points.last!.time == now)
        #expect(data.points == data.points.sorted { $0.time < $1.time })
    }

    /// The forecast overlay is layered onto the shared base, leaving the
    /// actual line (what the share image renders) untouched.
    @Test func withProjectionLeavesActualLineAlone() {
        let now = Date(timeIntervalSince1970: 7_000_000)
        let resets = now.addingTimeInterval(Self.sevenDays * 0.5)
        let history = jitteredCycle(resets: resets, elapsed: Self.sevenDays * 0.5)
        let base = try! #require(PaceChartView.Data.cycle(
            scoped: history.last!, history: history, duration: Self.sevenDays, now: now))

        let overlay = [PaceChartView.Data.Point(time: now, value: 15),
                       PaceChartView.Data.Point(time: resets, value: 40)]
        let live = base.withProjection(overlay, crossesFullAt: nil)

        #expect(live.points == base.points)
        #expect(base.projection == nil)
        #expect(live.projection?.count == 2)
    }
}
