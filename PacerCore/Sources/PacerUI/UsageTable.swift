import AppKit
import SwiftUI
import PacerCore

// One sortable, customizable table for every "by model / by project / by day /
// by session" usage list (#215 follow-up): Models, Today by model, Projects,
// Top days, Day detail's models and projects, and the sessions lists.
//
// It is SwiftUI's own `Table`, not a hand-rolled grid, because what the owner
// asked for is exactly what `TableColumnCustomization` gives a native table:
// right-click a header to show or hide a column, drag a header to reorder,
// drag an edge to resize. Each screen used to draw its own header row of
// `SortableColumnHeader`s over an `HStack` per row, and they had drifted: one
// counted three token parts, another two, and none could show the parts.
//
// Native does not have to mean stock. `PacerTableStyler` reaches the
// `NSTableView` underneath and gives it the header every other list in the app
// has (small, uppercase, tracked, secondary; a chevron on the sorted column;
// no column dividers), and fits the columns to the card so nothing scrolls
// sideways. The right-click menu, reordering, resizing and the saved layout
// are AppKit's and SwiftUI's, untouched.
//
// What a native `Table` costs inside a scrolling page is its height. It is an
// `NSScrollView` and reports no content height of its own (an off-screen host
// measures it as zero), so the table sets its own frame from the row count
// (`PacerUsageTableMetrics`), up to a cap past which it scrolls inside.
// `UsageTableLayoutTests` checks that height against the rows a real
// `NSTableView` lays out, on whichever OS runs it.

// MARK: - Column titles, tooltips and cell text

public extension UsageColumn {
    /// The header title. The label column takes the table's own ("Model",
    /// "Project", "Date").
    func title(label: String) -> String {
        switch self {
        case .name:            return label
        case .input:           return "Input"
        case .output:          return "Output"
        case .cacheRead:       return "Cache read"
        case .cacheWrite:      return "Cache write"
        case .cacheWrite5m:    return "5m write"
        case .cacheWrite1h:    return "1h write"
        case .tokens:          return "Total"
        case .outputShare:     return "Out %"
        case .cacheWriteShare: return "Write %"
        case .cost:            return "Cost"
        case .mix:             return "Mix"
        }
    }

    /// The header's tooltip: what the column counts, in a fragment.
    var headerHelp: String? {
        switch self {
        case .name:            return nil
        case .input:           return "Uncached prompt tokens"
        case .output:          return "Response tokens"
        case .cacheRead:       return "Prompt tokens read from the cache"
        case .cacheWrite:      return "Prompt tokens written to the cache, 5m and 1h"
        case .cacheWrite5m:    return "Tokens written to the 5-minute cache"
        case .cacheWrite1h:    return "Tokens written to the 1-hour cache"
        case .tokens:          return "Every token, all five parts"
        case .outputShare:     return "Output's share of the cost"
        case .cacheWriteShare: return "Cache writes' share of the cache cost"
        case .cost:            return nil
        case .mix:             return "Cost by part"
        }
    }

    /// Column widths. A table starts each column at its ideal width and the
    /// styler fits them to the card (`PacerTableStyler`), taking the same
    /// few points from each, so the ideals are set for the header (10pt
    /// tracked caps) to survive that: the two cache columns' titles are the
    /// longest. The minimums are where a window narrowed later stops
    /// shrinking them.
    var idealWidth: CGFloat {
        switch self {
        case .name:            return 140
        case .input:           return 50
        case .output:          return 56
        case .cacheRead:       return 78
        case .cacheWrite:      return 84
        case .cacheWrite5m:    return 62
        case .cacheWrite1h:    return 60
        case .tokens:          return 52
        case .outputShare:     return 50
        case .cacheWriteShare: return 56
        case .cost:            return 60
        case .mix:             return 64
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 110
        case .mix:  return 48
        default:    return 40
        }
    }

