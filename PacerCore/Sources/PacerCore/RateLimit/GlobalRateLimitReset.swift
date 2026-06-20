import Foundation

/// Detects an *off-schedule global reset* of a rate-limit window — the
/// event where Anthropic resets everyone's usage ahead of the normal
/// cycle boundary (they've done this a few times, usually before they
/// announce it). The fingerprint that distinguishes it from an ordinary
/// rollover: utilization collapses from a meaningful level to near-zero
/// while the cycle was **not** due to end — the pre-reset `resetsAt`
/// anchor sat comfortably in the future at the drop, and across the
/// collapse that anchor either stays put OR is **cleared to null**.
/// (Anthropic's 2026-06-20 reset nulled the anchor and dropped the 7-day
/// window from a modest ~17%; an earlier reset left the anchor in place
/// at a higher level — this detector handles both.) A normal rollover, by
/// contrast, lands *at* the anchor and advances it; that's the separate
/// rollover path in `NotificationCoordinator`.
///
/// Contrast with the normal-rollover path in `NotificationCoordinator`
/// (`handleRateLimitReset`), which fires only when `resetsAt` advances.
/// The two are mutually exclusive by construction: a rollover advances
/// the anchor; an early global reset leaves it where it was. That
/// "anchor didn't move" check is the whole reason this needs its own
/// detector rather than reusing the rollover logic.
///
/// Pure and source-agnostic so it's unit-testable without a
/// `ModelContext`. Callers map their persisted samples — filtered to a
/// single window and ideally to the authoritative OAuth source — into
/// `Observation` values and hand them over in any order; `detect` sorts
/// internally. The function reads only the observations' own
/// timestamps, never the wall clock, so it's deterministic.
///
/// Detection deliberately does NOT require the high→low transition to be
/// recent: a reset that landed while the Mac was asleep or the app was
/// closed is still worth surfacing the moment Pacer sees a sustained low
/// on the unchanged anchor (the headroom persists until the real reset
/// day). The caller's only obligation is to feed observations spanning
/// the current cycle so the pre-reset high is present to compare against
/// — which, since the anchor hasn't rolled, is always within one
/// window-duration of now.
public enum GlobalRateLimitReset {

    /// One window observation, source-agnostic. Maps from a
    /// `RateLimitSample` at the call site.
    public struct Observation: Equatable, Sendable {
        public let sampledAt: Date
        public let usedPercentage: Double
        public let resetsAt: Date?

