import AppKit
import SwiftUI
import PacerCore

// One sortable, customizable table for every full "by model / by project / by
// day / by session" usage list (#215 follow-up): Models, Projects, Top days,
// Day detail's models and projects, and the sessions lists. A donut card's
// short list beside its ring is not one of these (`PacerDonutListCard`).
//
// It is SwiftUI's own `Table`, not a hand-rolled grid, because what the owner
// asked for is exactly what `TableColumnCustomization` gives a native table:
// right-click a header to show or hide a column, drag a header to reorder,
// drag an edge to resize. Each screen used to draw its own header row of
// `SortableColumnHeader`s over an `HStack` per row, and they had drifted: one
// counted three token parts, another two, and none could show the parts.
//
// It is styled only through SwiftUI's own API: the inset style with no
// alternating rows and the card showing through. The table is its own card
// (`PacerTableCard`): its surface is the card's, with the title above the
// header, rather than a bordered table nested in another card's padding,
// which read as a card in a card. The header is the system's, dividers
// included: they are how a Mac table says its columns resize. The right-click
// column menu, reordering, resizing and the saved layout are all SwiftUI's.
//
// It opens on at most seven columns (`UsageColumn.wideDefaults`, plus at most
// one of the screen's own): the owner found every token part at once too many
// to read. Everything else is in the header's menu, which also resets the
// layout (`PacerTableHeaderMenu`).
//
// It never scrolls sideways. Columns start at widths their content needs
// (`UsageColumn.idealWidth`), and each screen's defaults fit its card at the
// window's default size (`UsageTableLayoutTests` measures that). AppKit's
// uniform autoresizing spreads spare width between the columns and takes it
// back as the window narrows, down to minimums small enough that a cell
// truncates ("88.…") before the table would overflow. What autoresizing does
// not cover is a saved layout: SwiftUI restores saved widths as they were,
// so a layout saved in a wider window started too wide in a narrower one.
// `PacerTableFit` refits those to the width the table has (below).
//
// What a native `Table` costs inside a scrolling page is its height. It is an
// `NSScrollView` and reports no content height of its own (an off-screen host
// measures it as zero), so the table sets its own frame from the row count
// (`PacerUsageTableMetrics`), up to a cap past which it scrolls inside.
// `UsageTableLayoutTests` checks that height against the rows a real
// `NSTableView` lays out, on whichever OS runs it.

// MARK: - Column titles, widths and cell text

public extension UsageColumn {
    /// The header title. The label column takes the table's own ("Model",
    /// "Project", "Date").
    func title(label: String) -> String {
        switch self {
        case .name:         return label
        // Input that missed the cache: "Input" alone read as every prompt
        // token, of which this is a sliver.
        case .input:        return "Uncached"
        case .output:       return "Output"
        case .cacheRead:    return "Cache read"
        case .cacheWrite:   return "Cache write"
        case .cacheWrite5m: return "5m write"
        case .cacheWrite1h: return "1h write"
        // Every token, named the same in a table, a donut list and a
        // donut's centre. "Total" read as total cost once the table opened
        // without the parts beside it (round 5).
        case .tokens:       return "Tokens"
        case .cacheHitRate: return "Hit %"
        case .outputShare:  return "Out %"
        case .cost:         return "Cost"
        case .mix:          return "Mix"
        }
    }

    /// The header's tooltip, for a title that does not say it all. Set on
    /// the `NSTableColumn` (`PacerTableHeaderHelp`): SwiftUI's `TableColumn`
    /// takes a title, and nothing for its header's tooltip.
    var headerHelp: String? {
        switch self {
        case .tokens:       return "Every token: cached, uncached and output"
        case .cacheWrite:   return "5m and 1h cache writes"
        case .cacheHitRate: return "Share of the prompt tokens read from the cache"
        case .outputShare:  return "Output's share of the cost"
        case .mix:          return "The cost by part"
        default:            return nil
        }
    }

