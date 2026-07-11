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
    /// Anthropic's `extra_usage` field — additional spend beyond plan
    /// quota, denominated in USD cents. Surfaced for Max-plan users
    /// who can exceed quota at metered rates. nil when the response
    /// omits the field or it's a shape we don't recognize.
    public let extraUsageCents: Int?
    /// The account this observation belongs to, read from the
    /// `anthropic-organization-id` response header. The multi-token
    /// poller uses it as a same-account guard: a Desktop token that
    /// resolves to a *different* organization is dropped from the poll
    /// pool and its samples are never persisted, so interleaving tokens
    /// can never mix two accounts' usage into one timeline. nil when the
    /// header was absent (older server, or a transport that doesn't
    /// surface it).
    public let organizationId: String?

    /// The newer, scoped, extensible `limits[]` representation — a strict
    /// superset of `fiveHour`/`sevenDay` that also carries per-model weekly
    /// windows, `severity`, and the binding-limit flag. Empty when the
    /// server omitted the array (older server) or every item was malformed;
    /// each present item renders and persists generically, so a new model /
    /// kind / group / surface flows through with no code change. Additive
    /// and defaulted so existing callers/tests are untouched.
    public let limits: [UsageLimit]

    public init(
        sampledAt: Date,
        fiveHour: RateLimitWindow?,
        sevenDay: RateLimitWindow?,
        extraUsageCents: Int? = nil,
        organizationId: String? = nil,
        limits: [UsageLimit] = []
    ) {
        self.sampledAt = sampledAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.extraUsageCents = extraUsageCents
        self.organizationId = organizationId
        self.limits = limits
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
