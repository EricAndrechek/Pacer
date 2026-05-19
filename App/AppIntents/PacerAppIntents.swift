// AppIntents' Swift 6 concurrency annotations are incomplete in Xcode
// 16.x — `static let appShortcuts: [AppShortcut]` triggers a Sendable
// error even though AppShortcut is meant as immutable manifest data.
// `@preconcurrency` demotes those API-mismatch errors to warnings until
// Apple finishes annotating the framework.
@preconcurrency import AppIntents
import SwiftData
import PacerCore

/// Pacer's Shortcuts.app integration. Four intents covering the most
/// common automation use cases:
///
/// 1. **GetUsageIntent** — current 5-hour utilization (Double).
/// 2. **GetSevenDayUsageIntent** — current 7-day utilization (Double).
/// 3. **GetTodayCostIntent** — today's spend in USD (Double).
/// 4. **RefreshScanIntent** — trigger an immediate scan cycle.
///
/// Each intent opens its own short-lived `ModelContext` against the
/// shared App Group container. Reads only; no migrations or writes.
///
/// The `AppShortcuts` provider at the bottom registers all four with
/// system Shortcuts so they appear in the picker and Spotlight without
/// the user authoring a custom shortcut first.

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
        let pct = try fetchLatestUsage(forWindow: "five_hour")
        let dialog: IntentDialog
        if let pct {
            dialog = IntentDialog(stringLiteral: "5-hour usage is \(Int(pct.rounded()))%.")
            return .result(value: pct, dialog: dialog)
        } else {
            dialog = "5-hour usage is unavailable — no rate-limit samples yet."
            return .result(value: 0, dialog: dialog)
        }
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
        let pct = try fetchLatestUsage(forWindow: "seven_day")
        let dialog: IntentDialog
        if let pct {
            dialog = IntentDialog(stringLiteral: "7-day usage is \(Int(pct.rounded()))%.")
            return .result(value: pct, dialog: dialog)
        } else {
            dialog = "7-day usage is unavailable — no rate-limit samples yet."
            return .result(value: 0, dialog: dialog)
        }
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
        let cost = try fetchTodayCost()
        let dialog = IntentDialog(stringLiteral: "Today's Claude Code cost is \(formatUSD(cost)).")
        return .result(value: cost, dialog: dialog)
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

// MARK: - Shared helpers

@MainActor
private func fetchLatestUsage(forWindow window: String) throws -> Double? {
    let container = try PacerStore.sharedModelContainer()
    let context = ModelContext(container)
    // Sorted desc; the most recent sample matching the window is
    // the one we want. fetchLimit=8 covers both windows × a couple of
    // back-fills with comfortable headroom.
    var descriptor = FetchDescriptor<RateLimitSample>(
        sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
    )
    descriptor.fetchLimit = 8
    let rows = try context.fetch(descriptor)
    return rows.first { $0.window == window }?.usedPercentage
}

@MainActor
private func fetchTodayCost() throws -> Double {
    let container = try PacerStore.sharedModelContainer()
    let context = ModelContext(container)
    let today = TokenSample.formatDate(Date())
    let descriptor = FetchDescriptor<DailyAggregate>(
        predicate: #Predicate<DailyAggregate> { $0.date == today }
    )
    let rows = try context.fetch(descriptor)
    return rows.reduce(0) { $0 + $1.totalCostUSD }
}

private func formatUSD(_ amount: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    return f.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
}

// MARK: - AppShortcutsProvider

/// Registers Pacer's intents with Shortcuts.app so they appear in the
/// picker (and Spotlight) without the user authoring a custom shortcut
/// first. The `phrases` are the natural-language triggers; they expand
/// `applicationName` into the actual app name at runtime.
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
            intent: RefreshScanIntent(),
            phrases: [
                "Refresh \(.applicationName)"
            ],
            shortTitle: "Refresh scan",
            systemImageName: "arrow.clockwise"
        )
    ]
}
