import Foundation
import SwiftData

/// One Claude Code session as observed across one or more JSONL files.
/// `sessionId` is unique because Claude Code never re-uses one — even on
/// resume it spawns a fresh session id (which is part of why we need the
/// cross-file `dedupKey` guard on `TokenSample`).
///
/// Cumulative columns are denormalized roll-ups of this session's
/// `TokenSample` rows. Recomputed alongside `DailyAggregate` so the
/// "session" IPC method has constant-time reads.
@Model
public final class SessionInfo {
    @Attribute(.unique) public var sessionId: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var projectPath: String
    public var ccVersion: String?
    public var transcriptPath: String?
    public var cumulativeCostUSD: Double
    public var cumulativeInputTokens: Int64
    public var cumulativeOutputTokens: Int64
    /// `"active"` or `"ended"`. A session is `active` while its
    /// transcript file's mtime is fresh (within the active-window we
    /// pick later — likely 30min) and `ended` otherwise. Stored so
    /// queries don't have to recompute per-read.
    public var status: String

    public init(
        sessionId: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        projectPath: String,
        ccVersion: String? = nil,
        transcriptPath: String? = nil,
        cumulativeCostUSD: Double = 0,
        cumulativeInputTokens: Int64 = 0,
        cumulativeOutputTokens: Int64 = 0,
        status: String = "active"
    ) {
        self.sessionId = sessionId
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.projectPath = projectPath
        self.ccVersion = ccVersion
        self.transcriptPath = transcriptPath
        self.cumulativeCostUSD = cumulativeCostUSD
        self.cumulativeInputTokens = cumulativeInputTokens
        self.cumulativeOutputTokens = cumulativeOutputTokens
        self.status = status
    }
}
