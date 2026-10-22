import AppKit
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// The list beside a donut card's ring (`PacerShareListData`): every card's
// columns are Mix, Tokens, Cost and Share, and no card has others; nothing
// that does not add up is a number or a ring; a click on a column title sorts
// the list and turns the ring to that column; the list is the ring's legend,
// folded tail included; and the list fills the card beside the ring, its Mix
// bar taking the spare width.

@Suite("Donut card list")
struct ShareListTests {

    typealias Project = ShareDonutTests.Project
    typealias Row = PacerUsageRow<Project>

    /// The donut tests' three rows: different orders by cost (b, c, a), by
    /// output (a, c, b) and by sessions (a, c, b), with cache reads (a 0,
    /// b 50, c 20) so Tokens orders them b, c, a ascending (160, 230, 310).
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

    func data(_ sort: PacerUsageSort, rows: [Row] = ShareListTests.rows(),
              maxSlices: Int = .max) -> PacerShareListData<Project> {
        PacerShareListData(rows: rows, sort: sort, maxSlices: maxSlices)
    }

    @Test("every donut list has Mix, Tokens, Cost and Share: Mix first, then the tables' titles in the tables' order")
    func standardColumns() {
        let standard = PacerShareListColumn.standard
        #expect(standard.map { $0.title } == ["Mix", "Tokens", "Cost", "Share"])
        #expect(standard.map { $0.id } == [PacerShareListColumn.mixBar.id, UsageColumn.tokens.rawValue,
                                          UsageColumn.cost.rawValue, PacerShareListColumn.ringShare.id])
        // The amounts under the titles a table gives them, in the order a
        // table lays them out.
        let usage: [UsageColumn] = standard.compactMap { UsageColumn(rawValue: $0.id) }
        #expect(usage == [.tokens, .cost])
        #expect(usage.map { $0.title(label: "") } == ["Tokens", "Cost"])
        #expect(UsageColumn.displayOrder.filter(usage.contains) == usage)
        // Every card reads the one set.
        #expect(data(.costDescending).columns == standard)
        // Mix is the one column that takes the spare width, and the first
        // after the name.
        #expect(standard.filter(\.isFlexible).map(\.id) == [PacerShareListColumn.mixBar.id])
        #expect(standard.first?.isFlexible == true)
    }

    @Test("a donut list's numbers are amounts that add up; its Mix is a bar, never a number")
    func amountsOnly() {
        let usage: [UsageColumn] = PacerShareListColumn.standard.compactMap { UsageColumn(rawValue: $0.id) }
        #expect(usage.allSatisfy { $0.isAdditive })
        #expect(!usage.contains { $0.isRatio })
        // The list's own two (the bar and the ring's share) are no usage
        // column's id, so nothing reads them as one.
        for column in [PacerShareListColumn.mixBar, PacerShareListColumn.ringShare] {
            #expect(UsageColumn(storedId: column.id) == nil)
        }
    }

    @Test("a sort the list has no column for (Hit %, Out %, Mix, a retired Sessions) runs by cost",
          arguments: ["hitRate", "outShare", "writeShare", "mix", "__mixBar__", "__ringShare__", "sessions",
                      "lastActive", "output"])
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
    }

    @Test("a title click sorts by its column, largest first; a second click flips it")
    func titleClicks() {
        let byCost = data(.costDescending)
        #expect(byCost.sort(byColumn: "cost") == PacerUsageSort(.cost, descending: false))
        #expect(byCost.sort(byColumn: "tokens") == PacerUsageSort(.tokens, descending: true))
        // The label column starts A to Z, as a table's does.
        #expect(byCost.sort(byColumn: "name") == PacerUsageSort(.name, descending: false))
        // Neither the ring's share nor the Mix bar is a sort.
        #expect(!PacerShareListColumn.ringShare.isSortable)
        #expect(!PacerShareListColumn.mixBar.isSortable)
        #expect(byCost.columns.filter(\.isSortable).map(\.id) == ["tokens", "cost"])
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
        #expect(byCost.cell(.ringShare, row: b).help == "Share of the cost")
        // Sorted by tokens, the ring is tokens, and so is Share: b has 160 of
        // the rows' 700 tokens.
        let byTokens = data(PacerUsageSort(.tokens, descending: true))
        let bTokens = try #require(byTokens.rows.first { $0.id == "b" })
        #expect(byTokens.cell(.ringShare, row: bTokens).text == "23%")
        // The Mix bar draws itself: no text.
        #expect(byCost.cell(.mixBar, row: b).text == "")
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
        // Ascending: the five largest, smallest of them first; Other last.
        let list = data(PacerUsageSort(.cost, descending: false), rows: Self.manyRows(9), maxSlices: 5)
        #expect(list.rows.map(\.id) == ["p4", "p3", "p2", "p1", "p0"])
        let other = try #require(list.other)
        #expect(other.label == "4 others")
        #expect(other.count == 4)
        // 4 + 3 + 2 + 1 of 45 dollars.
        #expect(other.cost == 10)
        #expect(list.otherCell(.ringShare, other).text == "22%")
        // The tail's tokens summed: 4 rows of 10 input and 30 reads, and
        // 4 + 3 + 2 + 1 output.
        #expect(list.otherCell(.usage(.tokens), other).text == pacerTokens(170))
        #expect(list.otherCell(.usage(.cost), other).text == pacerCost(10))
        #expect(list.otherCell(.mixBar, other).text == "")
        #expect(list.donut.slices.last?.id == PacerShareDonutData.otherID)
        // Nothing to fold: every row listed, no Other.
        let few = data(.costDescending, rows: Self.manyRows(6), maxSlices: 5)
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
        // The ring follows only amounts: a sort by the bar, or by the
        // table's Mix, runs by cost.
        for id in [column.id, UsageColumn.mix.rawValue] {
            let list = data(PacerUsageSort(column: id, descending: true))
            #expect(list.sort == .costDescending)
            #expect(list.donut.metric == .cost)
        }
        // Its least is the list's least bar, and it grows to a cap.
        #expect(column.width == PacerShareListMetrics.minMixWidth)
        #expect(PacerShareListMetrics.maxMixWidth > PacerShareListMetrics.minMixWidth)
    }

    @Test("the label column is as wide as its longest label, its title's at least, and no wider than its cap")
    @MainActor
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
        // Room for the longest label, and not much more: the bar starts just
        // past the names, not after a gap.
        #expect(short >= longest)
        #expect(short <= longest + 4)
        #expect(short < width(["Opus 4.7", "Sonnet 4.6 with a much longer name"]))
        // Never under the title, never over the cap.
        #expect(width(["A"], title: "Project") >= width(["A"], title: "Model"))
        #expect(width([String(repeating: "x", count: 200)]) == PacerShareListMetrics.maxLabelWidth)
        #expect(width(["A"]) >= PacerShareListMetrics.minLabelWidth)
    }

    /// What the list's fixed parts take: the row's padding, the colour dot,
    /// the gaps between columns and the number columns at their own widths.
    /// Everything but the label and the Mix bar.
    static var fixedWidth: CGFloat {
        let columns: [PacerShareListColumn] = PacerShareListColumn.standard
        let numbers: CGFloat = columns.filter { !$0.isFlexible }.reduce(CGFloat(0)) { $0 + $1.width }
        let gaps: CGFloat = PacerShareListMetrics.columnSpacing * CGFloat(columns.count + 1)
        let insets: EdgeInsets = PacerShareListMetrics.rowPadding
        let padding: CGFloat = insets.leading + insets.trailing
        let dot: CGFloat = 8
        return padding + dot + gaps + numbers
    }

    @Test("the list's ideal is its columns at their own widths and the Mix bar at its widest")
    @MainActor
    func listIdeal() {
        let list = PacerShareList(data: data(.costDescending), labelTitle: "Project", onSort: { _ in })
        // Its ideal width, which is what it takes when offered nothing in
        // particular.
        let measured: CGFloat = NSHostingView(rootView: list).fittingSize.width
        let mix: CGFloat = PacerShareListMetrics.maxMixWidth
        let expected: CGFloat = Self.fixedWidth + list.labelWidth + mix
        #expect(abs(measured - expected) <= 1, "measured \(measured), expected \(expected)")
    }

    @Test("beside the ring the list fills the card: the Mix bar takes the spare width up to its cap, then the numbers",
          arguments: [CGFloat(572), 672, 761, 1312])
    @MainActor
    func listFillsCard(content: CGFloat) throws {
        // A card's content at a modal's width (Day, Project detail), the
        // dashboard's and a wide window's: the list is offered what the
        // ring leaves.
        let ring: CGFloat = PacerDonutListCard<Project, EmptyView>.donutSize
            + PacerDonutListCard<Project, EmptyView>.spacing
        let offered: CGFloat = content - ring
        let list = PacerShareList(data: data(.costDescending, rows: Self.manyRows(6)), labelTitle: "Model",
                                  onSort: { _ in })
        let size: CGSize = NSHostingController(rootView: list)
            .sizeThatFits(in: CGSize(width: offered, height: 1_000))
        // The most it takes: its label, the bar at its cap and the numbers
        // at their stretch.
        let stretch: CGFloat = PacerShareListMetrics.maxNumberStretch
        let numbers: CGFloat = PacerShareListColumn.standard.filter { !$0.isFlexible }
            .reduce(CGFloat(0)) { $0 + $1.width }
        let most: CGFloat = Self.fixedWidth + numbers * (stretch - 1) + list.labelWidth
            + PacerShareListMetrics.maxMixWidth
        let expected: CGFloat = Swift.min(offered, most)
        #expect(abs(size.width - expected) <= 1, "offered \(offered): list \(size.width), expected \(expected)")
        // No band at the right of a modal's card or the dashboard's.
        if content <= 761 { #expect(abs(size.width - offered) <= 1) }
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
        let card = PacerDonutListCard("Card", data: data(.costDescending, rows: long),
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
        let label: CGFloat = PacerShareListMetrics.minLabelWidth
        let mix: CGFloat = PacerShareListMetrics.minMixWidth
        let least: CGFloat = donut + Self.fixedWidth + label + mix
        #expect(least <= content, "the list's least, \(least)pt, overflows \(content)pt")
    }
}