    /// What a cell prints (compact, so seven numbers fit a card) and what
    /// its tooltip spells out (exact). Nil for the label and the Mix bar,
    /// which draw themselves.
    func cellText(tokens: TokenBreakdown, cost: Double, costParts: CostComponents) -> PacerUsageCellText? {
        switch self {
        case .name, .mix:
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
        case .outputShare:
            let help = "Output \(pacerCostExact(max(0, costParts.output))) of \(pacerCostExact(costParts.total))"
            return PacerUsageCellText(share: costParts.outputShare, help: help, none: "No cost")
        case .cacheWriteShare:
            let writes = max(0, costParts.cacheWrite5m) + max(0, costParts.cacheWrite1h)
            let cache = writes + max(0, costParts.cacheRead)
            let help = "Cache writes \(pacerCostExact(writes)) of \(pacerCostExact(cache)) cache cost"
            return PacerUsageCellText(share: costParts.cacheWriteShare, help: help, none: "No cache cost")
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

    /// A share as a whole percent: "38%", "<1%" for a share too small to
    /// round to 1 but not nothing, "–" when there is nothing to divide.
    init(share: Double?, help: String, none: String) {
        guard let share else {
            self.init(text: "–", help: none)
            return
        }
        let percent = Int((share * 100).rounded())
        let text = percent == 0 && share > 0 ? "<1%" : "\(percent)%"
        self.init(text: text, help: help)
    }
}

// MARK: - Rows

/// One row of a usage table. A plain value: each screen folds its own
/// rollup into these, so the table never knows whether a row is a model, a
/// project, a day or a session.
///
/// `Extra` carries whatever the screen's own columns show (a model's active
/// days, a project's sessions) — see `PacerUsageExtra`.
public struct PacerUsageRow<Extra>: Identifiable, UsageColumnValues {
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
    /// The cost by priced part, from the rollup's per-part columns (#296):
    /// what the ratio columns divide and the Mix bar draws.
    public let costParts: CostComponents
    /// The total the Cost column prints and sorts by.
    public let cost: Double
    public let extra: Extra

    /// - Parameter cost: the row's total as the rest of the page prints it.
    ///   Defaults to the parts' sum, which is what every rollup stores as its
    ///   total (`RollupCostColumns`); pass it when the page sums totals
    ///   rather than parts (Top days ranks by the summed totals, and the
    ///   table must order ties the way that ranking did).
    public init(
        id: String,
        label: String,
        subtitle: String? = nil,
        sortLabel: String? = nil,
        color: Color? = nil,
        tokens: TokenBreakdown,
        costParts: CostComponents,
        cost: Double? = nil,
        extra: Extra
    ) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.sortLabel = sortLabel ?? label
        self.color = color
        self.tokens = tokens
        self.costParts = costParts
        self.cost = cost ?? costParts.total
        self.extra = extra
    }

    /// The parts with their tokens, as the shared cost views take them.
    public var breakdown: CostBreakdown { CostBreakdown(cost: costParts, tokens: tokens) }
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
        costParts: CostComponents,
        cost: Double? = nil
    ) {
        self.init(id: id, label: label, subtitle: subtitle, sortLabel: sortLabel,
                  color: color, tokens: tokens, costParts: costParts, cost: cost,
                  extra: PacerUsageNoExtra())
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
    /// between refreshes. A standard column compares through
    /// `UsageColumn.compare`, the one `DayRanking` uses too.
    static func ascending<Extra: PacerUsageExtra>(
        _ lhs: PacerUsageRow<Extra>, _ rhs: PacerUsageRow<Extra>, column: String
    ) -> ComparisonResult {
        let primary: ComparisonResult
        if let standard = UsageColumn(rawValue: column) {
            primary = standard == .name
                ? lhs.sortLabel.localizedCaseInsensitiveCompare(rhs.sortLabel)
                : standard.compare(lhs, rhs)
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
    /// How far the table reaches past its container on each side, so its
    /// first column starts where the hand-rolled lists' did.
    static let outdent: CGFloat = 8
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
/// - `onOpen`: a click on a row, or Return on the row the arrow keys
///   reached. Rows that open nothing keep the native selection instead.
/// - `defaultColumns`: the standard columns shown until the user changes
///   them — `UsageColumn.wideDefaults` or `.narrowDefaults`, plus whatever a
///   screen adds. The rest are one right-click away.
/// - `leadingColumns`: screen columns that belong beside the label (a
///   sessions list's Project), built with `PacerUsageColumns.extra`.
/// - `extraColumns`: the screen's own columns, built with
///   `PacerUsageColumns.extra`, after Cost and before Mix.
/// - `labelAccessory`: views after the label (Projects' git badge).
/// - `rowMenu`: the row's context menu.
public struct PacerUsageTable<Extra: PacerUsageExtra, Leading: TableColumnContent,
                              Extras: TableColumnContent, Accessory: View, RowMenu: View>: View
where Leading.TableRowValue == PacerUsageRow<Extra>,
      Leading.TableColumnSortComparator == PacerUsageComparator<Extra>,
      Extras.TableRowValue == PacerUsageRow<Extra>,
      Extras.TableColumnSortComparator == PacerUsageComparator<Extra> {
    public typealias Row = PacerUsageRow<Extra>
    public typealias Comparator = PacerUsageComparator<Extra>

    let rows: [Row]
    let labelTitle: String
    let sort: PacerUsageSort
    let onSort: (PacerUsageSort) -> Void
    let onOpen: ((Row) -> Void)?
    let maxVisibleRows: Int
    let defaultColumns: Set<UsageColumn>
    let leadingColumns: () -> Leading
    let extraColumns: () -> Extras
    let labelAccessory: (Row) -> Accessory
    let rowMenu: (Row) -> RowMenu

    /// Visibility, order and widths, per table, across launches. SwiftUI
    /// stores `TableColumnCustomization` in `AppStorage` itself.
    @AppStorage private var columns: TableColumnCustomization<Row>
    @State private var selection: Row.ID?
    /// The height of a legacy horizontal scroll bar while one is showing
    /// (the columns cannot shrink into a narrow window), added to the frame
    /// so the bar does not take it from the rows. Set by the styler.
    @State private var scrollerAllowance: CGFloat = 0

    public init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        defaultColumns: Set<UsageColumn> = UsageColumn.wideDefaults,
        store: UserDefaults = PacerPreferences.store,
        @TableColumnBuilder<Row, Comparator> leadingColumns: @escaping () -> Leading,
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
        self.defaultColumns = defaultColumns
        self.leadingColumns = leadingColumns
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
            leadingColumns()
            Group {
                numberColumn(.input)
                numberColumn(.output)
                numberColumn(.cacheRead)
                numberColumn(.cacheWrite)
                numberColumn(.cacheWrite5m)
                numberColumn(.cacheWrite1h)
            }
            Group {
                numberColumn(.tokens)
                numberColumn(.outputShare)
                numberColumn(.cacheWriteShare)
                numberColumn(.cost)
            }
            extraColumns()
            mixColumn
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // The card is the background.
        .scrollContentBackground(.hidden)
        // A table that fits its rows has nothing to scroll, and without this
        // it still rubber-bands, taking the wheel from the page around it.
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        .background(PacerTableStyler(style: headerStyle,
                                     onScrollerAllowance: { scrollerAllowance = $0 }))
        .frame(height: PacerUsageTableMetrics.height(
            rowCount: sorted.count, twoLine: twoLine, maxVisibleRows: maxVisibleRows)
            + scrollerAllowance)
        // The inset style starts a row 16pt in; the lists it replaced started
        // 8pt in from the card's padding, under the card's title.
        .padding(.horizontal, -PacerUsageTableMetrics.outdent)
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let id = ids.first, let row = sorted.first(where: { $0.id == id }) {
                rowMenu(row)
            }
        } primaryAction: { ids in
            // Return on the row the arrow keys reached. A double-click lands
            // here too, but its first click already opened the row.
            guard let onOpen, PacerTableEvents.lastWasKey,
                  let id = ids.first, let row = sorted.first(where: { $0.id == id }) else { return }
            selection = nil
            onOpen(row)
        }
        .onChange(of: selection) { _, id in
            guard let onOpen, let id else { return }
            // An arrow key moved the selection: leave it there, so the keys
            // walk the rows without opening each one, and Return opens.
            if PacerTableEvents.lastWasKey { return }
            // A click opens the row and leaves nothing selected, so the
            // same row opens again next time, as the hand-rolled rows did.
            selection = nil
            if let row = sorted.first(where: { $0.id == id }) { onOpen(row) }
        }
    }

    /// What the header draws: which title is sorted, and every column's
    /// tooltip, by title (an `NSTableColumn` knows its title, not the id
    /// SwiftUI customizes it under).
    private var headerStyle: PacerTableHeaderStyle {
        var help: [String: String] = [:]
        for column in UsageColumn.allCases {
            if let text = column.headerHelp { help[column.title(label: labelTitle)] = text }
        }
        let extras = PacerUsageColumns.registered(for: Extra.self)
        for (_, column) in extras {
            if let text = column.help { help[column.title] = text }
        }
        let sortedTitle = UsageColumn(rawValue: sort.column)?.title(label: labelTitle)
            ?? extras[sort.column]?.title
        return PacerTableHeaderStyle(sortedTitle: sortedTitle, descending: sort.descending, help: help)
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
            let cell = column.cellText(tokens: row.tokens, cost: row.cost, costParts: row.costParts)
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
        .defaultVisibility(defaultColumns.contains(column) ? .automatic : .hidden)
    }

    /// The five cost parts as one slim 100% bar, in the palette's part
    /// colours (`PacerCostBar`). Sorts by the uncached share, which is where
    /// the bar's cache part starts.
    @TableColumnBuilder<Row, Comparator>
    private var mixColumn: some TableColumnContent<Row, Comparator> {
        TableColumn(
            UsageColumn.mix.title(label: labelTitle),
            sortUsing: Comparator(column: UsageColumn.mix.rawValue, order: .reverse)
        ) { row in
            PacerCostBar(row.breakdown, height: 6)
        }
        .width(min: UsageColumn.mix.minWidth, ideal: UsageColumn.mix.idealWidth)
        .customizationID(UsageColumn.mix.rawValue)
        .defaultVisibility(defaultColumns.contains(.mix) ? .automatic : .hidden)
    }
}

/// The `Leading` or `Extras` of a table with no such columns: an absent
/// column.
public typealias PacerUsageNoColumns<Extra: PacerUsageExtra> =
    TableColumn<PacerUsageRow<Extra>, PacerUsageComparator<Extra>, EmptyView, Text>?

/// Passed as a value, not a closure literal, so the column builder does not
/// try to build `nil` into a column.
func pacerUsageNoColumns<Extra: PacerUsageExtra>() -> PacerUsageNoColumns<Extra> { nil }

public extension PacerUsageTable where Leading == PacerUsageNoColumns<Extra> {
    /// Extra columns, things after the label, and a row menu.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        defaultColumns: Set<UsageColumn> = UsageColumn.wideDefaults,
        store: UserDefaults = PacerPreferences.store,
        @TableColumnBuilder<Row, Comparator> extraColumns: @escaping () -> Extras,
        @ViewBuilder labelAccessory: @escaping (Row) -> Accessory,
        @ViewBuilder rowMenu: @escaping (Row) -> RowMenu
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows,
                  defaultColumns: defaultColumns, store: store,
                  leadingColumns: pacerUsageNoColumns, extraColumns: extraColumns,
                  labelAccessory: labelAccessory, rowMenu: rowMenu)
    }
}

