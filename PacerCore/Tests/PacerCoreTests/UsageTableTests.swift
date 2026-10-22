import Foundation
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// The shared usage table's pure parts: which number each column is, how
// every column sorts, and that History's ranking agrees with the table.

@Suite("Usage table columns")
struct UsageColumnTests {

    /// A different power of ten in every field, so a column reading the wrong
    /// one shows a different number rather than an equal one.
    static let distinct = TokenBreakdown(
        inputTokens: 1,
        outputTokens: 20,
        cacheReadTokens: 300,
        cacheCreation5mTokens: 4_000,
        cacheCreation1hTokens: 50_000)

    @Test("every token column reads its own field")
    func tokenCounts() {
        let t = Self.distinct
        let input: Int64? = UsageColumn.input.tokenCount(of: t)
        let output: Int64? = UsageColumn.output.tokenCount(of: t)
        let read: Int64? = UsageColumn.cacheRead.tokenCount(of: t)
        let write: Int64? = UsageColumn.cacheWrite.tokenCount(of: t)
        let write5m: Int64? = UsageColumn.cacheWrite5m.tokenCount(of: t)
        let write1h: Int64? = UsageColumn.cacheWrite1h.tokenCount(of: t)
        let total: Int64? = UsageColumn.tokens.tokenCount(of: t)
        #expect(input == 1)
        #expect(output == 20)
        #expect(read == 300)
        #expect(write == 54_000)
        #expect(write5m == 4_000)
        #expect(write1h == 50_000)
        #expect(total == 54_321)
        #expect(UsageColumn.name.tokenCount(of: t) == nil)
        #expect(UsageColumn.cost.tokenCount(of: t) == nil)
    }

    @Test("no two token columns print the same number for the distinct row")
    func distinctCells() {
        let columns: [UsageColumn] = UsageColumn.allCases.filter { $0 != .name }
        let texts: [String] = columns.compactMap {
            $0.cellText(tokens: Self.distinct, cost: 6.5)?.text
        }
        #expect(texts.count == columns.count)
        #expect(Set(texts).count == texts.count)
    }

    @Test("cells print compact and tooltip exact; cache write splits its tiers")
    func cellText() {
        let big = TokenBreakdown(
            inputTokens: 1_234_567,
            cacheCreation5mTokens: 4_000,
            cacheCreation1hTokens: 50_000)
        let input: PacerUsageCellText? = UsageColumn.input.cellText(tokens: big, cost: 0)
        #expect(input?.text == pacerTokens(1_234_567))
        #expect(input?.help == pacerTokensExact(1_234_567))

        let write: PacerUsageCellText? = UsageColumn.cacheWrite.cellText(tokens: big, cost: 0)
        let expectedHelp = "\(pacerTokensExact(54_000)): 5m \(pacerTokensExact(4_000)) · 1h \(pacerTokensExact(50_000))"
        #expect(write?.text == pacerTokens(54_000))
        #expect(write?.help == expectedHelp)

        let cost: PacerUsageCellText? = UsageColumn.cost.cellText(tokens: big, cost: 1234.5)
        #expect(cost?.text == pacerCost(1234.5))
        #expect(cost?.help == pacerCostExact(1234.5))
        #expect(UsageColumn.name.cellText(tokens: big, cost: 1) == nil)
    }

    @Test("titles are short and Total keeps the persisted raw value \"tokens\"")
    func titles() {
        let titles: [String] = UsageColumn.allCases.map { $0.title(label: "Model") }
        #expect(titles == ["Model", "Input", "Output", "Cache read", "Cache write",
                           "5m write", "1h write", "Total", "Cost"])
        #expect(UsageColumn.tokens.rawValue == "tokens")
        #expect(UsageColumn(rawValue: "cost") == .cost)
        #expect(UsageColumn(rawValue: "name") == .name)
    }

    @Test("only the two cache-write tiers start hidden; only the label sorts A to Z first")
    func defaults() {
        let hidden: [UsageColumn] = UsageColumn.allCases.filter { !$0.isVisibleByDefault }
        let ascendingFirst: [UsageColumn] = UsageColumn.allCases.filter { !$0.sortsDescendingFirst }
        #expect(hidden == [.cacheWrite5m, .cacheWrite1h])
        #expect(ascendingFirst == [.name])
        #expect(PacerUsageSort.costDescending == PacerUsageSort(column: "cost", descending: true))
    }
}

