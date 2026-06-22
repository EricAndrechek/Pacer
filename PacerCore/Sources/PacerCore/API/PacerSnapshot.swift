import Foundation
import SwiftData

/// The canonical, versioned read model Pacer exposes to the outside world.
///
/// One builder feeds every external surface — the Shortcuts/App Intents JSON
/// intent and the local HTTP server (`/v1/snapshot`, `/metrics`, SSE) — so
/// they all report numbers that agree with each other and with the dashboard.
/// Reads the shared App-Group store directly, so it answers correctly whether
/// or not the app's UI is running, exactly like the widgets.
///
/// Dates encode as ISO-8601 strings; durations are integer seconds-from-now.
/// Bump `schemaVersion` on a breaking change; additive fields don't require a
/// bump.
public struct PacerSnapshotPayload: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let limits: Limits
    public let cost: Cost
    public let tokens: Tokens
    public let pace: Pace
    public let session: Session?
    public let overageUSD: Double
    public let dataSource: DataSource

    public struct Limits: Codable, Sendable {
        public let fiveHour: Window?
        public let sevenDay: Window?

        public struct Window: Codable, Sendable {
            public let usedPercent: Double
            public let resetsAt: Date?
            public let resetsInSeconds: Int?
            public let projectedEndPercent: Double?
            public let projectedEndLowPercent: Double?
            public let projectedEndHighPercent: Double?
            public let willHitLimit: Bool
            public let limitEtaAt: Date?
            public let limitEtaInSeconds: Int?
        }
    }

    public struct Cost: Codable, Sendable {
        public let todayUSD: Double
        public let weekUSD: Double
        public let monthUSD: Double
        public let allTimeUSD: Double
        public let projectedTodayUSD: Double?
        public let projectedTodayLowUSD: Double?
        public let projectedTodayHighUSD: Double?
        public let projectedMonthUSD: Double?
        public let projectedMonthLowUSD: Double?
        public let projectedMonthHighUSD: Double?
    }

    public struct Tokens: Codable, Sendable {
        public let todayInput: Int
        public let todayOutput: Int
        public let todayCacheRead: Int
        /// Input + output (cache excluded) — matches the menu bar's "today tokens".
        public let todayTotal: Int
    }

    public struct Pace: Codable, Sendable {
        /// 0…1 — today's projected spend as a percentile of your daily norm.
        public let percentile: Double?
        /// "running hot" / "about normal" / "quieter than usual".
        public let status: String?
    }

    public struct Session: Codable, Sendable {
        public let project: String
        public let projectPath: String
        public let costUSD: Double
        public let tokens: Int
        public let lastActiveAt: Date
    }

    public struct DataSource: Codable, Sendable {
        public let source: String?
        public let lastSampleAt: Date?
        public let ageSeconds: Int?
        /// True when a fresh (≤30 min) engine projection backs the forecast fields.
        public let forecastFresh: Bool
    }

    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Builder (single source of truth for every external surface)

public enum PacerSnapshotBuilder {

    private static let fiveHourKey = "five_hour"
    private static let sevenDayKey = "seven_day"