public extension PacerUsageTable where Leading == PacerUsageNoColumns<Extra>, Accessory == EmptyView {
    /// Extra columns and a row menu, nothing after the label.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        defaultColumns: Set<UsageColumn> = UsageColumn.wideDefaults,
        store: UserDefaults = PacerPreferences.store,
        @TableColumnBuilder<Row, Comparator> extraColumns: @escaping () -> Extras,
        @ViewBuilder rowMenu: @escaping (Row) -> RowMenu
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows,
                  defaultColumns: defaultColumns, store: store,
                  leadingColumns: pacerUsageNoColumns, extraColumns: extraColumns,
                  labelAccessory: { _ in EmptyView() }, rowMenu: rowMenu)
    }
}

public extension PacerUsageTable where Accessory == EmptyView, RowMenu == EmptyView {
    /// Columns beside the label and after Cost, nothing else.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        defaultColumns: Set<UsageColumn> = UsageColumn.wideDefaults,
        store: UserDefaults = PacerPreferences.store,
        @TableColumnBuilder<Row, Comparator> leadingColumns: @escaping () -> Leading,
        @TableColumnBuilder<Row, Comparator> extraColumns: @escaping () -> Extras
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows,
                  defaultColumns: defaultColumns, store: store,
                  leadingColumns: leadingColumns, extraColumns: extraColumns,
                  labelAccessory: { _ in EmptyView() }, rowMenu: { _ in EmptyView() })
    }
}

