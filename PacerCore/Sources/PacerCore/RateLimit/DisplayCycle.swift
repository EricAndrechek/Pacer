import Foundation

/// One rate-limit window's time bracket as the dashboard should display
/// it — distinct from the *underlying sample's* cycle, which may already
/// be in the past.
///
/// When `now < resetsAt`, this just mirrors the underlying cycle. When
/// `now >= resetsAt` (the displayed sample is from a cycle that already
/// ended, and Pacer hasn't ingested a fresh sample yet), the bracket
/// rolls forward by one duration and `isAwaiting` flips true so every
/// consumer — chart, hero %, pace chip, caption — can suppress
/// prior-cycle numbers in favor of an "awaiting first sample" treatment.
///
/// See #4 for the UX motivation and #2 for the visual bug that surfaced
/// the underlying staleness.
public struct DisplayCycle: Sendable, Equatable {
    /// Left edge of the displayed window. For an active cycle, this is
    /// `resetsAt - duration`. For an awaiting cycle, this is the prior
    /// sample's `resetsAt` (i.e. the moment the new cycle would start).
    public let cycleStart: Date
    /// Right edge of the displayed window. For an active cycle, the
    /// sample's own `resetsAt`. For an awaiting cycle, one `duration`
    /// past it.
    public let resetsAt: Date
    /// True when the displayed cycle has been rolled forward because
    /// the underlying sample's cycle already ended. Consumers must
    /// render a neutral placeholder when this is true — the
    /// percentages and band classifications from the prior sample are
    /// not meaningful for the new cycle.
    public let isAwaiting: Bool
    /// Fraction (0…1) of the displayed cycle that has elapsed. Always
    /// 0 when `isAwaiting` is true (the new cycle hasn't started
    /// accumulating from Pacer's perspective).
    public let paceFraction: Double

    public init(cycleStart: Date, resetsAt: Date, isAwaiting: Bool, paceFraction: Double) {
        self.cycleStart = cycleStart
        self.resetsAt = resetsAt
        self.isAwaiting = isAwaiting
        self.paceFraction = paceFraction
    }
}

public extension DisplayCycle {
    /// Resolve the display cycle for one window. `resetsAt` is the most
    /// recent sample's reset time, `duration` is the window's nominal
    /// length (e.g. 5×3600 for the 5-hour window). Pass `now` in tests
    /// to control time; production uses the current date.
    static func resolve(
        resetsAt: Date,
        duration: TimeInterval,
        now: Date = Date()
    ) -> DisplayCycle {
        if now >= resetsAt {
            // Prior cycle has ended. Roll forward by exactly one
            // duration. The new bracket is a placeholder — its
            // boundaries are correct relative to the prior reset, but
            // no data populates it until a fresh sample lands.
            return DisplayCycle(
                cycleStart: resetsAt,
                resetsAt: resetsAt.addingTimeInterval(duration),
                isAwaiting: true,
                paceFraction: 0
            )
        }
        let cycleStart = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(cycleStart)
        let paceFraction = max(0, min(1, elapsed / duration))
        return DisplayCycle(
            cycleStart: cycleStart,
            resetsAt: resetsAt,
            isAwaiting: false,
            paceFraction: paceFraction
        )
    }
}
