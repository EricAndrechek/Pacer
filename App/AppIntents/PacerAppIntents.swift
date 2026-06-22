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