public extension PacerUsageTable
where Leading == PacerUsageNoColumns<Extra>, Accessory == EmptyView, RowMenu == EmptyView {
    /// Extra columns only.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        defaultColumns: Set<UsageColumn> = UsageColumn.wideDefaults,
        store: UserDefaults = PacerPreferences.store,
        @TableColumnBuilder<Row, Comparator> extraColumns: @escaping () -> Extras
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows,
                  defaultColumns: defaultColumns, store: store,
                  leadingColumns: pacerUsageNoColumns, extraColumns: extraColumns,
                  labelAccessory: { _ in EmptyView() }, rowMenu: { _ in EmptyView() })
    }
}

public extension PacerUsageTable
where Leading == PacerUsageNoColumns<Extra>, Extras == PacerUsageNoColumns<Extra>,
      Accessory == EmptyView {
    /// The standard columns and a row menu.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        defaultColumns: Set<UsageColumn> = UsageColumn.wideDefaults,
        store: UserDefaults = PacerPreferences.store,
        @ViewBuilder rowMenu: @escaping (Row) -> RowMenu
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows,
                  defaultColumns: defaultColumns, store: store,
                  leadingColumns: pacerUsageNoColumns, extraColumns: pacerUsageNoColumns,
                  labelAccessory: { _ in EmptyView() }, rowMenu: rowMenu)
    }
}