    /// The width a column starts at: what its values need (a compact count
    /// is at most five characters, "86.0M"; a cost six, "$12.3k" in
    /// semibold; a hit rate "96.8%") and what its title needs where that is
    /// more. AppKit's uniform autoresizing then gives every column the same
    /// share of the card's spare width, so these are the least each column
    /// starts at: their sum is what decides whether a screen's defaults fit
    /// its card. `UsageTableLayoutTests` measures the titles and the fit
    /// against the real header on whichever OS runs it.
    var idealWidth: CGFloat {
        switch self {
        case .name:         return 110
        case .input:        return 60
        case .output:       return 50
        case .cacheRead:    return 68
        case .cacheWrite:   return 70
        case .cacheWrite5m: return 56
        case .cacheWrite1h: return 54
        case .tokens:       return 46
        case .cacheHitRate: return 46
        case .outputShare:  return 44
        case .cost:         return 52
        case .mix:          return 40
        }
    }

    /// How narrow autoresizing (or the user) may take a column: small, so a
    /// window narrowed past a screen's defaults truncates its cells rather
    /// than scrolling the table sideways.
    var minWidth: CGFloat {
        switch self {
        case .name: return 64
        default:    return 28
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
        case .cacheHitRate:
            // At the precision every other surface prints a hit rate
            // (`pacerCacheHitText`): it sits near 98% on most rows, and a
            // whole percent would print the same number on all of them.
            guard let ratio = tokens.cacheHitRatio else {
                return PacerUsageCellText(text: "–", help: "No prompt tokens")
            }
            let help = "Cache reads \(pacerTokensExact(tokens.cacheReadTokens)) of \(pacerTokensExact(tokens.promptTokens)) prompt tokens"
            return PacerUsageCellText(text: pacerCacheHitText(ratio), help: help)
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

/// "Last active" for a row known only to the day it was last active (a
/// model, from the daily rollup): that day relative to today, as a row known
/// to the minute prints relative to now ("today", "yesterday", "3d ago",
/// "2w ago"), and the date in its tooltip. `day` is a rollup date key,
/// "2026-10-21"; a key that is not one prints as it is.
///
/// Models printed the key itself under "Last seen" while Projects printed
/// "2h ago" under "Last active": two names and two formats for one fact.
public func pacerLastActiveDay(_ day: String, now: Date = PacerClock.now) -> PacerUsageCellText {
    guard let date = PacerLastActiveFormat.key.date(from: day) else {
        return PacerUsageCellText(text: day, help: day)
    }
    let calendar = Calendar.current
    let start: Date = calendar.startOfDay(for: date)
    let today: Date = calendar.startOfDay(for: now)
    let help: String = PacerLastActiveFormat.help.string(from: date)
    // The same day, or a key a clock skew put after today.
    if start >= today {
        return PacerUsageCellText(text: PacerLastActiveFormat.relative.localizedString(
            from: DateComponents(day: 0)), help: help)
    }
    return PacerUsageCellText(text: PacerLastActiveFormat.relative.localizedString(
        for: start, relativeTo: today), help: help)
}

/// The formatters `pacerLastActiveDay` reuses: a table prints one per row.
private enum PacerLastActiveFormat {
    nonisolated(unsafe) static let key: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    nonisolated(unsafe) static let help: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    /// "today", "yesterday", then the abbreviated units `pacerRelative`
    /// prints ("3d ago", "2w ago").
    nonisolated(unsafe) static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .named
        return f
    }()
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

    /// What a share donut beside the table measures while it is sorted by
    /// the screen column `id`: nil unless the column's values add up to a
    /// whole (a count of sessions does; a date does not). See
    /// `PacerShareDonutData`.
    static func shareMetric(forColumn id: String) -> PacerShareMetric?

    /// This row's value in that metric.
    func shareValue(forColumn id: String) -> Double?
}

public extension PacerUsageExtra {
    static func shareMetric(forColumn id: String) -> PacerShareMetric? { nil }
    func shareValue(forColumn id: String) -> Double? { nil }
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

    /// - Parameter column: as stored. A retired column id is read as its
    ///   successor's ("writeShare" sorts by Hit %), so a sort saved before a
    ///   column was replaced still names a column on screen.
    public init(column: String, descending: Bool) {
        self.column = UsageColumn.migratedId(column)
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

    /// A saved layout with every retired column id renamed to its successor
    /// (`UsageColumn.legacyIds`), or nil when it names none. "writeShare"
    /// becomes "hitRate", so the place, width and visibility a user gave
    /// Write % carry over to Hit %, the column that replaced it.
    ///
    /// The ids are JSON strings in `TableColumnCustomization`'s encoding, so
    /// this renames the quoted id and leaves the rest of the encoding alone.
    /// A layout that already names the successor is left as it is: two
    /// entries for one id would not decode.
    static func migratedLayout(_ data: Data) -> Data? {
        guard var json = String(data: data, encoding: .utf8) else { return nil }
        var changed = false
        for (old, new) in UsageColumn.legacyIds {
            let quotedOld = "\"\(old)\"", quotedNew = "\"\(new.rawValue)\""
            guard json.contains(quotedOld), !json.contains(quotedNew) else { continue }
            json = json.replacingOccurrences(of: quotedOld, with: quotedNew)
            changed = true
        }
        return changed ? Data(json.utf8) : nil
    }

    /// Renames retired ids in the layout stored for `tableId`, before the
    /// table reads it.
    static func migrateLayout(tableId: String, store: UserDefaults) {
        let key = columnsKey(tableId: tableId)
        guard let data = store.data(forKey: key), let migrated = migratedLayout(data) else { return }
        store.set(migrated, forKey: key)
    }

    /// The layout-defaults version of each table whose defaults have changed
    /// since its users saved layouts. A layout stored before a table reached
    /// its version is cleared once, the first time the table is built, so the
    /// table opens on its new defaults rather than on whatever SwiftUI kept
    /// of the old ones (a saved layout records widths and order, and can
    /// record visibility, so a changed `.defaultVisibility` alone does not
    /// reach it). A table not listed is at version 0 and never cleared.
    ///
    /// Bump a table's version, deliberately, when its defaults change enough
    /// that a user should see them; the cost is that table's widths, order
    /// and shown columns, once.
    ///
    /// - Round 5 (version 1) cut every wide table from up to ten columns to
    ///   six: the tables that opened on the token parts.
    /// - Round 6 put Hit % and Out % into every table's defaults
    ///   (`UsageColumn.wideDefaults`, `.narrowDefaults`), so every table moves
    ///   on one: the round-5 tables to 2, the rest to 1. Models and Projects
    ///   also hide one of their own columns (Days, Sessions) to stay at seven.
    static let layoutDefaultsVersions: [String: Int] = [
        "models": 2,
        "projects": 2,
        "topDays": 2,
        "dayDetail.models": 2,
        "dayDetail.projects": 2,
        "dayDetail.sessions": 1,
        "projectDetail.models": 1,
        "projectDetail.subprojects": 1,
        "projectDetail.sessions": 1,
    ]

    /// Where the layout-defaults version a table's saved layout is at is
    /// kept, beside the layout.
    static func layoutDefaultsKey(tableId: String) -> String {
        "pacer.table.\(tableId).defaultsVersion"
    }

    /// Clears the layout stored for `tableId` if it predates the table's
    /// layout-defaults version, and records the version either way. Once per
    /// version: a layout the user makes afterwards is theirs to keep. Returns
    /// whether it cleared anything.
    @discardableResult
    static func applyLayoutDefaults(tableId: String, store: UserDefaults,
                                    versions: [String: Int] = layoutDefaultsVersions) -> Bool {
        guard let current = versions[tableId], current > 0 else { return false }
        let key = layoutDefaultsKey(tableId: tableId)
        // Absent reads as 0: every layout saved before versions existed.
        guard store.integer(forKey: key) < current else { return false }
        let columns = columnsKey(tableId: tableId)
        let cleared = store.object(forKey: columns) != nil
        store.removeObject(forKey: columns)
        store.set(current, forKey: key)
        return cleared
    }

    /// Puts the table `tableId` back to its defaults: its default columns,
    /// in declaration order, at their starting widths. The sort is the
    /// screen's and stays. What "Reset Columns" in the header's menu and the
    /// table's context menu does; every table on screen with that id follows.
    @MainActor
    public static func resetColumns(tableId: String) {
        NotificationCenter.default.post(name: .pacerResetTableColumns, object: tableId)
    }
}

extension Notification.Name {
    /// Posted by `PacerUsageTableMetrics.resetColumns(tableId:)`; the object
    /// is the table id.
    static let pacerResetTableColumns = Notification.Name("PacerResetTableColumns")
}

// MARK: - Table

/// The shared usage table.
///
/// - `rows`: in any order; the table sorts them by `sort`.
/// - `tableId`: names the persisted column layout, one per table.
/// - `sort` / `onSort`: the sort is read by value and written through the
///   callback, so the screen that owns and persists it re-renders on a
///   header click (AGENTS.md, "SwiftUI state and data flow").
/// - `onOpen`: a click on a row, or Return (or a double-click) on the row
///   the arrow keys reached. Rows that open nothing keep the native
///   selection instead.
/// - `defaultColumns`: the standard columns shown until the user changes
///   them — `UsageColumn.wideDefaults` or `.narrowDefaults`. With the
///   screen's own columns that is at most `UsageColumn.maxDefaultColumns`;
///   the rest are one right-click away. A screen's defaults fit its card at
///   the window's default size, with its own columns.
/// - `leadingColumns`: screen columns that belong beside the label (a
///   sessions list's Project), built with `PacerUsageColumns.extra`.
/// - `extraColumns`: the screen's own columns, built with
///   `PacerUsageColumns.extra`, after Cost and before Mix.
/// - `labelAccessory`: views after the label (Projects' git badge).
/// - `rowMenu`: the row's context menu. "Reset Columns" follows it on every
///   table, and is the whole menu of a table with none. It is in the
///   header's menu too, after AppKit's own column items.
public struct PacerUsageTable<Extra: PacerUsageExtra, Leading: TableColumnContent,
                              Extras: TableColumnContent, Accessory: View, RowMenu: View>: View
where Leading.TableRowValue == PacerUsageRow<Extra>,
      Leading.TableColumnSortComparator == PacerUsageComparator<Extra>,
      Extras.TableRowValue == PacerUsageRow<Extra>,
      Extras.TableColumnSortComparator == PacerUsageComparator<Extra> {
    public typealias Row = PacerUsageRow<Extra>
    public typealias Comparator = PacerUsageComparator<Extra>

    let rows: [Row]
    let tableId: String
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
    /// Bumped by "Reset Columns" to build the table afresh at its starting
    /// widths: SwiftUI applies an emptied layout's visibility and order to
    /// the table it already has, but not its widths.
    @State private var layoutGeneration = 0

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
        self.tableId = tableId
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
        PacerUsageTableMetrics.applyLayoutDefaults(tableId: tableId, store: store)
        PacerUsageTableMetrics.migrateLayout(tableId: tableId, store: store)
        _columns = AppStorage(
            wrappedValue: TableColumnCustomization<Row>(),
            PacerUsageTableMetrics.columnsKey(tableId: tableId),
            store: store)
    }

    public var body: some View {
        let sorted: [Row] = rows.sortedForUsageTable(sort)
        let twoLine = rows.contains { $0.subtitle != nil }
        let parts: [UsageColumn] = UsageColumn.partColumns
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
            // The token parts in the parts' own order (`partColumns`, read
            // from `CostComponent`), so the columns follow the order every
            // bar and breakdown draws the parts in. Six slots: five parts and
            // Cache write, both tiers together (`UsageTableTests` checks).
            Group {
                numberColumn(parts[0])
                numberColumn(parts[1])
                numberColumn(parts[2])
                numberColumn(parts[3])
                numberColumn(parts[4])
                numberColumn(parts[5])
            }
            Group {
                numberColumn(.tokens)
                numberColumn(.cacheHitRate)
                numberColumn(.outputShare)
                numberColumn(.cost)
            }
            extraColumns()
            mixColumn
        }
        .id(layoutGeneration)
        .tableStyle(.inset)
        // Off: on a table that hugs its rows, the stripe pattern carries on
        // into the margin under the last row as a cut-off band.
        .alternatingRowBackgrounds(.disabled)
        // The card is the background, as it is for everything else in it.
        .scrollContentBackground(.hidden)
        // A table that fits its rows has nothing to scroll, and without this
        // it still rubber-bands, taking the wheel from the page around it.
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        .frame(height: PacerUsageTableMetrics.height(
            rowCount: sorted.count, twoLine: twoLine, maxVisibleRows: maxVisibleRows))
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if RowMenu.self != EmptyView.self,
               let id = ids.first, let row = sorted.first(where: { $0.id == id }) {
                rowMenu(row)
                Divider()
            }
            // Also in the header's own menu (`PacerTableHeaderMenu`), where
            // the owner looked for it first.
            Button(PacerTableHeaderMenu.resetTitle) { PacerUsageTableMetrics.resetColumns(tableId: tableId) }
        } primaryAction: { ids in
            // Return, or a double-click. A click has already opened its row
            // (below), so only the keyboard's reaches `onOpen` here.
            guard let onOpen, PacerTableInput.lastWasKey,
                  let id = ids.first, let row = sorted.first(where: { $0.id == id }) else { return }
            selection = nil
            onOpen(row)
        }
        .onChange(of: selection) { _, id in
            guard let onOpen, let id else { return }
            // An arrow key moved the selection: leave it there, so the keys
            // walk the rows without opening each one, and Return opens.
            if PacerTableInput.lastWasKey { return }
            // A click opens the row and leaves nothing selected, so the
            // same row opens again next time, as the hand-rolled rows did.
            selection = nil
            if let row = sorted.first(where: { $0.id == id }) { onOpen(row) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pacerResetTableColumns)) { note in
            guard note.object as? String == tableId else { return }
            columns = TableColumnCustomization()
            layoutGeneration += 1
        }
        .onAppear { PacerTableInput.watch() }
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
            // Inside a cell, so it can find the table it is in by walking up
            // (`PacerTableFitter`): it keeps the table fitted to its width,
            // gives the header its tooltips and "Reset Columns".
            .background(PacerTableFitter(tableId: tableId))
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
                // A column narrowed past its number cuts the number short
                // ("88.…") rather than overflowing into its neighbour.
                .lineLimit(1)
                .truncationMode(.tail)
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
    @MainActor
    public static func extra<Extra: PacerUsageExtra, Content: View>(
        _ id: String,
        title: String,
        of extra: Extra.Type,
        numeric: Bool = true,
        minWidth: CGFloat = 28,
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

// MARK: - Keyboard and mouse

/// Whether the last key or mouse button pressed in the app was a key: how
/// the table tells an arrow key's selection change (walk, do not open) from
/// a click's (open), and Return from a double-click.
///
/// Round 2 read `NSApp.currentEvent`, the last event of any kind the app took
/// off the queue. SwiftUI delivers a selection change on its next update,
/// and a mouse-moved or scroll event taken in between made an arrow key look
/// like a click and open the row. A local monitor sees only key-downs and
/// button-downs, so whatever arrives in between cannot change the answer.
/// It observes, and hands every event on unchanged.
@MainActor
enum PacerTableInput {
    private(set) static var lastWasKey = false
    private static var monitor: Any?

    /// Starts watching, once per process. Every table calls it on appear.
    static func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            let isKey = event.type == .keyDown
            MainActor.assumeIsolated { record(keyDown: isKey) }
            return event
        }
    }

    static func record(keyDown: Bool) {
        lastWasKey = keyDown
    }
}
