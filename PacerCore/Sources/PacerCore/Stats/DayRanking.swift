import Foundation

/// What History → Top days ranks by. The raw values are persisted by the
/// card's sort preference, so they stay as they are: `date`, `tokens` and
/// `cost` were the first three, and every other case is the `UsageColumn`
/// raw value of the column it sorts, so the card's table can sort by any of
/// its columns and the choice is stored the same way.
public enum TopDaysSort: String, CaseIterable, Identifiable, Sendable {
    case date, tokens, cost
    case input, output, cacheRead, cacheWrite, cacheWrite5m, cacheWrite1h
    case hitRate, outShare, mix
    public var id: String { rawValue }

    /// A stored sort, retired column ids included: "writeShare" (Write %)
    /// ranks by Hit %, the column that replaced it. Anything unknown ranks
    /// by cost.
    public init(stored raw: String) {
        self = TopDaysSort(rawValue: UsageColumn.migratedId(raw)) ?? .cost
    }

    /// The table column this sort is. `date` is the label column.
    public var column: UsageColumn {
        self == .date ? .name : UsageColumn(rawValue: rawValue) ?? .cost
    }

    /// The sort for a table column: the label column is the date.
    public init(column: UsageColumn) {
        self = column == .name ? .date : TopDaysSort(rawValue: column.rawValue) ?? .cost
    }
}

/// One day summed across every model.
public struct DayTotal: Sendable, Equatable, Identifiable, UsageColumnValues {
    public let date: String
    public var cost: Double
    public var tokens: TokenBreakdown
    /// `cost` by priced part, for the ratio and Mix columns.
    public var costParts: CostComponents
    public var id: String { date }

    public init(date: String, cost: Double = 0, tokens: TokenBreakdown = .zero,
                costParts: CostComponents = .zero) {
        self.date = date
        self.cost = cost
        self.tokens = tokens
        self.costParts = costParts
    }
}

/// The Top days ranking (#215), out of the view so it can be tested.
///
/// "Tokens" ranks by `TokenBreakdown.all`. It ranked by input + output once,
/// and on a store where cache reads and writes were ~98% of every token that
/// put months-old days of heavy uncached input above the recent days that
/// cost the most: the ranking left out almost everything it claimed to count.
///
/// The card shows the top 10 (or 100) of this ranking in the shared usage
/// table, which sorts what it is given by the same column. The two orders
/// have to agree, ties included, or the table would reshuffle the days this
/// picked; both compare through `UsageColumn.compare`, and
/// `UsageTableTests` checks every column in both directions.
public enum DayRanking {

    /// The rows folded to one total per date, in no particular order.
    public static func totals(_ rows: [DailyRow]) -> [DayTotal] {
        var byDate: [String: DayTotal] = [:]
        for row in rows {
            var day = byDate[row.date] ?? DayTotal(date: row.date)
            day.cost += row.totalCostUSD
            day.tokens += row.tokens
            day.costParts += row.cost
            byDate[row.date] = day
        }
        return Array(byDate.values)
    }

    /// Every day in `rows`, ordered by `sort`, largest (or latest) first when
    /// `descending`. Equal values fall back to the date, so a refresh never
    /// reshuffles a tie.
    public static func ranked(
        _ rows: [DailyRow], by sort: TopDaysSort, descending: Bool
    ) -> [DayTotal] {
        ranked(totals(rows), by: sort, descending: descending)
    }

    /// `ranked(_:by:descending:)` over days already folded.
    public static func ranked(
        _ days: [DayTotal], by sort: TopDaysSort, descending: Bool
    ) -> [DayTotal] {
        let column = sort.column
        let ascending = days.sorted { lhs, rhs in
            switch column.compare(lhs, rhs) {
            case .orderedAscending:  return true
            case .orderedDescending: return false
            case .orderedSame:       return lhs.date < rhs.date
            }
        }
        return descending ? ascending.reversed() : ascending
    }
}
