import SwiftUI
import PacerCore

// One sortable, customizable table for every "by model / by project / by day"
// usage list (#215 follow-up): Models, Today by model, Projects, Top days, and
// Day detail's models and projects.
//
// It is SwiftUI's own `Table`, not a hand-rolled grid, because what the owner
// asked for is exactly what `TableColumnCustomization` gives a native table:
// right-click a header to show or hide a column, drag a header to reorder,
// drag an edge to resize. Each screen used to draw its own header row of
// `SortableColumnHeader`s over an `HStack` per row, and they had drifted: one
// counted three token parts, another two, and none could show the parts.
//
// What a native `Table` costs inside a scrolling page is its height. It is an
// `NSScrollView` and reports no content height of its own (an off-screen host
// measures it as zero), so the table sets its own frame from the row count
// (`PacerUsageTableMetrics`), up to a cap past which it scrolls inside, the
// way `SessionsTable` does. `UsageTableLayoutTests` checks that height
// against the rows a real `NSTableView` lays out, on whichever OS runs it.

// MARK: - Column titles and cell text

public extension UsageColumn {
    /// The header title. The label column takes the table's own ("Model",
    /// "Project", "Date").
    func title(label: String) -> String {
        switch self {
        case .name:         return label
        case .input:        return "Input"
        case .output:       return "Output"
        case .cacheRead:    return "Cache read"
        case .cacheWrite:   return "Cache write"
        case .cacheWrite5m: return "5m write"
        case .cacheWrite1h: return "1h write"
        case .tokens:       return "Total"
        case .cost:         return "Cost"
        }
    }

    /// Column widths. A table starts each column at its ideal width and
    /// spreads any room left over across all of them, so the ideals are the
    /// narrowest a column reads well at: its header (11pt) and a compact
    /// number side by side. The minimums are where a window narrowed later
    /// stops shrinking them; past those the table scrolls sideways.
    var idealWidth: CGFloat {
        switch self {
        case .name:         return 150
        case .input:        return 50
        case .output:       return 56
        case .cacheRead:    return 74
        case .cacheWrite:   return 78
        case .cacheWrite5m: return 64
        case .cacheWrite1h: return 62
        case .tokens:       return 52
        case .cost:         return 62
        }
    }

    var minWidth: CGFloat { self == .name ? 110 : 44 }

    /// What a cell prints (compact, so seven numbers fit a card) and what
    /// its tooltip spells out (exact). Nil for the label column.
    func cellText(tokens: TokenBreakdown, cost: Double) -> PacerUsageCellText? {
        switch self {
        case .name:
            return nil
        case .cost:
            return PacerUsageCellText(text: pacerCost(cost), help: pacerCostExact(cost))
        case .cacheWrite:
            // The split lives here rather than in two more default columns:
            // Cache write is one number on screen and the tiers are one hover
            // away, which is the "same number twice" rule's answer.
            let total = pacerTokensExact(tokens.cacheWrite)
            let fiveMinute = pacerTokensExact(tokens.cacheCreation5mTokens)
            let oneHour = pacerTokensExact(tokens.cacheCreation1hTokens)
            return PacerUsageCellText(
                text: pacerTokens(tokens.cacheWrite),
                help: "\(total): 5m \(fiveMinute) · 1h \(oneHour)")
        default:
            let count = tokenCount(of: tokens) ?? 0
            return PacerUsageCellText(text: pacerTokens(count), help: pacerTokensExact(count))
        }
    }
}

/// One cell's printed value and its tooltip.
public struct PacerUsageCellText: Equatable, Sendable {
    public let text: String
    public let help: String

    public init(text: String, help: String) {
        self.text = text
        self.help = help
    }
}

// MARK: - Rows

/// One row of a usage table. A plain value: each screen folds its own
/// rollup into these, so the table never knows whether a row is a model, a
/// project or a day.
///
/// `Extra` carries whatever the screen's own columns show (a model's active
/// days, a project's sessions) — see `PacerUsageExtra`.
public struct PacerUsageRow<Extra>: Identifiable {
    public let id: String
    public let label: String
    /// A second, smaller line under the label (a model id, a project path).
    public let subtitle: String?
    /// What the label column sorts by. The label unless given: Top days
    /// prints "Thu Apr 30" but sorts by "2026-04-30".
    public let sortLabel: String
    /// A dot before the label, in the colour the screen's charts use for it.
    public let color: Color?
    public let tokens: TokenBreakdown
    public let cost: Double
    public let extra: Extra

