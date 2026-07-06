import Foundation
import SwiftData

/// The prediction trail — every snapshot the engine recorded of what it was
/// telling the user, with the evidence behind each answer. This is the
/// debugging/replay export: join rows to realized truths on
/// (`surface`, `periodKey`) via the self-eval outcomes (or the raw samples)
/// to see which past predictions held up.
public struct PacerPredictionHistory: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    /// Version tag of the engine constants at export time (rows carry their own).
    public let currentParamsVersion: String
    /// The full current knob values — so the replay harness reproduces the
    /// shipping configuration without reading Swift source.
    public let currentParams: EngineParams
    public let rows: [Row]

    public struct Row: Codable, Sendable {
        public let recordedAt: Date
        public let surface: String
        public let method: String
        public let paramsVersion: String
        public let engineVersion: String
        public let periodKey: String
        public let periodEnd: Date?
        public let value: Double?
        public let lo80: Double?
        public let hi80: Double?
        public let lo50: Double?
        public let hi50: Double?
        public let confidence: String
        public let support: Int
        public let note: String?
        public let crossingAt: Date?
        public let crossingEarliest: Date?
        public let crossingLatest: Date?
        public let usedPct: Double?
        public let anchorShift: Double?
        public let slopePercentPerHour: Double?
        public let bandStratum: String?
        public let residualCount: Int?
        public let spendSoFar: Double?
    }

    public func encodedJSON() throws -> String { try pacerAPIEncodedJSON(self) }
}

public enum PacerPredictionHistoryBuilder {

    /// Snapshot rows from the last `days` days (clamped to 1…365), oldest
    /// first, optionally filtered to one surface (`"rl-five_hour"`,
    /// `"rl-seven_day"`, `"eod"`, `"month"`). Own short-lived `ModelContext`
    /// (like `PacerUsageBuilder`) so the HTTP server reads it off its
    /// background queue.
    public nonisolated static func history(days: Int, surface: String? = nil, now: Date = Date()) throws -> PacerPredictionHistory {
        let span = min(max(days, 1), 365)
        let container = try PacerStore.sharedModelContainer()
        let context = ModelContext(container)
        let cutoff = now.addingTimeInterval(-Double(span) * 86400)
        let descriptor: FetchDescriptor<PredictionSnapshot>
        if let surface {
            descriptor = FetchDescriptor<PredictionSnapshot>(
                predicate: #Predicate { $0.recordedAt >= cutoff && $0.surface == surface },
                sortBy: [SortDescriptor(\.recordedAt, order: .forward)])
        } else {
            descriptor = FetchDescriptor<PredictionSnapshot>(
                predicate: #Predicate { $0.recordedAt >= cutoff },
                sortBy: [SortDescriptor(\.recordedAt, order: .forward)])
        }
        let all = (try? context.fetch(descriptor)) ?? []
        let rows = all.map { s in
            PacerPredictionHistory.Row(
                recordedAt: s.recordedAt, surface: s.surface, method: s.method,
                paramsVersion: s.paramsVersion, engineVersion: s.engineVersion,
                periodKey: s.periodKey, periodEnd: s.periodEnd,
                value: s.value, lo80: s.lo80, hi80: s.hi80, lo50: s.lo50, hi50: s.hi50,
                confidence: s.confidence, support: s.support, note: s.note,
                crossingAt: s.crossingAt, crossingEarliest: s.crossingEarliest,
                crossingLatest: s.crossingLatest, usedPct: s.usedPct,
                anchorShift: s.anchorShift, slopePercentPerHour: s.slopePercentPerHour,
                bandStratum: s.bandStratum, residualCount: s.residualCount,
                spendSoFar: s.spendSoFar)
        }
        return PacerPredictionHistory(
            schemaVersion: 1, generatedAt: now,
            currentParamsVersion: EngineParams.version,
            currentParams: EngineParams.current, rows: rows)
    }
}
