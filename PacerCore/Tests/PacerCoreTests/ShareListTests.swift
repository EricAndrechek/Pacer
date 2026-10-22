import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// The list beside a donut card's ring (`PacerShareListData`): every card's
// columns are Tokens, Cost and Share; nothing that does not add up can be
// listed; a click on a column title sorts the list and turns the ring to that
// column; the list is the ring's legend, folded tail included; and a share
// column prints each row's part of the whole.

@Suite("Donut card list")
struct ShareListTests {

    typealias Project = ShareDonutTests.Project
    typealias Row = PacerUsageRow<Project>

    /// The donut tests' three rows: different orders by cost (b, c, a), by
    /// output (a, c, b) and by sessions (a, c, b), with cache reads (a 0,
    /// b 50, c 20) so Tokens orders them b, c, a ascending.
    static func rows() -> [Row] {
        let base = ShareDonutTests.rows()
        let reads: [String: (Int64, Int64)] = ["a": (0, 0), "b": (50, 0), "c": (20, 0)]
        return base.map { row in
            var tokens = row.tokens
            tokens.cacheReadTokens = reads[row.id]?.0 ?? 0
            return Row(id: row.id, label: row.label, color: row.color, tokens: tokens,
                       costParts: row.costParts, extra: row.extra)
        }
    }

    /// Every donut list's columns: Tokens, Cost, Share.
    static let columns: [PacerShareListColumn] = PacerShareListColumn.standard

    /// The standard columns and a screen's own count, for the tests of a
    /// screen column that adds up.
    static let withSessions: [PacerShareListColumn] =
        PacerShareListColumn.standard + [.count("sessions", title: "Sessions", format: .count)]

    func data(_ sort: PacerUsageSort, rows: [Row] = ShareListTests.rows(),
              columns: [PacerShareListColumn] = ShareListTests.columns,
              maxSlices: Int = .max) -> PacerShareListData<Project> {
        PacerShareListData(rows: rows, sort: sort, columns: columns, maxSlices: maxSlices)
    }

