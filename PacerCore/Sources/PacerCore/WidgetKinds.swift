import Foundation

/// String identifiers used by `WidgetKit` to refer to each widget type.
/// Hoisted here (rather than living inline in each widget) so the App
/// target can call `WidgetCenter.shared.reloadTimelines(ofKind: …)` for
/// specific kinds without duplicating literals — keeping every widget's
/// `kind` and every reload call site in lockstep is otherwise easy to
/// get wrong.
///
/// **Never rename these strings without a migration story.** The string
/// is the persistent identifier WidgetKit uses to remember user-placed
/// widget instances + their configuration choices (which `LookbackRangeOption`,
/// which `PaceWindowOption`, which pinned `ProjectEntity`, etc.). Changing
/// `LiveSessionWidget` to `LiveSession` here would orphan every widget
/// the user has already placed.
public enum WidgetKinds {
    public static let liveSession = "LiveSessionWidget"
    public static let todayCost   = "TodayCostWidget"
    public static let dailyChart  = "DailyChartWidget"
    public static let topProjects = "TopProjectsWidget"
    public static let paceChart   = "PaceChartWidget"
    public static let paceGauges  = "PaceGaugesWidget"

    /// All kinds, ordered roughly from highest-update-cadence (live
    /// session) to lowest (long-lookback aggregates). The refresh
    /// coordinator iterates this list when fanning a "everything
    /// changed" event out to per-kind throttled reloads.
    public static let all: [String] = [
        liveSession,
        todayCost,
        paceGauges,
        paceChart,
        dailyChart,
        topProjects
    ]
}
