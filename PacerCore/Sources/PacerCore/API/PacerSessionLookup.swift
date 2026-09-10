import Foundation
import SwiftData

/// What Pacer knows about one Claude Code session, keyed by the session id.
///
/// This exists so a script running *inside* a session can stop being told
/// things about itself. Claude Code puts `CLAUDE_CODE_SESSION_ID` into the
/// environment of every command it runs, and it is the same id that names the
/// transcript Pacer already parses — so a caller can hand it over and get back
/// the two facts it cannot determine on its own:
///
/// - **Which model it is running.** The pacing skill needs it to know whether a
///   per-model cap binds this agent at all, and nothing in the environment
///   says so.
/// - **Which account its work is billed to.** More direct than resolving a
///   config directory: this is the attribution Pacer actually recorded for
///   these turns, not an inference about a profile.
///
/// Both come from the newest recorded turn, so a session Pacer has not seen a
/// turn from yet is "not found" rather than a guess. A subagent gets its own
/// session id, so this answers for the subagent rather than its parent.
public struct PacerSessionLookup: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let sessionId: String
    /// The model on the most recent real turn — what a per-model cap gates.
    public let model: String?
    /// The account that turn was attributed to.
    public let accountId: String?
    public let projectPath: String?
    /// Last path component of `projectPath`, for display.
    public let project: String?
    public let lastActiveAt: Date?

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }
}

/// Who else is spending this account's budget right now.
///
/// A rate-limit window is **account-wide**: every session signed into that
/// account draws from the same percentage. So a burn rate already includes
/// everyone — but an agent deciding whether to fan out needs to know how much
/// of that rate is its own, and a human wants to know where the rest is coming
/// from before killing something.
///
/// Deliberately *not* carrying a git branch. A branch is the most volatile
/// thing about a checkout — it changes without producing a turn for Pacer to
/// observe — so a stored one would be wrong more often than right. The path is
/// stable and identifies a worktree uniquely; a caller that wants the branch
/// can read it from that path at the moment it asks, which is the only time
/// the answer is true.
public struct PacerSessionList: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let sessions: [Row]

    public struct Row: Codable, Sendable {
        public let sessionId: String
        public let accountId: String?
        public let model: String?
        public let projectPath: String?
        public let project: String?
        /// The project's git remote origin, when it has one — so two checkouts
        /// of the same repo are recognisable as such.
        public let repository: String?
        public let lastActiveAt: Date
        /// `active` (≤5 min), `recent` (≤1 h) or `idle`, the same thresholds
        /// the dashboard and menu bar use.
        public let activity: String
    }

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }
}

public enum PacerSessionLookupBuilder {

    public nonisolated static func lookup(sessionId: String,
                                          now: Date = Date()) throws -> PacerSessionLookup? {
        try lookup(container: PacerStore.sharedModelContainer(),
                   sessionId: sessionId, now: now)
    }

    /// Every session seen within `withinSeconds`, newest first.
    ///
    /// Reads the per-account session table so each row can name the account
    /// whose budget it is drawing from; that table is only written for turns
    /// the activation trail could attribute, which is the same rule the
    /// per-account rollups follow.
    public nonisolated static func list(withinSeconds: TimeInterval = LiveSessionActivity.recentThreshold,
                                        account: String? = nil,
                                        now: Date = Date()) throws -> PacerSessionList {
        try list(container: PacerStore.sharedModelContainer(),
                 withinSeconds: withinSeconds, account: account, now: now)
    }

    nonisolated static func list(container: ModelContainer, withinSeconds: TimeInterval,
                                 account: String?, now: Date) throws -> PacerSessionList {
        let context = ModelContext(container)
        let cutoff = now.addingTimeInterval(-max(0, withinSeconds))
        var descriptor = FetchDescriptor<AccountSessionInfo>(
            predicate: #Predicate { $0.lastSeenAt >= cutoff },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        descriptor.fetchLimit = 200
        let rows = ((try? context.fetch(descriptor)) ?? [])
            .filter { account == nil || $0.accountId == account }

        // One lookup for every project involved, rather than one per session.
        let paths = Set(rows.map(\.projectPath))
        var origins: [String: String] = [:]
        for meta in (try? context.fetch(FetchDescriptor<ProjectMeta>())) ?? [] where
            paths.contains(meta.projectPath) {
            // `colorSeed` is the git remote *or* a canonical path — it exists to
            // be a stable colour input, not to identify a repo. Reporting the
            // fallback under a field called `repository` would hand a caller a
            // local directory and call it a remote, so only a real remote
            // qualifies: a URL with a scheme, or scp-style `user@host:path`.
            guard let seed = meta.colorSeed, !seed.hasPrefix("/") else { continue }
            let looksRemote = seed.contains("://")
                || (seed.contains("@") && seed.contains(":"))
            if looksRemote { origins[meta.projectPath] = seed }
        }

        return PacerSessionList(
            schemaVersion: 1,
            generatedAt: now,
            sessions: rows.map { row in
                PacerSessionList.Row(
                    sessionId: row.sessionId,
                    accountId: row.accountId,
                    model: row.topModel.isEmpty ? nil : row.topModel,
                    projectPath: row.projectPath,
                    project: URL(fileURLWithPath: row.projectPath).lastPathComponent,
                    repository: origins[row.projectPath],
                    lastActiveAt: row.lastSeenAt,
                    activity: LiveSessionActivity.from(lastSeen: row.lastSeenAt, now: now).label)
            })
    }

    nonisolated static func lookup(container: ModelContainer, sessionId: String,
                                   now: Date) throws -> PacerSessionLookup? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let context = ModelContext(container)

        // Newest first, and a handful rather than one: the top row can be a
        // `<synthetic>` turn, Claude Code's sentinel for non-billable internal
        // traffic, which names no real model and is skipped everywhere else in
        // Pacer for exactly this reason.
        var descriptor = FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.sessionId == trimmed },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        descriptor.fetchLimit = 16
        let rows = (try? context.fetch(descriptor)) ?? []
        guard let newest = rows.first else { return nil }

        let model = rows.first {
            $0.model != JSONLLineParser.syntheticModelSentinel && !$0.model.isEmpty
        }?.model
        let path = newest.projectPath
        return PacerSessionLookup(
            schemaVersion: 1,
            generatedAt: now,
            sessionId: trimmed,
            model: model,
            accountId: newest.accountId,
            projectPath: path,
            project: path.map { URL(fileURLWithPath: $0).lastPathComponent },
            lastActiveAt: newest.sampledAt)
    }
}
