import Foundation

/// When the HTTP API's snapshot refresher builds: one build at a time, a rest
/// after each (`PacerSnapshotSpacing`), and an urgent request that does not
/// wait out a rest. Pure, so a test can drive it; the refresher holds one
/// under its lock and does what each step says.
///
/// A build is in one of two states, which used to be one "in flight" flag:
/// - **scheduled**: waiting out the rest after the last build, on a timer the
///   refresher can cancel. Nothing is running. A normal request is folded
///   into it. An urgent one (the active login changed, so every client holds
///   the wrong login's snapshot) replaces it with a build that starts now.
/// - **running**: on the build queue, where nothing interrupts it. Requests
///   meanwhile become exactly one build after it: at once if any of them was
///   urgent, otherwise after the rest.
///
/// With the one flag, an urgent request that landed during a rest returned
/// early like any other and waited the rest out, up to a minute after a slow
/// build, before the new login's snapshot was built.
public struct PacerSnapshotBuildPlan: Sendable, Equatable {

    /// What the refresher does next.
    public enum Step: Sendable, Equatable {
        /// Nothing: a running or scheduled build takes the request with it.
        case none
        /// Start build `token` in `delay` awake seconds, first cancelling the
        /// scheduled build `replacing`, when there is one.
        case schedule(token: UInt64, delay: TimeInterval, replacing: UInt64?)
    }

    public private(set) var spacing = PacerSnapshotSpacing()
    /// A build is running.
    public private(set) var isBuilding = false
    /// The build waiting out its rest, if any.
    public private(set) var scheduled: UInt64?
    /// A request that no build has taken up yet.
    public private(set) var pending = false
    /// One of those requests was urgent: the next build skips the rest.
    public private(set) var pendingUrgent = false
    private var lastToken: UInt64 = 0

    public init() {}

    /// A request for a rebuild. `now` is awake seconds.
    public mutating func request(urgent: Bool, now: TimeInterval) -> Step {
        pending = true
        if urgent { pendingUrgent = true }
        // `finish` schedules the follow-up, at once if this was urgent.
        if isBuilding { return .none }
        if let scheduled {
            return urgent ? schedule(delay: 0, replacing: scheduled) : .none
        }
        return schedule(delay: pendingUrgent ? 0 : spacing.delay(now: now), replacing: nil)
    }

    /// Build `token`'s timer fired. Returns whether the build is urgent, or
    /// nil when it should not run: it was replaced or dropped (a timer
    /// cancelled after it had already started still gets here), or no
    /// request is waiting.
    public mutating func begin(token: UInt64) -> Bool? {
        guard scheduled == token else { return nil }
        scheduled = nil
        guard pending else { return nil }
        let urgent = pendingUrgent
        pending = false
        pendingUrgent = false
        isBuilding = true
        return urgent
    }

    /// The running build ended. All three times are awake seconds. `proceed`
    /// is false once the refresher has stopped: nothing follows then.
    public mutating func finish(startedAt: TimeInterval, endedAt: TimeInterval,
                                now: TimeInterval, proceed: Bool) -> Step {
        isBuilding = false
        spacing.buildFinished(startedAt: startedAt, endedAt: endedAt)
        guard proceed else {
            pending = false
            pendingUrgent = false
            return .none
        }
        guard pending else { return .none }
        return schedule(delay: pendingUrgent ? 0 : spacing.delay(now: now), replacing: nil)
    }

    /// Stop: forget every request, and drop the scheduled build, whose token
    /// is returned so its timer can be cancelled. A running build carries on
    /// and still reports to `finish`. The spacing starts over.
    public mutating func reset() -> UInt64? {
        let dropped = scheduled
        scheduled = nil
        pending = false
        pendingUrgent = false
        spacing = PacerSnapshotSpacing()
        return dropped
    }

    private mutating func schedule(delay: TimeInterval, replacing: UInt64?) -> Step {
        lastToken &+= 1
        scheduled = lastToken
        return .schedule(token: lastToken, delay: delay, replacing: replacing)
    }
}
