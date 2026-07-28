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
    /// A *stable* one-line descriptor for the option row — the window's scope
    /// and cadence ("Weekly limit · all models", "Per-model · weekly"), never
    /// a live percentage. The config sheet is edited rarely, so a number that
    /// changes every poll would only read as noise here. `nil` when the window
    /// can't be classified (best-effort re-hydrate of a briefly-absent id).
    var subtitle: String? = nil

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Usage window"
    static let defaultQuery = PaceWindowQuery()

    var displayRepresentation: DisplayRepresentation {
        if let subtitle {
            return DisplayRepresentation(title: "\(displayName)", subtitle: "\(subtitle)")
        }
        return DisplayRepresentation(title: "\(displayName)")
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
            live[id] ?? PaceWindowResolver.absentEntity(for: id)
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
            out.append(PaceWindowEntity(
                id: spec.key, displayName: spec.displayName,
                subtitle: fixedSubtitle(spec.key)))
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
            .map { PaceWindowEntity(id: $0.identity, displayName: $0.label,
                                    subtitle: scopedSubtitle(group: $0.group)) }
    }

    /// Best-effort re-hydrate of a stored id that isn't currently in the live
    /// set — keeps a briefly-absent selection fully labeled (name + subtitle)
    /// instead of blank. Fixed ids resolve locally; a scoped id is looked up in
    /// its last-seen row.
    static func absentEntity(for id: String) -> PaceWindowEntity {
        switch id {
        case "five_hour":
            return PaceWindowEntity(id: id, displayName: "5-hour", subtitle: fixedSubtitle(id))
        case "seven_day":
            return PaceWindowEntity(id: id, displayName: "7-day", subtitle: fixedSubtitle(id))
        default:
            guard let container = try? PacerStore.sharedModelContainer() else {
                return PaceWindowEntity(id: id, displayName: id)
            }
            let context = ModelContext(container)
            var d = FetchDescriptor<UsageLimitSample>(
                predicate: #Predicate<UsageLimitSample> { $0.identity == id },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
            d.fetchLimit = 1
            if let row = (try? context.fetch(d))?.first {
                return PaceWindowEntity(id: id, displayName: row.label,
                                        subtitle: scopedSubtitle(group: row.group))
            }
            return PaceWindowEntity(id: id, displayName: id)
        }
    }

    /// The concrete entity a config slot defaults to, so the Edit sheet shows a
    /// real selection (5-hour / 7-day) instead of "None". Pulls the label from
    /// `WindowSpec.fixedWindows` so it stays in lockstep with the option list.
    static func fixedDefault(_ key: String) -> PaceWindowEntity {
        let name = WindowSpec.fixedWindows.first { $0.key == key }?.displayName
            ?? (key == "five_hour" ? "5-hour" : "7-day")
        return PaceWindowEntity(id: key, displayName: name, subtitle: fixedSubtitle(key))
    }

    /// Stable subtitle for a fixed account-wide window. States the scope the
    /// title's cadence ("5-hour"/"7-day") doesn't — that these cover every model.
    static func fixedSubtitle(_ key: String) -> String {
        key == "five_hour" ? "Session limit · all models" : "Weekly limit · all models"
    }

    /// Stable subtitle for a scoped per-model window. The title is the model
    /// name, so the subtitle carries the cadence and that it's a per-model cap.
    static func scopedSubtitle(group: String) -> String {
        switch group.lowercased() {
        case "session": return "Per-model · session"
        case "weekly":  return "Per-model · weekly"
        default:        return "Per-model window"
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
/// large shows every window regardless.
///
/// Both slots carry a real default (`primaryWindow` = 5-hour, `secondaryWindow`
/// = 7-day) via the non-deprecated macOS-15 `@Parameter(default:)` entity init,
/// so the Edit sheet opens on a concrete pair rather than "None". The params
/// stay optional so the on-disk config shape is unchanged: a legacy widget
/// placed before this (nil slots) still decodes and, like an unset default,
/// resolves to 5h primary / 7d secondary in the provider — the rendered output
/// is byte-for-byte identical either way. A user's explicit pick is stored by
/// id and re-hydrated by `PaceWindowQuery`, so it's never replaced by the
/// default even when a scoped window is briefly absent between polls.
struct PaceChartConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Rate-limit pace"
    static let description = IntentDescription(
        "Choose which usage windows the pace chart shows. The small widget shows the left window; medium shows left and right side by side; large shows every window.")

    static var parameterSummary: some ParameterSummary {
        Summary("Left \(\.$primaryWindow), right \(\.$secondaryWindow)")
    }

    @Parameter(
        title: "Left window",
        description: "The left chart on the medium widget — and the only chart the small widget shows.",
        default: PaceWindowResolver.fixedDefault("five_hour"))
    var primaryWindow: PaceWindowEntity?

    @Parameter(
        title: "Right window",
        description: "The right chart on the medium widget. Not shown on the small widget.",
        default: PaceWindowResolver.fixedDefault("seven_day"))
    var secondaryWindow: PaceWindowEntity?
}

/// Configuration for the pace-gauges widget — same two-slot window picker as
/// the chart (same defaults, same optional-but-pre-filled behaviour), kept in
/// lockstep so a user sees the same options and defaults on both.
struct PaceGaugesConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Rate limits"
    static let description = IntentDescription(
        "Choose which usage windows the gauges show. The small widget shows the left window; medium shows left and right side by side; large shows every window.")

    static var parameterSummary: some ParameterSummary {
        Summary("Left \(\.$primaryWindow), right \(\.$secondaryWindow)")
    }

    @Parameter(
        title: "Left window",
        description: "The left gauge on the medium widget — and the only gauge the small widget shows.",
        default: PaceWindowResolver.fixedDefault("five_hour"))
    var primaryWindow: PaceWindowEntity?

    @Parameter(
        title: "Right window",
        description: "The right gauge on the medium widget. Not shown on the small widget.",
        default: PaceWindowResolver.fixedDefault("seven_day"))
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
