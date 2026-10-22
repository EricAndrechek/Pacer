import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// The list beside a donut card's ring (`PacerShareListData`): a click on a
// column title sorts the list and turns the ring to that column when its
// values add up; the list is the ring's legend, folded tail included; and a
// share column prints each row's part of the whole.

@Suite("Donut card list")
struct ShareListTests {

    typealias Project = ShareDonutTests.Project
    typealias Row = PacerUsageRow<Project>

    /// The donut tests' three rows: different orders by cost (b, c, a), by
    /// output (a, c, b) and by sessions (a, c, b), and by Hit %:
    /// a 0/10, b 50/60, c 20/30 cache reads over prompt tokens.
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

    static let columns: [PacerShareListColumn] = [
        .usage(.tokens), .usage(.cacheHitRate), .usage(.outputShare), .usage(.cost), .ringShare,
    ]

    func data(_ sort: PacerUsageSort, rows: [Row] = ShareListTests.rows(),
              columns: [PacerShareListColumn] = ShareListTests.columns,
              maxSlices: Int = .max) -> PacerShareListData<Project> {
        PacerShareListData(rows: rows, sort: sort, columns: columns, maxSlices: maxSlices)
    }

    @Test("the list runs in its sort, both ways; the ring follows the sorted column when it adds up")
    func sortAndRing() {
        let byCost = data(PacerUsageSort(.cost, descending: true))
        #expect(byCost.rows.map(\.id) == ["b", "c", "a"])
        #expect(byCost.donut.metric == .cost)

        let byTotal = data(PacerUsageSort(.tokens, descending: false))
        #expect(byTotal.rows.map(\.id) == ["b", "c", "a"])
        #expect(byTotal.donut.metric.title == "Tokens")
        // The ring runs largest first whichever way the list does.
        #expect(byTotal.donut.slices.map(\.id) == ["a", "c", "b"])

        let bySessions = data(PacerUsageSort(column: "sessions", descending: true))
        #expect(bySessions.rows.map(\.id) == ["a", "c", "b"])
        #expect(bySessions.donut.metric.title == "Sessions")
    }

    @Test("Hit % sorts the list by the hit rate and leaves the ring on cost",
          arguments: [true, false])
    func hitRateSort(descending: Bool) {
        let byHit = data(PacerUsageSort(.cacheHitRate, descending: descending))
        // b 50/60, c 20/30, a 0/10.
        let expected: [String] = ["a", "c", "b"]
        #expect(byHit.rows.map(\.id) == (descending ? expected.reversed() : expected))
        #expect(byHit.donut.metric == .cost)
        #expect(byHit.donut.slices.map(\.id) == ["b", "c", "a"])
    }

    @Test("a title click sorts by its column, largest first; a second click flips it")
    func titleClicks() {
        let byCost = data(.costDescending)
        #expect(byCost.sort(byColumn: "cost") == PacerUsageSort(.cost, descending: false))
        #expect(byCost.sort(byColumn: "tokens") == PacerUsageSort(.tokens, descending: true))
        #expect(byCost.sort(byColumn: "hitRate") == PacerUsageSort(.cacheHitRate, descending: true))
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
        let total = byCost.cell(.usage(.tokens), row: b)
        #expect(total.text == pacerTokens(160))
        let hit = byCost.cell(.usage(.cacheHitRate), row: b)
        // 50 reads of 10 input + 50 reads.
        #expect(hit.text == pacerCacheHitText(50.0 / 60.0))
        let cost = byCost.cell(.usage(.cost), row: b)
        #expect(cost.text == pacerCost(6))
        // b is 6 of 12 dollars.
        #expect(byCost.cell(.ringShare, row: b).text == "50%")
        // Sorted by output, the ring is output, and so is Share: b is 100 of
        // 600 output tokens.
        let byOutput = data(PacerUsageSort(.output, descending: true))
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
            .usage(.cacheHitRate), .usage(.cost),
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
        // A ratio of the tail's sums: 120 reads of 40 input + 120 reads.
        #expect(list.otherCell(shares[2], other).text == pacerCacheHitText(0.75))
        #expect(list.otherCell(shares[3], other).text == pacerCost(10))
        #expect(list.donut.slices.last?.id == PacerShareDonutData.otherID)
        // Nothing to fold: every row listed, no Other.
        let few = data(.costDescending, rows: Self.manyRows(6), columns: shares, maxSlices: 5)
        #expect(few.rows.count == 6)
        #expect(few.other == nil)
    }
}
