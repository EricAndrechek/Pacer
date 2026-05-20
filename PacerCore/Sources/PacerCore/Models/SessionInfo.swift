import Foundation
import SwiftData

/// One Claude Code session as observed across one or more JSONL files.
/// `sessionId` is unique because Claude Code never re-uses one — even on
/// resume it spawns a fresh session id (which is part of why we need the
/// cross-file `dedupKey` guard on `TokenSample`).
///
/// Cumulative columns are denormalized roll-ups of this session's
/// `TokenSample` rows. Recomputed by `SessionInfoRecomputer` whenever the
/// session's bucket gets dirtied during a scan, just like
/// `DailyAggregate` and `ProjectDailyAggregate`. With this table
/// maintained, `ProjectDetailView`'s sessions list reads from a small
/// precomputed set instead of iterating raw samples on display.
@Model
public final class SessionInfo {
    // Sessions list views filter by `projectPath`; the day-detail
    // modal filters by `(firstSeenAt, lastSeenAt)` overlap on a
    // date. Index both so those predicates are range scans.
    #Index<SessionInfo>([\.projectPath], [\.lastSeenAt])

    @Attribute(.unique) public var sessionId: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var projectPath: String
    public var ccVersion: String?
    public var cumulativeCostUSD: Double
    public var cumulativeInputTokens: Int64
    public var cumulativeOutputTokens: Int64
    public var cumulativeCacheReadTokens: Int64
    public var cumulativeCacheCreation5mTokens: Int64
    public var cumulativeCacheCreation1hTokens: Int64
    /// Model that contributed the most tokens in this session — driver
    /// for the "model" column in the sessions list. Ties broken
    /// arbitrarily; ties at zero stay as the first-seen model.
    public var topModel: String

    public init(
        sessionId: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        projectPath: String,
        ccVersion: String? = nil,
        cumulativeCostUSD: Double = 0,
        cumulativeInputTokens: Int64 = 0,
        cumulativeOutputTokens: Int64 = 0,
        cumulativeCacheReadTokens: Int64 = 0,
        cumulativeCacheCreation5mTokens: Int64 = 0,
        cumulativeCacheCreation1hTokens: Int64 = 0,
        topModel: String = ""
    ) {
        self.sessionId = sessionId
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.projectPath = projectPath
        self.ccVersion = ccVersion
        self.cumulativeCostUSD = cumulativeCostUSD
        self.cumulativeInputTokens = cumulativeInputTokens
        self.cumulativeOutputTokens = cumulativeOutputTokens
        self.cumulativeCacheReadTokens = cumulativeCacheReadTokens
        self.cumulativeCacheCreation5mTokens = cumulativeCacheCreation5mTokens
        self.cumulativeCacheCreation1hTokens = cumulativeCacheCreation1hTokens
        self.topModel = topModel
    }
}

extension SessionInfo {
    public var totalTokens: Int64 {
        cumulativeInputTokens + cumulativeOutputTokens
    }
}
