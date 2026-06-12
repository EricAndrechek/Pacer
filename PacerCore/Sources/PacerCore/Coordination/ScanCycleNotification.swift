import Foundation

/// Signal that a scan cycle (or out-of-band write, like an OAuth poll)
/// has just landed new data in the shared SwiftData store. Consumers
/// that live OUTSIDE the SwiftData reactivity graph — the most important
/// case is the WidgetKit extension, which doesn't observe `@Query` —
/// subscribe to this notification to know when to refresh.
///
/// Posted on the main queue from:
///   - `ScanCoordinator.runScanCycle()` after a successful `context.save()`
///     when the cycle actually wrote user-visible data.
///   - `ScanCoordinator.runAliasMigrationOnly()` after a successful save
///     when the alias-driven re-attribution changed any rows.
///   - `OAuthPoller.persist()` after a successful save of fresh
///     `RateLimitSample` rows.
///
/// `object` is always a `ScanCycleSummary` describing which categories
/// of data changed. Observers should switch on that to issue selective
/// refreshes (e.g. only kick the pace widgets when rate-limit rows
/// changed) rather than reloading every widget on every signal — the
/// WidgetKit reload budget is finite and a chatty Claude Code session
/// will easily issue dozens of scan cycles per minute.
public extension Notification.Name {
    static let pacerScanCycleDidComplete = Notification.Name(
        "com.ericandrechek.pacer.scanCycleDidComplete"
    )

    /// The intelligence engine finished a refit and has fresh answers.
    /// Engine-consuming cards refresh on THIS (not on raw scan ticks) so they
    /// re-ask exactly when the answers changed — never one tick stale, never
    /// speculatively. Posted on the main queue by the background service after
    /// every (throttled) `UsageIntelligenceEngine.recompute`.
    static let pacerEngineDidRecompute = Notification.Name(
        "com.ericandrechek.pacer.engineDidRecompute"
    )
}

/// What changed in one scan cycle, from the perspective of UI surfaces
/// that need to refresh. Intentionally coarser than `ScanReport`: the
/// summary's job is to tell observers which widget kinds (or other
/// out-of-process consumers) to reload, not to expose persistence
/// internals.
///
/// The three axes are orthogonal in principle:
///   - `samplesChanged` — new `TokenSample` rows + dependent rollups
///     (`DailyAggregate`, `ProjectDailyAggregate`, `SessionInfo`).
///   - `rateLimitsChanged` — new `RateLimitSample` rows from the
///     OAuth poller. Doesn't imply `samplesChanged` and vice-versa.
///   - `projectAttributionChanged` — a `ProjectPathAlias` edit caused
///     existing samples to re-bucket under different project paths.
///     Implies the project-dimensional rollups + session display names
///     shifted, even though no new raw samples landed.
///
/// Use `hasAnyChanges` for the "kick everything" pattern that doesn't
/// care about the breakdown.
public struct ScanCycleSummary: Sendable {
    public let samplesChanged: Bool
    public let rateLimitsChanged: Bool
    public let projectAttributionChanged: Bool

    public init(
        samplesChanged: Bool = false,
        rateLimitsChanged: Bool = false,
        projectAttributionChanged: Bool = false
    ) {
        self.samplesChanged = samplesChanged
        self.rateLimitsChanged = rateLimitsChanged
        self.projectAttributionChanged = projectAttributionChanged
    }

    public var hasAnyChanges: Bool {
        samplesChanged || rateLimitsChanged || projectAttributionChanged
    }
}

/// Post a `ScanCycleSummary` on the main queue. Wraps the
/// `NotificationCenter.post` call so callers don't have to remember the
/// notification name or the main-queue requirement (observers register
/// on `.main`, so posting off-main would deliver on the poster's queue
/// and break the @MainActor assumption in `WidgetRefreshCoordinator`).
///
/// No-op when `summary.hasAnyChanges == false`. The save-skip path in
/// `ScanCoordinator` already filters out idle cycles, but this is a
/// belt-and-suspenders guard against future call sites that don't.
@MainActor
public func postScanCycleSummary(_ summary: ScanCycleSummary) {
    guard summary.hasAnyChanges else { return }
    NotificationCenter.default.post(
        name: .pacerScanCycleDidComplete,
        object: summary
    )
}