public extension PacerUsageTable
where Leading == PacerUsageNoColumns<Extra>, Extras == PacerUsageNoColumns<Extra>,
      Accessory == EmptyView, RowMenu == EmptyView {
    /// The standard columns only.
    init(
        rows: [Row],
        tableId: String,
        labelTitle: String,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((Row) -> Void)? = nil,
        maxVisibleRows: Int = PacerUsageTableMetrics.defaultMaxVisibleRows,
        defaultColumns: Set<UsageColumn> = UsageColumn.wideDefaults,
        store: UserDefaults = PacerPreferences.store
    ) {
        self.init(rows: rows, tableId: tableId, labelTitle: labelTitle, sort: sort,
                  onSort: onSort, onOpen: onOpen, maxVisibleRows: maxVisibleRows,
                  defaultColumns: defaultColumns, store: store,
                  leadingColumns: pacerUsageNoColumns, extraColumns: pacerUsageNoColumns,
                  labelAccessory: { _ in EmptyView() }, rowMenu: { _ in EmptyView() })
    }
}

// MARK: - Building a screen's own columns

public enum PacerUsageColumns {
    /// One of a screen's own columns, set up the way the standard ones are:
    /// sortable by `Extra.sortKey(forColumn: id)`, hideable and reorderable
    /// under `id`, numbers right-aligned.
    ///
    /// - `help`: the header's tooltip.
    @MainActor
    public static func extra<Extra: PacerUsageExtra, Content: View>(
        _ id: String,
        title: String,
        of extra: Extra.Type,
        help: String? = nil,
        numeric: Bool = true,
        minWidth: CGFloat = 40,
        idealWidth: CGFloat = 64,
        descendingFirst: Bool = true,
        visibleByDefault: Bool = true,
        @ViewBuilder content: @escaping (PacerUsageRow<Extra>) -> Content
    ) -> some TableColumnContent<PacerUsageRow<Extra>, PacerUsageComparator<Extra>> {
        register(Registered(title: title, help: help), id: id, for: Extra.self)
        return TableColumn(
            title,
            sortUsing: PacerUsageComparator<Extra>(column: id, order: descendingFirst ? .reverse : .forward),
            content: content)
            .width(min: minWidth, ideal: idealWidth)
            .alignment(numeric ? .numeric : .leading)
            .customizationID(id)
            .defaultVisibility(visibleByDefault ? .automatic : .hidden)
    }

    /// A screen column's header text, kept so the table's header can find
    /// the sorted column and its tooltip by title: `NSTableColumn` knows its
    /// title, not the id SwiftUI customizes it under. Keyed by the `Extra`
    /// type, which is one per screen, so two screens' "share" columns do not
    /// collide.
    struct Registered: Equatable {
        let title: String
        let help: String?
    }

    @MainActor private static var registry: [String: [String: Registered]] = [:]

    @MainActor
    private static func register<Extra>(_ column: Registered, id: String, for _: Extra.Type) {
        let key = String(reflecting: Extra.self)
        if registry[key]?[id] != column { registry[key, default: [:]][id] = column }
    }

    @MainActor
    static func registered<Extra>(for _: Extra.Type) -> [String: Registered] {
        registry[String(reflecting: Extra.self)] ?? [:]
    }
}

// MARK: - Keyboard

/// Whether the event being handled came from the keyboard: how the table
/// tells an arrow key's selection change (walk, do not open) from a click's
/// (open). `currentEvent` is the last event the app took off the queue, and
/// SwiftUI delivers the change before taking the next.
@MainActor
enum PacerTableEvents {
    static var lastWasKey: Bool {
        NSApp?.currentEvent?.type == .keyDown
    }
}