    @Test("every donut list has Tokens, Cost and Share: the tables' titles, in the tables' order")
    func standardColumns() {
        let standard = PacerShareListColumn.standard
        #expect(standard.map { $0.title } == ["Tokens", "Cost", "Share"])
        #expect(standard.map { $0.id } == [UsageColumn.tokens.rawValue, UsageColumn.cost.rawValue,
                                          PacerShareListColumn.ringShare.id])
        // The titles a table gives the same numbers, in the order a table
        // lays them out.
        let usage: [UsageColumn] = standard.compactMap { UsageColumn(rawValue: $0.id) }
        #expect(usage.map { $0.title(label: "") } == Array(standard.map { $0.title }.prefix(2)))
        #expect(UsageColumn.displayOrder.filter(usage.contains) == usage)
        // A card with less than every token keeps the same places and
        // titles, with what it has under Tokens.
        let inOut = PacerShareListColumn.count("inOut", title: "Tokens", format: .tokens,
                                               help: "Uncached input and output tokens")
        let limited = PacerShareListColumn.standard(tokens: inOut)
        #expect(limited.map { $0.title } == standard.map { $0.title })
        #expect(limited[0].id == "inOut")
        #expect(PacerShareListColumn.standard() == standard)
    }

    @Test("a donut list takes only amounts that add up: never a ratio, the label or Mix")
    func ratiosRejected() {
        for id in ["hitRate", "outShare", "mix", "name", "writeShare"] {
            #expect(!PacerShareListColumn.accepts(id: id), "\(id) is not an amount")
        }
        for column in UsageColumn.allCases where column.isAdditive {
            #expect(PacerShareListColumn.accepts(id: column.rawValue))
        }
        // A screen's own number adds up by contract (`shareValue`).
        #expect(PacerShareListColumn.accepts(id: "sessions"))
        // Every standard column a list can name is an amount.
        let usage: [UsageColumn] = Self.columns.compactMap { UsageColumn(rawValue: $0.id) }
        #expect(usage.allSatisfy { $0.isAdditive })
    }

    @Test("a sort the list has no column for (Hit %, Out %, a retired Sessions) runs by cost",
          arguments: ["hitRate", "outShare", "writeShare", "mix", "sessions", "lastActive"])
    func strayStoredSort(column: String) {
        let list = data(PacerUsageSort(column: column, descending: false))
        #expect(list.sort == .costDescending)
        #expect(list.rows.map(\.id) == ["b", "c", "a"])
        #expect(list.donut.metric == .cost)
        // The label and the list's own columns are kept as asked.
        let byName = PacerUsageSort(.name, descending: false)
        #expect(data(byName).sort == byName)
        let byTokens = PacerUsageSort(.tokens, descending: false)
        #expect(data(byTokens).sort == byTokens)
    }

    @Test("the list runs in its sort, both ways; the ring follows the sorted column")
    func sortAndRing() {
        let byCost = data(PacerUsageSort(.cost, descending: true))
        #expect(byCost.rows.map(\.id) == ["b", "c", "a"])
        #expect(byCost.donut.metric == .cost)

        let byTokens = data(PacerUsageSort(.tokens, descending: false))
        #expect(byTokens.rows.map(\.id) == ["b", "c", "a"])
        #expect(byTokens.donut.metric.title == "Tokens")
        // The ring runs largest first whichever way the list does.
        #expect(byTokens.donut.slices.map(\.id) == ["a", "c", "b"])

        let bySessions = data(PacerUsageSort(column: "sessions", descending: true), columns: Self.withSessions)
        #expect(bySessions.rows.map(\.id) == ["a", "c", "b"])
        #expect(bySessions.donut.metric.title == "Sessions")
    }

    @Test("a title click sorts by its column, largest first; a second click flips it")
    func titleClicks() {
        let byCost = data(.costDescending)
        #expect(byCost.sort(byColumn: "cost") == PacerUsageSort(.cost, descending: false))
        #expect(byCost.sort(byColumn: "tokens") == PacerUsageSort(.tokens, descending: true))
        // The label column starts A to Z, as a table's does.
        #expect(byCost.sort(byColumn: "name") == PacerUsageSort(.name, descending: false))
        // The ring's share is not a sort.
        #expect(!PacerShareListColumn.ringShare.isSortable)
        #expect(Self.columns.filter(\.isSortable).count == Self.columns.count - 1)
    }

    @Test("cells print as the usage table does, and Share is each row's part of the ring")
    func cells() throws {
        let byCost = data(.costDescending)
        let b = try #require(byCost.rows.first)
        let tokens = byCost.cell(.usage(.tokens), row: b)
        #expect(tokens.text == pacerTokens(160))
        #expect(tokens.text == UsageColumn.tokens.cellText(tokens: b.tokens, cost: b.cost,
                                                           costParts: b.costParts)?.text)
        let cost = byCost.cell(.usage(.cost), row: b)
        #expect(cost.text == pacerCost(6))
        #expect(cost.help == pacerCostExact(6))
        // b is 6 of 12 dollars.
        #expect(byCost.cell(.ringShare, row: b).text == "50%")
        // Sorted by output (a part the list may show), the ring is output,
        // and so is Share: b is 100 of 600 output tokens.
        let withOutput: [PacerShareListColumn] = Self.columns + [.usage(.output)]
        let byOutput = data(PacerUsageSort(.output, descending: true), columns: withOutput)
        let bOut = try #require(byOutput.rows.last)
        #expect(bOut.id == "b")
        #expect(byOutput.cell(.ringShare, row: bOut).text == "17%")
    }

    @Test("a share column prints each row's part of the whole, with the amounts in its tooltip")
    func shareColumns() throws {
        let shares: [PacerShareListColumn] = [
            .share(of: "cost", title: "Cost", format: .cost),
            .share(of: "sessions", title: "Sessions", format: .count),
        ]
        let list = data(.costDescending, columns: shares)
        let b = try #require(list.rows.first)
        let cost = list.cell(shares[0], row: b)
        #expect(cost.text == "50%")
        #expect(cost.help == "\(pacerCostExact(6)) of \(pacerCostExact(12))")
        // b has 5 of 35 sessions.
        let sessions = list.cell(shares[1], row: b)
        #expect(sessions.text == "14%")
        #expect(sessions.help == "5 of 35")
        // Sorting by a share column sorts by its amount, and turns the ring.
        let bySessions = data(PacerUsageSort(column: "sessions", descending: true), columns: shares)
        #expect(bySessions.rows.map(\.id) == ["a", "c", "b"])
        #expect(bySessions.donut.metric.title == "Sessions")
    }

    static func manyRows(_ n: Int) -> [PacerUsageRow<Project>] {
        (0..<n).map { i in
            PacerUsageRow(id: "p\(i)", label: "P\(i)", color: .orange,
                          tokens: TokenBreakdown(inputTokens: 10, outputTokens: Int64(n - i),
                                                 cacheReadTokens: 30),
                          costParts: CostComponents(input: Double(n - i)),
                          extra: Project(sessions: i + 1, lastActive: .distantPast))
        }
    }

    @Test("the list is the ring's legend: its named wedges, then the folded tail as one line")
    func otherLine() throws {
        let shares: [PacerShareListColumn] = [
            .share(of: "cost", title: "Cost", format: .cost),
            .share(of: "sessions", title: "Sessions", format: .count),
            .usage(.tokens), .usage(.cost),
        ]
        // Ascending: the five largest, smallest of them first; Other last.
        let list = data(PacerUsageSort(.cost, descending: false), rows: Self.manyRows(9),
                        columns: shares, maxSlices: 5)
        #expect(list.rows.map(\.id) == ["p4", "p3", "p2", "p1", "p0"])
        let other = try #require(list.other)
        #expect(other.label == "4 others")
        #expect(other.count == 4)
        // 4 + 3 + 2 + 1 of 45 dollars; sessions 6 + 7 + 8 + 9 of 45.
        #expect(other.cost == 10)
        #expect(list.otherCell(shares[0], other).text == "22%")
        #expect(list.otherCell(shares[1], other).text == "67%")
        // The tail's tokens summed: 4 rows of 10 input and 30 reads, and
        // 4 + 3 + 2 + 1 output.
        #expect(list.otherCell(shares[2], other).text == pacerTokens(170))
        #expect(list.otherCell(shares[3], other).text == pacerCost(10))
        #expect(list.donut.slices.last?.id == PacerShareDonutData.otherID)
        // Nothing to fold: every row listed, no Other.
        let few = data(.costDescending, rows: Self.manyRows(6), columns: shares, maxSlices: 5)
        #expect(few.rows.count == 6)
        #expect(few.other == nil)
    }
}
