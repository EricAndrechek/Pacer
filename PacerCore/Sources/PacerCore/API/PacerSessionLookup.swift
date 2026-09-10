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

public enum PacerSessionLookupBuilder {

    public nonisolated static func lookup(sessionId: String,
                                          now: Date = Date()) throws -> PacerSessionLookup? {
        try lookup(container: PacerStore.sharedModelContainer(),
                   sessionId: sessionId, now: now)
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
