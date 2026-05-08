import AppIntents
import Foundation
import SwiftData
import PacerCore
import PacerUI

/// AppIntent types for user-configurable widget options. Long-press a
/// widget on the desktop / Notification Center → "Edit Widget" → these
/// surface as native pickers without any per-widget UI work on our end.
///
/// Kept in one file because the picker enums (`PaceWindowOption`,
/// `LookbackRangeOption`) are shared across more than one widget; the
/// intents themselves are tiny so co-locating them avoids a hop when
/// adding/changing options.

// MARK: - Pace window picker (PaceChart, PaceGauges)

/// Which rate-limit window a pace widget shows. `both` only renders
/// usefully on medium/large families — small canvases collapse `both`
/// to whichever window's data is currently more interesting (typically
/// the 5-hour cycle, since it's the one users hit first).
enum PaceWindowOption: String, AppEnum {
    case fiveHour
    case sevenDay
    case both

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Window"
    static let caseDisplayRepresentations: [PaceWindowOption: DisplayRepresentation] = [
        .fiveHour: DisplayRepresentation(title: "5-hour only"),
        .sevenDay: DisplayRepresentation(title: "7-day only"),
        .both:     DisplayRepresentation(title: "Both windows")
    ]
}

struct PaceChartConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Rate-limit pace"
    static let description = IntentDescription("Choose which rate-limit window the pace chart shows.")

    @Parameter(title: "Window", default: .both)
    var window: PaceWindowOption
}

struct PaceGaugesConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Rate limits"
    static let description = IntentDescription("Choose which rate-limit window the gauge shows.")

    @Parameter(title: "Window", default: .both)
    var window: PaceWindowOption
}

// MARK: - Lookback range picker (DailyChart, TopProjects)

/// Lookback windows for cost-history widgets. Shared between DailyChart
/// and TopProjects so users see a consistent set of options.
enum LookbackRangeOption: String, AppEnum {
    case days7
    case days14
    case days30
    case days90

    /// Number of days to roll up. Used by the providers' fetch logic.
    var days: Int {
        switch self {
        case .days7:  return 7
        case .days14: return 14
        case .days30: return 30
        case .days90: return 90
        }
    }

    /// Compact label for chart titles ("LAST 7d" etc.).
    var shortLabel: String {
        switch self {
        case .days7:  return "7d"
        case .days14: return "14d"
        case .days30: return "30d"
        case .days90: return "90d"
        }
    }

    /// Long-form label for status lines ("last 7 days" etc.).
    var longLabel: String {
        "last \(days) days"
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Range"
    static let caseDisplayRepresentations: [LookbackRangeOption: DisplayRepresentation] = [
        .days7:  DisplayRepresentation(title: "Last 7 days"),
        .days14: DisplayRepresentation(title: "Last 14 days"),
        .days30: DisplayRepresentation(title: "Last 30 days"),
        .days90: DisplayRepresentation(title: "Last 90 days")
    ]
}

struct DailyChartConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Daily cost"
    static let description = IntentDescription("Choose how far back the daily cost chart looks.")

    @Parameter(title: "Range", default: .days14)
    var range: LookbackRangeOption
}

// MARK: - TopProjects: range + optional pinned project

/// One project surfaced in the picker. `costUSD` is captured at query
/// time so the picker can sort by spend; the widget itself recomputes
/// against the chosen range when it renders.
struct ProjectEntity: AppEntity, Identifiable {
    let id: String           // full project path — stable identifier
    let displayName: String  // `pacerShortPath` form — what the user sees

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = ProjectQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

/// Dynamic options provider — reads the user's actual project list from
/// SwiftData so the picker always reflects what they've been working
/// on. 90-day lookback so the suggestion list stays current without
/// surfacing dormant projects.
struct ProjectQuery: EntityQuery {
    func entities(for identifiers: [ProjectEntity.ID]) async throws -> [ProjectEntity] {
        let all = try await suggestedEntities()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0] }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        let container = try PacerStore.makeModelContainer()
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ProjectDailyAggregate>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let aggregates = try context.fetch(descriptor)
        let cutoff = TokenSample.formatDate(
            Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        )
        let recent = aggregates.filter { $0.date >= cutoff }
        var totals: [String: Double] = [:]
        for r in recent {
            totals[r.projectPath, default: 0] += r.totalCostUSD
        }
        return totals
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { (path, _) in
                ProjectEntity(id: path, displayName: pacerShortPath(path))
            }
    }
}

struct TopProjectsConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Top projects"
    static let description = IntentDescription("Choose the lookback range. Optionally pin a single project to focus the widget on it.")

    @Parameter(title: "Range", default: .days7)
    var range: LookbackRangeOption

    @Parameter(title: "Focus project (optional)")
    var pinnedProject: ProjectEntity?
}
