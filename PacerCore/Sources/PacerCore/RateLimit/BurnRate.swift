import Foundation

/// Linear projection of when a rate-limit window will hit 100% based on
/// the slope of recent samples. The math is intentionally simple — port
/// of Claude God's `UsageManager.swift:602-628` approach — so it's
/// fast, stable, and matches user expectations ("if I keep going at
/// this rate…").
///
/// The window-reset boundary is treated as a hard reset rather than a
/// slope inflection. If the linear projection lands after the reset we
/// report no projected limit hit — the user will reset to 0% first.
public enum BurnRate {

    /// Result of one burn-rate computation.
    public struct Projection: Equatable, Sendable {
        /// Slope from the first considered sample to the last, in
        /// percentage points per hour. Negative when the window's
        /// usage is decreasing (just past a reset, or the server's
        /// rolling window rolled some old usage out).
        public let slopePercentPerHour: Double
        /// When the linear extrapolation crosses 100%. nil when:
        /// - slope is non-positive (not increasing → no projected hit)
        /// - the projection lands past the reset boundary (the window
        ///   resets first)
        public let projectedFullAt: Date?
        /// Convenience: `projectedFullAt.timeIntervalSince(now)`. nil
        /// when `projectedFullAt` is nil.
        public let etaSeconds: TimeInterval?
        /// True iff `projectedFullAt` is non-nil. Mirrors the field for
        /// readable call sites.
        public var willHitLimitBeforeReset: Bool { projectedFullAt != nil }
    }

    /// Minimum samples to consider. Two is enough for a slope, but the
    /// quality of the projection is much higher with more — the
    /// recommended minimum is three, which excludes a single
    /// transient-spike artifact.
    public static let minSamples = 3
    /// Minimum wall-clock span across the considered samples. Without
    /// this an extrapolation off two samples 30 seconds apart projects
    /// wild numbers ("limit in 12 minutes!") from noise.
    public static let minWindowSeconds: TimeInterval = 5 * 60
    /// Maximum sample age included in the linear regression. Older
    /// samples drag the slope toward "average over the whole window"
    /// when what we want is "what's happening RIGHT NOW." 90 minutes
    /// captures enough samples (at 5-min OAuth cadence that's ≥18
    /// rows) while staying responsive to behavioral changes.
    public static let lookbackSeconds: TimeInterval = 90 * 60

    /// Convenience parameter bundle so call sites don't have to thread
    /// six positional arguments. All fields default to the conservative
    /// production values; tests inject their own.
    public struct Parameters: Sendable {
        public var minSamples: Int
        public var minWindowSeconds: TimeInterval
        public var lookbackSeconds: TimeInterval
        public var now: Date

        public init(
            minSamples: Int = BurnRate.minSamples,
            minWindowSeconds: TimeInterval = BurnRate.minWindowSeconds,
            lookbackSeconds: TimeInterval = BurnRate.lookbackSeconds,
            now: Date = Date()
        ) {
            self.minSamples = minSamples
            self.minWindowSeconds = minWindowSeconds
            self.lookbackSeconds = lookbackSeconds
            self.now = now
        }
    }

    /// One observation, mirror of the on-disk `RateLimitSample` minus
    /// the SwiftData attributes. Decoupling lets the pure math live
    /// without importing SwiftData into the test path.
    public struct Sample: Equatable, Sendable {
        public let sampledAt: Date
        public let usedPercentage: Double

        public init(sampledAt: Date, usedPercentage: Double) {
            self.sampledAt = sampledAt
            self.usedPercentage = usedPercentage
        }
    }

    /// Project when the window will hit 100%.
    ///
    /// - Parameters:
    ///   - samples: history for ONE window. Order doesn't matter — we
    ///     sort internally — but the caller must pre-filter to a single
    ///     window kind (mixing 5h and 7d rows is meaningless).
    ///   - resetsAt: optional reset boundary. When the projection lands
    ///     after this point, we return a non-projecting result —
    ///     `slopePercentPerHour` is still populated for display.
    ///   - parameters: knobs (see `Parameters`).
    /// - Returns: a projection with at minimum `slopePercentPerHour`.
    ///   `projectedFullAt` is nil when there's no positive slope, when
    ///   we don't have enough signal, or when the projection lands
    ///   past `resetsAt`.
    public static func project(
        samples: [Sample],
        resetsAt: Date?,
        parameters: Parameters = Parameters()
    ) -> Projection? {
        let now = parameters.now
        let lookbackCutoff = now.addingTimeInterval(-parameters.lookbackSeconds)
        let recent = samples
            .filter { $0.sampledAt >= lookbackCutoff && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }

        guard recent.count >= parameters.minSamples,
              let first = recent.first,
              let last = recent.last
        else {
            return nil
        }
        let spanSeconds = last.sampledAt.timeIntervalSince(first.sampledAt)
        guard spanSeconds >= parameters.minWindowSeconds else { return nil }

        let deltaPct = last.usedPercentage - first.usedPercentage
        let slope = deltaPct / (spanSeconds / 3600.0)

        // Slope is positive only when usage is increasing. Negative
        // means we're past a reset and rolling old usage out. We still
        // return the slope so the UI can show "-3%/hr" — but no full-
        // limit projection.
        guard slope > 0 else {
            return Projection(
                slopePercentPerHour: slope,
                projectedFullAt: nil,
                etaSeconds: nil
            )
        }

        let remainingPct = max(0, 100 - last.usedPercentage)
        // If we're already at 100% the projection is "right now" — but
        // surfacing "now" is more confusing than helpful. The card UI
        // already shows the 100% state directly; suppress the eta in
        // that case.
        guard remainingPct > 0 else {
            return Projection(
                slopePercentPerHour: slope,
                projectedFullAt: nil,
                etaSeconds: nil
            )
        }

        let hoursToFull = remainingPct / slope
        let projectedAt = now.addingTimeInterval(hoursToFull * 3600.0)

        // Reset comes first → no usable projection. We still leak the
        // slope so callers can show a rate without misleading them
        // about a limit they won't actually hit this cycle.
        if let resetsAt, projectedAt > resetsAt {
            return Projection(
                slopePercentPerHour: slope,
                projectedFullAt: nil,
                etaSeconds: nil
            )
        }

        return Projection(
            slopePercentPerHour: slope,
            projectedFullAt: projectedAt,
            etaSeconds: projectedAt.timeIntervalSince(now)
        )
    }

    /// Don't raise a burn-rate warning below this utilization. Early in a
    /// window a brief burst projects an alarming slope that almost always
    /// flattens out; gating on a floor keeps the warning from crying wolf
    /// at, say, 15%. Distinct from the fixed-percentage threshold alerts —
    /// those fire on *level*, this on *rate*.
    public static let warningUsedFloor: Double = 50

    /// Whether a projection warrants a "you'll hit the limit before it
    /// resets" warning: the linear projection lands before the reset
    /// boundary (`willHitLimitBeforeReset`) AND you're already past the
    /// floor. Pure so the notification layer stays a thin caller.
    public static func warrantsWarning(
        _ projection: Projection,
        usedPct: Double,
        floor: Double = warningUsedFloor
    ) -> Bool {
        projection.willHitLimitBeforeReset && usedPct >= floor
    }
}