        public init(sampledAt: Date, usedPercentage: Double, resetsAt: Date?) {
            self.sampledAt = sampledAt
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    /// A confirmed early-reset event.
    public struct Detection: Equatable, Sendable {
        /// Utilization at the drop edge — the last reading before the
        /// collapse. The "from" in "dropped from X% to Y%".
        public let droppedFrom: Double
        /// Utilization now (the sustained low). The "to".
        public let droppedTo: Double
        /// The cycle anchor that stayed put across the drop — the proof
        /// this was an early reset and not a rollover. Used as the
        /// dedup key so we alert at most once per cycle.
        public let resetsAt: Date?
        /// `sampledAt` of the most recent confirming low sample.
        public let confirmedAt: Date

        public init(droppedFrom: Double, droppedTo: Double, resetsAt: Date?, confirmedAt: Date) {
            self.droppedFrom = droppedFrom
            self.droppedTo = droppedTo
            self.resetsAt = resetsAt
            self.confirmedAt = confirmedAt
        }
    }

    // MARK: - Tunables

    /// Default floor on how high the drop edge must have been for the
    /// collapse to be worth reporting. A window sitting at 8% ticking to
    /// 0% isn't a meaningful "you got headroom back" event. The caller
    /// overrides this per window — the 7-day window hitting 0% is rare
    /// and significant, so it uses a lower bar than the chatty 5-hour one.
    public static let highWatermark: Double = 25
    /// Default lower bound on how far in the future the pre-reset anchor
    /// must sit at the drop edge for the collapse to count as an *early*
    /// reset and not a normal rollover. A rollover lands *at* its anchor
    /// (lead ≈ one poll), so any real lead cleanly separates the two; this
    /// is also what stops the brief 0%/null window right after an ordinary
    /// rollover from reading as an early reset. Overridable per window.
    public static let defaultMinAnchorLead: TimeInterval = 30 * 60
    /// Post-reset utilization must be at or below this to count as a
    /// collapse to (near) zero.
    public static let lowWatermark: Double = 5
    /// `resetsAt` readings within this tolerance are treated as
    /// unchanged. Absorbs sub-minute server clock jitter in the anchor
    /// without admitting a real forward rollover (those jump by hours).
    public static let anchorTolerance: TimeInterval = 5 * 60
    /// The low state must hold across at least this many observations…
    public static let minConfirmingSamples: Int = 2
    /// …spanning at least this much wall-clock time. Together these two
    /// reject a single bad reading (fails the count) and a burst of
    /// rapid same-second pushes (fails the duration), so only a low that
    /// genuinely persists fires the alert — the user's "confirm it's not
    /// just a blip" requirement.
    public static let minConfirmDuration: TimeInterval = 4 * 60

    /// Returns a `Detection` if the most recent observations show a
    /// sustained collapse to near-zero preceded by a meaningfully high
    /// reading whose cycle anchor was still in the future — and the anchor
    /// did not roll forward across the collapse (it stayed put or was
    /// cleared to null). Otherwise nil.
    public static func detect(
        _ observations: [Observation],
        highWatermark: Double = GlobalRateLimitReset.highWatermark,
        minAnchorLead: TimeInterval = GlobalRateLimitReset.defaultMinAnchorLead
    ) -> Detection? {
        let series = observations.sorted { $0.sampledAt < $1.sampledAt }
        // Need at least the confirming low run plus one drop-edge sample.
        guard series.count >= minConfirmingSamples + 1 else { return nil }

        // The newest sample must currently be low. Unlike the original
        // detector we do NOT require it to carry an anchor: a global reset
        // can clear `resets_at` to null, and that's exactly the case we
        // most need to catch. We prove "the cycle didn't roll" off the
        // drop-edge anchor instead (below).
        guard let newest = series.last,
              newest.usedPercentage <= lowWatermark else { return nil }

        // Walk back from the newest sample collecting the maximal suffix
        // of low readings — the confirming low run. Anchors are checked
        // against the drop edge afterward, so a cleared (null) anchor
        // doesn't truncate the run here.
        var startIdx = series.count - 1
        var i = series.count - 1
        while i >= 0, series[i].usedPercentage <= lowWatermark {
            startIdx = i
            i -= 1
        }
        let lowRun = series[startIdx...]

        // Sustained: enough samples AND enough elapsed time.
        guard lowRun.count >= minConfirmingSamples else { return nil }
        guard newest.sampledAt.timeIntervalSince(lowRun.first!.sampledAt) >= minConfirmDuration else {
            return nil
        }

        // There must be a sample immediately before the low run to act
        // as the drop edge, and it must itself be meaningfully high.
        guard startIdx > 0 else { return nil }
        let before = series[startIdx - 1]
        guard before.usedPercentage >= highWatermark else { return nil }

        // The drop edge must carry a cycle anchor (the pre-reset reset
        // day) — without it we can't tell an early reset from a rollover.
        guard let beforeAnchor = before.resetsAt else { return nil }

        // Cut short: the cycle was NOT due to end at the drop — its anchor
        // sat comfortably in the future. A normal rollover lands *at* its
        // anchor (lead ≈ one poll), so this is what rejects the brief
        // 0%/null window that follows an ordinary rollover.
        guard beforeAnchor.timeIntervalSince(before.sampledAt) >= minAnchorLead else {
            return nil
        }

        // The anchor did NOT roll forward across the low run: every
        // confirming sample's anchor is either cleared (null) or still the
        // pre-reset anchor within jitter tolerance. A forward jump means a
        // real rollover began → not an early reset. (This also keeps a long
        // gap honest: a drop edge from before a rollover carries the old
        // anchor while the low run carries the advanced one, and is
        // rejected here no matter how far back we look.)
        for s in lowRun {
            if let r = s.resetsAt,
               abs(r.timeIntervalSince(beforeAnchor)) > anchorTolerance {
                return nil
            }
        }

        return Detection(
            droppedFrom: before.usedPercentage,
            droppedTo: newest.usedPercentage,
            // Report the stable pre-reset anchor — non-null even when the
            // live one was cleared — so the caller's per-cycle dedup key
            // doesn't churn across the null-anchor window.
            resetsAt: beforeAnchor,
            confirmedAt: newest.sampledAt
        )
    }
}