    public init(
        id: String,
        label: String,
        subtitle: String? = nil,
        sortLabel: String? = nil,
        color: Color? = nil,
        tokens: TokenBreakdown,
        cost: Double,
        extra: Extra
    ) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.sortLabel = sortLabel ?? label
        self.color = color
        self.tokens = tokens
        self.cost = cost
        self.extra = extra
    }
}

extension PacerUsageRow: Sendable where Extra: Sendable {}
extension PacerUsageRow: Equatable where Extra: Equatable {}

public extension PacerUsageRow where Extra == PacerUsageNoExtra {
    init(
        id: String,
        label: String,
        subtitle: String? = nil,
        sortLabel: String? = nil,
        color: Color? = nil,
        tokens: TokenBreakdown,
        cost: Double
    ) {
        self.init(id: id, label: label, subtitle: subtitle, sortLabel: sortLabel,
                  color: color, tokens: tokens, cost: cost, extra: PacerUsageNoExtra())
    }
}

// MARK: - Screen-specific columns

/// What a screen's own columns sort by. A screen's `Extra` type answers for
/// each of its column ids, so the value a column prints and the value it
/// sorts by come from the same struct.
public protocol PacerUsageExtra {
    /// The key the column `id` sorts by, or nil if `id` is not one of this
    /// screen's columns.
    func sortKey(forColumn id: String) -> PacerUsageSortKey?
}

/// A screen-specific column's sort key.
public enum PacerUsageSortKey: Sendable, Equatable {
    case number(Double)
    /// Compared case-insensitively, the way the label column is.
    case text(String)
    case date(Date)

    static func compare(_ a: PacerUsageSortKey?, _ b: PacerUsageSortKey?) -> ComparisonResult {
        switch (a, b) {
        case let (.number(x)?, .number(y)?): return PacerUsageOrdering.compare(x, y)
        case let (.date(x)?, .date(y)?):     return PacerUsageOrdering.compare(x, y)
        case let (.text(x)?, .text(y)?):     return x.localizedCaseInsensitiveCompare(y)
        // Missing or mismatched keys sort first, so one odd row cannot
        // scatter the rest.
        case (nil, nil):                     return .orderedSame
        case (nil, _):                       return .orderedAscending
        case (_, nil):                       return .orderedDescending
        default:                             return .orderedSame
        }
    }
}

/// For a table with no columns of its own.
public struct PacerUsageNoExtra: PacerUsageExtra, Sendable, Equatable {
    public init() {}
    public func sortKey(forColumn id: String) -> PacerUsageSortKey? { nil }
}

// MARK: - Sorting

/// A table's sort: a column id and a direction. Plain and `Codable` so a
/// screen can persist it under its own keys; the table never stores it.
public struct PacerUsageSort: Hashable, Sendable, Codable {
    /// A `UsageColumn` raw value, or one of the screen's extra column ids.
    public var column: String
    public var descending: Bool

    public init(column: String, descending: Bool) {
        self.column = column
        self.descending = descending
    }

    public init(_ column: UsageColumn, descending: Bool) {
        self.init(column: column.rawValue, descending: descending)
    }

    /// Every table's default: what cost the most, first.
    public static let costDescending = PacerUsageSort(.cost, descending: true)
}

/// The `SortComparator` a table hands SwiftUI's `Table`. Equal by column and
/// direction only, which is how `Table` matches a sort to its column header.
public struct PacerUsageComparator<Extra: PacerUsageExtra>: SortComparator {
    public var column: String
    public var order: SortOrder

    public init(column: String, order: SortOrder) {
        self.column = column
        self.order = order
    }

    public init(_ sort: PacerUsageSort) {
        self.init(column: sort.column, order: sort.descending ? .reverse : .forward)
    }

    public var sort: PacerUsageSort {
        PacerUsageSort(column: column, descending: order == .reverse)
    }

    public func compare(_ lhs: PacerUsageRow<Extra>, _ rhs: PacerUsageRow<Extra>) -> ComparisonResult {
        // The id tiebreak flips with the direction, as every per-screen sort
        // it replaces did (ascending sort, then `reversed()`), and as
        // `DayRanking` does: the Top days card ranks with one and shows the
        // result in the other, so they must break ties the same way.
        let ascending = PacerUsageOrdering.ascending(lhs, rhs, column: column)
        guard order == .reverse else { return ascending }
        switch ascending {
        case .orderedAscending:  return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame:       return .orderedSame
        }
    }
}