    /// Read the shared store + the exported engine outlook and assemble the
    /// full snapshot. `nonisolated` and self-contained (creates its own
    /// short-lived `ModelContext`), so it can run on the App Intents main
    /// actor *or* the HTTP server's background queue without a hop.
    public nonisolated static func build(now: Date = Date()) throws -> PacerSnapshotPayload {
        let container = try PacerStore.sharedModelContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current

        // --- Rate-limit samples (latest per window + freshest overall) ---
        var rlDescriptor = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        rlDescriptor.fetchLimit = 16
        let rlRows = (try? context.fetch(rlDescriptor)) ?? []
        let latestFive = rlRows.first { $0.window == fiveHourKey }
        let latestSeven = rlRows.first { $0.window == sevenDayKey }
        let freshestSample = rlRows.first

        // --- Engine outlook export (forecast / pace), fresh only ---
        let snapshot = engineSnapshot(context: context)

        // --- Daily aggregates (cost + tokens, all spans from one fetch) ---
        let daily = (try? context.fetch(FetchDescriptor<DailyAggregate>())) ?? []
        let todayKey = TokenSample.formatDate(now)
        let weekKey = TokenSample.formatDate(calendar.date(byAdding: .day, value: -6, to: now) ?? now)
        let monthKey: String = {
            let comps = calendar.dateComponents([.year, .month], from: now)
            return calendar.date(from: comps).map { TokenSample.formatDate($0) } ?? todayKey
        }()
        let todayRows = daily.filter { $0.date == todayKey }
        let limits = PacerSnapshotPayload.Limits(
            fiveHour: window(latestFive, outlook: snapshot?.fiveHour, now: now),
            sevenDay: window(latestSeven, outlook: snapshot?.sevenDay, now: now))

        let cost = PacerSnapshotPayload.Cost(
            todayUSD: todayRows.reduce(0) { $0 + $1.totalCostUSD },
            weekUSD: daily.filter { $0.date >= weekKey }.reduce(0) { $0 + $1.totalCostUSD },
            monthUSD: daily.filter { $0.date >= monthKey }.reduce(0) { $0 + $1.totalCostUSD },
            allTimeUSD: daily.reduce(0) { $0 + $1.totalCostUSD },
            projectedTodayUSD: snapshot?.cost?.projectedTodayUSD,
            projectedTodayLowUSD: snapshot?.cost?.projectedTodayLoUSD,
            projectedTodayHighUSD: snapshot?.cost?.projectedTodayHiUSD,
            projectedMonthUSD: snapshot?.cost?.projectedMonthUSD,
            projectedMonthLowUSD: snapshot?.cost?.projectedMonthLoUSD,
            projectedMonthHighUSD: snapshot?.cost?.projectedMonthHiUSD)

        let todayInput = todayRows.reduce(Int64(0)) { $0 + $1.inputTokens }
        let todayOutput = todayRows.reduce(Int64(0)) { $0 + $1.outputTokens }
        let todayCacheRead = todayRows.reduce(Int64(0)) { $0 + $1.cacheReadTokens }
        let tokens = PacerSnapshotPayload.Tokens(
            todayInput: Int(todayInput),
            todayOutput: Int(todayOutput),
            todayCacheRead: Int(todayCacheRead),
            todayTotal: Int(todayInput + todayOutput))

        let pace = PacerSnapshotPayload.Pace(
            percentile: snapshot?.cost?.pacePercentile,
            status: snapshot?.cost?.paceNote)

        // --- Running session (most recent by last activity) ---
        var sessionDescriptor = FetchDescriptor<SessionInfo>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        sessionDescriptor.fetchLimit = 1
        let session = (try? context.fetch(sessionDescriptor))?.first.map {
            PacerSnapshotPayload.Session(
                project: URL(fileURLWithPath: $0.projectPath).lastPathComponent,
                projectPath: $0.projectPath,
                costUSD: $0.cumulativeCostUSD,
                tokens: Int($0.totalTokens),
                lastActiveAt: $0.lastSeenAt)
        }

        // --- Extra (overage) usage ---
        var extraDescriptor = FetchDescriptor<ExtraUsageSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        extraDescriptor.fetchLimit = 1
        let overageUSD = (try? context.fetch(extraDescriptor))?.first?.amountUSD ?? 0

        let dataSource = PacerSnapshotPayload.DataSource(
            source: freshestSample?.source,
            lastSampleAt: freshestSample?.sampledAt,
            ageSeconds: freshestSample.map { max(0, Int(now.timeIntervalSince($0.sampledAt))) },
            forecastFresh: snapshot != nil)

        return PacerSnapshotPayload(
            schemaVersion: 1,
            generatedAt: now,
            limits: limits,
            cost: cost,
            tokens: tokens,
            pace: pace,
            session: session,
            overageUSD: overageUSD,
            dataSource: dataSource)
    }

    /// Assemble one window's live usage (from the freshest sample) plus the
    /// engine's projection — but only attach the projection when the snapshot
    /// belongs to the *same* cycle as the sample (reset within ±2 min). A
    /// projection from a previous cycle would be nonsense, exactly as the
    /// pace-chart widget guards.
    private static func window(
        _ sample: RateLimitSample?,
        outlook: EngineSnapshot.WindowOutlook?,
        now: Date
    ) -> PacerSnapshotPayload.Limits.Window? {
        guard let sample else { return nil }
        let resetsAt = sample.resetsAt
        let resetsInSeconds = resetsAt.map { max(0, Int($0.timeIntervalSince(now))) }

        var endPct: Double?
        var endLo: Double?
        var endHi: Double?
        var crossingAt: Date?
        if let outlook, let resetsAt,
           abs(outlook.resetsUnix - resetsAt.timeIntervalSince1970) < 120 {
            endPct = outlook.endPct
            endLo = outlook.endLoPct
            endHi = outlook.endHiPct
            if let c = outlook.crossingDate, c > now { crossingAt = c }
        }
        return PacerSnapshotPayload.Limits.Window(
            usedPercent: sample.usedPercentage,
            resetsAt: resetsAt,
            resetsInSeconds: resetsInSeconds,
            projectedEndPercent: endPct,
            projectedEndLowPercent: endLo,
            projectedEndHighPercent: endHi,
            willHitLimit: crossingAt != nil,
            limitEtaAt: crossingAt,
            limitEtaInSeconds: crossingAt.map { max(0, Int($0.timeIntervalSince(now))) })
    }

    /// Read + decode the engine's outlook export from `ClaudeCodeMeta`. `nil`
    /// when absent or stale (the app may not be running; an old projection is
    /// worse than none) — same contract the widgets use.
    private static func engineSnapshot(context: ModelContext) -> EngineSnapshot? {
        let key = EngineSnapshot.metaKey
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key })
        guard let json = try? context.fetch(descriptor).first?.value,
              let snapshot = EngineSnapshot.decode(json), snapshot.isFresh else { return nil }
        return snapshot
    }
}
