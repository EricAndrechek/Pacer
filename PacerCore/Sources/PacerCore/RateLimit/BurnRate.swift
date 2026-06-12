import Foundation

/// The burn-rate warning contract between the intelligence engine and the
/// notification layer.
///
/// Historically this type owned the projection math too (a 90-minute linear
/// slope, later joined by a recency-weighted estimator for the 7-day window).
/// That math now lives in the engine — `UsageIntelligenceEngine.burnOutlook`
/// projects the limit crossing with the per-window *selected* model (for 7d,
/// typically the diurnal shape that knows an overnight lull is coming) — and
/// what remains here is the stable, view-independent shape the coordinator
/// consumes plus the warning decision itself.
public enum BurnRate {

    /// Result of one burn-outlook computation, in the shape the notification
    /// coordinator consumes.
    public struct Projection: Equatable, Sendable {
        /// Recent slope in percentage points per hour. Negative when the
        /// window's usage is decreasing (just past a reset, or the server's
        /// rolling window rolled some old usage out).
        public let slopePercentPerHour: Double
        /// When the projection crosses 100%, strictly before the reset
        /// boundary. nil when no pre-reset hit is projected.
        public let projectedFullAt: Date?
        /// Convenience: `projectedFullAt.timeIntervalSince(now)`. nil
        /// when `projectedFullAt` is nil.
        public let etaSeconds: TimeInterval?
        /// True iff `projectedFullAt` is non-nil. Mirrors the field for
        /// readable call sites.
        public var willHitLimitBeforeReset: Bool { projectedFullAt != nil }

        public init(
            slopePercentPerHour: Double,
            projectedFullAt: Date?,
            etaSeconds: TimeInterval?
        ) {
            self.slopePercentPerHour = slopePercentPerHour
            self.projectedFullAt = projectedFullAt
            self.etaSeconds = etaSeconds
        }
    }

    /// Don't raise a burn-rate warning below this utilization. Early in a
    /// window a brief burst projects an alarming slope that almost always
    /// flattens out; gating on a floor keeps the warning from crying wolf
    /// at, say, 15%. Distinct from the fixed-percentage threshold alerts —
    /// those fire on *level*, this on *rate*.
    public static let warningUsedFloor: Double = 50

    /// Whether a projection warrants a "you'll hit the limit before it
    /// resets" warning: the projection lands before the reset boundary
    /// (`willHitLimitBeforeReset`) AND you're already past the floor. Pure so
    /// the notification layer stays a thin caller.
    public static func warrantsWarning(
        _ projection: Projection,
        usedPct: Double,
        floor: Double = warningUsedFloor
    ) -> Bool {
        projection.willHitLimitBeforeReset && usedPct >= floor
    }
}
