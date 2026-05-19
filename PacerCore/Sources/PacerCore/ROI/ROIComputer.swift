import Foundation

/// Joins git commits to Claude Code sessions and produces per-project
/// ROI rollups. The inputs are deliberately abstract — commits +
/// session windows + (optional) per-session cost — so the math has
/// zero dependency on SwiftData and is straightforwardly testable.
///
/// Attribution model: each commit lands in the session whose window
/// `[firstSeenAt, lastSeenAt + slack]` contains the commit timestamp.
/// Commits with no enclosing session are reported as "unattributed"
/// — they're still counted in the LOC totals but cost stays 0.
///
/// Cost is split *evenly* across the commits attributed to a session.
/// A commit during a $4 session that produced 4 commits gets $1. This
/// matches Claude God's split and keeps the math simple — the
/// alternative (prorate by commit duration) requires an end-of-commit
/// boundary that doesn't exist.
public enum ROIComputer {

    /// Subset of `SessionInfo` the math actually needs. Decouples the
    /// view-side fetch (which has many more fields) from the input
    /// surface here.
    public struct SessionWindow: Sendable, Equatable {
        public let sessionId: String
        public let projectPath: String
        public let firstSeenAt: Date
        public let lastSeenAt: Date
        public let costUSD: Double

        public init(
            sessionId: String,
            projectPath: String,
            firstSeenAt: Date,
            lastSeenAt: Date,
            costUSD: Double
        ) {
            self.sessionId = sessionId
            self.projectPath = projectPath
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
            self.costUSD = costUSD
        }
    }

    /// Per-project ROI rollup ready for the view layer.
    public struct ProjectROI: Sendable, Equatable {
        public let projectPath: String
        public let commitCount: Int
        public let linesAdded: Int
        public let linesRemoved: Int
        public let attributedCostUSD: Double
        public let unattributedCommits: Int
        public let attributedSessions: Int

        /// $/commit. Defined only when there's at least one commit
        /// AND at least one attributed dollar — a project with cost
        /// but no commits returns nil because "Inf $/commit" is not
        /// meaningful.
        public var costPerCommit: Double? {
            guard commitCount > 0, attributedCostUSD > 0 else { return nil }
            return attributedCostUSD / Double(commitCount)
        }

        /// $/line-of-code-changed. Same nil semantics as
        /// `costPerCommit` — no LOC, no metric.
        public var costPerLine: Double? {
            let lines = linesAdded + linesRemoved
            guard lines > 0, attributedCostUSD > 0 else { return nil }
            return attributedCostUSD / Double(lines)
        }
    }

    /// Forgiveness window past `lastSeenAt`. A commit made within
    /// `attributionSlack` of a session ending still attributes to
    /// that session — the user types "git commit" a few seconds
    /// after Claude wraps. 60 seconds is generous without
    /// accidentally pulling commits from a long-after coffee break
    /// into an old session.
    public static let attributionSlack: TimeInterval = 60

    /// Compute a single-project ROI rollup. Sessions and commits
    /// are pre-filtered to one project by the caller — this function
    /// doesn't iterate across projects, so the caller can run
    /// per-project concurrently if it wants.
    public static func computeProject(
        projectPath: String,
        commits: [GitLogReader.Commit],
        sessions: [SessionWindow]
    ) -> ProjectROI {
        // Sort sessions by firstSeenAt so we can binary-search later
        // if needed. For the typical case of ≤ a few hundred sessions
        // per project linear search is fine — keep it simple.
        let sortedSessions = sessions.sorted { $0.firstSeenAt < $1.firstSeenAt }

        // Group commits by attributed session.
        var commitsBySession: [String: Int] = [:]
        var unattributed = 0
        var commitToSession: [String: String] = [:]  // commit hash → session id

        for commit in commits {
            if let session = enclosingSession(for: commit.date, in: sortedSessions) {
                commitsBySession[session.sessionId, default: 0] += 1
                commitToSession[commit.hash] = session.sessionId
            } else {
                unattributed += 1
            }
        }

        // Distribute each session's cost evenly across the commits
        // that landed in its window. A session with zero attributed
        // commits contributes nothing to attributedCost — we don't
        // amortize "session cost without any commit" anywhere,
        // because the user got no visible work product for it (or at
        // least none we can measure).
        var attributedCost: Double = 0
        for session in sortedSessions {
            guard let count = commitsBySession[session.sessionId], count > 0 else { continue }
            attributedCost += session.costUSD
        }

        let linesAdded = commits.reduce(0) { $0 + $1.linesAdded }
        let linesRemoved = commits.reduce(0) { $0 + $1.linesRemoved }

        return ProjectROI(
            projectPath: projectPath,
            commitCount: commits.count,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            attributedCostUSD: attributedCost,
            unattributedCommits: unattributed,
            attributedSessions: commitsBySession.count
        )
    }

    /// Find the session whose window contains `at`. Sessions are
    /// pre-sorted by firstSeenAt. Window includes the slack past
    /// lastSeenAt. Returns the FIRST matching session if multiple
    /// overlap (overlap is rare — sessions are sequential).
    static func enclosingSession(
        for at: Date,
        in sortedSessions: [SessionWindow]
    ) -> SessionWindow? {
        for session in sortedSessions {
            if at < session.firstSeenAt { continue }
            if at <= session.lastSeenAt.addingTimeInterval(attributionSlack) {
                return session
            }
        }
        return nil
    }
}
