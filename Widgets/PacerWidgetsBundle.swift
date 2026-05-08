import WidgetKit
import SwiftUI

/// Six Pacer widgets, all in this single app-extension target. Each
/// `Widget` type below declares its own `supportedFamilies` so the
/// gallery shows one entry per widget with the appropriate sizes
/// underneath:
///   - TodayCostWidget    : compact today summary (small)
///   - PaceGaugesWidget   : 5h + 7d rate-limit gauges (small / medium) — configurable window
///   - PaceChartWidget    : cycle-anchored pace line graphs (small / medium / large) — configurable window
///   - DailyChartWidget   : daily cost bar chart (medium / large) — configurable range
///   - LiveSessionWidget  : current session pulse (small / medium)
///   - TopProjectsWidget  : where the budget is going (medium / large) — configurable range + project pin
///
/// Four of the six use `AppIntentConfiguration` so the user can long-
/// press → "Edit Widget" → pick options; the configurable ones can be
/// added more than once to the desktop with different settings (one
/// small pace chart pinned to 5-hour, another to 7-day, both running
/// independent timelines). The remaining two (`TodayCostWidget`,
/// `LiveSessionWidget`) are static — there's nothing useful to
/// configure on them.
///
/// All widgets share the App Group SwiftData container the daemon
/// writes to, so timelines reflect the same data the dashboard reads.
@main
struct PacerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayCostWidget()
        PaceGaugesWidget()
        PaceChartWidget()
        DailyChartWidget()
        LiveSessionWidget()
        TopProjectsWidget()
    }
}
