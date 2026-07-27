import AppIntents
import Foundation
import SwiftData
import PacerCore
import PacerUI

/// AppIntent types for user-configurable widget options. Long-press a
/// widget on the desktop / Notification Center → "Edit Widget" → these
/// surface as native pickers without any per-widget UI work on our end.
///
/// Kept in one file because the pickers (`PaceWindowEntity` /
/// `LookbackRangeOption`) are shared across more than one widget; the
/// intents themselves are tiny so co-locating them avoids a hop when
/// adding/changing options.

// MARK: - Pace window picker (PaceChart, PaceGauges)

/// One selectable rate-limit window for a pace widget's configuration —
/// the fixed 5-hour / 7-day blocks plus whatever scoped per-model windows
/// (`limits[]`) the account currently has ("Fable", "cowork", …). The `id`
/// is the window's stable key (`WindowSpec.key` / `UsageLimit.identity`), so
/// a selection survives a relabel and can be matched back to live data in the
/// timeline provider. This replaces the old fixed `5h/7d/both` enum: the
/// option set is now provided *dynamically* by `PaceWindowQuery`, so the
/// "Edit Widget" sheet grows on its own as Anthropic adds limits.
struct PaceWindowEntity: AppEntity, Identifiable {
    let id: String           // WindowSpec key / limit identity — stable
    let displayName: String  // "5-hour", "7-day", "Fable", …

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Rate-limit window"
    static let defaultQuery = PaceWindowQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

/// Dynamic options provider for the window pickers. `suggestedEntities()`
/// returns the LIVE window set — the two fixed windows first, then the latest
/// poll's scoped per-model windows — so the picker reflects reality with no
/// hardcoded enum. `entities(for:)` re-hydrates a stored id even when its
/// window is briefly absent (a scoped window between polls) so a saved
/// selection is never silently dropped.
struct PaceWindowQuery: EntityQuery {
    func entities(for identifiers: [PaceWindowEntity.ID]) async throws -> [PaceWindowEntity] {
        let live = Dictionary(
            PaceWindowResolver.liveWindows().map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })
        // Keep every requested id resolvable — fall back to a best-effort
        // label so a momentarily-absent scoped selection stays configured.
        return identifiers.map { id in
            live[id] ?? PaceWindowEntity(id: id, displayName: PaceWindowResolver.name(for: id))
        }
    }

    func suggestedEntities() async throws -> [PaceWindowEntity] {
        PaceWindowResolver.liveWindows()
    }
}

/// Reads the live rate-limit window set from the shared store for the window
/// pickers, and resolves stored selections back to live windows. Fixed 5h/7d
/// come from `WindowSpec.fixedWindows`; scoped windows come from the most
/// recent `UsageLimitSample` batch (the same source the widgets and dashboard
/// use), so the picker and the rendered widget always agree on what exists.
enum PaceWindowResolver {
    /// The full ordered option set: the two fixed windows, then this account's
    /// scoped per-model windows (active/hottest first). De-duplicated by id.
    static func liveWindows() -> [PaceWindowEntity] {
        var seen = Set<String>()
        var out: [PaceWindowEntity] = []
        for spec in WindowSpec.fixedWindows where seen.insert(spec.key).inserted {
            out.append(PaceWindowEntity(id: spec.key, displayName: spec.displayName))
        }
        for e in scopedEntities() where seen.insert(e.id).inserted {
            out.append(e)
        }
        return out
    }

    /// The latest poll's scoped (model/surface) windows — identical filtering
    /// to the widget providers, so the picker never offers a window the widget
    /// can't render.
    private static func scopedEntities() -> [PaceWindowEntity] {
        guard let container = try? PacerStore.sharedModelContainer() else { return [] }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<UsageLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        descriptor.fetchLimit = 200
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.latestBatch()
            .filter {
                ($0.modelId?.isEmpty == false)
                    || ($0.modelDisplayName?.isEmpty == false)
                    || ($0.surface?.isEmpty == false)
            }
            .map { PaceWindowEntity(id: $0.identity, displayName: $0.label) }
    }

    /// Best-effort display name for a stored id that isn't currently live —
    /// keeps a briefly-absent scoped selection labeled instead of blank.
    static func name(for id: String) -> String {
        switch id {
        case "five_hour": return "5-hour"
        case "seven_day": return "7-day"
        default:
            guard let container = try? PacerStore.sharedModelContainer() else { return id }
            let context = ModelContext(container)
            var d = FetchDescriptor<UsageLimitSample>(
                predicate: #Predicate<UsageLimitSample> { $0.identity == id },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
            d.fetchLimit = 1
            return (try? context.fetch(d))?.first?.label ?? id
        }
    }

    /// Resolve a stored/selected window id to a key that exists in `available`,
    /// falling back to `fallback` when the id is nil or its window is gone — so
    /// a widget never renders blank because a scoped window disappeared.
    static func resolveKey(_ id: String?, available: Set<String>, fallback: String) -> String {
        if let id, available.contains(id) { return id }
        return fallback
    }
}

/// Configuration for the pace-chart widget. Two window slots so the medium
/// family can show any pair (5h+7d, 5h+Fable, …); small uses only the first;
/// large shows every window regardless. Both optional — an unset slot falls
/// back to today's defaults (5h primary, 7d secondary), so a placed widget
/// with no explicit configuration renders exactly as it did before.
struct PaceChartConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Rate-limit pace"
    static let description = IntentDescription(
        "Pick the rate-limit window(s) to show. Small shows the first window; medium shows both; large shows every window.")

    @Parameter(title: "Window")
    var primaryWindow: PaceWindowEntity?

    @Parameter(title: "Second window (medium)")
    var secondaryWindow: PaceWindowEntity?
}

/// Configuration for the pace-gauges widget — same two-slot window picker as
/// the chart, kept in lockstep so a user sees the same option set on both.
struct PaceGaugesConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Rate limits"
    static let description = IntentDescription(
        "Pick the rate-limit window(s) to show. Small shows the first window; medium shows both; large shows every window.")

    @Parameter(title: "Window")
    var primaryWindow: PaceWindowEntity?

    @Parameter(title: "Second window (medium)")
    var secondaryWindow: PaceWindowEntity?
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
        let container = try PacerStore.sharedModelContainer()
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
