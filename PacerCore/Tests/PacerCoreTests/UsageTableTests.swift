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
        #expect(UsageColumn.outputShare.tokenCount(of: t) == nil)
        #expect(UsageColumn.cacheWriteShare.tokenCount(of: t) == nil)
        #expect(UsageColumn.mix.tokenCount(of: t) == nil)
    }

    /// A different value in every cost part, chosen so reading any wrong
    /// part (or only one write tier, or reads for writes) gives a different
    /// percent.
    static let parts = CostComponents(
        input: 7, output: 23, cacheRead: 41, cacheWrite5m: 18, cacheWrite1h: 11)

    @Test("Out % is output's share of the cost; Write % is writes' share of the cache cost")
    func shares() throws {
        let p = Self.parts
        let out: Double = try #require(p.outputShare)
        let write: Double = try #require(p.cacheWriteShare)
        let uncached: Double = try #require(p.uncachedShare)
        #expect(abs(out - 0.23) < 1e-12)
        // (18 + 11) / (41 + 18 + 11)
        let expectedWrite: Double = 29.0 / 70.0
        #expect(abs(write - expectedWrite) < 1e-12)
        #expect(abs(uncached - 0.30) < 1e-12)
        let outColumn: Double? = UsageColumn.outputShare.share(of: p)
        let writeColumn: Double? = UsageColumn.cacheWriteShare.share(of: p)
        #expect(outColumn == p.outputShare)
        #expect(writeColumn == p.cacheWriteShare)
        #expect(UsageColumn.cost.share(of: p) == nil)
    }

    @Test("a row with nothing to divide has no share, and residue below zero counts as zero")
    func sharesWithNothingToDivide() {
        #expect(CostComponents.zero.outputShare == nil)
        #expect(CostComponents.zero.cacheWriteShare == nil)
        let uncachedOnly = CostComponents(input: 2, output: 3)
        #expect(uncachedOnly.cacheWriteShare == nil)
        #expect(uncachedOnly.outputShare == 0.6)
        // `apportion` can leave -1e-17 on the 1h tier.
        let residue = CostComponents(cacheRead: 3, cacheWrite5m: 1, cacheWrite1h: -1e-17)
        #expect(residue.cacheWriteShare == 0.25)
    }

    @Test("ratio cells print a whole percent, <1% for a sliver and a dash for no answer")
    func shareCells() {
        let t = Self.distinct
        let out: PacerUsageCellText? = UsageColumn.outputShare.cellText(tokens: t, cost: 100, costParts: Self.parts)
        let write: PacerUsageCellText? = UsageColumn.cacheWriteShare.cellText(tokens: t, cost: 100, costParts: Self.parts)
        #expect(out?.text == "23%")
        #expect(write?.text == "41%")
        #expect(out?.help == "Output \(pacerCostExact(23)) of \(pacerCostExact(100))")
        #expect(write?.help == "Cache writes \(pacerCostExact(29)) of \(pacerCostExact(70)) cache cost")
        let sliver = CostComponents(output: 0.001, cacheRead: 10)
        let small: PacerUsageCellText? = UsageColumn.outputShare.cellText(tokens: t, cost: 10, costParts: sliver)
        #expect(small?.text == "<1%")
        let none: PacerUsageCellText? = UsageColumn.cacheWriteShare.cellText(tokens: t, cost: 0, costParts: .zero)
        #expect(none?.text == "–")
        #expect(UsageColumn.mix.cellText(tokens: t, cost: 1, costParts: Self.parts) == nil)
    }

    @Test("no two token columns print the same number for the distinct row")
    func distinctCells() {
        let columns: [UsageColumn] = UsageColumn.allCases.filter { $0 != .name && $0 != .mix }
        let texts: [String] = columns.compactMap {
            $0.cellText(tokens: Self.distinct, cost: 6.5, costParts: Self.parts)?.text
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
        let input: PacerUsageCellText? = UsageColumn.input.cellText(tokens: big, cost: 0, costParts: .zero)
        #expect(input?.text == pacerTokens(1_234_567))
        #expect(input?.help == pacerTokensExact(1_234_567))

        let write: PacerUsageCellText? = UsageColumn.cacheWrite.cellText(tokens: big, cost: 0, costParts: .zero)
        let expectedHelp = "\(pacerTokensExact(54_000)): 5m \(pacerTokensExact(4_000)) · 1h \(pacerTokensExact(50_000))"
        #expect(write?.text == pacerTokens(54_000))
        #expect(write?.help == expectedHelp)

        let cost: PacerUsageCellText? = UsageColumn.cost.cellText(tokens: big, cost: 1234.5, costParts: .zero)
        #expect(cost?.text == pacerCost(1234.5))
        #expect(cost?.help == pacerCostExact(1234.5))
        #expect(UsageColumn.name.cellText(tokens: big, cost: 1, costParts: .zero) == nil)
    }

    @Test("titles are short and Total keeps the persisted raw value \"tokens\"")
    func titles() {
        let titles: [String] = UsageColumn.allCases.map { $0.title(label: "Model") }
        #expect(titles == ["Model", "Input", "Output", "Cache read", "Cache write",
                           "5m write", "1h write", "Total", "Out %", "Write %", "Cost", "Mix"])
        #expect(UsageColumn.tokens.rawValue == "tokens")
        // Persisted as sort columns and layout ids. "mix" is the id the
        // Models table's own Mix column had, so its saved layout carries over.
        #expect(UsageColumn.outputShare.rawValue == "outShare")
        #expect(UsageColumn.cacheWriteShare.rawValue == "writeShare")
        #expect(UsageColumn.mix.rawValue == "mix")
        #expect(UsageColumn(rawValue: "cost") == .cost)
        #expect(UsageColumn(rawValue: "name") == .name)
    }

    @Test("wide tables show the token parts; narrow ones the total, the ratios and the cost")
    func defaults() {
        let wide: [UsageColumn] = UsageColumn.allCases.filter { UsageColumn.wideDefaults.contains($0) }
        let narrow: [UsageColumn] = UsageColumn.allCases.filter { UsageColumn.narrowDefaults.contains($0) }
        #expect(wide == [.name, .input, .output, .cacheRead, .cacheWrite, .tokens, .cost])
        #expect(narrow == [.name, .tokens, .outputShare, .cacheWriteShare, .cost])
        let ascendingFirst: [UsageColumn] = UsageColumn.allCases.filter { !$0.sortsDescendingFirst }
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
                           cacheCreation5mTokens: 1, cacheCreation1hTokens: 3),
            CostComponents(input: 30, output: 10, cacheRead: 30, cacheWrite5m: 20, cacheWrite1h: 10)),
        row("b", label: "alpha", sessions: 3, cost: 1,
            TokenBreakdown(inputTokens: 2, outputTokens: 1, cacheReadTokens: 3,
                           cacheCreation5mTokens: 3, cacheCreation1hTokens: 1),
            CostComponents(input: 10, output: 50, cacheRead: 32, cacheWrite5m: 5, cacheWrite1h: 3)),
        row("c", label: "Bravo", sessions: 1, cost: 2,
            TokenBreakdown(inputTokens: 3, outputTokens: 2, cacheReadTokens: 1,
                           cacheCreation5mTokens: 2, cacheCreation1hTokens: 2),
            CostComponents(input: 5, output: 20, cacheRead: 15, cacheWrite5m: 50, cacheWrite1h: 10)),
    ]

    static func row(_ id: String, label: String, sessions: Int, cost: Double,
                    _ tokens: TokenBreakdown, _ parts: CostComponents) -> Row {
        Row(id: id, label: label, tokens: tokens, costParts: parts, cost: cost,
            extra: Sessions(count: sessions))
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
            // Out %: a 10%, c 20%, b 50%.
            ("outShare", ["a", "c", "b"]),
            // Write %: b 8/40, a 30/60, c 60/75.
            ("writeShare", ["b", "a", "c"]),
            // Mix, by the uncached share: c 25%, a 40%, b 60%.
            ("mix", ["c", "a", "b"]),
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
                                   "cacheWrite5m", "cacheWrite1h", "tokens", "outShare",
                                   "writeShare", "cost", "mix"]
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

    @Test("a row with no cost sorts below every share, both ways round")
    func noAnswerSortsFirst() {
        let free = Self.row("z", label: "Zulu", sessions: 0, cost: 0, TokenBreakdown(), .zero)
        let all: [Row] = Self.rows + [free]
        let up: [Row] = all.sortedForUsageTable(PacerUsageSort(.outputShare, descending: false))
        let down: [Row] = all.sortedForUsageTable(PacerUsageSort(.outputShare, descending: true))
        #expect(up.first?.id == "z")
        #expect(down.last?.id == "z")
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
                                        cacheCreation5mTokens: 3, cacheCreation1hTokens: 0),
                 costParts: CostComponents(input: 1, output: 1, cacheRead: 2, cacheWrite5m: 1)),
        DayTotal(date: "2026-10-02", cost: 5,
                 tokens: TokenBreakdown(inputTokens: 1, outputTokens: 9, cacheReadTokens: 3,
                                        cacheCreation5mTokens: 0, cacheCreation1hTokens: 7),
                 costParts: CostComponents(input: 1, output: 1, cacheRead: 2, cacheWrite5m: 1)),
        DayTotal(date: "2026-10-03", cost: 2,
                 tokens: TokenBreakdown(inputTokens: 4, outputTokens: 4, cacheReadTokens: 4,
                                        cacheCreation5mTokens: 4, cacheCreation1hTokens: 4),
                 costParts: CostComponents(output: 1, cacheRead: 0.5, cacheWrite1h: 0.5)),
        DayTotal(date: "2026-09-30", cost: 8,
                 tokens: TokenBreakdown(inputTokens: 2, outputTokens: 2, cacheReadTokens: 9,
                                        cacheCreation5mTokens: 7, cacheCreation1hTokens: 0),
                 costParts: CostComponents(input: 3, output: 1, cacheRead: 3, cacheWrite5m: 1)),
        // Nothing spent: no share, which must sort the same way in both.
        DayTotal(date: "2026-09-29", cost: 0,
                 tokens: TokenBreakdown(inputTokens: 5), costParts: .zero),
    ]

    @Test("every sort, both directions, gives the table's order")
    func agree() {
        let rows: [PacerUsageRow<PacerUsageNoExtra>] = Self.days.map {
            PacerUsageRow(id: $0.date, label: "day", sortLabel: $0.date, tokens: $0.tokens,
                          costParts: $0.costParts, cost: $0.cost)
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
        // Every table column but the label is a Top days sort.
        let columns: Set<UsageColumn> = Set(TopDaysSort.allCases.map(\.column))
        #expect(columns == Set(UsageColumn.allCases))
    }

    @Test("a day's parts are the sum of its models' parts")
    func dayParts() {
        let rows: [DailyRow] = [
            DailyRow(date: "2026-10-01", model: "m1", inputTokens: 1, outputTokens: 2,
                     cacheReadTokens: 3, cacheCreation5mTokens: 4, cacheCreation1hTokens: 5,
                     totalCostUSD: 15, cost: CostComponents(input: 1, output: 2, cacheRead: 3,
                                                            cacheWrite5m: 4, cacheWrite1h: 5)),
            DailyRow(date: "2026-10-01", model: "m2", inputTokens: 1, outputTokens: 1,
                     cacheReadTokens: 1, cacheCreation5mTokens: 1, cacheCreation1hTokens: 1,
                     totalCostUSD: 50, cost: CostComponents(input: 10, output: 20, cacheRead: 5,
                                                            cacheWrite5m: 7, cacheWrite1h: 8)),
        ]
        let day: DayTotal? = DayRanking.totals(rows).first
        let expected = CostComponents(input: 11, output: 22, cacheRead: 8, cacheWrite5m: 11, cacheWrite1h: 13)
        #expect(day?.costParts == expected)
        #expect(day?.cost == 65)
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

// On the main actor: the rows are built where a view builds them.
@MainActor
@Suite("Sessions on the shared table")
struct SessionsTableTests {

    static let session = SessionRow(
        sessionId: "3fa291c0-aaaa-4bbb-8ccc-123456789abc",
        firstSeenAt: Date(timeIntervalSince1970: 1_790_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_790_011_520),
        projectPath: "/tmp/acme-web", ccVersion: "2.1.4", cumulativeCostUSD: 12.5,
        cumulativeInputTokens: 1, cumulativeOutputTokens: 20, cumulativeCacheReadTokens: 300,
        cumulativeCacheCreation5mTokens: 4_000, cumulativeCacheCreation1hTokens: 50_000,
        topModel: "claude-opus-4-7",
        cost: CostComponents(input: 0.5, output: 3, cacheRead: 4, cacheWrite5m: 2, cacheWrite1h: 3))

    @Test("a session is its model over its short id, with its parts and its times")
    func row() throws {
        let row: PacerSessionsTable.Row = try #require(PacerSessionsTable.rows([Self.session]).first)
        #expect(row.id == Self.session.sessionId)
        #expect(row.label == pacerModelDisplayName("claude-opus-4-7"))
        #expect(row.subtitle == "3fa291c0")
        #expect(row.tokens == Self.session.tokens)
        #expect(row.costParts == Self.session.cost)
        #expect(row.cost == 12.5)
        #expect(row.extra.projectName == pacerShortPath("/tmp/acme-web"))
        #expect(row.extra.duration == 11_520)
        #expect(pacerSessionDuration(row.extra.duration) == "3h 12m")
    }

    @Test("a sort stored by the old sessions table carries over")
    func storedSorts() {
        let byId: PacerUsageSort = PacerSessionsTable.sort(stored: "id", descending: false)
        let byModel: PacerUsageSort = PacerSessionsTable.sort(stored: "model", descending: true)
        let byLastSeen: PacerUsageSort = PacerSessionsTable.sort(stored: "lastSeen", descending: true)
        let byProject: PacerUsageSort = PacerSessionsTable.sort(stored: "project", descending: false)
        #expect(byId == PacerUsageSort(.name, descending: false))
        #expect(byModel == PacerUsageSort(.name, descending: true))
        #expect(byLastSeen == PacerUsageSort(column: PacerSessionExtra.lastSeen, descending: true))
        #expect(byProject == PacerUsageSort(column: PacerSessionExtra.project, descending: false))
        // "tokens" and "cost" were already column ids.
        #expect(PacerSessionsTable.sort(stored: "tokens", descending: true) == PacerUsageSort(.tokens, descending: true))
        #expect(PacerSessionsTable.sort(stored: "cost", descending: true) == .costDescending)
    }

    @Test("its own columns sort by their own values")
    func extraSorts() {
        let early = PacerSessionExtra(projectPath: "/b", projectName: "beta",
                                      firstSeenAt: Date(timeIntervalSince1970: 0),
                                      lastSeenAt: Date(timeIntervalSince1970: 100))
        let late = PacerSessionExtra(projectPath: "/a", projectName: "Alpha",
                                     firstSeenAt: Date(timeIntervalSince1970: 90),
                                     lastSeenAt: Date(timeIntervalSince1970: 200))
        #expect(early.sortKey(forColumn: PacerSessionExtra.lastSeen) == .date(Date(timeIntervalSince1970: 100)))
        #expect(early.sortKey(forColumn: PacerSessionExtra.duration) == .number(100))
        #expect(late.sortKey(forColumn: PacerSessionExtra.duration) == .number(110))
        #expect(late.sortKey(forColumn: PacerSessionExtra.project) == .text("Alpha"))
        #expect(early.sortKey(forColumn: "cost") == nil)
    }

    @Test("by default a sessions table shows its label, the total and the cost")
    func defaults() {
        let shown: [UsageColumn] = UsageColumn.allCases.filter { PacerSessionsTable.defaultColumns.contains($0) }
        #expect(shown == [.name, .tokens, .cost])
    }
}
