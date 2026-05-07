import Foundation

/// One five-hour or seven-day window from `/api/oauth/usage`.
/// `usedPercentage` is 0–100 (server returns it pre-computed; we don't
/// divide here). `resetsAt` is when the window rolls over — may be nil
/// when the server returned `resets_at: null`, which Anthropic does in
/// rare account states (we surface it as nil rather than synthesizing
/// a fake date).
public struct RateLimitWindow: Sendable, Equatable {
    public let usedPercentage: Double
    public let resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

/// One observation of the OAuth usage endpoint. Either window may be
/// nil — Anthropic occasionally returns only one for API-only users
/// or during account transitions. When persisting, we write a row only
/// for the windows that are present so we never overwrite a known
/// value with a missing one.
public struct RateLimitSnapshot: Sendable, Equatable {
    /// Wall-clock time we received the response. Pulled from a clock
    /// rather than parsed from the body so a clock skew between client
    /// and server doesn't desync sample timing.
    public let sampledAt: Date
    public let fiveHour: RateLimitWindow?
    public let sevenDay: RateLimitWindow?

    public init(sampledAt: Date, fiveHour: RateLimitWindow?, sevenDay: RateLimitWindow?) {
        self.sampledAt = sampledAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

/// Source labels written into `RateLimitSample.source`. String constants
/// rather than an enum because old SwiftData rows would fail to decode
/// if we ever rename a case.
public enum RateLimitSource {
    public static let oauth = "oauth"
    public static let statusline = "statusline"
}

/// Window-name constants. Same string-not-enum reasoning as
/// `RateLimitSource` above.
public enum RateLimitWindowName {
    public static let fiveHour = "five_hour"
    public static let sevenDay = "seven_day"
}
