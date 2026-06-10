import Foundation

/// Detects an *off-schedule global reset* of a rate-limit window — the
/// event where Anthropic resets everyone's usage ahead of the normal
/// cycle boundary (they've done this a few times, usually before they
/// announce it). The fingerprint that distinguishes it from an ordinary
/// rollover: utilization collapses from a meaningful level to near-zero
/// while the `resetsAt` cycle anchor does **not** move forward.
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

    /// The drop edge must have been at least this high for the collapse
    /// to be worth reporting. A window sitting at 8% ticking to 0% isn't
    /// a meaningful "you got headroom back" event.
    public static let highWatermark: Double = 25
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
    /// The drop must be observed *live*: the gap between the last high
    /// reading and the first low reading must be no larger than this.
    /// A multi-hour gap means the app was closed / asleep across the
    /// transition, so we can't say when in that gap the reset happened
    /// and it's probably stale — suppress rather than fire a banner
    /// about something from this morning.
    public static let maxDropGap: TimeInterval = 30 * 60

    /// Returns a `Detection` if the most recent observations show a
    /// sustained, anchor-stable collapse to near-zero preceded by a
    /// meaningfully high reading on the same cycle anchor. Otherwise nil.
    public static func detect(_ observations: [Observation]) -> Detection? {
        let series = observations.sorted { $0.sampledAt < $1.sampledAt }
        // Need at least the confirming low run plus one drop-edge sample.
        guard series.count >= minConfirmingSamples + 1 else { return nil }

        // The newest sample must currently be low and carry a cycle
        // anchor we can compare against (we can't prove "anchor didn't
        // move" without one).
        guard let newest = series.last,
              newest.usedPercentage <= lowWatermark,
              let anchor = newest.resetsAt else { return nil }

        // Walk back from the newest sample collecting the maximal suffix
        // of anchor-stable low readings — the confirming low run.
        var startIdx = series.count - 1
        var i = series.count - 1
        while i >= 0 {
            let s = series[i]
            guard s.usedPercentage <= lowWatermark,
                  let r = s.resetsAt,
                  abs(r.timeIntervalSince(anchor)) <= anchorTolerance else { break }
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
        // as the drop edge.
        guard startIdx > 0 else { return nil }
        let before = series[startIdx - 1]

        // The drop edge must itself be meaningfully high…
        guard before.usedPercentage >= highWatermark else { return nil }
        // …carry the SAME cycle anchor as the low run (if its anchor is
        // earlier, the cycle rolled over → normal reset, not this)…
        guard let beforeAnchor = before.resetsAt,
              abs(beforeAnchor.timeIntervalSince(anchor)) <= anchorTolerance else { return nil }
        // …and the high→low transition must have been seen live.
        guard lowRun.first!.sampledAt.timeIntervalSince(before.sampledAt) <= maxDropGap else {
            return nil
        }

        return Detection(
            droppedFrom: before.usedPercentage,
            droppedTo: newest.usedPercentage,
            resetsAt: anchor,
            confirmedAt: newest.sampledAt
        )
    }
}
