import SwiftUI
import PacerCore

// The sessions lists — Project detail's sessions and Day detail's sessions
// on that day — in the shared usage table (#215 follow-up).
//
// They were the last hand-rolled table: a header row of `SortableColumnHeader`s
// over `HoverRow`s, with its own sort, its own fonts and only two of the
// numbers. Now a session is a row like a model or a project: the same header,
// sort, column menu and saved layout, and every token part, the two ratios
// and the Mix bar one right-click away.

/// What a sessions table shows beyond the standard columns: the session's
/// project, how long it ran, and when it was last seen.
public struct PacerSessionExtra: PacerUsageExtra, Sendable, Equatable {
    public static let project = "project"
    public static let duration = "duration"
    /// "lastSeen", the raw value both screens stored for this sort before.
    public static let lastSeen = "lastSeen"

    public let projectPath: String
    /// The project's short name, as the Project column prints it.
    public let projectName: String
    public let firstSeenAt: Date
    public let lastSeenAt: Date

    public init(projectPath: String, projectName: String, firstSeenAt: Date, lastSeenAt: Date) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    /// First seen to last seen.
    public var duration: TimeInterval { max(0, lastSeenAt.timeIntervalSince(firstSeenAt)) }

    public func sortKey(forColumn id: String) -> PacerUsageSortKey? {
        switch id {
        case Self.project:  return .text(projectName)
        case Self.duration: return .number(duration)
        case Self.lastSeen: return .date(lastSeenAt)
        default:            return nil
        }
    }
}

/// A sessions table: the session's top model over its short id, the Project
/// column when the list spans projects, Total, Cost and a Last seen that
/// keeps ticking. Duration, every token part, Out %, Write % and Mix are in
/// the header's menu.
public struct PacerSessionsTable: View {
    public typealias Row = PacerUsageRow<PacerSessionExtra>

    let rows: [Row]
    let tableId: String
    let showProject: Bool
    let sort: PacerUsageSort
    let onSort: (PacerUsageSort) -> Void
    let onOpen: (Row) -> Void
    let store: UserDefaults

    /// About eight two-line rows before it scrolls, the height the
    /// hand-rolled list stopped at.
    public static let maxVisibleRows = 8

    /// The standard columns a sessions table shows by default: a session's
    /// line is long enough with its label, project and times, so the parts
    /// and ratios wait in the column menu.
    public static let defaultColumns: Set<UsageColumn> = [.name, .tokens, .cost]

    /// - `rows`: from `rows(_:)`, cached by the screen.
    /// - `showProject`: the Project column, for a list that spans projects
    ///   (Day detail). Project detail's sessions are all one project.
    public init(
        rows: [Row],
        tableId: String,
        showProject: Bool,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: @escaping (Row) -> Void,
        store: UserDefaults = PacerPreferences.store
    ) {
        self.rows = rows
        self.tableId = tableId
        self.showProject = showProject
        self.sort = sort
        self.onSort = onSort
        self.onOpen = onOpen
        self.store = store
    }

    public var body: some View {
        let showProject = self.showProject
        PacerUsageTable(
            rows: rows,
            tableId: tableId,
            labelTitle: "Session",
            sort: sort,
            onSort: onSort,
            onOpen: onOpen,
            maxVisibleRows: Self.maxVisibleRows,
            defaultColumns: Self.defaultColumns,
            store: store
        ) {
            // Beside the label: which project a session was in reads with
            // which session it was.
            if showProject {
                PacerUsageColumns.extra(PacerSessionExtra.project, title: "Project",
                                        of: PacerSessionExtra.self, numeric: false,
                                        minWidth: 70, idealWidth: 100, descendingFirst: false) { row in
                    Text(row.extra.projectName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.extra.projectPath)
                }
            }
        } extraColumns: {
            PacerUsageColumns.extra(PacerSessionExtra.duration, title: "Duration",
                                    of: PacerSessionExtra.self,
                                    minWidth: 48, idealWidth: 56, visibleByDefault: false) { row in
                Text(pacerSessionDuration(row.extra.duration))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("\(pacerRelativeExact(row.extra.firstSeenAt)) → \(pacerRelativeExact(row.extra.lastSeenAt))")
            }
            PacerUsageColumns.extra(PacerSessionExtra.lastSeen, title: "Last seen",
                                    of: PacerSessionExtra.self,
                                    minWidth: 60, idealWidth: 64) { row in
                // Judged against the clock, so it needs one: nothing else
                // redraws an open detail on an idle machine, and "2 min ago"
                // stayed "2 min ago".
                TimelineView(.everyMinute) { _ in
                    Text(pacerRelative(row.extra.lastSeenAt))
                        .help(pacerRelativeExact(row.extra.lastSeenAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The rows for `sessions`. A screen builds these once per change of its
    /// sessions and keeps them; the table sorts them itself.
    public static func rows(_ sessions: [SessionRow]) -> [Row] {
        sessions.map { session in
            PacerUsageRow(
                id: session.sessionId,
                label: pacerModelDisplayName(session.topModel),
                subtitle: String(session.sessionId.prefix(8)),
                color: pacerModelColor(session.topModel),
                tokens: session.tokens,
                costParts: session.cost,
                cost: session.cumulativeCostUSD,
                extra: PacerSessionExtra(
                    projectPath: session.projectPath,
                    projectName: pacerShortPath(session.projectPath),
                    firstSeenAt: session.firstSeenAt,
                    lastSeenAt: session.lastSeenAt))
        }
    }

    /// A sort stored before the shared table. Its "id" and "model" columns
    /// are both the label column now (the label is the model, over the id);
    /// "project", "tokens", "cost" and "lastSeen" are column ids already.
    public static func sort(stored column: String, descending: Bool) -> PacerUsageSort {
        let migrated = column == "id" || column == "model" ? UsageColumn.name.rawValue : column
        return PacerUsageSort(column: migrated, descending: descending)
    }
}

/// `firstSeen → lastSeen` as "45s", "12m", "3h 12m", "2d 4h": second
/// granularity under a minute so "0m" is never the answer.
public func pacerSessionDuration(_ seconds: TimeInterval) -> String {
    let seconds = max(0, seconds)
    if seconds < 60 { return "\(Int(seconds))s" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remMin = minutes % 60
    if hours < 24 { return remMin == 0 ? "\(hours)h" : "\(hours)h \(remMin)m" }
    let days = hours / 24
    let remHr = hours % 24
    return remHr == 0 ? "\(days)d" : "\(days)d \(remHr)h"
}
