import Foundation
import SwiftData

/// A rate-limit reading as the chart actually uses it: four scalars, no
/// `@Model`, `Sendable`.
///
/// The pace chart plots 8 days, which on a busy account is ~12,500 fixed rows
/// and ~19,000 scoped ones. As `@Model` objects those are context-bound and
/// main-actor-bound, so loading them is main-thread work — and SwiftData
/// faults whole objects at roughly 66 µs each regardless of
/// `propertiesToFetch`, so a load is seconds of frozen UI. That was tolerable
/// while it happened on appear and then incrementally every five minutes. It
/// stopped being tolerable when switching accounts started triggering it,
/// because a freeze you cause by clicking something reads as the app being
/// broken.
///
/// Values can be built on a background context and handed across, which is the
/// same shape `AccountTotals` and `TokenPoolStatus` already use: do the work
/// off the main actor, cross the boundary with something small.
public struct LimitSamplePoint: Sendable, Equatable {
    public let sampledAt: Date
    /// `"five_hour"` / `"seven_day"` — the chart buckets on it.
    public let window: String
    public let usedPercentage: Double
    public let resetsAt: Date?

    public init(sampledAt: Date, window: String, usedPercentage: Double, resetsAt: Date?) {
        self.sampledAt = sampledAt
        self.window = window
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

/// The scoped (`limits[]`) counterpart to `LimitSamplePoint`.
public struct ScopedSamplePoint: Sendable, Equatable {
    public let sampledAt: Date
    /// `kind|model|surface` — several identities share one history bag, so the
    /// line for a column filters on this.
    public let identity: String
    public let percent: Double
    public let resetsAt: Date?

    public init(sampledAt: Date, identity: String, percent: Double, resetsAt: Date?) {
        self.sampledAt = sampledAt
        self.identity = identity
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public extension RateLimitSample {
    var limitPoint: LimitSamplePoint {
        LimitSamplePoint(sampledAt: sampledAt, window: window,
                         usedPercentage: usedPercentage, resetsAt: resetsAt)
    }
}

public extension UsageLimitSample {
    var scopedPoint: ScopedSamplePoint {
        ScopedSamplePoint(sampledAt: sampledAt, identity: identity,
                          percent: percent, resetsAt: resetsAt)
    }
}

public extension Sequence where Element == LimitSamplePoint {
    /// Points belonging to the cycle resetting at `resets`. Same jitter-tolerant
    /// rule as the `RateLimitSample` version — see that one for why filtering
    /// on the sample's own reset beats filtering on its timestamp.
    func inCycle(resetting resets: Date, duration: TimeInterval) -> [LimitSamplePoint] {
        filter { RateLimitCycle.contains(sampleReset: $0.resetsAt, resets: resets, duration: duration) }
    }
}

public extension Sequence where Element == ScopedSamplePoint {
    func inCycle(identity: String, resetting resets: Date,
                 duration: TimeInterval) -> [ScopedSamplePoint] {
        filter {
            $0.identity == identity
                && RateLimitCycle.contains(sampleReset: $0.resetsAt, resets: resets, duration: duration)
        }
    }
}
