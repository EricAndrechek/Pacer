import Foundation
import Testing
@testable import PacerCore

@Suite("GlobalRateLimitReset.detect")
struct GlobalRateLimitResetTests {

    /// A fixed cycle anchor (the user's reset day) that stays put across
    /// an early global reset. 8 days out so it's clearly distinct from
    /// any rolled-forward anchor in the rollover tests.
    private let anchor = Date(timeIntervalSince1970: 1_750_000_000)

    /// Build an observation `minutesAgo` before a fixed "now" base, with
    /// the given utilization and anchor. Negative time offsets keep the
    /// series ordered oldest→newest as `minutesAgo` decreases.
    private func obs(
        minutesAgo: Double,
        pct: Double,
        anchor: Date?
    ) -> GlobalRateLimitReset.Observation {
        let base = Date(timeIntervalSince1970: 1_749_000_000)
        return .init(
            sampledAt: base.addingTimeInterval(-minutesAgo * 60),
            usedPercentage: pct,
            resetsAt: anchor
        )
    }

    // MARK: - Positive: the real early-reset signature

    @Test func detectsSustainedCollapseWithUnchangedAnchor() {
        // 60% → 0% → 0% → 0%, anchor never moves, polls 5 min apart.
        let series = [
            obs(minutesAgo: 15, pct: 60, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: anchor),
            obs(minutesAgo: 5, pct: 0, anchor: anchor),
            obs(minutesAgo: 0, pct: 0, anchor: anchor),
        ]
        let d = GlobalRateLimitReset.detect(series)
        #expect(d != nil)
        #expect(d?.droppedFrom == 60)
        #expect(d?.droppedTo == 0)
        #expect(d?.resetsAt == anchor)
    }

    @Test func ignoresSampleOrder() {
        // Same data shuffled — detect sorts internally.
        let series = [
            obs(minutesAgo: 0, pct: 0, anchor: anchor),
            obs(minutesAgo: 15, pct: 55, anchor: anchor),
            obs(minutesAgo: 5, pct: 1, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: anchor),
        ]
        #expect(GlobalRateLimitReset.detect(series)?.droppedFrom == 55)
    }

    // MARK: - Negative: the normal rollover (anchor advances)

    @Test func rejectsNormalRolloverWhereAnchorAdvances() {
        let nextAnchor = anchor.addingTimeInterval(7 * 24 * 3600)
        // High on the OLD anchor, then low on the NEW (advanced) anchor —
        // this is an ordinary rollover, handled elsewhere.
        let series = [
            obs(minutesAgo: 15, pct: 60, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: nextAnchor),
            obs(minutesAgo: 5, pct: 0, anchor: nextAnchor),
            obs(minutesAgo: 0, pct: 0, anchor: nextAnchor),
        ]
        #expect(GlobalRateLimitReset.detect(series) == nil)
    }

    // MARK: - Negative: blips and weak signals

    @Test func rejectsSingleLowSampleBlip() {
        // One low reading sandwiched — not sustained.
        let series = [
            obs(minutesAgo: 15, pct: 60, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: anchor),
            obs(minutesAgo: 5, pct: 58, anchor: anchor),
            obs(minutesAgo: 0, pct: 61, anchor: anchor),
        ]
        // Newest sample is high → not a current collapse.
        #expect(GlobalRateLimitReset.detect(series) == nil)
    }

    @Test func rejectsLowRunTooShortInTime() {
        // Two low samples but only ~30s apart (a burst of statusline
        // pushes), below minConfirmDuration — not confirmed.
        let series = [
            obs(minutesAgo: 6, pct: 60, anchor: anchor),
            obs(minutesAgo: 0.5, pct: 0, anchor: anchor),
            obs(minutesAgo: 0, pct: 0, anchor: anchor),
        ]
        #expect(GlobalRateLimitReset.detect(series) == nil)
    }

    @Test func rejectsWhenPriorUtilizationTooLow() {
        // Dropped from only 12% — not a meaningful headroom event.
        let series = [
            obs(minutesAgo: 15, pct: 12, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: anchor),
            obs(minutesAgo: 5, pct: 0, anchor: anchor),
            obs(minutesAgo: 0, pct: 0, anchor: anchor),
        ]
        #expect(GlobalRateLimitReset.detect(series) == nil)
    }

    @Test func detectsDropAcrossLongGap() {
        // High reading, then a multi-hour gap (Mac asleep / app closed),
        // then a sustained low on the SAME anchor. The headroom is real
        // and persists, so we surface it once a sustained low confirms —
        // the gap is fine because the anchor didn't roll.
        let series = [
            obs(minutesAgo: 200, pct: 60, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: anchor),
            obs(minutesAgo: 5, pct: 0, anchor: anchor),
            obs(minutesAgo: 0, pct: 0, anchor: anchor),
        ]
        let d = GlobalRateLimitReset.detect(series)
        #expect(d != nil)
        #expect(d?.droppedFrom == 60)
    }

    @Test func rejectsRolloverEvenAcrossLongGap() {
        // Same long gap, but the anchor advanced across it → ordinary
        // rollover, not an early reset. Must still be rejected no matter
        // how far back the high sits.
        let nextAnchor = anchor.addingTimeInterval(7 * 24 * 3600)
        let series = [
            obs(minutesAgo: 200, pct: 60, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: nextAnchor),
            obs(minutesAgo: 5, pct: 0, anchor: nextAnchor),
            obs(minutesAgo: 0, pct: 0, anchor: nextAnchor),
        ]
        #expect(GlobalRateLimitReset.detect(series) == nil)
    }

    @Test func rejectsWhenNewestStillHigh() {
        // Recovered/never-collapsed: newest is high.
        let series = [
            obs(minutesAgo: 15, pct: 60, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: anchor),
            obs(minutesAgo: 5, pct: 0, anchor: anchor),
            obs(minutesAgo: 0, pct: 40, anchor: anchor),
        ]
        #expect(GlobalRateLimitReset.detect(series) == nil)
    }

    @Test func rejectsWhenAnchorMissing() {
        // No cycle anchor on the low samples — can't prove "anchor
        // didn't move", so we don't claim an early reset.
        let series = [
            obs(minutesAgo: 15, pct: 60, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: nil),
            obs(minutesAgo: 5, pct: 0, anchor: nil),
            obs(minutesAgo: 0, pct: 0, anchor: nil),
        ]
        #expect(GlobalRateLimitReset.detect(series) == nil)
    }

    @Test func rejectsTooFewSamples() {
        let series = [
            obs(minutesAgo: 5, pct: 60, anchor: anchor),
            obs(minutesAgo: 0, pct: 0, anchor: anchor),
        ]
        #expect(GlobalRateLimitReset.detect(series) == nil)
    }

    @Test func absorbsSubMinuteAnchorJitter() {
        // The anchor wobbles by a few seconds between polls (server
        // rounding) — still the same cycle, should still detect.
        let series = [
            obs(minutesAgo: 15, pct: 60, anchor: anchor),
            obs(minutesAgo: 10, pct: 0, anchor: anchor.addingTimeInterval(3)),
            obs(minutesAgo: 5, pct: 0, anchor: anchor.addingTimeInterval(-2)),
            obs(minutesAgo: 0, pct: 0, anchor: anchor.addingTimeInterval(1)),
        ]
        #expect(GlobalRateLimitReset.detect(series) != nil)
    }
}
