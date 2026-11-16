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
///
/// **Times are awake seconds** (`awakeNow()`), a clock that stops while the
/// Mac sleeps. On the wall clock a build the Mac slept through measured the
/// whole night: an 8 h sleep became a 24 h rest, and `asyncAfter`, which
/// counts only awake time, stretched that further still, while every trigger
/// in between was folded into the one waiting build. The rest is capped as
/// well (`maximumRest`), so no measurement, however wrong, can park the
/// snapshot for longer than a minute.
public struct PacerSnapshotSpacing: Sendable, Equatable {
    /// The least rest after a build, however quick it was.
    public static let minimumRest: TimeInterval = 2
    /// A build of duration d rests `restFactor * d` before the next starts, so
    /// the refresher's duty cycle is bounded at 1/(1 + restFactor) = 25%.
    public static let restFactor: Double = 3
    /// The longest rest, whatever the last build took. A build slow enough to
    /// reach it (20 s) is already a stall; resting longer would only leave
    /// every client's answer that much older.
    public static let maximumRest: TimeInterval = 60

    /// When the last build ended, in awake seconds.
    public private(set) var lastEndedAt: TimeInterval?
    public private(set) var lastDuration: TimeInterval = 0

    public init() {}

    /// Now, in seconds on the clock the spacing runs on: mach absolute time,
    /// which does not advance while the Mac sleeps. It is also the clock
    /// `DispatchTime.now()` and so `asyncAfter` count on, so a delay computed
    /// here is waited out exactly.
    public static func awakeNow() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// The rest a build of `duration` earns.
    public static func rest(afterBuildOf duration: TimeInterval) -> TimeInterval {
        min(maximumRest, max(minimumRest, restFactor * duration))
    }

    /// Note a finished build (successful or not: a failing one costs the
    /// same). Both times are awake seconds.
    public mutating func buildFinished(startedAt: TimeInterval, endedAt: TimeInterval) {
        lastEndedAt = endedAt
        lastDuration = max(0, endedAt - startedAt)
    }

    /// Seconds until the next build may start; 0 when it may start now. `now`
    /// is awake seconds. Never more than the rest itself, even for a `now`
    /// before the last build ended.
    public func delay(now: TimeInterval) -> TimeInterval {
        guard let lastEndedAt else { return 0 }
        let rest = Self.rest(afterBuildOf: lastDuration)
        return min(rest, max(0, rest - (now - lastEndedAt)))
    }

    /// Whether a scan cycle's request may start a build. At `warning` or worse
    /// only the slow timer (and an urgent account change) does: a scan cycle
    /// can land every few seconds while Claude Code is busy, and each build
    /// pages in what the main thread is about to want.
    public static func scanRequestMayBuild(pressure: MemoryPressure.Level) -> Bool {
        pressure < .warning
    }
}
