import Foundation
import SwiftData

/// Shared JSON encoding for the API surface (ISO-8601 dates, stable key order).
func pacerAPIEncodedJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// Per-day, per-model token + cost history — the full-fidelity view a consumer
/// needs to reproduce a daily/per-model breakdown (all five token categories,
/// not just the snapshot's compact "today" aggregate).
///
/// **Today is live.** The row whose `date == today` is an in-progress partial
/// that updates as Pacer ingests new JSONL (same source as
/// `PacerSnapshotPayload.tokens.todayTotal`), and is flagged `inProgress`.
/// Dates are local-day keys (`yyyy-MM-dd`), matching how the app rolls "today"
/// over at local midnight.
public struct PacerDailyUsage: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    /// Local-day key for "today" — the `inProgress` row, if any usage so far.
    public let today: String
    public let rows: [Row]

    public struct Row: Codable, Sendable {
        public let date: String
        public let model: String
        public let input: Int
        public let output: Int
        public let cacheRead: Int
        public let cacheCreation5m: Int
        public let cacheCreation1h: Int
        public let costUSD: Double
        /// True for the still-accumulating current local day.
        public let inProgress: Bool
    }

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }
}

/// Per-model lifetime totals (all five token categories + cost), aggregated
/// across Pacer's full retained daily history.
public struct PacerModelUsage: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let models: [Row]

    public struct Row: Codable, Sendable {
        public let model: String
        public let input: Int
        public let output: Int
        public let cacheRead: Int
        public let cacheCreation5m: Int
        public let cacheCreation1h: Int
        public let costUSD: Double
        public let firstDate: String
        public let lastDate: String
    }

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }
}

/// Builders for the usage-history endpoints. `nonisolated` + self-contained
/// (own short-lived `ModelContext`), like `PacerSnapshotBuilder`, so the HTTP
/// server reads them off its background queue.
public enum PacerUsageBuilder {

    /// Per-day, per-model rows for the last `days` local days (inclusive of
    /// today). `days` is clamped to 1…3650.
    public nonisolated static func daily(days: Int, now: Date = Date()) throws -> PacerDailyUsage {
        let span = min(max(days, 1), 3650)
        let container = try PacerStore.sharedModelContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let todayKey = TokenSample.formatDate(now)
        let cutoffDate = calendar.date(byAdding: .day, value: -(span - 1), to: now) ?? now
        let cutoffKey = TokenSample.formatDate(cutoffDate)

        let all = (try? context.fetch(FetchDescriptor<DailyAggregate>())) ?? []
        let filtered = all.filter { $0.date >= cutoffKey }
        let sorted = filtered.sorted { $0.date != $1.date ? $0.date < $1.date : $0.model < $1.model }
        var rows: [PacerDailyUsage.Row] = []
        rows.reserveCapacity(sorted.count)
        for agg in sorted {
            rows.append(PacerDailyUsage.Row(
                date: agg.date,
                model: agg.model,
                input: Int(agg.inputTokens),
                output: Int(agg.outputTokens),
                cacheRead: Int(agg.cacheReadTokens),
                cacheCreation5m: Int(agg.cacheCreation5mTokens),
                cacheCreation1h: Int(agg.cacheCreation1hTokens),
                costUSD: agg.totalCostUSD,
                inProgress: agg.date == todayKey))
        }
        return PacerDailyUsage(schemaVersion: 1, generatedAt: now, today: todayKey, rows: rows)
    }

    /// Today's per-model rows only — the live, in-progress slice. Used for the
    /// `pacer_model_*` Prometheus series.
    public nonisolated static func todayByModel(now: Date = Date()) throws -> [PacerDailyUsage.Row] {
        try daily(days: 1, now: now).rows.filter { $0.inProgress }
    }

    /// Per-model lifetime totals across all retained daily history.
    public nonisolated static func models(now: Date = Date()) throws -> PacerModelUsage {
        let container = try PacerStore.sharedModelContainer()
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<DailyAggregate>())) ?? []

        struct Accumulator {
            var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0
            var c5m: Int64 = 0, c1h: Int64 = 0, cost: Double = 0
            var firstDate = "", lastDate = ""
        }
        var byModel: [String: Accumulator] = [:]
        for agg in all {
            var acc = byModel[agg.model] ?? Accumulator()
            acc.input += agg.inputTokens
            acc.output += agg.outputTokens
            acc.cacheRead += agg.cacheReadTokens
            acc.c5m += agg.cacheCreation5mTokens
            acc.c1h += agg.cacheCreation1hTokens
            acc.cost += agg.totalCostUSD
            if acc.firstDate.isEmpty || agg.date < acc.firstDate { acc.firstDate = agg.date }
            if acc.lastDate.isEmpty || agg.date > acc.lastDate { acc.lastDate = agg.date }
            byModel[agg.model] = acc
        }
        let models = byModel
            .map { model, acc in
                PacerModelUsage.Row(
                    model: model,
                    input: Int(acc.input), output: Int(acc.output), cacheRead: Int(acc.cacheRead),
                    cacheCreation5m: Int(acc.c5m), cacheCreation1h: Int(acc.c1h),
                    costUSD: acc.cost, firstDate: acc.firstDate, lastDate: acc.lastDate)
            }
            .sorted { $0.costUSD > $1.costUSD }
        return PacerModelUsage(schemaVersion: 1, generatedAt: now, models: models)
    }
}