enum PacerUsageOrdering {
    static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// Ascending by `column`, then by id so equal values never reshuffle
    /// between refreshes.
    static func ascending<Extra: PacerUsageExtra>(
        _ lhs: PacerUsageRow<Extra>, _ rhs: PacerUsageRow<Extra>, column: String
    ) -> ComparisonResult {
        let primary: ComparisonResult
        if let standard = UsageColumn(rawValue: column) {
            switch standard {
            case .name:
                primary = lhs.sortLabel.localizedCaseInsensitiveCompare(rhs.sortLabel)
            case .cost:
                primary = compare(lhs.cost, rhs.cost)
            default:
                let l: Int64 = standard.tokenCount(of: lhs.tokens) ?? 0
                let r: Int64 = standard.tokenCount(of: rhs.tokens) ?? 0
                primary = compare(l, r)
            }
        } else {
            primary = PacerUsageSortKey.compare(
                lhs.extra.sortKey(forColumn: column), rhs.extra.sortKey(forColumn: column))
        }
        return primary == .orderedSame ? compare(lhs.id, rhs.id) : primary
    }
}

public extension Array {
    /// `rows` in the order a usage table shows them under `sort`.
    func sortedForUsageTable<Extra: PacerUsageExtra>(
        _ sort: PacerUsageSort
    ) -> [PacerUsageRow<Extra>] where Element == PacerUsageRow<Extra> {
        let comparator = PacerUsageComparator<Extra>(sort)
        return sorted { comparator.compare($0, $1) == .orderedAscending }
    }
}

// MARK: - Layout

/// The table's height, and the storage key of its column layout.
public enum PacerUsageTableMetrics {
    /// Header row of the inset table style.
    static let headerHeight: CGFloat = 28
    /// The inset style's padding above the first row and below the last.
    static let verticalInsets: CGFloat = 15
    /// What a row adds around its cell content.
    static let rowPadding: CGFloat = 8
    /// A little over, never under: a table one point short scrolls and
    /// clips its last row, one a few points tall just has a margin.
    static let slack: CGFloat = 3

    /// The label cell's fixed height, which fixes every row's: one line, or
    /// a label over a subtitle. Fixed so the height below is arithmetic
    /// rather than a guess at what the text will measure.
    static func labelHeight(twoLine: Bool) -> CGFloat { twoLine ? 31 : 16 }

    static func rowHeight(twoLine: Bool) -> CGFloat { labelHeight(twoLine: twoLine) + rowPadding }

    /// Rows a table shows before it scrolls inside: a short list hugs its
    /// rows, a long one (Projects, Top days' 100) stops here.
    public static let defaultMaxVisibleRows = 14

    /// The frame height for `rowCount` rows, hugging up to `maxVisibleRows`.
    public static func height(rowCount: Int, twoLine: Bool,
                              maxVisibleRows: Int = defaultMaxVisibleRows) -> CGFloat {
        let visible = CGFloat(Swift.max(1, Swift.min(rowCount, maxVisibleRows)))
        return headerHeight + verticalInsets + visible * rowHeight(twoLine: twoLine) + slack
    }

    /// Where a table's column layout (visibility, order, widths) is kept.
    public static func columnsKey(tableId: String) -> String {
        "pacer.table.\(tableId).columns"
    }
}

// MARK: - Table

/// The shared usage table.
///
/// - `rows`: in any order; the table sorts them by `sort`.
/// - `tableId`: names the persisted column layout, one per table.
/// - `sort` / `onSort`: the sort is read by value and written through the
///   callback, so the screen that owns and persists it re-renders on a
///   header click (AGENTS.md, "SwiftUI state and data flow").
/// - `onOpen`: a click on a row. Rows that open nothing keep the native
///   selection highlight instead.
/// - `extraColumns`: the screen's own columns, built with
///   `PacerUsageColumns.extra`, after the standard ones.
/// - `labelAccessory`: views after the label (Projects' git badge).
/// - `rowMenu`: the row's context menu.
public struct PacerUsageTable<Extra: PacerUsageExtra, Extras: TableColumnContent,
                              Accessory: View, RowMenu: View>: View