// MARK: - The app's look on the native table

/// What the header shows: the sorted column (by title) and its direction,
/// and each column's tooltip.
struct PacerTableHeaderStyle: Equatable {
    var sortedTitle: String?
    var descending: Bool
    var help: [String: String]
}

/// Gives the `NSTableView` under a SwiftUI `Table` the look of every other
/// list in the app, without taking any of its behaviour away.
///
/// SwiftUI has no API for a table's header or grid, so this reaches the
/// AppKit table the way a probe does: an empty view placed behind the
/// `Table`, which finds the table whose frame it shares. It then
///
/// - swaps each column's header cell for `PacerTableHeaderCell`, which draws
///   the title the way `Eyebrow` does (10pt semibold caps, tracked,
///   secondary; primary with a chevron when sorted) and no column dividers;
/// - sets each column's header tooltip;
/// - turns off alternating rows and the vertical grid;
/// - fits the columns to the card when their ideal widths add up to more,
///   so a column is never cut off at the edge (the "2026-1" in round 1), and
///   with legacy scroll bars a horizontal one never appears under the rows
///   and steals the height the table set for them (the square in the
///   corner was where the two scroll bars met).
///
/// The header's right-click menu, column drag, resize, sort clicks and the
/// saved layout all stay AppKit's and SwiftUI's: the header view, the
/// columns and their sort prototypes are untouched.
struct PacerTableStyler: NSViewRepresentable {
    let style: PacerTableHeaderStyle
    /// Told the height of a legacy horizontal scroll bar while one shows
    /// (zero otherwise), so the table can grow by it.
    let onScrollerAllowance: (CGFloat) -> Void

    func makeNSView(context: Context) -> PacerTableStylerView {
        PacerTableStylerView()
    }

    func updateNSView(_ view: PacerTableStylerView, context: Context) {
        view.style = style
        view.onScrollerAllowance = onScrollerAllowance
        view.scheduleApply()
    }
}

final class PacerTableStylerView: NSView {
    var style = PacerTableHeaderStyle(sortedTitle: nil, descending: true, help: [:])
    var onScrollerAllowance: ((CGFloat) -> Void)?
    private weak var table: NSTableView?
    private var applyPending = false
    private var reportedAllowance: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        table = nil
        scheduleApply()
    }

    // Never in the way of a click: the table it styles sits on top of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Once per run-loop turn, after SwiftUI has finished updating the table
    /// it sits behind, so anything SwiftUI resets is set again.
    ///
    /// On the run loop rather than the main queue: a turn of the run loop
    /// comes after SwiftUI's update either way, and a nested one (a modal
    /// session, live resize, a test that spins the loop from a main-queue
    /// block) still services it, where a serial queue already inside a block
    /// would not.
    func scheduleApply() {
        guard !applyPending else { return }
        applyPending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyPending = false
                self.apply()
            }
        }
    }

    func apply() {
        guard let table = locateTable() else { return }
        PacerTableAppearance.apply(style, to: table)
        let allowance = PacerTableAppearance.scrollerAllowance(table)
        if allowance != reportedAllowance {
            reportedAllowance = allowance
            onScrollerAllowance?(allowance)
        }
    }

    /// The table this probe sits behind: the one whose scroll view covers
    /// the probe's own frame. Several tables can share a page (Day detail
    /// has three), so it is matched by frame, and searched for near the
    /// probe rather than across the window.
    private func locateTable() -> NSTableView? {
        guard window != nil else { return nil }
        let mine = convert(bounds, to: nil)
        if let table, table.window === window, let scroll = table.enclosingScrollView,
           Self.overlap(scroll.convert(scroll.bounds, to: nil), mine) > 0.9 {
            return table
        }
        var ancestor = superview
        for _ in 0..<4 {
            guard let root = ancestor else { break }
            var best: (table: NSTableView, overlap: CGFloat)?
            Self.tables(in: root, depth: 6) { candidate in
                guard let scroll = candidate.enclosingScrollView else { return }
                let o = Self.overlap(scroll.convert(scroll.bounds, to: nil), mine)
                if o > (best?.overlap ?? 0.9) { best = (candidate, o) }
            }
            if let best {
                table = best.table
                return best.table
            }
            ancestor = root.superview
        }
        return nil
    }

    private static func tables(in view: NSView, depth: Int, _ found: (NSTableView) -> Void) {
        if let table = view as? NSTableView {
            found(table)
            return
        }
        guard depth > 0 else { return }
        for sub in view.subviews { tables(in: sub, depth: depth - 1, found) }
    }

    /// The shared area over the larger of the two, so a match means the
    /// same rectangle, not one inside the other.
    private static func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull, a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return 0 }
        let area = shared.width * shared.height
        return area / max(a.width * a.height, b.width * b.height)
    }
}