@Suite("Usage table sorting")
struct UsageTableSortTests {

    /// One screen-specific number, to sort an extra column by.
    struct Sessions: PacerUsageExtra, Sendable {
        let count: Int
        func sortKey(forColumn id: String) -> PacerUsageSortKey? {
            id == "sessions" ? .number(Double(count)) : nil
        }
    }

    typealias Row = PacerUsageRow<Sessions>

    /// Three rows whose order differs for every column, so a comparator that
    /// read the wrong column cannot produce the expected order by accident.
    /// Each line is "id: order for that column, ascending".
    static let rows: [Row] = [
        row("a", label: "Charlie", sessions: 2, cost: 3,
            TokenBreakdown(inputTokens: 1, outputTokens: 3, cacheReadTokens: 2,
                           cacheCreation5mTokens: 1, cacheCreation1hTokens: 3)),
        row("b", label: "alpha", sessions: 3, cost: 1,
            TokenBreakdown(inputTokens: 2, outputTokens: 1, cacheReadTokens: 3,
                           cacheCreation5mTokens: 3, cacheCreation1hTokens: 1)),
        row("c", label: "Bravo", sessions: 1, cost: 2,
            TokenBreakdown(inputTokens: 3, outputTokens: 2, cacheReadTokens: 1,
                           cacheCreation5mTokens: 2, cacheCreation1hTokens: 2)),
    ]

    static func row(_ id: String, label: String, sessions: Int, cost: Double,
                    _ tokens: TokenBreakdown) -> Row {
        Row(id: id, label: label, tokens: tokens, cost: cost, extra: Sessions(count: sessions))
    }

    func ids(_ column: String, descending: Bool) -> [String] {
        let sort = PacerUsageSort(column: column, descending: descending)
        let sorted: [Row] = Self.rows.sortedForUsageTable(sort)
        return sorted.map(\.id)
    }

    @Test("each column sorts by its own value, both ways")
    func everyColumn() {
        // Ascending ids per column, worked out by hand from the rows above.
        // Cache write: a = 4, b = 4, c = 4 ties, so the id breaks it.
        // Total: a = 10, b = 10, c = 10, also a tie on purpose.
        let expected: [(String, [String])] = [
            ("name", ["b", "c", "a"]),          // alpha, Bravo, Charlie (case-insensitive)
            ("input", ["a", "b", "c"]),
            ("output", ["b", "c", "a"]),
            ("cacheRead", ["c", "a", "b"]),
            ("cacheWrite", ["a", "b", "c"]),
            ("cacheWrite5m", ["a", "c", "b"]),
            ("cacheWrite1h", ["b", "c", "a"]),
            ("tokens", ["a", "b", "c"]),
            ("cost", ["b", "c", "a"]),
            ("sessions", ["c", "a", "b"]),
        ]
        for (column, ascending) in expected {
            #expect(ids(column, descending: false) == ascending, "ascending \(column)")
            let descending: [String] = ascending.reversed()
            #expect(ids(column, descending: true) == descending, "descending \(column)")
        }
    }

    @Test("every standard column is covered by the sort test")
    func coverage() {
        let tested: Set<String> = ["name", "input", "output", "cacheRead", "cacheWrite",
                                   "cacheWrite5m", "cacheWrite1h", "tokens", "cost"]
        let all: Set<String> = Set(UsageColumn.allCases.map(\.rawValue))
        #expect(all == tested)
    }

    @Test("the comparator round-trips the sort and matches by column and direction")
    func comparator() {
        let sort = PacerUsageSort(.cacheRead, descending: true)
        let c = PacerUsageComparator<Sessions>(sort)
        #expect(c.order == .reverse)
        #expect(c.sort == sort)
        let same = PacerUsageComparator<Sessions>(column: "cacheRead", order: .reverse)
        let flipped = PacerUsageComparator<Sessions>(column: "cacheRead", order: .forward)
        #expect(c == same)
        #expect(c != flipped)
    }

    @Test("an unknown column sorts by id, so a stale stored sort is still stable")
    func unknownColumn() {
        #expect(ids("gone", descending: false) == ["a", "b", "c"])
    }

