// AppIntents' Swift 6 concurrency annotations are incomplete in Xcode
// 16.x — `static let appShortcuts: [AppShortcut]` triggers a Sendable
// error even though AppShortcut is meant as immutable manifest data.
// `@preconcurrency` demotes those API-mismatch errors to warnings until
// Apple finishes annotating the framework.
@preconcurrency import AppIntents
import Foundation
import SwiftData
import PacerCore
import PacerUI

/// Pacer's Shortcuts.app / Spotlight / Siri integration — the supported,
/// permissionless way for third-party automations (Stream Deck, Raycast,
/// menu-bar scripts, …) to read Pacer's usage data.
///
/// **Design:** every intent reads the shared App Group store directly via a
/// short-lived `ModelContext` (reads only — no migrations, no writes). Like
/// the widgets, that means the intents answer correctly **whether or not the
/// Pacer app is running**, and they never reach into the in-process
/// intelligence engine actor. Forecast/pace numbers come from the
/// `EngineSnapshot` the app exports into `ClaudeCodeMeta` after every refit —
/// the *same* projection the dashboard and widgets draw.
///
/// One `PacerSnapshotBuilder.build()` assembles the whole picture once; the
/// scalar intents pull a single field from it and `GetPacerSnapshotIntent`
/// serialises the lot as versioned JSON, so all surfaces report numbers that
/// agree with each other and with the UI.
///
/// The `AppShortcuts` provider at the bottom registers a curated subset with
/// system Shortcuts so they appear in the picker / Spotlight without the user
/// authoring a shortcut first. Every intent defined here is usable as a
/// Shortcuts *action* regardless of whether it's in that gallery list.

// MARK: - Errors

enum PacerIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noRateLimitData

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noRateLimitData:
            return "No rate-limit data yet — open Pacer once so it can poll your usage."
        }
    }
}

// MARK: - Get 5-hour usage

struct GetUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get 5-Hour Usage"
    static let description = IntentDescription(
        "Returns the current 5-hour rate-limit utilization as a percentage (0–100)."
    )
    /// Surface Pacer in the Shortcuts gallery's "What's New" / suggested
    /// section. Cheap and silent — no permission prompts, no write
    /// side effects.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let snap = try PacerSnapshotBuilder.build()
        guard let pct = snap.limits.fiveHour?.usedPercent else {
            return .result(value: 0, dialog: "5-hour usage is unavailable — no rate-limit samples yet.")
        }
        return .result(value: pct, dialog: "5-hour usage is \(Int(pct.rounded()))%.")
    }
}

// MARK: - Get 7-day usage

struct GetSevenDayUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get 7-Day Usage"
    static let description = IntentDescription(
        "Returns the current 7-day rate-limit utilization as a percentage (0–100)."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let snap = try PacerSnapshotBuilder.build()
        guard let pct = snap.limits.sevenDay?.usedPercent else {
            return .result(value: 0, dialog: "7-day usage is unavailable — no rate-limit samples yet.")
        }
        return .result(value: pct, dialog: "7-day usage is \(Int(pct.rounded()))%.")
    }
}

// MARK: - Get today's cost

struct GetTodayCostIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today's Cost"
    static let description = IntentDescription(
        "Returns today's Claude Code spend in USD."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let cost = try PacerSnapshotBuilder.build().cost.todayUSD
        return .result(value: cost, dialog: "Today's Claude Code cost is \(pacerCostExact(cost)).")
    }
}

// MARK: - Get this week's cost

struct GetWeekCostIntent: AppIntent {
    static let title: LocalizedStringResource = "Get This Week's Cost"
    static let description = IntentDescription(
        "Returns the last 7 days of Claude Code spend in USD (rolling, includes today)."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let cost = try PacerSnapshotBuilder.build().cost.weekUSD
        return .result(value: cost, dialog: "This week's Claude Code cost is \(pacerCostExact(cost)).")
    }
}

// MARK: - Get this month's cost

