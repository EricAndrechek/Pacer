import Foundation
import SwiftUI
import WidgetKit
import PacerCore
import PacerUI

/// Deterministic fake `TimelineEntry` values for the README widget shots —
/// kept consistent with the dashboard seed (Opus-heavy, cache-dominated,
/// 5h ≈32% / 7d ≈62%, ~$124 today).
///
/// One source of truth for two consumers: the app's screenshot mode renders
/// the views with them directly (the widget-picker and scoped mockups), and a
/// widget extension built with `PACER_WIDGET_FIXTURES` serves them from its
/// providers, so WidgetKit Simulator renders the real extension over them for
/// `docs/screenshots/widgets.png` (bin/widgetkit-sim-shots.sh).
enum WidgetFixtures {
    /// True only in a build compiled with `PACER_WIDGET_FIXTURES` — the CI
    /// screenshot job's build (`make screenshots`). Compile-time rather than
    /// a file or an App Group default, because nothing on a user's Mac can
    /// then turn it on: a shipped extension does not contain the switch, so a
    /// stray flag can never put fake numbers on somebody's desktop. (An
    /// environment variable does not reach an extension WidgetKit launches.)
    #if PACER_WIDGET_FIXTURES
    static let enabled = true
    #else
    static let enabled = false
    #endif

    /// The widgets `docs/screenshots/widgets.png` shows, each in the one
    /// family it is photographed in — the order is the gallery's.
    static let readmeShots: [(kind: String, family: WidgetFamily)] = [
        (WidgetKinds.todayCost, .systemSmall),
        (WidgetKinds.paceGauges, .systemMedium),
        (WidgetKinds.liveSession, .systemMedium),
        (WidgetKinds.dailyChart, .systemMedium),
        (WidgetKinds.topProjects, .systemMedium),
    ]

    /// Which kind a fixture build exposes, when the screenshot job asks for
    /// just one: `PacerFixtureKind` in the extension's Info.plist, written by
    /// bin/widgetkit-sim-shots.sh before it signs the bundle. Unset means all.
    static let selectedKind: String? = enabled
        ? Bundle.main.object(forInfoDictionaryKey: "PacerFixtureKind") as? String
        : nil

    /// A widget's `supportedFamilies`. Unchanged in every normal build; in a
    /// fixture build, only the family the README shows (so the simulator has
    /// exactly one size to render), and none at all for a kind the job did not
    /// ask for.
    static func families(_ all: [WidgetFamily], kind: String) -> [WidgetFamily] {
        guard enabled else { return all }
        if let selectedKind, selectedKind != kind { return [] }
        guard let shot = readmeShots.first(where: { $0.kind == kind }) else { return all }
        return [shot.family]
    }

    private static let now = Date()
    static let opus = "claude-opus-4-7"

    static var todayCost: TodayCostEntry {
        TodayCostEntry(date: now, costUSD: 124.0, tokens: 540_000, modelCount: 3, isFresh: true)
    }

    static var paceGauges: PaceGaugesEntry {
        PaceGaugesEntry(
            date: now,
            fiveHour: .init(usedPct: 32, resetsAt: now.addingTimeInterval(2 * 3600)),
            sevenDay: .init(usedPct: 62, resetsAt: now.addingTimeInterval(3 * 86_400)),
            primaryKey: "five_hour", secondaryKey: "seven_day"
        )
    }

    /// Synthetic identity for the "Fable" scoped weekly window used by the
    /// widget-picker mockups — the stable key a config-stored selection uses.
    static let fableKey = "weekly_scoped|Fable|"

    /// Large pace-chart widget with scoped per-model windows as first-class
    /// rows below 5h/7d.
    static var paceChartScopedLarge: PaceChartEntry {
        PaceChartEntry(
            date: now,
            fiveHour: chartWindow(duration: 5 * 3600, usedPct: 32, projectTo: 46),
            sevenDay: chartWindow(duration: 7 * 86_400, usedPct: 62, projectTo: 88),
            // Fable only. Anthropic reports exactly one per-model window
            // today, so caps for Haiku/Opus/Sonnet beside it advertised a
            // product nobody has. The grid is built for N of these; a
            // committed screenshot is a claim about what you get.
            scoped: [
                .init(key: fableKey, label: "Fable",
                      state: chartWindow(duration: 7 * 86_400, usedPct: 49, projectTo: 71),
                      isActive: true),
            ],
            primaryKey: "five_hour", secondaryKey: "seven_day"
        )
    }

    /// A pace-chart entry with 5h, 7d, and a scoped "Fable" weekly window, for
    /// the widget-picker mockups. `primaryKey`/`secondaryKey` pick which windows
    /// the small/medium canvases render — exactly what the Edit-Widget sheet
    /// stores. (Large ignores them and shows every window.)
    static func paceChartPicker(primaryKey: String, secondaryKey: String) -> PaceChartEntry {
        PaceChartEntry(
            date: now,
            fiveHour: chartWindow(duration: 5 * 3600, usedPct: 32, projectTo: 46),
            sevenDay: chartWindow(duration: 7 * 86_400, usedPct: 62, projectTo: 88),
            scoped: [
                .init(key: fableKey, label: "Fable",
                      state: chartWindow(duration: 7 * 86_400, usedPct: 49, projectTo: 71), isActive: true),
            ],
            primaryKey: primaryKey, secondaryKey: secondaryKey)
    }

