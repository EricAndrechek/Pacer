import Foundation

/// When the HTTP API's snapshot refresher may start its next build, pure so a
/// test can drive the clock and the memory pressure.
///
/// Why this exists: spacing builds 2 s after the previous *start* meant that
/// once a build took longer than that (up to 36 s on a Mac under memory
/// pressure) the next one began the moment it ended, and builds ran back to
/// back for 46-90% of some hours. Each one reads the window's turns and every
/// account's rollups, which keeps evicting the pages the main thread needs, so
/// the refresher was a cause of the very stalls it should not be able to
/// cause. A slow build now earns a proportionally long rest, and a Mac under
/// pressure rebuilds on the slow timer alone. An answer going stale is the
/// design's accepted cost: its age is on every response.
public struct PacerSnapshotSpacing: Sendable, Equatable {
    /// The least rest after a build, however quick it was.
    public static let minimumRest: TimeInterval = 2
    /// A build of duration d rests `restFactor * d` before the next starts, so
    /// the refresher's duty cycle is bounded at 1/(1 + restFactor) = 25%.
    public static let restFactor: Double = 3

    public private(set) var lastEndedAt: Date?
    public private(set) var lastDuration: TimeInterval = 0

    public init() {}

    /// Note a finished build (successful or not: a failing one costs the same).
    public mutating func buildFinished(startedAt: Date, endedAt: Date) {
        lastEndedAt = endedAt
        lastDuration = max(0, endedAt.timeIntervalSince(startedAt))
    }

    /// Seconds until the next build may start; 0 when it may start now.
    public func delay(now: Date) -> TimeInterval {
        guard let lastEndedAt else { return 0 }
        let rest = max(Self.minimumRest, Self.restFactor * lastDuration)
        return max(0, rest - now.timeIntervalSince(lastEndedAt))
    }

    /// Whether a scan cycle's request may start a build. At `warning` or worse
    /// only the slow timer (and an urgent account change) does: a scan cycle
    /// can land every few seconds while Claude Code is busy, and each build
    /// pages in what the main thread is about to want.
    public static func scanRequestMayBuild(pressure: MemoryPressure.Level) -> Bool {
        pressure < .warning
    }
}
