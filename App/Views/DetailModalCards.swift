import SwiftUI
import PacerCore
import PacerUI

/// The cards Day detail and Project detail share under their first card
/// (round 5), so the two modals read the same way: By model as a donut card,
/// then the models as a table, then the paths (a day's projects, a project's
/// subprojects) and the sessions as tables, each with the same title,
/// columns and height in both.
///
/// Built here once rather than in each modal: two copies of a card drift, and
/// the owner asked for one layout.
@MainActor
enum DetailModalCards {
    /// Rows a modal's table shows before it scrolls inside: the sessions
    /// table's own cap, so every table in a modal stops at the same height
    /// and a busy day or project does not make the modal very long.
    static let maxVisibleRows: Int = PacerSessionsTable.maxVisibleRows

    /// By model's columns: each model's share of the cost and of the tokens,
    /// as the Models tab's Share card has them. Shares, not amounts: the
    /// Models table under the card prints the amounts, and a modal prints a
    /// number once.
    static let modelShareColumns: [PacerShareListColumn] = [
        .share(of: UsageColumn.cost.rawValue, title: "Cost", format: .cost, help: "Share of the cost"),
        .share(of: UsageColumn.tokens.rawValue, title: "Tokens", format: .tokens, help: "Share of every token"),
    ]

    /// A modal's models, as the donut card and the table both take them.
    typealias ModelRow = PacerUsageRow<PacerUsageNoExtra>

    /// One model's row: its colour, every token part and its cost by part.
    static func modelRow(model: String, tokens: TokenBreakdown, costParts: CostComponents,
                         cost: Double) -> ModelRow {
        PacerUsageRow(id: model, label: pacerModelDisplayName(model), color: pacerModelColor(model),
                      tokens: tokens, costParts: costParts, cost: cost)
    }

    /// How the models divide the cost and the tokens: the shared donut card.
    /// Clicking Cost or Tokens ranks the list by it and turns the ring to it.
    static func modelShareCard(
        rows: [ModelRow], sort: PacerUsageSort, subject: String,
        onSort: @escaping (PacerUsageSort) -> Void
    ) -> some View {
        let data = PacerShareListData(rows: rows, sort: sort, columns: modelShareColumns, maxSlices: 8)
        return PacerDonutListCard(
            "By model",
            data: data,
            labelTitle: "Model",
            accessibilityLabel: "\(data.donut.metric.title) by model for \(subject)",
            onSort: onSort)
    }

    /// Every model, in the usage table's narrow form (Total, Hit %, Out %,
    /// Cost; the token parts and Mix one right-click away).
    static func modelsTableCard(
        rows: [ModelRow], tableId: String, sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void
    ) -> some View {
        PacerTableCard("Models") {
            PacerUsageTable(
                rows: rows,
                tableId: tableId,
                labelTitle: "Model",
                sort: sort,
                onSort: onSort,
                maxVisibleRows: maxVisibleRows,
                defaultColumns: UsageColumn.narrowDefaults)
        }
    }

    /// A day's projects or a project's subprojects: the usage table in the
    /// narrow form the Models table has (the wide one's four token parts do
    /// not fit beside a Sessions column at a Day modal's width), with how
    /// many sessions ran in each path, capped at `maxVisibleRows` with its
    /// own scroll.
    static func pathsTableCard<RowMenu: View>(
        _ title: String,
        labelTitle: String,
        rows: [PacerUsageRow<DetailPathExtra>],
        tableId: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((PacerUsageRow<DetailPathExtra>) -> Void)? = nil,
        @ViewBuilder rowMenu: @escaping (PacerUsageRow<DetailPathExtra>) -> RowMenu
    ) -> some View {
        PacerTableCard(title) {
            PacerUsageTable(
                rows: rows,
                tableId: tableId,
                labelTitle: labelTitle,
                sort: sort,
                onSort: onSort,
                onOpen: onOpen,
                maxVisibleRows: maxVisibleRows,
                defaultColumns: UsageColumn.narrowDefaults,
                extraColumns: {
                    PacerUsageColumns.extra(DetailPathExtra.sessions, title: "Sessions",
                                            of: DetailPathExtra.self,
                                            minWidth: 28, idealWidth: 58) { row in
                        Text("\(row.extra.sessions)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                },
                rowMenu: rowMenu)
        }
    }

    /// The sessions, in the shared sessions table (which caps its own
    /// height). No count in the header: the first card has it.
    static func sessionsCard(
        rows: [PacerSessionsTable.Row], tableId: String, showProject: Bool,
        sort: PacerUsageSort, onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: @escaping (PacerSessionsTable.Row) -> Void
    ) -> some View {
        PacerTableCard("Sessions") {
            PacerSessionsTable(
                rows: rows,
                tableId: tableId,
                showProject: showProject,
                sort: sort,
                onSort: onSort,
                onOpen: onOpen)
        }
    }

    /// A sort read back from storage, kept when it names a standard column
    /// or one of `own`, else cost first. A sort saved for a column that has
    /// gone (Project detail's By model "In + out") would otherwise rank by
    /// nothing.
    static func sort(stored column: String, descending: Bool, own: Set<String> = []) -> PacerUsageSort {
        // Built first, so a retired id is read as its successor before the
        // check ("writeShare" is Hit % now).
        let sort = PacerUsageSort(column: column, descending: descending)
        if UsageColumn(rawValue: sort.column) != nil || own.contains(sort.column) {
            return sort
        }
        return .costDescending
    }
}

/// What a day's project row or a project's subpath row has beyond the
/// standard columns: how many sessions ran in it.
struct DetailPathExtra: PacerUsageExtra, Sendable, Equatable {
    static let sessions = "sessions"
    let sessions: Int

    func sortKey(forColumn id: String) -> PacerUsageSortKey? {
        id == Self.sessions ? .number(Double(sessions)) : nil
    }
}
