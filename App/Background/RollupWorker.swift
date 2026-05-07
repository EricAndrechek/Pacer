import Foundation
import SwiftData
import PacerCore

/// Background worker for view-driven rollups. Each method runs on the
/// actor's isolation (off the main thread), fetches via its own
/// `ModelContext`, iterates, and returns a Sendable DTO that the
/// caller applies on the main actor without further per-row work.
///
/// This exists because @Query on a populated install fires on every
/// SwiftData save, materializes the full result set, and re-evaluates
/// any view that reads it. For views that aggregate ~30k TokenSamples
/// (Projects, ProjectDetail, debug stats), doing the iteration on the
/// main thread freezes the UI on every scan cycle — even when the
/// affected tab isn't visible. ModelActor + Sendable DTOs is the
/// supported way to push that work to a background context.
@ModelActor
actor RollupWorker {
    func projectRows(rangeSince: Date?) -> [ProjectRollupRow] {
        let descriptor: FetchDescriptor<TokenSample>
        if let cutoff = rangeSince {
            descriptor = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.sampledAt >= cutoff },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<TokenSample>(
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
        }
        guard let samples = try? modelContext.fetch(descriptor) else { return [] }

        struct Acc {
            var cost: Double = 0
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            var sessions: Set<String> = []
            var models: Set<String> = []
            var lastActive: Date = .distantPast
        }
        var byProject: [String: Acc] = [:]
        for s in samples {
            let key = s.projectPath ?? "(unknown)"
            var a = byProject[key] ?? Acc()
            a.cost += s.sourceCostUSD ?? 0
            a.input += s.inputTokens
            a.output += s.outputTokens
            a.cacheRead += s.cacheReadTokens
            if let sid = s.sessionId { a.sessions.insert(sid) }
            a.models.insert(s.model)
            if s.sampledAt > a.lastActive { a.lastActive = s.sampledAt }
            byProject[key] = a
        }
        return byProject.map { (key, a) in
            ProjectRollupRow(
                path: key,
                cost: a.cost,
                inputTokens: a.input,
                outputTokens: a.output,
                cacheReadTokens: a.cacheRead,
                totalTokens: a.input + a.output + a.cacheRead,
                sessionCount: a.sessions.count,
                lastActive: a.lastActive,
                modelCount: a.models.count
            )
        }.sorted { $0.cost > $1.cost }
    }

    func projectDetail(projectPath: String, since: Date?) -> ProjectDetailRollup {
        let descriptor: FetchDescriptor<TokenSample>
        let path = projectPath
        if let cutoff = since {
            descriptor = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> {
                    $0.projectPath == path && $0.sampledAt >= cutoff
                },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.projectPath == path },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
        }
        guard let samples = try? modelContext.fetch(descriptor) else {
            return ProjectDetailRollup(totals: .init(), dailySeries: [], modelSlices: [], sessions: [], sampleCount: 0)
        }

        var totals = ProjectDetailRollup.Totals()
        var byDate: [String: (cost: Double, tokens: Int64)] = [:]
        var byModel: [String: Int64] = [:]
        struct SessionAcc {
            var lastSeen: Date = .distantPast
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            var cost: Double = 0
            var modelTokens: [String: Int64] = [:]
        }
        var bySession: [String: SessionAcc] = [:]

        for s in samples {
            let sCost = s.sourceCostUSD ?? 0
            let sTokens = s.inputTokens + s.outputTokens + s.cacheReadTokens

            totals.cost += sCost
            totals.input += s.inputTokens
            totals.output += s.outputTokens
            totals.cacheRead += s.cacheReadTokens

            var d = byDate[s.date] ?? (0, 0)
            d.cost += sCost
            d.tokens += sTokens
            byDate[s.date] = d

            byModel[s.model, default: 0] += sTokens

            if let sid = s.sessionId {
                var a = bySession[sid] ?? SessionAcc()
                a.input += s.inputTokens
                a.output += s.outputTokens
                a.cacheRead += s.cacheReadTokens
                a.cost += sCost
                a.modelTokens[s.model, default: 0] += sTokens
                if s.sampledAt > a.lastSeen { a.lastSeen = s.sampledAt }
                bySession[sid] = a
            }
        }

        let dailySeries = byDate.keys.sorted().map { date in
            ProjectDetailRollup.DayPoint(date: date, cost: byDate[date]?.cost ?? 0, tokens: byDate[date]?.tokens ?? 0)
        }
        let modelSlices = byModel.map { ProjectDetailRollup.ModelSlice(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
        let sessions = bySession.map { (sid, a) in
            let topModel = a.modelTokens.max(by: { $0.value < $1.value })?.key ?? "—"
            return ProjectDetailRollup.SessionRow(
                sessionId: sid,
                lastSeen: a.lastSeen,
                totalTokens: a.input + a.output + a.cacheRead,
                cost: a.cost,
                topModel: topModel
            )
        }.sorted { $0.lastSeen > $1.lastSeen }

        return ProjectDetailRollup(
            totals: totals,
            dailySeries: dailySeries,
            modelSlices: modelSlices,
            sessions: sessions,
            sampleCount: samples.count
        )
    }

    func modelRollups(rangeSince: String?) -> ModelRollups {
        let descriptor: FetchDescriptor<DailyAggregate>
        if let cutoff = rangeSince {
            descriptor = FetchDescriptor<DailyAggregate>(
                predicate: #Predicate<DailyAggregate> { $0.date >= cutoff },
                sortBy: [SortDescriptor(\.date)]
            )
        } else {
            descriptor = FetchDescriptor<DailyAggregate>(
                sortBy: [SortDescriptor(\.date)]
            )
        }
        guard let aggregates = try? modelContext.fetch(descriptor) else {
            return ModelRollups(rows: [], dailyMix: [])
        }

        struct Acc {
            var cost: Double = 0
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            var dates: Set<String> = []
            var firstSeen: String = "9999-99-99"
            var lastSeen: String = "0000-00-00"
        }
        var byModel: [String: Acc] = [:]
        var mix: [ModelDailyMix] = []
        mix.reserveCapacity(aggregates.count)
        for r in aggregates {
            var a = byModel[r.model] ?? Acc()
            a.cost += r.totalCostUSD
            a.input += r.inputTokens
            a.output += r.outputTokens
            a.cacheRead += r.cacheReadTokens
            a.dates.insert(r.date)
            if r.date < a.firstSeen { a.firstSeen = r.date }
            if r.date > a.lastSeen { a.lastSeen = r.date }
            byModel[r.model] = a
            mix.append(ModelDailyMix(
                date: r.date,
                model: r.model,
                tokens: r.inputTokens + r.outputTokens + r.cacheReadTokens
            ))
        }
        let rows = byModel.map { (model, a) in
            ModelRollupRow(
                model: model,
                cost: a.cost,
                inputTokens: a.input,
                outputTokens: a.output,
                cacheReadTokens: a.cacheRead,
                totalTokens: a.input + a.output + a.cacheRead,
                activeDays: a.dates.count,
                firstSeen: a.firstSeen,
                lastSeen: a.lastSeen
            )
        }.sorted { $0.cost > $1.cost }
        return ModelRollups(rows: rows, dailyMix: mix)
    }

    func debugAggregateStats() -> DebugAggregateStats {
        let descriptor = FetchDescriptor<TokenSample>()
        let total = (try? modelContext.fetchCount(descriptor)) ?? 0
        guard let samples = try? modelContext.fetch(descriptor) else {
            return DebugAggregateStats(totalSampleCount: total, distinctDates: 0, distinctModels: 0, distinctVersions: [])
        }
        var dates = Set<String>()
        var models = Set<String>()
        var versions = Set<String>()
        for s in samples {
            dates.insert(s.date)
            models.insert(s.model)
            if let v = s.ccVersion, !v.isEmpty {
                versions.insert(v)
            }
        }
        return DebugAggregateStats(
            totalSampleCount: total,
            distinctDates: dates.count,
            distinctModels: models.count,
            distinctVersions: versions.sorted(by: >)
        )
    }
}

// MARK: - Sendable DTOs
//
// Plain structs with Sendable fields so the worker's results can cross
// the actor boundary back to MainActor without a borrow check on
// PersistentModel. Views map these into their internal display types
// (which add display-only computed fields like `displayName`) on the
// main thread — that mapping is over a small list (tens of rows) and
// is cheap.

struct ProjectRollupRow: Sendable, Identifiable {
    let path: String
    let cost: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let totalTokens: Int64
    let sessionCount: Int
    let lastActive: Date
    let modelCount: Int
    var id: String { path }
}

struct ProjectDetailRollup: Sendable {
    struct Totals: Sendable {
        var cost: Double = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
    }
    struct DayPoint: Sendable, Identifiable {
        let date: String
        let cost: Double
        let tokens: Int64
        var id: String { date }
    }
    struct ModelSlice: Sendable, Identifiable {
        let model: String
        let tokens: Int64
        var id: String { model }
    }
    struct SessionRow: Sendable, Identifiable {
        let sessionId: String
        let lastSeen: Date
        let totalTokens: Int64
        let cost: Double
        let topModel: String
        var id: String { sessionId }
    }

    let totals: Totals
    let dailySeries: [DayPoint]
    let modelSlices: [ModelSlice]
    let sessions: [SessionRow]
    let sampleCount: Int
}

struct ModelRollupRow: Sendable, Identifiable {
    let model: String
    let cost: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let totalTokens: Int64
    let activeDays: Int
    let firstSeen: String
    let lastSeen: String
    var id: String { model }
}

struct ModelDailyMix: Sendable, Identifiable {
    let date: String
    let model: String
    let tokens: Int64
    var id: String { "\(date)|\(model)" }
}

struct ModelRollups: Sendable {
    let rows: [ModelRollupRow]
    let dailyMix: [ModelDailyMix]
}

struct DebugAggregateStats: Sendable {
    let totalSampleCount: Int
    let distinctDates: Int
    let distinctModels: Int
    let distinctVersions: [String]
}
