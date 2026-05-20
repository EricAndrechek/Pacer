import SwiftUI
import SwiftData
import PacerCore

/// Shared sortable table of `SessionInfo` rows. Used by both
/// `ProjectDetailView` (project's sessions) and `DayDetailView`
/// (sessions active on a specific day) so both surfaces have the
/// same look-and-feel + sort behavior.
///
/// The user flagged that two different surfaces displayed sessions
/// in two different layouts with two different feature sets — the
/// day modal had no sortable columns, no chevron, and capped at
/// "+ N more" rows that weren't reachable. Consolidating into one
/// component eliminates that drift and gives both surfaces:
///   - Sortable column headers with persistent direction
///   - Hover-row affordance + chevron + pointing cursor
///   - Inner scroll with a visible scrollbar past a row threshold
///   - Optional "Project" column (used by Day modal; hidden for Project modal)
///
/// Sort fields and persistence are caller-supplied so each surface
/// can store its preference under a distinct App Group key.
public struct SessionsTable: View {
    /// Already filtered + ready-to-sort. Caller supplies the rows
    /// from its own @Query so SwiftData updates stay incremental.
    public let rows: [SessionInfo]
    /// Show the "Project" column. The project-detail modal already
    /// scopes by one project so the column is redundant there; the
    /// day-detail modal benefits from it.
    public let showProjectColumn: Bool
    /// Callback for opening a session's detail modal.
    public let onSessionTap: (SessionInfo) -> Void

    @Binding public var sort: SessionsTableSort
    @Binding public var sortDescending: Bool

    public init(
        rows: [SessionInfo],
        showProjectColumn: Bool,
        sort: Binding<SessionsTableSort>,
        sortDescending: Binding<Bool>,
        onSessionTap: @escaping (SessionInfo) -> Void
    ) {
        self.rows = rows
        self.showProjectColumn = showProjectColumn
        self._sort = sort
        self._sortDescending = sortDescending
        self.onSessionTap = onSessionTap
    }

    /// Above this many rows the body switches to an inner scroll
    /// view with a visible scrollbar. Below the threshold we render
    /// inline so a small list doesn't get an awkward mini-scroller.
    private static let inlineRowThreshold = 12
    private static let scrollMaxHeight: CGFloat = 320

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Divider().padding(.vertical, 2)
            if sortedRows.isEmpty {
                Text("No sessions in scope.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else if sortedRows.count <= Self.inlineRowThreshold {
                ForEach(sortedRows, id: \.sessionId) { row in
                    rowView(row)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sortedRows, id: \.sessionId) { row in
                            rowView(row)
                        }
                    }
                }
                .frame(maxHeight: Self.scrollMaxHeight)
                // Visible scrollbar so the user can see there's more
                // content + how far they've scrolled. User flagged
                // that hidden indicators on a long list felt like
                // missing affordance.
                .scrollIndicators(.visible)
            }
        }
    }

    private var sortedRows: [SessionInfo] {
        let primary: (SessionInfo, SessionInfo) -> Bool
        switch sort {
        case .id:
            primary = { $0.sessionId < $1.sessionId }
        case .model:
            primary = { $0.topModel < $1.topModel }
        case .project:
            primary = { $0.projectPath.localizedCaseInsensitiveCompare($1.projectPath) == .orderedAscending }
        case .tokens:
            primary = { $0.totalTokens < $1.totalTokens }
        case .cost:
            primary = { $0.cumulativeCostUSD < $1.cumulativeCostUSD }
        case .lastSeen:
            primary = { $0.lastSeenAt < $1.lastSeenAt }
        }
        let sorted = rows.sorted { lhs, rhs in
            if primary(lhs, rhs) { return true }
            if primary(rhs, lhs) { return false }
            // Stable tiebreaker — session IDs are unique, no shuffle.
            return lhs.sessionId < rhs.sessionId
        }
        return sortDescending ? sorted.reversed() : sorted
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            SortableColumnHeader(
                "ID",
                field: SessionsTableSort.id,
                alignment: .leading,
                active: $sort,
                descending: $sortDescending,
                defaultDescending: false
            ).frame(width: 80, alignment: .leading)
            SortableColumnHeader(
                "Model",
                field: SessionsTableSort.model,
                alignment: .leading,
                active: $sort,
                descending: $sortDescending,
                defaultDescending: false
            ).frame(maxWidth: showProjectColumn ? 150 : 220, alignment: .leading)
            if showProjectColumn {
                SortableColumnHeader(
                    "Project",
                    field: SessionsTableSort.project,
                    alignment: .leading,
                    active: $sort,
                    descending: $sortDescending,
                    defaultDescending: false
                ).frame(width: 130, alignment: .leading)
            }
            Spacer()
            SortableColumnHeader(
                "Tokens",
                field: SessionsTableSort.tokens,
                alignment: .trailing,
                active: $sort,
                descending: $sortDescending
            ).frame(width: 80)
            SortableColumnHeader(
                "Cost",
                field: SessionsTableSort.cost,
                alignment: .trailing,
                active: $sort,
                descending: $sortDescending
            ).frame(width: 70)
            SortableColumnHeader(
                "Last seen",
                field: SessionsTableSort.lastSeen,
                alignment: .trailing,
                active: $sort,
                descending: $sortDescending
            ).frame(width: 90)
            // Reserve room for the row's chevron-icon column.
            Spacer().frame(width: 16)
        }
    }

    @ViewBuilder
    private func rowView(_ row: SessionInfo) -> some View {
        HoverRow(action: { onSessionTap(row) }) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(row.sessionId.prefix(8)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(pacerShortModel(row.topModel))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: showProjectColumn ? 150 : 220, alignment: .leading)
                if showProjectColumn {
                    Text(pacerShortPath(row.projectPath))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 130, alignment: .leading)
                }
                Spacer(minLength: 8)
                Text(pacerTokens(row.totalTokens))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                    .help(pacerTokensExact(row.totalTokens))
                Text(pacerCost(row.cumulativeCostUSD))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                    .help(pacerCostExact(row.cumulativeCostUSD))
                Text(pacerRelative(row.lastSeenAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 90, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, alignment: .trailing)
            }
        }
    }
}

/// Shared sort field for the sessions table. Matches what both
/// surfaces persist; legal values include `.project` for the Day
/// modal which renders the extra column. The Project modal's
/// previous SessionsSort enum had only the first five — moved to
/// this superset so we don't fork the type.
public enum SessionsTableSort: String, CaseIterable, Identifiable {
    case id, model, project, tokens, cost, lastSeen
    public var id: String { rawValue }
}