    @Test("the sort is Codable, so a screen can persist it")
    func sortCodable() throws {
        let sort = PacerUsageSort(.cacheWrite1h, descending: false)
        let data: Data = try JSONEncoder().encode(sort)
        let back: PacerUsageSort = try JSONDecoder().decode(PacerUsageSort.self, from: data)
        #expect(back == sort)
    }
}

@Suite("Top days ranking agrees with the table")
struct TopDaysTableAgreementTests {

    /// Ties in cost and in total, so the tiebreak is exercised too.
    static let days: [DayTotal] = [
        DayTotal(date: "2026-10-01", cost: 5,
                 tokens: TokenBreakdown(inputTokens: 9, outputTokens: 1, cacheReadTokens: 7,
                                        cacheCreation5mTokens: 3, cacheCreation1hTokens: 0)),
        DayTotal(date: "2026-10-02", cost: 5,
                 tokens: TokenBreakdown(inputTokens: 1, outputTokens: 9, cacheReadTokens: 3,
                                        cacheCreation5mTokens: 0, cacheCreation1hTokens: 7)),
        DayTotal(date: "2026-10-03", cost: 2,
                 tokens: TokenBreakdown(inputTokens: 4, outputTokens: 4, cacheReadTokens: 4,
                                        cacheCreation5mTokens: 4, cacheCreation1hTokens: 4)),
        DayTotal(date: "2026-09-30", cost: 8,
                 tokens: TokenBreakdown(inputTokens: 2, outputTokens: 2, cacheReadTokens: 9,
                                        cacheCreation5mTokens: 7, cacheCreation1hTokens: 0)),
    ]

    @Test("every sort, both directions, gives the table's order")
    func agree() {
        let rows: [PacerUsageRow<PacerUsageNoExtra>] = Self.days.map {
            PacerUsageRow(id: $0.date, label: "day", sortLabel: $0.date, tokens: $0.tokens, cost: $0.cost)
        }
        for sort in TopDaysSort.allCases {
            for descending in [false, true] {
                let ranked: [String] = DayRanking.ranked(Self.days, by: sort, descending: descending).map(\.date)
                let tableSort = PacerUsageSort(sort.column, descending: descending)
                let table: [String] = rows.sortedForUsageTable(tableSort).map(\.id)
                #expect(ranked == table, "\(sort.rawValue) descending=\(descending)")
            }
        }
    }

    @Test("the persisted raw values carry over, and map to columns and back")
    func rawValues() {
        #expect(TopDaysSort(rawValue: "date") == .date)
        #expect(TopDaysSort(rawValue: "tokens") == .tokens)
        #expect(TopDaysSort(rawValue: "cost") == .cost)
        for sort in TopDaysSort.allCases {
            #expect(TopDaysSort(column: sort.column) == sort)
        }
        #expect(TopDaysSort.date.column == .name)
        #expect(TopDaysSort.tokens.column == .tokens)
    }
}

@Suite("Usage table height")
struct UsageTableHeightTests {

    @Test("hugs its rows, then stops at the cap")
    func hugsThenCaps() {
        let one: CGFloat = PacerUsageTableMetrics.height(rowCount: 1, twoLine: false)
        let three: CGFloat = PacerUsageTableMetrics.height(rowCount: 3, twoLine: false)
        let cap = PacerUsageTableMetrics.defaultMaxVisibleRows
        let atCap: CGFloat = PacerUsageTableMetrics.height(rowCount: cap, twoLine: false)
        let past: CGFloat = PacerUsageTableMetrics.height(rowCount: cap + 40, twoLine: false)
        let empty: CGFloat = PacerUsageTableMetrics.height(rowCount: 0, twoLine: false)
        #expect(one < three)
        #expect(atCap == past)
        #expect(empty == one)
        let twoLine: CGFloat = PacerUsageTableMetrics.height(rowCount: 3, twoLine: true)
        #expect(twoLine > three)
    }

    @Test("each table keeps its layout under its own key")
    func keys() {
        #expect(PacerUsageTableMetrics.columnsKey(tableId: "models") == "pacer.table.models.columns")
        #expect(PacerUsageTableMetrics.columnsKey(tableId: "models")
                != PacerUsageTableMetrics.columnsKey(tableId: "projects"))
    }
}
