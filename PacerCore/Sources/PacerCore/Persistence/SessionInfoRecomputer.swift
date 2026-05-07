import Foundation
import SwiftData

/// Materializes `SessionInfo` rows from the underlying `TokenSample`
/// table. Recomputes per-session — never the whole table. Counterpart
/// to `AggregateRecomputer` and `ProjectAggregateRecomputer`: same
/// dirty-set pattern, keyed by `sessionId` rather than `(date, model)`
/// or `(project, date)`.
///
/// Maintaining this rollup is what lets `ProjectDetailView` display
/// the sessions list instantly. Without it, the detail view had to
/// drop into a `RollupWorker` and iterate every TokenSample for the
/// project on each scan tick — measurable lag on a populated install.
@MainActor
public final class SessionInfoRecomputer {

    private let container: ModelContainer
    private let context: ModelContext

    public init(container: ModelContainer, context: ModelContext) {
        self.container = container
        self.context = context
    }

    public struct Stats: Sendable {
        public var sessionsRecomputed: Int
        public var sessionsUpserted: Int
        public var sessionsDeleted: Int
    }

    /// Above this many dirty session ids we hand off to a background
    /// `@ModelActor` worker. Backfill on first install can produce
    /// hundreds-thousands of dirty ids; normal incremental scans
    /// produce a handful and stay on the main context.
    private static let bulkRecomputeThreshold = 64

    @discardableResult
    public func recompute(sessionIds: Set<String>) async throws -> Stats {
        var stats = Stats(sessionsRecomputed: 0, sessionsUpserted: 0, sessionsDeleted: 0)
        if sessionIds.isEmpty { return stats }
        if sessionIds.count >= Self.bulkRecomputeThreshold {
            try context.save()
            let worker = SessionInfoBulkWorker(modelContainer: container)
            return try await worker.bulkRecompute(sessionIds: sessionIds)
        }
        for sid in sessionIds {
            stats.sessionsRecomputed += 1
            try recomputeOne(sessionId: sid, stats: &stats)
        }
        return stats
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
        Self.applySamples(
            sessionId: sid, samples: samples, existing: existing,
            insert: { context.insert($0) },
            delete: { context.delete($0) },
            stats: &stats
        )
    }

    fileprivate nonisolated static func applySamples(
        sessionId: String,
        samples: [TokenSample],
        existing: SessionInfo?,
        insert: (SessionInfo) -> Void,
        delete: (SessionInfo) -> Void,
        stats: inout Stats
    ) {
        if samples.isEmpty {
            if let existing {
                delete(existing)
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
            insert(SessionInfo(
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

/// Off-main bulk recompute path for SessionInfo. Owns its own
/// `ModelContext` via `@ModelActor`. Same shape as
/// `ProjectAggregateBulkWorker`.
@ModelActor
actor SessionInfoBulkWorker {

    private static let yieldInterval = 32

    func bulkRecompute(sessionIds: Set<String>) async throws -> SessionInfoRecomputer.Stats {
        var stats = SessionInfoRecomputer.Stats(
            sessionsRecomputed: 0, sessionsUpserted: 0, sessionsDeleted: 0)

        let allSamples = try modelContext.fetch(
            FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.sessionId != nil }
            )
        )
        var grouped: [String: [TokenSample]] = [:]
        for s in allSamples {
            guard let sid = s.sessionId, !sid.isEmpty else { continue }
            grouped[sid, default: []].append(s)
        }
        let existingAll = try modelContext.fetch(FetchDescriptor<SessionInfo>())
        var existingById: [String: SessionInfo] = [:]
        for row in existingAll { existingById[row.sessionId] = row }

        var processed = 0
        for sid in sessionIds {
            stats.sessionsRecomputed += 1
            SessionInfoRecomputer.applySamples(
                sessionId: sid,
                samples: grouped[sid] ?? [],
                existing: existingById[sid],
                insert: { modelContext.insert($0) },
                delete: { modelContext.delete($0) },
                stats: &stats
            )
            processed += 1
            if processed.isMultiple(of: Self.yieldInterval) {
                await Task.yield()
            }
        }

        try modelContext.save()
        return stats
    }
}