where Extras.TableRowValue == PacerUsageRow<Extra>,
      Extras.TableColumnSortComparator == PacerUsageComparator<Extra> {
    public typealias Row = PacerUsageRow<Extra>
    public typealias Comparator = PacerUsageComparator<Extra>

    let rows: [Row]
    let labelTitle: String
    let sort: PacerUsageSort
    let onSort: (PacerUsageSort) -> Void
    let onOpen: ((Row) -> Void)?
    let maxVisibleRows: Int
    let extraColumns: () -> Extras
    let labelAccessory: (Row) -> Accessory
    let rowMenu: (Row) -> RowMenu

    /// Visibility, order and widths, per table, across launches. SwiftUI
    /// stores `TableColumnCustomization` in `AppStorage` itself.
    @AppStorage private var columns: TableColumnCustomization<Row>
    @State private var selection: Row.ID?

    public init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        store: UserDefaults = PacerPreferences.store,
        @TableColumnBuilder<Row, Comparator> extraColumns: @escaping () -> Extras,
        @ViewBuilder labelAccessory: @escaping (Row) -> Accessory,
        @ViewBuilder rowMenu: @escaping (Row) -> RowMenu
    ) {
        self.rows = rows
        self.labelTitle = labelTitle
        self.sort = sort
        self.onSort = onSort
        self.onOpen = onOpen
        self.maxVisibleRows = maxVisibleRows
        self.extraColumns = extraColumns
        self.labelAccessory = labelAccessory
        self.rowMenu = rowMenu
        _columns = AppStorage(
            wrappedValue: TableColumnCustomization<Row>(),
            PacerUsageTableMetrics.columnsKey(tableId: tableId),
            store: store)
    }

    public var body: some View {
        let sorted: [Row] = rows.sortedForUsageTable(sort)
        let twoLine = rows.contains { $0.subtitle != nil }
        let current = sort
        let onSort = self.onSort
        let sortOrder = Binding<[Comparator]>(
            get: { [Comparator(current)] },
            // `Table` puts the clicked column's comparator first: a new
            // column in the direction its comparator was declared with, the
            // current one flipped.
            set: { new in if let first = new.first { onSort(first.sort) } })
        Table(sorted, selection: $selection, sortOrder: sortOrder, columnCustomization: $columns) {
            labelColumn(twoLine: twoLine)
            Group {
                numberColumn(.input)
                numberColumn(.output)
                numberColumn(.cacheRead)
                numberColumn(.cacheWrite)
                numberColumn(.cacheWrite5m)
                numberColumn(.cacheWrite1h)
                numberColumn(.tokens)
                numberColumn(.cost)
            }
            extraColumns()
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // The card is the background.
        .scrollContentBackground(.hidden)
        // A table that fits its rows has nothing to scroll, and without this
        // it still rubber-bands, taking the wheel from the page around it.
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        .frame(height: PacerUsageTableMetrics.height(
            rowCount: sorted.count, twoLine: twoLine, maxVisibleRows: maxVisibleRows))
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let id = ids.first, let row = sorted.first(where: { $0.id == id }) {
                rowMenu(row)
            }
        }
        .onChange(of: selection) { _, id in
            // A click opens the row and leaves nothing selected, so the
            // same row opens again next time, as the hand-rolled rows did.
            guard let onOpen, let id else { return }
            selection = nil
            if let row = sorted.first(where: { $0.id == id }) { onOpen(row) }
        }
    }

    @TableColumnBuilder<Row, Comparator>
    private func labelColumn(twoLine: Bool) -> some TableColumnContent<Row, Comparator> {
        TableColumn(labelTitle, sortUsing: Comparator(column: UsageColumn.name.rawValue, order: .forward)) { row in
            HStack(spacing: 6) {
                if let color = row.color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.label)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        labelAccessory(row)
                    }
                    if twoLine {
                        Text(row.subtitle ?? "")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(height: PacerUsageTableMetrics.labelHeight(twoLine: twoLine), alignment: .leading)
            .help(row.subtitle ?? row.label)
        }
        .width(min: UsageColumn.name.minWidth, ideal: UsageColumn.name.idealWidth)
        .customizationID(UsageColumn.name.rawValue)
        // Hiding the label would leave rows nobody can tell apart.
        .disabledCustomizationBehavior(.visibility)
    }

    @TableColumnBuilder<Row, Comparator>
    private func numberColumn(_ column: UsageColumn) -> some TableColumnContent<Row, Comparator> {
        let isCost = column == .cost
        TableColumn(
            column.title(label: labelTitle),
            sortUsing: Comparator(column: column.rawValue,
                                  order: column.sortsDescendingFirst ? .reverse : .forward)
        ) { row in
            let cell = column.cellText(tokens: row.tokens, cost: row.cost)
            Text(cell?.text ?? "")
                .font(isCost
                      ? .system(size: 12, weight: .semibold, design: .rounded)
                      : .system(size: 12))
                .foregroundStyle(isCost ? .primary : .secondary)
                .monospacedDigit()
                .help(cell?.help ?? "")
        }
        .width(min: column.minWidth, ideal: column.idealWidth)
        .alignment(.numeric)
        .customizationID(column.rawValue)
        .defaultVisibility(column.isVisibleByDefault ? .automatic : .hidden)
    }
}

