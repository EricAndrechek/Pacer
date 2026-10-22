import AppKit
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

    @Test("the Mix bar is display only: no sort, no ring, no number, and a sort stored by it runs by cost")
    func mixBar() throws {
        let column = PacerShareListColumn.mixBar
        #expect(!column.isSortable)
        #expect(column.isFlexible)
        #expect(column.title == "Mix")
        #expect(column.help == UsageColumn.mix.headerHelp)
        // No usage column's id: nothing reads it as one.
        #expect(UsageColumn(storedId: column.id) == nil)
        let columns: [PacerShareListColumn] = Self.columns + [.mixBar]
        // The ring follows only amounts: a sort by the bar, or by the
        // table's Mix, runs by cost.
        for id in [column.id, UsageColumn.mix.rawValue] {
            let list = data(PacerUsageSort(column: id, descending: true), columns: columns)
            #expect(list.sort == .costDescending)
            #expect(list.donut.metric == .cost)
        }
        let list = data(.costDescending, columns: columns)
        let b = try #require(list.rows.first)
        #expect(list.cell(column, row: b).text == "")
        // The other columns are as they were without it.
        #expect(list.cell(.ringShare, row: b).text == "50%")
        #expect(list.columns.filter(\.isSortable).map(\.id) == ["tokens", "cost"])
    }

    @Test("the label column is as wide as its longest label, its title's at least, and no wider than its cap")
    func labelWidth() {
        func width(_ labels: [String], title: String = "Model") -> CGFloat {
            let rows: [Row] = labels.enumerated().map { i, label in
                Row(id: "r\(i)", label: label, tokens: TokenBreakdown(inputTokens: 1),
                    costParts: CostComponents(input: Double(i + 1)),
                    extra: Project(sessions: 1, lastActive: .distantPast))
            }
            return PacerShareList(data: data(.costDescending, rows: rows), labelTitle: title,
                                  onSort: { _ in }).labelWidth
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let longest: CGFloat = ("Sonnet 4.6" as NSString).size(withAttributes: [.font: font]).width
        let short: CGFloat = width(["Opus 4.7", "Sonnet 4.6", "Haiku 4.5"])
        // Room for the longest label, and not much more: the numbers sit
        // beside the names, not at the card's far edge.
        #expect(short >= longest)
        #expect(short <= longest + 4)
        #expect(short < width(["Opus 4.7", "Sonnet 4.6 with a much longer name"]))
        // Never under the title, never over the cap.
        #expect(width(["A"], title: "Project") >= width(["A"], title: "Model"))
        #expect(width([String(repeating: "x", count: 200)]) == PacerShareList<Project>.maxLabelWidth)
        #expect(width(["A"]) >= PacerShareList<Project>.minLabelWidth)
    }

    /// The list alone, and what its columns add up to.
    @MainActor
    private func listWidth(_ columns: [PacerShareListColumn]) -> (measured: CGFloat, expected: CGFloat) {
        let list = PacerShareList(data: data(.costDescending, columns: columns), labelTitle: "Project",
                                  onSort: { _ in })
        // Its ideal width, which is what it takes when offered more.
        let measured: CGFloat = NSHostingView(rootView: list).fittingSize.width
        let mix: CGFloat = PacerShareList<Project>.maxMixWidth
        let fixed: CGFloat = columns.reduce(CGFloat(0)) { $0 + ($1.isFlexible ? mix : $1.width) }
        let spacing: CGFloat = PacerShareList<Project>.columnSpacing * CGFloat(columns.count + 1)
        let insets: EdgeInsets = PacerShareList<Project>.rowPadding
        let padding: CGFloat = insets.leading + insets.trailing
        let dot: CGFloat = 8
        let label: CGFloat = list.labelWidth
        let expected: CGFloat = padding + dot + label + spacing + fixed
        return (measured, expected)
    }

    @Test("the list is as wide as its columns, not the card: a dashboard's width leaves no gap after the names")
    @MainActor
    func listHugs() {
        // A card a table follows: the shares, no Mix.
        let shares = listWidth(PacerShareListColumn.shares)
        #expect(abs(shares.measured - shares.expected) <= 1, "\(shares)")
        // Today by model: the standard columns and the Mix bar, which grows
        // to its cap and no further.
        let today = listWidth(PacerShareListColumn.standard + [.mixBar])
        #expect(abs(today.measured - today.expected) <= 1, "\(today)")
        #expect(today.measured < 2_000 / 2)
    }

    @Test("the donut card fits a modal and the narrowest window without overflowing", arguments: [CGFloat(612), 601])
    @MainActor
    func donutCardFits(width: CGFloat) throws {
        let long: [Row] = (0..<8).map { i in
            Row(id: "r\(i)", label: "a-project-with-a-very-long-name-\(i)", color: .orange,
                tokens: TokenBreakdown(inputTokens: 1_000, outputTokens: 2_000_000, cacheReadTokens: 900_000_000),
                costParts: CostComponents(input: 1, output: Double(800 - i), cacheRead: 400),
                extra: Project(sessions: 1, lastActive: .distantPast))
        }
        for columns in [PacerShareListColumn.shares, PacerShareListColumn.standard + [.mixBar]] {
            let card = PacerDonutListCard("Card", data: data(.costDescending, rows: long, columns: columns),
                                          labelTitle: "Project", accessibilityLabel: "", onSort: { _ in })
                .frame(width: width)
            let host = NSHostingView(rootView: card)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            host.layoutSubtreeIfNeeded()
            // The card takes the width it is given; nothing inside asks for
            // more than that.
            #expect(host.fittingSize.width <= width + 0.5)
            // What the figure needs at its narrowest, typed step by step
            // (Xcode 16 times out on one long mixed expression).
            let content: CGFloat = width - 2 * PacerDesign.cardPadding
            let donut: CGFloat = PacerDonutListCard<Project, EmptyView>.donutSize
                + PacerDonutListCard<Project, EmptyView>.spacing
            let insets: EdgeInsets = PacerShareList<Project>.rowPadding
            let padding: CGFloat = insets.leading + insets.trailing
            let gaps: CGFloat = PacerShareList<Project>.columnSpacing * CGFloat(columns.count + 1)
            let numbers: CGFloat = columns.reduce(CGFloat(0)) { $0 + $1.width }
            let dot: CGFloat = 8
            let label: CGFloat = PacerShareList<Project>.minLabelWidth
            let least: CGFloat = donut + padding + dot + label + gaps + numbers
            #expect(least <= content, "the list's least, \(least)pt, overflows \(content)pt")
        }
    }
}