enum PacerTableAppearance {
    // The gap between columns is left at the inset style's 17pt: SwiftUI's
    // row view spaces its cells by that figure whatever the table's
    // `intercellSpacing` says, so narrowing it moved the header titles off
    // their columns.

    @MainActor
    static func apply(_ style: PacerTableHeaderStyle, to table: NSTableView) {
        if table.usesAlternatingRowBackgroundColors { table.usesAlternatingRowBackgroundColors = false }
        if !table.gridStyleMask.isEmpty { table.gridStyleMask = [] }
        var headerChanged = false
        for column in table.tableColumns {
            if !(column.headerCell is PacerTableHeaderCell) {
                let cell = PacerTableHeaderCell(textCell: column.title)
                cell.alignment = column.headerCell.alignment
                cell.lineBreakMode = .byTruncatingTail
                column.headerCell = cell
                headerChanged = true
            }
            let help = style.help[column.title]
            if column.headerToolTip != help { column.headerToolTip = help }
        }
        let sort = PacerTableSortMark(title: style.sortedTitle, descending: style.descending)
        if table.pacerSortMark != sort {
            table.pacerSortMark = sort
            headerChanged = true
        }
        if headerChanged { table.headerView?.needsDisplay = true }
        fitColumns(table)
    }

    /// The height a horizontal scroll bar takes from the rows: a legacy bar
    /// ("Show scroll bars: Always", or a mouse attached) sits under the rows
    /// once the columns are wider than the table even at their minimums.
    /// Overlay bars float over the content and take nothing.
    @MainActor
    static func scrollerAllowance(_ table: NSTableView) -> CGFloat {
        guard let scroll = table.enclosingScrollView, scroll.scrollerStyle == .legacy,
              let scroller = scroll.horizontalScroller, !scroller.isHidden else { return 0 }
        return scroller.frame.height
    }

    /// Shrinks the columns into the visible width when they add up to more,
    /// the way the table's own uniform resizing does when its window narrows.
    /// Only ever shrinks: a table that already fits keeps the widths the
    /// user gave it.
    @MainActor
    static func fitColumns(_ table: NSTableView) {
        guard let clip = table.enclosingScrollView?.contentView else { return }
        let available = clip.bounds.width
        guard available > 0, table.frame.width > available + 0.5 else { return }
        table.sizeToFit()
    }
}

/// The sort the header marks: a column title and a direction.
struct PacerTableSortMark: Equatable {
    var title: String?
    var descending: Bool
}

private nonisolated(unsafe) var pacerSortMarkKey: UInt8 = 0

/// Kept on the table rather than on the header cells: AppKit copies a header
/// cell to draw a column being dragged, with a shallow copy that does not
/// retain a Swift subclass's stored properties, so the cell holds none.
private final class PacerTableSortMarkBox: NSObject {
    let mark: PacerTableSortMark
    init(_ mark: PacerTableSortMark) { self.mark = mark }
}

