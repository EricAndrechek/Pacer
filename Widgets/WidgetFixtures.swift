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
/// the views with them directly (the widget-picker and scoped mockups), and
/// `ReadmeShotWidget` — compiled into the extension only for the CI screenshot
/// build — serves them to WidgetKit Simulator for `docs/screenshots/widgets.png`
/// and `scoped-firstclass-widget.png` (bin/widgetkit-sim-shots.sh).
enum WidgetFixtures {
    /// Every widget the README screenshots photograph, each in the one family
    /// it is shown at. `id` is the stand-in's kind suffix (`ReadmeShot.<id>`),
    /// which bin/widgetkit-sim-shots.sh names; keep the two in step.
    static let readmeShots: [(id: String, family: WidgetFamily)] = [
        ("today", .systemSmall),
        ("pace-gauges", .systemMedium),
        ("live-session", .systemMedium),
        ("daily-chart", .systemMedium),
        ("top-projects", .systemMedium),
        // scoped-firstclass-widget.png: per-model windows, first-class.
        ("pace-chart-scoped", .systemLarge),
        ("pace-gauges-scoped", .systemLarge),
    ]

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

#if PACER_WIDGET_FIXTURES
// MARK: - README screenshot widget (CI screenshot builds only)

/// The README's widgets, as WidgetKit Simulator photographs them
/// (bin/widgetkit-sim-shots.sh).
///
/// Why stand-ins rather than the real widget types: each README shot needs one
/// widget in one family over fixture data, and the fixture build must not
/// contain the real, store-reading widgets at all. What each renders is the
/// real widget view, in the real extension, laid out and drawn by WidgetKit;
/// only this wrapper is not the shipping `Widget`. It mirrors the one
/// configuration modifier that affects rendering — every Pacer widget opts out
/// of the system content margins — so keep it in step if that changes.
///
/// Compiled in only with `PACER_WIDGET_FIXTURES`, which only the README
/// screenshot workflow sets (an xcconfig over the whole build), so no build
/// that ships contains it — a stray setting on somebody's Mac can never put
/// fake numbers on their desktop.
protocol ReadmeShotWidget: Widget {
    /// Index into `WidgetFixtures.readmeShots`.
    static var index: Int { get }
}

extension ReadmeShotWidget {
    var body: some WidgetConfiguration {
        let (id, family) = WidgetFixtures.readmeShots[Self.index]
        // `ReadmeShot.<id>`: its own kind (a bundle's kinds must differ), a
        // stable one for `_XCWidgetKind` to name; the one family the README
        // shows it in. No display name: WidgetKit trapped (on the CI runner,
        // while listing the bundle) on an interpolated one, and nothing
        // shows it here.
        return StaticConfiguration(kind: "ReadmeShot.\(id)", provider: ReadmeShotProvider()) { _ in
            ReadmeShotView(id: id)
        }
        .supportedFamilies([family])
        .contentMarginsDisabled()
    }
}

struct ReadmeShot0: ReadmeShotWidget { static let index = 0 }
struct ReadmeShot1: ReadmeShotWidget { static let index = 1 }
struct ReadmeShot2: ReadmeShotWidget { static let index = 2 }
struct ReadmeShot3: ReadmeShotWidget { static let index = 3 }
struct ReadmeShot4: ReadmeShotWidget { static let index = 4 }
struct ReadmeShot5: ReadmeShotWidget { static let index = 5 }
struct ReadmeShot6: ReadmeShotWidget { static let index = 6 }

struct ReadmeShotEntry: TimelineEntry { let date: Date }

struct ReadmeShotProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReadmeShotEntry { ReadmeShotEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (ReadmeShotEntry) -> Void) {
        completion(ReadmeShotEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadmeShotEntry>) -> Void) {
        completion(Timeline(entries: [ReadmeShotEntry(date: Date())], policy: .never))
    }
}

/// The real widget view for shot `id`, over its fixture entry. The family is
/// the one WidgetKit renders it in, as on a desktop — never forced.
struct ReadmeShotView: View {
    let id: String
    var body: some View {
        switch id {
        case "today": TodayCostWidgetView(entry: WidgetFixtures.todayCost)
        case "pace-gauges": PaceGaugesWidgetView(entry: WidgetFixtures.paceGauges)
        case "live-session": LiveSessionWidgetView(entry: WidgetFixtures.liveSession)
        case "daily-chart": DailyChartWidgetView(entry: WidgetFixtures.dailyChart)
        case "top-projects": TopProjectsWidgetView(entry: WidgetFixtures.topProjects)
        case "pace-chart-scoped": PaceChartWidgetView(entry: WidgetFixtures.paceChartScopedLarge)
        case "pace-gauges-scoped": PaceGaugesWidgetView(entry: WidgetFixtures.paceGaugesScopedLarge)
        default: Text(id)
        }
    }
}
#endif