    /// Large gauges widget with scoped per-model windows as ring gauges.
    static var paceGaugesScopedLarge: PaceGaugesEntry {
        let weeklyReset = now.addingTimeInterval(2 * 86_400 + 4 * 3600)
        let weeklyDur: TimeInterval = 7 * 86_400
        return PaceGaugesEntry(
            date: now,
            fiveHour: .init(usedPct: 32, resetsAt: now.addingTimeInterval(2 * 3600)),
            sevenDay: .init(usedPct: 62, resetsAt: now.addingTimeInterval(3 * 86_400)),
            // See `paceChartScopedLarge`: one real per-model window, not four
            // invented ones.
            scoped: [
                .init(key: fableKey, label: "Fable", usedPct: 49,
                      resetsAt: weeklyReset, durationSeconds: weeklyDur, isActive: true),
            ],
            primaryKey: "five_hour", secondaryKey: "seven_day"
        )
    }

    /// A climbing actual line with a dashed linear projection to `projectTo` at
    /// reset — the shape a real window shows. `~62%` elapsed so the dashed
    /// segment is visible.
    private static func chartWindow(duration: TimeInterval, usedPct: Double, projectTo: Double) -> PaceChartEntry.WindowState {
        let resets = now.addingTimeInterval(duration * 0.38)
        let cycleStart = resets.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(cycleStart)
        let n = 12
        let points = (0..<n).map { i -> PaceChartView.Data.Point in
            let f = Double(i) / Double(n - 1)
            return .init(time: cycleStart.addingTimeInterval(elapsed * f),
                         value: usedPct * (f * (1.06 - 0.06 * f)))
        }
        let steps = 6
        let projection = (0...steps).map { i -> PaceChartView.Data.Point in
            let f = Double(i) / Double(steps)
            return .init(time: now.addingTimeInterval(resets.timeIntervalSince(now) * f),
                         value: min(100, usedPct + (projectTo - usedPct) * f))
        }
        let crossing: Date? = (projectTo > usedPct && projectTo >= 100)
            ? now.addingTimeInterval(resets.timeIntervalSince(now) * ((100 - usedPct) / (projectTo - usedPct)))
            : nil
        return PaceChartEntry.WindowState(
            chart: PaceChartView.Data(
                cycleStart: cycleStart, resetsAt: resets, durationSeconds: duration,
                points: points, usedPct: usedPct,
                projection: projection, projectionCrossesFullAt: crossing),
            resetsAt: resets)
    }

    static var liveSession: LiveSessionEntry {
        LiveSessionEntry(
            date: now,
            session: .init(
                projectDisplayName: "atlas-api",
                totalTokens: 9_400_000,
                costUSD: 142.0,
                topModel: opus,
                firstSeenAt: now.addingTimeInterval(-6.5 * 3600),
                lastSeenAt: now.addingTimeInterval(-30)
            )
        )
    }

    static var dailyChart: DailyChartEntry {
        // Weekday-driven with weekend dips and a spike — same shape as the
        // dashboard's 30-day chart.
        let cal = Calendar.current
        let days = (0..<14).map { i -> DailyChartEntry.DayCost in
            let day = cal.date(byAdding: .day, value: -(13 - i), to: now) ?? now
            let wd = cal.component(.weekday, from: day)
            let weekend = (wd == 1 || wd == 7)
            var cost = weekend ? 34.0 : 120.0
            cost *= 0.7 + 0.7 * Double((i * 7 + 3) % 11) / 11.0
            if i == 9 { cost *= 2.6 }          // a spike day
            return DailyChartEntry.DayCost(date: TokenSample.formatDate(day), cost: cost)
        }
        let total = days.reduce(0) { $0 + $1.cost }
        return DailyChartEntry(
            date: now, days: days,
            totalCostUSD: total,
            avgCostUSD: total / Double(days.count),
            todayCostUSD: days.last?.cost ?? 0,
            isFresh: true, range: .days14
        )
    }

    static var topProjects: TopProjectsEntry {
        let rows = [
            TopProjectsEntry.Row(displayName: "atlas-api", costUSD: 1_284.0),
            TopProjectsEntry.Row(displayName: "ml-pipeline", costUSD: 892.0),
            TopProjectsEntry.Row(displayName: "payments-svc", costUSD: 613.0),
            TopProjectsEntry.Row(displayName: "web-dashboard", costUSD: 421.0),
        ]
        return TopProjectsEntry(
            date: now, range: .days7,
            totalCostUSD: rows.reduce(0) { $0 + $1.costUSD } + 340,
            projectCount: 12,
            rows: rows, focus: nil
        )
    }
}
