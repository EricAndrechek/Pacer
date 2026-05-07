import Foundation
import SwiftData

/// Materializes `SessionInfo` rows from the underlying `TokenSample`
/// table. Recomputes per-session — never the whole table. Counterpart to
/// `AggregateRecomputer` and `ProjectAggregateRecomputer`: same
/// dirty-set pattern, keyed by `sessionId` rather than `(date, model)`
/// or `(project, date)`.
///
/// Maintaining this rollup is what lets `ProjectDetailView` display the
/// sessions list instantly. Without it, the detail view had to drop
/// into a `RollupWorker` and iterate every TokenSample for the project
/// on each scan tick — measurable lag on a populated install.
///
/// **Bulk vs per-id paths**: matches `ProjectAggregateRecomputer`'s
/// shape. The bulk path runs once on install when missing-id recovery
/// folds every existing session into the dirty set; subsequent
/// incremental scans touch a handful of ids and use the per-id path.
@MainActor
public final class SessionInfoRecomputer {

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public struct Stats: Sendable {
        public var sessionsRecomputed: Int
        public var sessionsUpserted: Int
        public var sessionsDeleted: Int
    }

    /// Above this many dirty session ids we switch from per-id fetches
    /// to a single full-table sweep + in-memory grouping. Backfill on
    /// first install can produce thousands of dirty ids; normal
    /// incremental scans produce a handful.
    private static let bulkRecomputeThreshold = 64
    /// Yield to the run loop every N sessions during the bulk path so
    /// SwiftUI keeps drawing during the first-install backfill. Stays
    /// on MainActor — work itself doesn't move, but the run loop gets
    /// to service draw/click events between batches.
    private static let yieldInterval = 32

    @discardableResult
    public func recompute(sessionIds: Set<String>) async throws -> Stats {
        var stats = Stats(sessionsRecomputed: 0, sessionsUpserted: 0, sessionsDeleted: 0)
        if sessionIds.isEmpty { return stats }
        if sessionIds.count >= Self.bulkRecomputeThreshold {
            try await recomputeBulk(sessionIds: sessionIds, stats: &stats)
        } else {
            for sid in sessionIds {
                stats.sessionsRecomputed += 1
                try recomputeOne(sessionId: sid, stats: &stats)
            }
        }
        return stats
    }

    /// Backfill / large-batch path: one fetch of every TokenSample with
    /// a non-nil sessionId, one fetch of every SessionInfo row, then
    /// upsert in-memory. Avoids the N small fetches the per-id path
    /// would do during install.
    private func recomputeBulk(sessionIds: Set<String>, stats: inout Stats) async throws {
        let allSamples = try context.fetch(
            FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.sessionId != nil }
            )
        )
        var grouped: [String: [TokenSample]] = [:]
        for s in allSamples {
            guard let sid = s.sessionId, !sid.isEmpty else { continue }
            grouped[sid, default: []].append(s)
        }
        let existingAll = try context.fetch(FetchDescriptor<SessionInfo>())
        var existingById: [String: SessionInfo] = [:]
        for row in existingAll { existingById[row.sessionId] = row }

        var processed = 0
        for sid in sessionIds {
            stats.sessionsRecomputed += 1
            applySamples(
                sessionId: sid,
                samples: grouped[sid] ?? [],
                existing: existingById[sid],
                stats: &stats
            )
            processed += 1
            if processed.isMultiple(of: Self.yieldInterval) {
                await Task.yield()
            }
        }
    }

    private func recomputeOne(sessionId: String, stats: inout Stats) throws {
        let sid = sessionId
        let samples = try context.fetch(
            FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.sessionId == sid }
            )
        )
        let existing = try context.fetch(
            FetchDescriptor<SessionInfo>(
                predicate: #Predicate<SessionInfo> { $0.sessionId == sid }
            )
        ).first
        applySamples(sessionId: sid, samples: samples, existing: existing, stats: &stats)
    }

    /// Shared upsert/delete logic. Empty sample set = the session was
    /// rolled back somehow, so remove the row if present.
    private func applySamples(
        sessionId: String,
        samples: [TokenSample],
        existing: SessionInfo?,
        stats: inout Stats
    ) {
        if samples.isEmpty {
            if let existing {
                context.delete(existing)
                stats.sessionsDeleted += 1
            }
            return
        }

        var firstSeen: Date = .distantFuture
        var lastSeen: Date = .distantPast
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var cache5m: Int64 = 0
        var cache1h: Int64 = 0
        var cost: Double = 0
        var modelTokens: [String: Int64] = [:]
        var projectPath: String?
        var ccVersion: String?
        // Preserve the model that contributed first if every model ties
        // at zero tokens — gives a deterministic "topModel" for empty
        // sessions instead of a hash-order pick.
        var firstModel: String?

        for s in samples {
            if s.sampledAt < firstSeen { firstSeen = s.sampledAt }
            if s.sampledAt > lastSeen {
                lastSeen = s.sampledAt
                ccVersion = s.ccVersion ?? ccVersion
                projectPath = s.projectPath ?? projectPath
            }
            inputTokens += s.inputTokens
            outputTokens += s.outputTokens
            cacheReadTokens += s.cacheReadTokens
            cache5m += s.cacheCreation5mTokens
            cache1h += s.cacheCreation1hTokens
            cost += s.sourceCostUSD ?? 0
            let t = s.inputTokens + s.outputTokens + s.cacheReadTokens
            modelTokens[s.model, default: 0] += t
            if firstModel == nil { firstModel = s.model }
        }
        let topModel = modelTokens.max { $0.value < $1.value }?.key
            ?? firstModel
            ?? ""
        let path = projectPath ?? ""

        if let existing {
            existing.firstSeenAt = firstSeen
            existing.lastSeenAt = lastSeen
            existing.projectPath = path
            existing.ccVersion = ccVersion
            existing.cumulativeCostUSD = cost
            existing.cumulativeInputTokens = inputTokens
            existing.cumulativeOutputTokens = outputTokens
            existing.cumulativeCacheReadTokens = cacheReadTokens
            existing.cumulativeCacheCreation5mTokens = cache5m
            existing.cumulativeCacheCreation1hTokens = cache1h
            existing.topModel = topModel
        } else {
            context.insert(SessionInfo(
                sessionId: sessionId,
                firstSeenAt: firstSeen,
                lastSeenAt: lastSeen,
                projectPath: path,
                ccVersion: ccVersion,
                cumulativeCostUSD: cost,
                cumulativeInputTokens: inputTokens,
                cumulativeOutputTokens: outputTokens,
                cumulativeCacheReadTokens: cacheReadTokens,
                cumulativeCacheCreation5mTokens: cache5m,
                cumulativeCacheCreation1hTokens: cache1h,
                topModel: topModel
            ))
        }
        stats.sessionsUpserted += 1
    }
}
