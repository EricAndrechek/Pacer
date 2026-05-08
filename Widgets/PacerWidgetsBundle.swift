import WidgetKit
import SwiftUI

/// Five Pacer widgets:
///   - TodayCostWidget    : compact today summary (small)
///   - PaceGaugesWidget   : 5h + 7d rate-limit gauges (small / medium)
///   - DailyChartWidget   : 14-day cost sparkline (medium / large)
///   - LiveSessionWidget  : current session pulse (small / medium)
///   - TopProjectsWidget  : where the budget is going (medium / large)
///
/// Each is its own StaticConfiguration backed by its own TimelineProvider
/// so the OS can render and budget them independently. They read from
/// the same App Group SwiftData container the app writes to.
@main
struct PacerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayCostWidget()
        PaceGaugesWidget()
        DailyChartWidget()
        LiveSessionWidget()
        TopProjectsWidget()
    }
}