struct GetMonthCostIntent: AppIntent {
    static let title: LocalizedStringResource = "Get This Month's Cost"
    static let description = IntentDescription(
        "Returns this calendar month's Claude Code spend so far, in USD."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let cost = try PacerSnapshotBuilder.build().cost.monthUSD
        return .result(value: cost, dialog: "This month's Claude Code cost is \(pacerCostExact(cost)).")
    }
}

// MARK: - Get today's tokens

struct GetTodayTokensIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today's Tokens"
    static let description = IntentDescription(
        "Returns today's total input + output token count (cache tokens excluded)."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let tokens = try PacerSnapshotBuilder.build().tokens.todayTotal
        return .result(value: tokens, dialog: "You've used \(tokens.formatted()) tokens today.")
    }
}

// MARK: - Get projected today's cost

struct GetProjectedTodayCostIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Projected Cost Today"
    static let description = IntentDescription(
        "Returns Pacer's projected end-of-day Claude Code spend in USD. Falls back to spend-so-far when there isn't enough history to project."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let snap = try PacerSnapshotBuilder.build()
        if let projected = snap.cost.projectedTodayUSD {
            return .result(value: projected, dialog: "Projected to spend \(pacerCostExact(projected)) today.")
        }
        let soFar = snap.cost.todayUSD
        return .result(value: soFar,
                       dialog: "Not enough history to project — you've spent \(pacerCostExact(soFar)) so far today.")
    }
}

// MARK: - When does the 5-hour limit reset

struct GetFiveHourResetIntent: AppIntent {
    static let title: LocalizedStringResource = "Get 5-Hour Reset Time"
    static let description = IntentDescription(
        "Returns the date/time the current 5-hour rate-limit window rolls over."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Date> {
        guard let resetsAt = try PacerSnapshotBuilder.build().limits.fiveHour?.resetsAt else {
            throw PacerIntentError.noRateLimitData
        }
        return .result(value: resetsAt,
                       dialog: "Your 5-hour limit resets \(pacerIntentRelative(resetsAt)).")
    }
}

// MARK: - Will I hit my limit?

struct GetWillHitLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Will I Hit My Limit"
    static let description = IntentDescription(
        "Returns true if Pacer projects you'll reach 100% of either the 5-hour or 7-day limit before it resets."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let limits = try PacerSnapshotBuilder.build().limits
        // Report the window that crosses soonest, if any.
        let windows: [(name: String, window: PacerSnapshotPayload.Limits.Window?)] =
            [("5-hour", limits.fiveHour), ("7-day", limits.sevenDay)]
        let crossing = windows
            .compactMap { entry -> (name: String, at: Date)? in
                guard let w = entry.window, w.willHitLimit, let at = w.limitEtaAt else { return nil }
                return (entry.name, at)
            }
            .min { $0.at < $1.at }
        if let crossing {
            return .result(value: true,
                           dialog: "On pace to hit your \(crossing.name) limit \(pacerIntentRelative(crossing.at)).")
        }
        return .result(value: false, dialog: "You're not on pace to hit a limit before it resets.")
    }
}

// MARK: - Get pace status

struct GetPaceStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Spending Pace"
    static let description = IntentDescription(
        "Returns how today's projected spend compares to your own norm: \"running hot\", \"about normal\", or \"quieter than usual\"."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let pace = try PacerSnapshotBuilder.build().pace
        guard let status = pace.status else {
            return .result(value: "unknown",
                           dialog: "Not enough history yet to judge your pace.")
        }
        return .result(value: status, dialog: "Today is \(status) for you.")
    }
}

// MARK: - Full snapshot (JSON firehose)