/// The `Extras` of a table with no columns of its own: an absent column.
public typealias PacerUsageNoColumns<Extra: PacerUsageExtra> =
    TableColumn<PacerUsageRow<Extra>, PacerUsageComparator<Extra>, EmptyView, Text>?

public extension PacerUsageTable where Accessory == EmptyView {
    /// Extra columns and a row menu, nothing after the label.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        store: UserDefaults = PacerPreferences.store,
        @TableColumnBuilder<Row, Comparator> extraColumns: @escaping () -> Extras,
        @ViewBuilder rowMenu: @escaping (Row) -> RowMenu
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows, store: store,
                  extraColumns: extraColumns, labelAccessory: { _ in EmptyView() }, rowMenu: rowMenu)
    }
}

public extension PacerUsageTable where Accessory == EmptyView, RowMenu == EmptyView {
    /// Extra columns only.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        store: UserDefaults = PacerPreferences.store,
        @TableColumnBuilder<Row, Comparator> extraColumns: @escaping () -> Extras
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows, store: store,
                  extraColumns: extraColumns, labelAccessory: { _ in EmptyView() },
                  rowMenu: { _ in EmptyView() })
    }
}

public extension PacerUsageTable where Extras == PacerUsageNoColumns<Extra>, Accessory == EmptyView {
    /// The standard columns and a row menu.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        store: UserDefaults = PacerPreferences.store,
        @ViewBuilder rowMenu: @escaping (Row) -> RowMenu
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows, store: store,
                  extraColumns: Self.noColumns, labelAccessory: { _ in EmptyView() }, rowMenu: rowMenu)
    }
}

public extension PacerUsageTable
where Extras == PacerUsageNoColumns<Extra>, Accessory == EmptyView, RowMenu == EmptyView {
    /// The standard columns only.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        store: UserDefaults = PacerPreferences.store
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows, store: store,
                  extraColumns: Self.noColumns, labelAccessory: { _ in EmptyView() },
                  rowMenu: { _ in EmptyView() })
    }
}

extension PacerUsageTable where Extras == PacerUsageNoColumns<Extra> {
    /// Passed as a value, not a closure literal, so the column builder does
    /// not try to build `nil` into a column.
    static var noColumns: () -> Extras { { nil } }
}

// MARK: - Building a screen's own columns

public enum PacerUsageColumns {
    /// One of a screen's own columns, set up the way the standard ones are:
    /// sortable by `Extra.sortKey(forColumn: id)`, hideable and reorderable
    /// under `id`, numbers right-aligned.
    @MainActor
    public static func extra<Extra: PacerUsageExtra, Content: View>(
        _ id: String,
        title: String,
        of extra: Extra.Type,
        numeric: Bool = true,
        minWidth: CGFloat = 44,
        idealWidth: CGFloat = 64,
        descendingFirst: Bool = true,
        visibleByDefault: Bool = true,
        @ViewBuilder content: @escaping (PacerUsageRow<Extra>) -> Content
    ) -> some TableColumnContent<PacerUsageRow<Extra>, PacerUsageComparator<Extra>> {
        TableColumn(
            title,
            sortUsing: PacerUsageComparator<Extra>(column: id, order: descendingFirst ? .reverse : .forward),
            content: content)
            .width(min: minWidth, ideal: idealWidth)
            .alignment(numeric ? .numeric : .leading)
            .customizationID(id)
            .defaultVisibility(visibleByDefault ? .automatic : .hidden)
    }
}
