import Foundation

/// What History → Top days ranks by. The raw values are persisted by the
/// card's sort preference, so they stay as they are.
public enum TopDaysSort: String, CaseIterable, Identifiable, Sendable {
    case date, tokens, cost
    public var id: String { rawValue }
}

/// One day summed across every model.
public struct DayTotal: Sendable, Equatable, Identifiable {
    public let date: String
    public var cost: Double
    public var tokens: TokenBreakdown
    public var id: String { date }

    public init(date: String, cost: Double = 0, tokens: TokenBreakdown = .zero) {
        self.date = date
        self.cost = cost
        self.tokens = tokens
    }
}

/// The Top days ranking (#215), out of the view so it can be tested.
///
/// "Tokens" ranks by `TokenBreakdown.all`. It ranked by input + output once,
/// and on a store where cache reads and writes were ~98% of every token that
/// put months-old days of heavy uncached input above the recent days that
/// cost the most: the ranking left out almost everything it claimed to count.
public enum DayRanking {

    /// The rows folded to one total per date, in no particular order.
    public static func totals(_ rows: [DailyRow]) -> [DayTotal] {
        var byDate: [String: DayTotal] = [:]
        for row in rows {
            var day = byDate[row.date] ?? DayTotal(date: row.date)
            day.cost += row.totalCostUSD
            day.tokens += row.tokens
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
        let ascending = totals(rows).sorted { lhs, rhs in
            switch sort {
            case .date:
                break
            case .tokens:
                let l: Int64 = lhs.tokens.all
                let r: Int64 = rhs.tokens.all
                if l != r { return l < r }
            case .cost:
                if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
            }
            return lhs.date < rhs.date
        }
        return descending ? ascending.reversed() : ascending
    }
}