struct GetPacerSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Usage Snapshot (JSON)"
    static let description = IntentDescription(
        """
        Returns the full Pacer usage snapshot as a JSON string: 5-hour and 7-day \
        limits with reset times and projections, costs (today/week/month/all-time \
        plus projections), token totals, spending pace, the running session, and \
        data-source freshness. Pipe into "Get Dictionary from Input" to read any \
        field. Schema is versioned for forward compatibility.
        """
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let snap = try PacerSnapshotBuilder.build()
        let json = try snap.encodedJSON()
        let five = snap.limits.fiveHour.map { "5h \(Int($0.usedPercent.rounded()))%" } ?? "5h —"
        let seven = snap.limits.sevenDay.map { "7d \(Int($0.usedPercent.rounded()))%" } ?? "7d —"
        return .result(value: json,
                       dialog: "\(five), \(seven), \(pacerCostExact(snap.cost.todayUSD)) today.")
    }
}

// MARK: - Refresh scan

struct RefreshScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Pacer Scan"
    static let description = IntentDescription(
        "Triggers an immediate JSONL scan and project-attribution refresh. Use after editing project aliases from outside the app."
    )
    /// True so the trigger reaches `AppBackgroundService` even when
    /// Pacer hasn't been launched. Shortcuts.app can fire intents
    /// against a non-running app for some intent classes; for our
    /// case we need the running scan coordinator, so the system
    /// brings the app up if needed.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(
            name: .pacerRequestImmediateScan,
            object: nil
        )
        return .result(dialog: "Refresh requested.")
    }
}

// MARK: - Snapshot payload (the versioned third-party contract)

/// The shape `GetPacerSnapshotIntent` serialises. Bump `schemaVersion` on a
/// breaking change; additive fields don't require a bump. Dates encode as
/// ISO-8601 strings; durations are integer seconds-from-now.
struct PacerSnapshotPayload: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let limits: Limits
    let cost: Cost
    let tokens: Tokens
    let pace: Pace
    let session: Session?
    let overageUSD: Double
    let dataSource: DataSource

    struct Limits: Codable, Sendable {
        let fiveHour: Window?
        let sevenDay: Window?

        struct Window: Codable, Sendable {
            let usedPercent: Double
            let resetsAt: Date?
            let resetsInSeconds: Int?
            let projectedEndPercent: Double?
            let projectedEndLowPercent: Double?
            let projectedEndHighPercent: Double?
            let willHitLimit: Bool
            let limitEtaAt: Date?
            let limitEtaInSeconds: Int?
        }
    }

    struct Cost: Codable, Sendable {
        let todayUSD: Double
        let weekUSD: Double
        let monthUSD: Double
        let allTimeUSD: Double
        let projectedTodayUSD: Double?
        let projectedTodayLowUSD: Double?
        let projectedTodayHighUSD: Double?
        let projectedMonthUSD: Double?
        let projectedMonthLowUSD: Double?
        let projectedMonthHighUSD: Double?
    }

    struct Tokens: Codable, Sendable {
        let todayInput: Int
        let todayOutput: Int
        let todayCacheRead: Int
        /// Input + output (cache excluded) — matches the menu bar's "today tokens".
        let todayTotal: Int
    }

    struct Pace: Codable, Sendable {
        /// 0…1 — today's projected spend as a percentile of your daily norm.
        let percentile: Double?
        /// "running hot" / "about normal" / "quieter than usual".
        let status: String?
    }

    struct Session: Codable, Sendable {
        let project: String
        let projectPath: String
        let costUSD: Double
        let tokens: Int
        let lastActiveAt: Date
    }

    struct DataSource: Codable, Sendable {
        let source: String?
        let lastSampleAt: Date?
        let ageSeconds: Int?
        /// True when a fresh (≤30 min) engine projection backs the forecast fields.
        let forecastFresh: Bool
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Snapshot builder (single source of truth for every intent)

enum PacerSnapshotBuilder {

    private static let fiveHourKey = "five_hour"
    private static let sevenDayKey = "seven_day"

    /// Read the shared store + the exported engine outlook and assemble the
    /// full snapshot. `@MainActor` because it touches a `ModelContext`.
    @MainActor
    static func build(now: Date = Date()) throws -> PacerSnapshotPayload {
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
    @MainActor
    private static func engineSnapshot(context: ModelContext) -> EngineSnapshot? {
        let key = EngineSnapshot.metaKey
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key })
        guard let json = try? context.fetch(descriptor).first?.value,
              let snapshot = EngineSnapshot.decode(json), snapshot.isFresh else { return nil }
        return snapshot
    }
}

