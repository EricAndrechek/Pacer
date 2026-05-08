import WidgetKit
import SwiftUI

/// Six Pacer widgets:
///   - TodayCostWidget    : compact today summary (small)
///   - PaceGaugesWidget   : 5h + 7d rate-limit gauges (small / medium)
///   - PaceChartWidget    : cycle-anchored pace line graphs (small / medium / large)
///   - DailyChartWidget   : 14-day cost bar chart (medium / large)
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
        PaceChartWidget()
        DailyChartWidget()
        LiveSessionWidget()
        TopProjectsWidget()
    }
}