extension NSTableView {
    var pacerSortMark: PacerTableSortMark? {
        get { (objc_getAssociatedObject(self, &pacerSortMarkKey) as? PacerTableSortMarkBox)?.mark }
        set {
            objc_setAssociatedObject(self, &pacerSortMarkKey, newValue.map(PacerTableSortMarkBox.init),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

/// A column header drawn the way the rest of the app labels columns: the
/// title in tracked 10pt semibold capitals, secondary; the sorted column in
/// the primary colour with a chevron for its direction, as
/// `SortableColumnHeader` drew it. No bezel and no divider: the columns are
/// separated by their alignment, as they were in the hand-rolled lists.
///
/// Holds no stored properties (see `PacerTableSortMarkBox`).
final class PacerTableHeaderCell: NSTableHeaderCell {
    static var font: NSFont { .systemFont(ofSize: 10, weight: .semibold) }
    static let tracking: CGFloat = 0.6
    static let chevronGap: CGFloat = 4

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let header = controlView as? NSTableHeaderView
        let table = header?.tableView
        let mark = table?.pacerSortMark
        let sorted = mark?.title != nil && mark?.title == stringValue
        var textRect = Self.contentRect(cellFrame, header: header)
        guard sorted, let chevron = Self.chevron(descending: mark?.descending ?? true) else {
            let title = Self.title(stringValue, sorted: false, alignment: alignment, width: textRect.width)
            Self.drawTitle(title, in: textRect)
            return
        }
        // Title then chevron, as `SortableColumnHeader` laid them out: at
        // the right edge for a number column, after the title otherwise.
        let size = chevron.size
        textRect.size.width = max(0, textRect.width - size.width - Self.chevronGap)
        let title = Self.title(stringValue, sorted: true, alignment: alignment, width: textRect.width)
        let chevronX: CGFloat
        if alignment == .right {
            chevronX = textRect.maxX + Self.chevronGap
        } else {
            let textWidth = min(textRect.width, ceil(title.size().width))
            chevronX = textRect.minX + textWidth + Self.chevronGap
        }
        Self.drawTitle(title, in: textRect)
        let chevronRect = NSRect(x: chevronX, y: cellFrame.midY - size.height / 2,
                                 width: size.width, height: size.height)
        chevron.draw(in: chevronRect, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
    }

    /// Where the column's cells put their content, so a title lines up with
    /// the numbers under it. SwiftUI's row view spaces its cells by its own
    /// figures, a few points off the column rectangle AppKit hands the header
    /// (6pt into the first column, 8pt into the rest), so the cells are
    /// asked where they are; with no row on screen, the column's width
    /// centred in its rectangle is within a point or two.
    private static func contentRect(_ cellFrame: NSRect, header: NSTableHeaderView?) -> NSRect {
        guard let header, let table = header.tableView else { return cellFrame }
        let index = header.column(at: NSPoint(x: cellFrame.midX, y: cellFrame.midY))
        guard index >= 0, index < table.numberOfColumns else { return cellFrame }
        let width = table.tableColumns[index].width
        var rect = NSRect(x: cellFrame.minX + (cellFrame.width - width) / 2, y: cellFrame.minY,
                          width: width, height: cellFrame.height)
        let firstRow = table.rows(in: table.visibleRect).location
        if firstRow != NSNotFound, firstRow < table.numberOfRows,
           let cell = table.view(atColumn: index, row: firstRow, makeIfNecessary: false),
           let rowView = cell.superview {
            let frame = rowView.convert(cell.frame, to: table)
            rect.origin.x = frame.minX
            rect.size.width = frame.width
        }
        return rect
    }

    /// AppKit's header bezel: the divider at each column's edge, which is
    /// most of what made the header read as a stock control on a card. Drawn
    /// as nothing. SwiftUI's own header cell overrides this same method to
    /// draw its version of it; the hairline under the whole header is the
    /// header view's, and stays.
    ///
    /// The interior is the only drawing method overridden besides this one:
    /// a cell that overrides `draw(withFrame:in:)` puts the header view on
    /// an older drawing path that fills a band behind the titles.
    @objc(_drawBezelWithFrame:highlighted:inView:)
    func pacerDrawBezel(withFrame frame: NSRect, highlighted: Bool, in view: NSView) {}

    // The chevron is drawn above, beside the title.
    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView,
                                    ascending: Bool, priority: Int) {}

    /// The title, tracked like `Eyebrow`; untracked and then tightened
    /// before it is cut short, when its column is too narrow for it.
    private static func title(_ text: String, sorted: Bool, alignment: NSTextAlignment,
                              width: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.allowsDefaultTighteningForTruncation = true
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: tracking,
            .foregroundColor: sorted ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let caps = text.uppercased()
        let tracked = NSAttributedString(string: caps, attributes: attributes)
        if ceil(tracked.size().width) <= width { return tracked }
        attributes[.kern] = 0
        return NSAttributedString(string: caps, attributes: attributes)
    }

    private static func drawTitle(_ title: NSAttributedString, in rect: NSRect) {
        let height = ceil(font.ascender - font.descender)
        let line = NSRect(x: rect.minX, y: rect.midY - height / 2, width: max(0, rect.width), height: height)
        title.draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func chevron(descending: Bool) -> NSImage? {
        let name = descending ? "chevron.down" : "chevron.up"
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