/// Compact "in 2h 14m" / "5m ago" for intent dialogs (kept local so the
/// intents don't depend on PacerUI formatter internals).
private func pacerIntentRelative(_ date: Date, now: Date = Date()) -> String {
    let fmt = RelativeDateTimeFormatter()
    fmt.unitsStyle = .abbreviated
    return fmt.localizedString(for: date, relativeTo: now)
}

// MARK: - AppShortcutsProvider

/// Registers a curated subset of Pacer's intents with Shortcuts.app so they
/// appear in the picker (and Spotlight) without the user authoring a custom
/// shortcut first. The `phrases` are the natural-language triggers; they
/// expand `applicationName` into the actual app name at runtime. Apple
/// surfaces a limited number of gallery entries, so the rarer intents
/// (today's tokens, projected cost) are intentionally left off this list —
/// they're still available as Shortcuts actions.
struct PacerAppShortcuts: AppShortcutsProvider {
    static let appShortcuts: [AppShortcut] = [
        AppShortcut(
            intent: GetUsageIntent(),
            phrases: [
                "Get my 5-hour \(.applicationName) usage",
                "What's my \(.applicationName) 5-hour usage",
                "How much \(.applicationName) have I used"
            ],
            shortTitle: "5-hour usage",
            systemImageName: "gauge.with.dots.needle.50percent"
        ),
        AppShortcut(
            intent: GetSevenDayUsageIntent(),
            phrases: [
                "Get my 7-day \(.applicationName) usage",
                "What's my \(.applicationName) weekly usage"
            ],
            shortTitle: "7-day usage",
            systemImageName: "calendar"
        ),
        AppShortcut(
            intent: GetTodayCostIntent(),
            phrases: [
                "How much did I spend on \(.applicationName) today",
                "What's my \(.applicationName) cost today"
            ],
            shortTitle: "Today's cost",
            systemImageName: "dollarsign.circle"
        ),
        AppShortcut(
            intent: GetWeekCostIntent(),
            phrases: [
                "What's my \(.applicationName) cost this week"
            ],
            shortTitle: "This week's cost",
            systemImageName: "calendar.badge.clock"
        ),
        AppShortcut(
            intent: GetMonthCostIntent(),
            phrases: [
                "What's my \(.applicationName) cost this month"
            ],
            shortTitle: "This month's cost",
            systemImageName: "calendar.circle"
        ),
        AppShortcut(
            intent: GetFiveHourResetIntent(),
            phrases: [
                "When does my \(.applicationName) limit reset"
            ],
            shortTitle: "5-hour reset",
            systemImageName: "clock.arrow.circlepath"
        ),
        AppShortcut(
            intent: GetWillHitLimitIntent(),
            phrases: [
                "Will I hit my \(.applicationName) limit",
                "Am I going to run out of \(.applicationName)"
            ],
            shortTitle: "Will I hit my limit",
            systemImageName: "exclamationmark.triangle"
        ),
        AppShortcut(
            intent: GetPaceStatusIntent(),
            phrases: [
                "What's my \(.applicationName) pace"
            ],
            shortTitle: "Spending pace",
            systemImageName: "speedometer"
        ),
        AppShortcut(
            intent: GetPacerSnapshotIntent(),
            phrases: [
                "Get my \(.applicationName) snapshot",
                "Get my \(.applicationName) usage data"
            ],
            shortTitle: "Usage snapshot",
            systemImageName: "doc.text"
        ),
        AppShortcut(
            intent: RefreshScanIntent(),
            phrases: [
                "Refresh \(.applicationName)"
            ],
            shortTitle: "Refresh scan",
            systemImageName: "arrow.clockwise"
        )
    ]
}
