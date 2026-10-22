import AppKit
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// The shared usage table hosted off-screen, measured against the real
// `NSTableView` SwiftUI builds for it: the frame it sets itself fits its rows,
// its columns start as specified per table and fit the cards they live in,
// the column layout a user makes (visibility, order) survives into the next
// table with the same id — a layout saved by the round-1 table included —
// "Reset columns" undoes it, and the header is the system's own.
//
// The host is an `NSHostingView` in a borderless window that is never
// ordered in. Without a window the table does not make its cell views, and
// it is the cells that size a row.

@MainActor
@Suite("Usage table, hosted", .serialized)
struct UsageTableLayoutTests {

    // MARK: Harness

    private struct Harness: View {
        let rows: [PacerUsageRow<PacerUsageNoExtra>]
        let tableId: String
        let store: UserDefaults
        var defaults: Set<UsageColumn> = UsageColumn.wideDefaults
        var width: CGFloat = 900
        var body: some View {
            PacerUsageTable(rows: rows, tableId: tableId, labelTitle: "Model",
                            sort: .costDescending, onSort: { _ in },
                            defaultColumns: defaults, store: store)
                .frame(width: width)
        }
    }

    private final class Hosted {
        let host: NSView
        let window: NSWindow
        init(host: NSView, window: NSWindow) {
            self.host = host
            self.window = window
        }
    }

    private static func rows(_ n: Int, subtitles: Bool) -> [PacerUsageRow<PacerUsageNoExtra>] {
        (0..<n).map { i in
            PacerUsageRow(
                id: "model-\(i)",
                label: "Model \(i)",
                subtitle: subtitles ? "claude-model-\(i)" : nil,
                tokens: TokenBreakdown(inputTokens: Int64(i + 1), outputTokens: 2,
                                       cacheReadTokens: 3, cacheCreation5mTokens: 4,
                                       cacheCreation1hTokens: 5),
                costParts: CostComponents(input: 0.25, output: Double(i)))
        }
    }

    private static func store() -> (UserDefaults, String) {
        let name = "pacer.tests.usageTable.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private static func host(_ view: some View, width: CGFloat = 900) -> Hosted {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: -60_000, y: -60_000, width: width, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        settle(host)
        return Hosted(host: host, window: window)
    }

    /// Lay out, make every cell, and let SwiftUI's run-loop work (a reset's
    /// rebuild, a selection's `onChange`) land.
    private static func settle(_ host: NSView) {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            if let table = table(in: host) {
                for row in 0..<table.numberOfRows {
                    for column in 0..<table.numberOfColumns {
                        _ = table.view(atColumn: column, row: row, makeIfNecessary: true)
                    }
                }
                table.noteHeightOfRows(withIndexesChanged: IndexSet(0..<table.numberOfRows))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        host.layoutSubtreeIfNeeded()
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let found = table(in: sub) { return found }
        }
        return nil
    }

    private static func column(_ title: String, in table: NSTableView) -> NSTableColumn? {
        table.tableColumns.first { $0.title == title }
    }

    private static func visibleTitles(_ table: NSTableView) -> [String] {
        table.tableColumns.filter { !$0.isHidden }.map(\.title)
    }

    /// `columns`' titles in the order a table lays them out
    /// (`UsageColumn.displayOrder`, which takes the parts' order from
    /// `CostComponent`): what a fresh table shows, never written out by hand.
    static func titles(_ columns: Set<UsageColumn>, label: String = "Model") -> [String] {
        UsageColumn.displayOrder.filter(columns.contains).map { $0.title(label: label) }
    }

    /// The wide defaults' token parts, in display order.
    static var wideParts: [String] {
        titles(UsageColumn.wideDefaults.subtracting([.name, .tokens, .cost]))
    }

    // MARK: Height

    @Test("a short table shows every row with nothing to scroll",
          arguments: [(1, false), (5, false), (3, true), (9, true)])
    func fitsItsRows(count: Int, subtitles: Bool) throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let hosted = Self.host(Harness(rows: Self.rows(count, subtitles: subtitles),
                                       tableId: "fit", store: store))
        let table = try #require(Self.table(in: hosted.host))
        let clip = try #require(table.enclosingScrollView?.contentView)
        #expect(table.numberOfRows == count)
        let last: NSRect = table.rect(ofRow: count - 1)
        // The clip view runs under the header and insets its content by it.
        let visible: CGFloat = clip.bounds.height - clip.contentInsets.top
        // Every row inside the visible area, and the table no taller than
        // it: nothing clipped, nothing to scroll.
        #expect(last.maxY <= visible)
        #expect(table.bounds.height <= visible)
        // And not a gaping margin under the last row either (the inset
        // style's own bottom padding plus the slack).
        let margin: CGFloat = visible - last.maxY
        #expect(margin <= 16, "rows end \(margin)pt above the table's bottom")
        // The row height the frame was computed from is the one laid out.
        let expected: CGFloat = PacerUsageTableMetrics.rowHeight(twoLine: subtitles)
        #expect(last.height == expected)
    }

    @Test("a long table stops at the cap and scrolls inside")
    func capsLongLists() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let count = PacerUsageTableMetrics.defaultMaxVisibleRows + 20
        let hosted = Self.host(Harness(rows: Self.rows(count, subtitles: false),
                                       tableId: "cap", store: store))
        let table = try #require(Self.table(in: hosted.host))
        let clip = try #require(table.enclosingScrollView?.contentView)
        let cap: CGFloat = PacerUsageTableMetrics.height(rowCount: count, twoLine: false)
        #expect(hosted.host.fittingSize.height == cap)
        #expect(table.bounds.height > clip.bounds.height - clip.contentInsets.top)
    }

    // MARK: Columns

    @Test("a wide table: the token parts in the parts' order, total and cost; the tiers, ratios and Mix hidden")
    func wideDefaults() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let hosted = Self.host(Harness(rows: Self.rows(2, subtitles: false),
                                       tableId: "columns", store: store))
        let table = try #require(Self.table(in: hosted.host))
        let titles: [String] = table.tableColumns.map(\.title)
        #expect(titles == Self.titles(Set(UsageColumn.allCases)))
        // The parts run in `CostComponent`'s order, Cache write before its
        // tiers, then Total, Hit %, Out %, Cost and Mix.
        let parts: [String] = UsageColumn.partColumns.map { $0.title(label: "Model") }
        #expect(Array(titles.dropFirst().prefix(6)) == parts)
        #expect(Array(titles.suffix(5)) == ["Total", "Hit %", "Out %", "Cost", "Mix"])
        #expect(titles.contains("Uncached"))
        let hidden: [String] = table.tableColumns.filter(\.isHidden).map(\.title)
        #expect(hidden == Self.titles([.cacheWrite5m, .cacheWrite1h, .cacheHitRate, .outputShare, .mix]))
        // Every column sorts.
        let unsortable: [String] = table.tableColumns
            .filter { $0.sortDescriptorPrototype == nil }.map(\.title)
        #expect(unsortable.isEmpty)
        // Numbers sort largest first on a first click, the label A to Z.
        let model = try #require(Self.column("Model", in: table))
        let ratio = try #require(Self.column("Hit %", in: table))
        let cost = try #require(Self.column("Cost", in: table))
        #expect(model.sortDescriptorPrototype?.ascending == true)
        #expect(ratio.sortDescriptorPrototype?.ascending == false)
        #expect(cost.sortDescriptorPrototype?.ascending == false)
    }

    @Test("a narrow table: Total, Hit %, Out % and Cost")
    func narrowDefaults() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let hosted = Self.host(Harness(rows: Self.rows(2, subtitles: false), tableId: "narrow",
                                       store: store, defaults: UsageColumn.narrowDefaults))
        let table = try #require(Self.table(in: hosted.host))
        #expect(Self.visibleTitles(table) == ["Model", "Total", "Hit %", "Out %", "Cost"])
    }

    @Test("the header lets the user reorder, resize, and hide every column but the label")
    func customizable() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let hosted = Self.host(Harness(rows: Self.rows(2, subtitles: false),
                                       tableId: "custom", store: store))
        let table = try #require(Self.table(in: hosted.host) as? NSOutlineView)
        #expect(table.allowsColumnReordering)
        #expect(table.allowsColumnResizing)
        // AppKit's own header menu (macOS 14) lists the columns its delegate
        // says the user may hide; SwiftUI answers from `customizationID` and
        // `disabledCustomizationBehavior`.
        let delegate = try #require(table.delegate)
        var hideable: [String] = []
        for column in table.tableColumns
        where delegate.outlineView?(table, userCanChangeVisibilityOf: column) == true {
            hideable.append(column.title)
        }
        #expect(hideable == Array(Self.titles(Set(UsageColumn.allCases)).dropFirst()))
    }

    // MARK: Persistence

    @Test("a layout the user makes is the next table's layout")
    func layoutPersists() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let first = Self.host(Harness(rows: Self.rows(2, subtitles: false),
                                      tableId: "persist", store: store))
        let table = try #require(Self.table(in: first.host) as? NSOutlineView)
        let delegate = try #require(table.delegate)

        // What AppKit does when the user drags Cost to second place and
        // ticks "Hit %" on in the header menu.
        let costIndex = try #require(table.tableColumns.firstIndex { $0.title == "Cost" })
        table.moveColumn(costIndex, toColumn: 1)
        let ratio = try #require(Self.column("Hit %", in: table))
        ratio.isHidden = false
        delegate.outlineView?(table, userDidChangeVisibilityOf: [ratio])
        Self.settle(first.host)

        let key = PacerUsageTableMetrics.columnsKey(tableId: "persist")
        let data = try #require(store.data(forKey: key))
        let saved = try JSONDecoder().decode(
            TableColumnCustomization<PacerUsageRow<PacerUsageNoExtra>>.self, from: data)
        #expect(saved[visibility: UsageColumn.cacheHitRate.rawValue] == .visible)

        let second = Self.host(Harness(rows: Self.rows(2, subtitles: false),
                                       tableId: "persist", store: store))
        let reopened = try #require(Self.table(in: second.host))
        #expect(Self.visibleTitles(reopened) == ["Model", "Cost"] + Self.wideParts + ["Total", "Hit %"])

        // A different table id keeps its own, default, layout.
        let other = Self.host(Harness(rows: Self.rows(2, subtitles: false),
                                      tableId: "persist-other", store: store))
        let untouched = try #require(Self.table(in: other.host))
        #expect(Self.visibleTitles(untouched) == Self.titles(UsageColumn.wideDefaults))
    }

    /// What the round-1 table stored after its user dragged Cost to second
    /// place, hid Input and widened Total: `TableColumnCustomization`'s own
    /// JSON, captured from that build. The owner has an install with layouts
    /// like it.
    static let round1Layout = #"{"columnOrder":[{"base":{"explicit":{"_0":"name"}}},{"base":{"explicit":{"_0":"cost"}}},{"base":{"explicit":{"_0":"input"}}},{"base":{"explicit":{"_0":"output"}}},{"base":{"explicit":{"_0":"cacheRead"}}},{"base":{"explicit":{"_0":"cacheWrite"}}},{"base":{"explicit":{"_0":"cacheWrite5m"}}},{"base":{"explicit":{"_0":"cacheWrite1h"}}},{"base":{"explicit":{"_0":"tokens"}}}],"perColumnState":[{"base":{"explicit":{"_0":"output"}}},{"visibility":{"automatic":{}},"currentWidth":108},{"base":{"explicit":{"_0":"name"}}},{"visibility":{"automatic":{}},"currentWidth":202},{"base":{"explicit":{"_0":"input"}}},{"visibility":{"hidden":{}},"currentWidth":85},{"base":{"explicit":{"_0":"tokens"}}},{"visibility":{"automatic":{}},"currentWidth":90},{"base":{"explicit":{"_0":"cost"}}},{"visibility":{"automatic":{}},"currentWidth":113},{"base":{"explicit":{"_0":"cacheRead"}}},{"visibility":{"automatic":{}},"currentWidth":126},{"base":{"explicit":{"_0":"cacheWrite"}}},{"visibility":{"automatic":{}},"currentWidth":130}]}"#

    @Test("a layout saved by the round-1 table still loads; the new columns follow the defaults",
          arguments: [false, true])
    func round1LayoutLoads(narrow: Bool) throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let data = Data(Self.round1Layout.utf8)
        // It decodes as the type the table stores.
        let decoded = try JSONDecoder().decode(
            TableColumnCustomization<PacerUsageRow<PacerUsageNoExtra>>.self, from: data)
        #expect(decoded[visibility: UsageColumn.input.rawValue] == .hidden)
        store.set(data, forKey: PacerUsageTableMetrics.columnsKey(tableId: "round1"))

        let defaults = narrow ? UsageColumn.narrowDefaults : UsageColumn.wideDefaults
        let hosted = Self.host(Harness(rows: Self.rows(2, subtitles: false), tableId: "round1",
                                       store: store, defaults: defaults))
        let table = try #require(Self.table(in: hosted.host))
        // The user's order and their hidden Input survive; the columns it
        // never knew come after it, shown or hidden by this table's defaults.
        // Token columns it left on "automatic" follow the defaults too, which
        // is how a narrow table drops them.
        let expected: [String] = narrow
            ? ["Model", "Cost", "Total", "Hit %", "Out %"]
            : ["Model", "Cost", "Output", "Cache read", "Cache write", "Total"]
        #expect(Self.visibleTitles(table) == expected)
    }

    @Test("a saved layout naming a column the table no longer has still loads")
    func layoutWithRetiredColumn() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        // Today by model had a Share column in round 1; the donut is the
        // share now, and the column is gone.
        let share = #"{"base":{"explicit":{"_0":"share"}}}"#
        let json: String = Self.round1Layout
            .replacingOccurrences(of: #""columnOrder":["#, with: #""columnOrder":["# + share + ",")
            .replacingOccurrences(of: #""perColumnState":["#,
                                  with: #""perColumnState":["# + share + #",{"visibility":{"automatic":{}},"currentWidth":48},"#)
        store.set(Data(json.utf8), forKey: PacerUsageTableMetrics.columnsKey(tableId: "retired"))
        let hosted = Self.host(Harness(rows: Self.rows(2, subtitles: false), tableId: "retired",
                                       store: store, defaults: UsageColumn.narrowDefaults))
        let table = try #require(Self.table(in: hosted.host))
        #expect(Self.visibleTitles(table) == ["Model", "Cost", "Total", "Hit %", "Out %"])
    }

    /// A saved layout with the wide defaults in their order, every column
    /// `width` wide (the label twice that): what a table left in a much
    /// wider, or narrower, window stores.
    static func wideLayout(width: CGFloat) -> String {
        let ids: [String] = UsageColumn.displayOrder.filter(UsageColumn.wideDefaults.contains).map(\.rawValue)
        let order: String = ids.map { #"{"base":{"explicit":{"_0":"\#($0)"}}}"# }.joined(separator: ",")
        let state: String = ids.map { id in
            let w: Int = Int(id == "name" ? width * 2 : width)
            return #"{"base":{"explicit":{"_0":"\#(id)"}}},{"visibility":{"automatic":{}},"currentWidth":\#(w)}"#
        }.joined(separator: ",")
        return #"{"columnOrder":[\#(order)],"perColumnState":[\#(state)]}"#
    }

    @Test("a layout saved in a wider window is refitted, not scrolled: proportions kept, saved fitted",
          arguments: [CGFloat(900), 600, 420])
    func savedTooWideRefits(width: CGFloat) throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let key = PacerUsageTableMetrics.columnsKey(tableId: "too-wide")
        store.set(Data(Self.wideLayout(width: 180).utf8), forKey: key)
        let hosted = Self.host(Harness(rows: Self.rows(3, subtitles: true), tableId: "too-wide",
                                       store: store, width: width), width: width)
        let table = try #require(Self.table(in: hosted.host))
        let clip = try #require(table.enclosingScrollView?.contentView)
        // SwiftUI restored 180pt columns (and a 360pt label): far wider than
        // any of these. The fitter brought them back inside.
        #expect(table.frame.width <= clip.bounds.width + 0.5,
                "columns \(table.frame.width)pt wide in \(clip.bounds.width)pt")
        let visible: [NSTableColumn] = table.tableColumns.filter { !$0.isHidden }
        #expect(visible.map(\.title) == Self.titles(UsageColumn.wideDefaults))
        // The user's proportions survive the fit: the label they made twice
        // as wide is still the widest, and the rest are alike.
        let label = try #require(visible.first)
        let numbers: [CGFloat] = visible.dropFirst().map(\.width)
        #expect(numbers.allSatisfy { label.width > $0 })
        #expect((numbers.max() ?? 0) - (numbers.min() ?? 0) <= 1)
        // The fitted widths are what is saved now, so the next table opens
        // fitted rather than fitting again.
        let data = try #require(store.data(forKey: key))
        let saved = try #require(String(data: data, encoding: .utf8))
        #expect(!saved.contains("\"currentWidth\":180"))
    }

    @Test("a layout saved in a narrower window fills the card rather than leaving a gap")
    func savedTooNarrowFills() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.set(Data(Self.wideLayout(width: 40).utf8),
                  forKey: PacerUsageTableMetrics.columnsKey(tableId: "too-narrow"))
        let width: CGFloat = 900
        let hosted = Self.host(Harness(rows: Self.rows(3, subtitles: false), tableId: "too-narrow",
                                       store: store, width: width), width: width)
        let table = try #require(Self.table(in: hosted.host))
        let clip = try #require(table.enclosingScrollView?.contentView)
        let columns: [Int] = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
        let first: NSRect = table.rect(ofColumn: try #require(columns.first))
        let last: NSRect = table.rect(ofColumn: try #require(columns.last))
        // The columns run from the inset on the left to the inset on the
        // right: no empty band after the last one.
        let gap: CGFloat = clip.bounds.width - last.maxX - first.minX
        #expect(abs(gap) <= 1, "\(gap)pt after the last column")
    }

    @Test("a layout that showed Write % shows Hit % in its place; the stored layout is renamed")
    func writeShareLayoutBecomesHitRate() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        // The round-1 layout, with Write % shown by hand (a wide table hides
        // it by default) and dragged to third place.
        let share = #"{"base":{"explicit":{"_0":"writeShare"}}}"#
        let json: String = Self.round1Layout
            .replacingOccurrences(of: #""columnOrder":[{"base":{"explicit":{"_0":"name"}}},"#,
                                  with: #""columnOrder":[{"base":{"explicit":{"_0":"name"}}},"# + share + ",")
            .replacingOccurrences(of: #""perColumnState":["#,
                                  with: #""perColumnState":["# + share + #",{"visibility":{"visible":{}},"currentWidth":61},"#)
        let key = PacerUsageTableMetrics.columnsKey(tableId: "write-share")
        store.set(Data(json.utf8), forKey: key)
        let hosted = Self.host(Harness(rows: Self.rows(2, subtitles: false), tableId: "write-share",
                                       store: store))
        let table = try #require(Self.table(in: hosted.host))
        // Hit % where the user put Write %: shown, second, before Cost.
        #expect(Self.visibleTitles(table) == ["Model", "Hit %", "Cost", "Output", "Cache read",
                                              "Cache write", "Total"])
        let stored: Data = try #require(store.data(forKey: key))
        let saved: String = try #require(String(data: stored, encoding: .utf8))
        #expect(!saved.contains("writeShare"))
        #expect(saved.contains("hitRate"))
        let decoded = try JSONDecoder().decode(
            TableColumnCustomization<PacerUsageRow<PacerUsageNoExtra>>.self, from: Data(saved.utf8))
        #expect(decoded[visibility: UsageColumn.cacheHitRate.rawValue] == .visible)
    }

    @Test("renaming a retired id: only when there is one, never onto an id already there")
    func migratedLayout() throws {
        let plain = Data(Self.round1Layout.utf8)
        #expect(PacerUsageTableMetrics.migratedLayout(plain) == nil)
        let old = Data(Self.round1Layout.replacingOccurrences(of: "\"cacheRead\"", with: "\"writeShare\"").utf8)
        let migrated = try #require(PacerUsageTableMetrics.migratedLayout(old))
        let text = try #require(String(data: migrated, encoding: .utf8))
        #expect(text == Self.round1Layout.replacingOccurrences(of: "\"cacheRead\"", with: "\"hitRate\""))
        // Both ids in one layout: renaming would give one id two entries,
        // which does not decode, so it is left alone.
        let both = Data((Self.round1Layout.replacingOccurrences(of: "\"cacheRead\"", with: "\"writeShare\"")
            .replacingOccurrences(of: "\"cacheWrite\"", with: "\"hitRate\"")).utf8)
        #expect(PacerUsageTableMetrics.migratedLayout(both) == nil)
    }

    @Test("the stored layout encodes and decodes to the same visibility and order")
    func codableRoundTrip() throws {
        typealias Customization = TableColumnCustomization<PacerUsageRow<PacerUsageNoExtra>>
        var layout = Customization()
        layout[visibility: UsageColumn.input.rawValue] = .hidden
        layout[visibility: UsageColumn.mix.rawValue] = .visible
        let data: Data = try JSONEncoder().encode(layout)
        let back: Customization = try JSONDecoder().decode(Customization.self, from: data)
        #expect(back == layout)
        #expect(back[visibility: UsageColumn.input.rawValue] == .hidden)
        #expect(back[visibility: UsageColumn.mix.rawValue] == .visible)
        #expect(back[visibility: UsageColumn.cost.rawValue] == .automatic)
    }

    // MARK: Look

    @Test("the header is the system's: its own cells and dividers, the sort marked natively")
    func nativeHeader() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let hosted = Self.host(Harness(rows: Self.rows(3, subtitles: true),
                                       tableId: "native", store: store))
        let table = try #require(Self.table(in: hosted.host))
        // Nothing of Pacer's in the header: every cell is the one SwiftUI
        // made, in the module SwiftUI made it in.
        let ours: [String] = table.tableColumns
            .filter { String(reflecting: type(of: $0.headerCell)).hasPrefix("PacerUI.") }
            .map(\.title)
        #expect(ours.isEmpty)
        #expect(table.headerView != nil)
        #expect(table.style == .inset)
        #expect(!table.usesAlternatingRowBackgroundColors)
        // The sort is the table's own sort descriptor, which is what the
        // system header draws its indicator from: Cost, largest first.
        let cost = try #require(Self.column("Cost", in: table))
        let first = try #require(table.sortDescriptors.first)
        #expect(first.key == cost.sortDescriptorPrototype?.key)
        #expect(first.ascending == false)
    }

    @Test("every title fits its column's starting width")
    func titlesFit() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let hosted = Self.host(Harness(rows: Self.rows(2, subtitles: false), tableId: "titles",
                                       store: store, defaults: Set(UsageColumn.allCases)), width: 1400)
        let table = try #require(Self.table(in: hosted.host))
        // Measured with the header's own cell, on whichever OS runs this:
        // the font and padding are the system's. Cost is the sorted column,
        // so its measure includes the sort indicator. With the table as its
        // own card there is room for the cache titles whole, which round 3
        // let shorten ("Cache re…").
        for column in UsageColumn.allCases where column != .name {
            let header = try #require(Self.column(column.title(label: "Model"), in: table)?.headerCell)
            let needed: CGFloat = header.cellSize.width
            #expect(needed <= column.idealWidth + 0.5,
                    "\(column) needs \(needed)pt for its title, starts at \(column.idealWidth)pt")
        }
    }

    /// Two screen columns, with the widths and the widest text of the
    /// screens' own: Models' Days and Last seen, or the Projects list's
    /// Sessions and Last active.
    struct TwoExtras: PacerUsageExtra, Sendable {
        func sortKey(forColumn id: String) -> PacerUsageSortKey? { nil }
    }

    struct ExtraColumn {
        let title: String
        let min: CGFloat
        let ideal: CGFloat
        let sample: String
        let font: Font
        var visible = true
    }

    private struct ExtrasHarness: View {
        let rows: [PacerUsageRow<TwoExtras>]
        let tableId: String
        let store: UserDefaults
        let defaults: Set<UsageColumn>
        let extras: [ExtraColumn]
        let width: CGFloat
        var body: some View {
            let first = extras[0], second = extras[1]
            PacerTableCard("Card") {
            PacerUsageTable(rows: rows, tableId: tableId, labelTitle: "Model",
                            sort: .costDescending, onSort: { _ in },
                            defaultColumns: defaults, store: store) {
                PacerUsageColumns.extra("first", title: first.title, of: TwoExtras.self,
                                        minWidth: first.min, idealWidth: first.ideal,
                                        visibleByDefault: first.visible) { _ in
                    Text(first.sample).font(first.font).monospacedDigit()
                }
                PacerUsageColumns.extra("second", title: second.title, of: TwoExtras.self,
                                        minWidth: second.min, idealWidth: second.ideal,
                                        visibleByDefault: second.visible) { _ in
                    Text(second.sample).font(second.font)
                }
            }
            }
            .frame(width: width)
        }
    }

    /// A row with the widest numbers each column prints: five-character
    /// counts, a six-character cost, a three-digit share.
    private static func widestRows() -> [PacerUsageRow<TwoExtras>] {
        let wide = PacerUsageRow(
            id: "wide", label: "Sonnet 4.6", subtitle: "claude-sonnet-4-6",
            tokens: TokenBreakdown(inputTokens: 88_800, outputTokens: 88_800_000,
                                   cacheReadTokens: 888_800_000, cacheCreation5mTokens: 48_800_000,
                                   cacheCreation1hTokens: 40_000_000),
            costParts: CostComponents(output: 12_340),
            cost: 12_340, extra: TwoExtras())
        let other = PacerUsageRow(
            id: "other", label: "Opus 4.7", subtitle: "claude-opus-4-7",
            tokens: TokenBreakdown(inputTokens: 1, outputTokens: 1),
            costParts: CostComponents(input: 1), extra: TwoExtras())
        return [wide, other]
    }

    // The screens' own columns, at the widths the screens give them.
    static let modelsExtras = [
        ExtraColumn(title: "Days", min: 28, ideal: 36, sample: "123", font: .system(size: 12)),
        ExtraColumn(title: "Last seen", min: 36, ideal: 72, sample: "2026-10-20",
                    font: .system(size: 11, design: .monospaced)),
    ]
    static let projectsExtras = [
        ExtraColumn(title: "Sessions", min: 28, ideal: 58, sample: "1234", font: .system(size: 12)),
        ExtraColumn(title: "Last active", min: 36, ideal: 70, sample: "59 min ago", font: .system(size: 11)),
    ]
    static let dayModelsExtras = [
        ExtraColumn(title: "Share", min: 28, ideal: 44, sample: "100%", font: .system(size: 12)),
        ExtraColumn(title: "B", min: 28, ideal: 40, sample: "", font: .body, visible: false),
    ]

    /// The card widths at the window's (or the modal's) default size: the
    /// page is 1080 less the sidebar, 849, and a card is 48pt narrower; Day
    /// detail's modal is 660 wide and Project detail's 760, each with 24pt
    /// of padding a side. The table is the card, less only the inset that
    /// lines its labels up under the title.
    nonisolated static let pageCard: CGFloat = 801
    nonisolated static let dayDetailCard: CGFloat = 612
    nonisolated static let projectDetailCard: CGFloat = 712

    @Test("a default layout fits its card at the window's default size, numbers and titles whole",
          arguments: [
            // Models: the wide columns, Mix, Days and Last seen.
            (UsageTableLayoutTests.pageCard, "models"),
            // All projects: the wide columns, Sessions and Last active.
            (UsageTableLayoutTests.pageCard, "projects"),
            // Day detail's projects (wide) and models (narrow, with Share).
            (UsageTableLayoutTests.dayDetailCard, "dayProjects"),
            (UsageTableLayoutTests.dayDetailCard, "dayModels"),
          ])
    func defaultLayoutFits(width: CGFloat, layout: String) throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults: Set<UsageColumn>
        let extras: [ExtraColumn]
        switch layout {
        case "models":
            defaults = UsageColumn.wideDefaults.union([.mix])
            extras = Self.modelsExtras
        case "projects":
            defaults = UsageColumn.wideDefaults
            extras = Self.projectsExtras
        case "dayModels":
            defaults = UsageColumn.narrowDefaults
            extras = Self.dayModelsExtras
        default:
            defaults = UsageColumn.wideDefaults
            extras = [ExtraColumn(title: "A", min: 40, ideal: 40, sample: "", font: .body, visible: false),
                      ExtraColumn(title: "B", min: 40, ideal: 40, sample: "", font: .body, visible: false)]
        }
        let hosted = Self.host(ExtrasHarness(rows: Self.widestRows(), tableId: "default-\(layout)",
                                             store: store, defaults: defaults, extras: extras,
                                             width: width), width: width)
        let table = try #require(Self.table(in: hosted.host))
        let clip = try #require(table.enclosingScrollView?.contentView)
        // Nothing to scroll sideways.
        #expect(table.frame.width <= clip.bounds.width + 0.5,
                "columns \(table.frame.width)pt wide in \(clip.bounds.width)pt")
        for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
            let cell = try #require(table.view(atColumn: index, row: 0, makeIfNecessary: true))
            if column.title != "Model" && column.title != "Mix" {
                // No number cut short: each cell's own fitting width is
                // within its column.
                let needed: CGFloat = cell.fittingSize.width
                #expect(needed <= column.width + 0.5,
                        "\(column.title) needs \(needed)pt, has \(column.width)pt")
            }
            // No title cut short either.
            let title: CGFloat = column.headerCell.cellSize.width
            #expect(title <= column.width + 0.5, "\(column.title) title needs \(title)pt, has \(column.width)pt")
        }
    }

    @Test("the sessions tables fit their modals' cards", arguments: [true, false])
    func sessionsFit(showProject: Bool) throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        // Day detail's lists sessions across projects; Project detail's, one.
        let width: CGFloat = showProject ? Self.dayDetailCard : Self.projectDetailCard
        let rows = PacerSessionsTable.rows(Self.sessions(3))
        let hosted = Self.host(SessionsHarness(rows: rows, showProject: showProject, store: store,
                                               width: width), width: width)
        let table = try #require(Self.table(in: hosted.host))
        let clip = try #require(table.enclosingScrollView?.contentView)
        #expect(table.frame.width <= clip.bounds.width + 0.5)
    }

    private struct ResetHarness: View {
        let rows: [PacerUsageRow<PacerUsageNoExtra>]
        let store: UserDefaults
        @State var sort = PacerUsageSort(.tokens, descending: false)
        var body: some View {
            VStack {
                PacerUsageTable(rows: rows, tableId: "reset", labelTitle: "Model",
                                sort: sort, onSort: { sort = $0 }, store: store)
                Text(sort.column + (sort.descending ? " desc" : " asc"))
            }
            .frame(width: 900)
        }
    }

    @Test("Reset columns brings back the default columns, order and widths, and keeps the sort")
    func resetColumns() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        // What a fresh table looks like, for comparison.
        let fresh = Self.host(Harness(rows: Self.rows(2, subtitles: false), tableId: "reset-fresh",
                                      store: store))
        let freshTable = try #require(Self.table(in: fresh.host))
        let freshWidths: [String: CGFloat] = Dictionary(
            uniqueKeysWithValues: freshTable.tableColumns.filter { !$0.isHidden }.map { ($0.title, $0.width) })

        let hosted = Self.host(ResetHarness(rows: Self.rows(2, subtitles: false), store: store))
        var table = try #require(Self.table(in: hosted.host) as? NSOutlineView)
        let delegate = try #require(table.delegate)
        // The user drags Cost to second place, shows Hit %, hides Uncached
        // and widens the label.
        let costIndex = try #require(table.tableColumns.firstIndex { $0.title == "Cost" })
        table.moveColumn(costIndex, toColumn: 1)
        let ratio = try #require(Self.column("Hit %", in: table))
        ratio.isHidden = false
        let input = try #require(Self.column("Uncached", in: table))
        input.isHidden = true
        delegate.outlineView?(table, userDidChangeVisibilityOf: [ratio, input])
        try #require(Self.column("Model", in: table)).width = 260
        Self.settle(hosted.host)
        #expect(Self.visibleTitles(table) == ["Model", "Cost"] + Self.wideParts.filter { $0 != "Uncached" }
                + ["Total", "Hit %"])

        PacerUsageTableMetrics.resetColumns(tableId: "reset")
        Self.settle(hosted.host)
        // A new table: the reset builds it afresh, at its starting widths.
        table = try #require(Self.table(in: hosted.host) as? NSOutlineView)
        #expect(Self.visibleTitles(table) == Self.visibleTitles(freshTable))
        for column in table.tableColumns where !column.isHidden {
            #expect(abs(column.width - (freshWidths[column.title] ?? -1)) <= 0.5,
                    "\(column.title) is \(column.width)pt after a reset, \(freshWidths[column.title] ?? -1)pt fresh")
        }
        // The saved layout is the default one again: nothing hidden or
        // shown by hand.
        let data = try #require(store.data(forKey: PacerUsageTableMetrics.columnsKey(tableId: "reset")))
        let saved = try JSONDecoder().decode(
            TableColumnCustomization<PacerUsageRow<PacerUsageNoExtra>>.self, from: data)
        #expect(saved[visibility: UsageColumn.input.rawValue] == .automatic)
        #expect(saved[visibility: UsageColumn.cacheHitRate.rawValue] == .automatic)
        // The sort is the screen's, and stays: Total, smallest first.
        let total = try #require(Self.column("Total", in: table))
        let first = try #require(table.sortDescriptors.first)
        #expect(first.key == total.sortDescriptorPrototype?.key)
        #expect(first.ascending)

        // Another table's layout is untouched by this one's reset.
        let other = Self.host(Harness(rows: Self.rows(2, subtitles: false), tableId: "reset-other",
                                      store: store))
        let otherTable = try #require(Self.table(in: other.host))
        let otherCost = try #require(otherTable.tableColumns.firstIndex { $0.title == "Cost" })
        otherTable.moveColumn(otherCost, toColumn: 1)
        Self.settle(other.host)
        PacerUsageTableMetrics.resetColumns(tableId: "reset")
        Self.settle(other.host)
        #expect(Self.visibleTitles(try #require(Self.table(in: other.host))).dropFirst().first == "Cost")
    }

    private struct OpeningHarness: View {
        let rows: [PacerUsageRow<PacerUsageNoExtra>]
        let store: UserDefaults
        let opened: (String) -> Void
        var body: some View {
            PacerUsageTable(rows: rows, tableId: "open", labelTitle: "Model",
                            sort: PacerUsageSort(.name, descending: false), onSort: { _ in },
                            onOpen: { opened($0.id) }, store: store)
                .frame(width: 900)
        }
    }

    @Test("a click opens its row and clears the selection; an arrow key only moves it")
    func clickOpensKeysWalk() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        final class Opened { var ids: [String] = [] }
        let opened = Opened()
        let hosted = Self.host(OpeningHarness(rows: Self.rows(3, subtitles: false), store: store,
                                              opened: { opened.ids.append($0) }))
        let table = try #require(Self.table(in: hosted.host))
        defer { PacerTableInput.record(keyDown: false) }

        // What the selection does after a key-down: the arrow keys walk.
        PacerTableInput.record(keyDown: true)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        Self.settle(hosted.host)
        #expect(opened.ids.isEmpty)
        #expect(table.selectedRow == 1)

        // After a button-down: the row opens, and nothing stays selected,
        // so the same row opens again next time.
        PacerTableInput.record(keyDown: false)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        Self.settle(hosted.host)
        #expect(opened.ids == ["model-2"])
        #expect(table.selectedRow == -1)
    }

    @Test("the columns fit the width they are given, however narrow: nothing to scroll sideways",
          arguments: [CGFloat(900), 600, 480, 420])
    func fitsItsWidth(width: CGFloat) throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let hosted = Self.host(Harness(rows: Self.rows(3, subtitles: true), tableId: "fitWidth",
                                       store: store, width: width), width: width)
        let table = try #require(Self.table(in: hosted.host))
        let clip = try #require(table.enclosingScrollView?.contentView)
        #expect(table.frame.width <= clip.bounds.width + 0.5,
                "columns \(table.frame.width)pt wide in \(clip.bounds.width)pt")
    }

    // MARK: Sessions

    private struct SessionsHarness: View {
        let rows: [PacerSessionsTable.Row]
        let showProject: Bool
        let store: UserDefaults
        var width: CGFloat = 640
        var body: some View {
            PacerTableCard("Sessions") {
                PacerSessionsTable(rows: rows, tableId: "sessions-\(showProject)",
                                   showProject: showProject,
                                   sort: PacerUsageSort(column: PacerSessionExtra.lastSeen, descending: true),
                                   onSort: { _ in }, onOpen: { _ in }, store: store)
            }
            .frame(width: width)
        }
    }

    static func sessions(_ n: Int) -> [SessionRow] {
        (0..<n).map { i in
            SessionRow(sessionId: String(format: "session-%03d", i),
                       firstSeenAt: Date(timeIntervalSince1970: 1_790_000_000),
                       lastSeenAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(i)),
                       projectPath: "/tmp/acme", ccVersion: nil, cumulativeCostUSD: 1,
                       cumulativeInputTokens: 1, cumulativeOutputTokens: 1,
                       cumulativeCacheReadTokens: 0, cumulativeCacheCreation5mTokens: 0,
                       cumulativeCacheCreation1hTokens: 0, topModel: "claude-opus-4-7",
                       cost: CostComponents(input: 0.5, output: 0.5))
        }
    }

    @Test("sessions: label, Project when it spans projects, Total, Cost, Last seen",
          arguments: [true, false])
    func sessionColumns(showProject: Bool) throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let rows = PacerSessionsTable.rows(Self.sessions(3))
        let hosted = Self.host(SessionsHarness(rows: rows, showProject: showProject, store: store),
                               width: 640)
        let table = try #require(Self.table(in: hosted.host))
        let expected: [String] = showProject
            ? ["Session", "Project", "Total", "Cost", "Last seen"]
            : ["Session", "Total", "Cost", "Last seen"]
        #expect(Self.visibleTitles(table) == expected)
        // The rest wait in the header's menu.
        let hidden: [String] = table.tableColumns.filter(\.isHidden).map(\.title)
        let parts: [String] = UsageColumn.partColumns.map { $0.title(label: "Session") }
        #expect(hidden == parts + ["Hit %", "Out %", "Duration", "Mix"])
        // Two-line rows (model over the session's short id), all fitting.
        let last: NSRect = table.rect(ofRow: 2)
        #expect(last.height == PacerUsageTableMetrics.rowHeight(twoLine: true))
    }

    @Test("a long sessions list stops at its own cap")
    func sessionsCap() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let rows = PacerSessionsTable.rows(Self.sessions(40))
        let hosted = Self.host(SessionsHarness(rows: rows, showProject: true, store: store), width: 640)
        let cap: CGFloat = PacerUsageTableMetrics.height(
            rowCount: 40, twoLine: true, maxVisibleRows: PacerSessionsTable.maxVisibleRows)
        let table = try #require(Self.table(in: hosted.host))
        let scroll = try #require(table.enclosingScrollView)
        #expect(scroll.frame.height == cap)
    }
}

// MARK: - Render (opt-in)

/// `PACER_RENDER_UI=1 PACER_RENDER_DIR=<dir> swift test --filter UsageTableRender`
/// draws the shared tables and donut cards to PNGs in light and dark, for a
/// person to look at: Models' table card at the window's default width,
/// wider, and at its minimum, Today by model, the Projects tab (Top projects over All projects,
/// and the card sorted by sessions with a wedge hovered), Project detail's By
/// model over its Sessions, Day detail's Models and Projects, a layout saved
/// too wide refitted, and the title-above option for the table card. A native
/// `Table` does not draw through `ImageRenderer`, so this caches the hosting
/// view's own display. Off by default: nothing is written in CI.
@MainActor
@Suite("Usage table render", .enabled(if: ProcessInfo.processInfo.environment["PACER_RENDER_UI"] == "1"))
struct UsageTableRender {

    struct Mix: PacerUsageExtra, Sendable {
        let days: Int
        let lastSeen: String
        func sortKey(forColumn id: String) -> PacerUsageSortKey? {
            switch id {
            case "days":     return .number(Double(days))
            case "lastSeen": return .text(lastSeen)
            default:         return nil
            }
        }
    }

    static let models = ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"]

    static func modelRows() -> [PacerUsageRow<Mix>] {
        models.enumerated().map { i, model in
            let scale = Int64(3 - i)
            let s = Double(scale)
            let shift: Double = Double(i)
            let output: Double = 180 * s + shift * 40
            let write1h: Double = 102 * s - shift * 30
            let parts = CostComponents(input: 0.6 * s, output: output, cacheRead: 455 * s,
                                       cacheWrite5m: 75 * s, cacheWrite1h: write1h)
            let reads: Int64 = 910_000_000 * scale - Int64(i) * 120_000_000
            return PacerUsageRow(
                id: model, label: pacerModelDisplayName(model), subtitle: model,
                color: pacerModelColor(model),
                tokens: TokenBreakdown(inputTokens: 41_000 * scale, outputTokens: 2_300_000 * scale,
                                       cacheReadTokens: reads,
                                       cacheCreation5mTokens: 12_000_000 * scale,
                                       cacheCreation1hTokens: 31_000_000 * scale),
                costParts: parts,
                extra: Mix(days: 30 - i * 7, lastSeen: "2026-10-2\(i)"))
        }
    }

    private struct ModelsCard: View {
        let store: UserDefaults
        var tableId = "render"
        @State var sort = PacerUsageSort.costDescending
        var body: some View {
            PacerTableCard("All models", trailing: {
                Text("3 models").font(.system(size: 11)).foregroundStyle(.secondary)
            }) {
                PacerUsageTable(rows: UsageTableRender.modelRows(), tableId: tableId, labelTitle: "Model",
                                sort: sort, onSort: { sort = $0 },
                                defaultColumns: UsageColumn.wideDefaults.union([.mix]), store: store) {
                    PacerUsageColumns.extra("days", title: "Days", of: Mix.self,
                                            minWidth: 28, idealWidth: 36) { row in
                        Text("\(row.extra.days)").font(.system(size: 12)).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    PacerUsageColumns.extra("lastSeen", title: "Last seen", of: Mix.self,
                                            minWidth: 36, idealWidth: 72) { row in
                        Text(row.extra.lastSeen).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static let todayColumns: [PacerShareListColumn] = [
        .usage(.tokens), .usage(.cacheHitRate), .usage(.outputShare), .usage(.cost), .ringShare,
    ]

    private struct TodayCard: View {
        @State var sort = PacerUsageSort.costDescending
        var hover: Double? = nil
        var body: some View {
            let rows: [PacerUsageRow<PacerUsageNoExtra>] = UsageTableRender.modelRows().map {
                PacerUsageRow(id: $0.id, label: $0.label, color: $0.color, tokens: $0.tokens,
                              costParts: $0.costParts)
            }
            PacerDonutListCard("Today by model",
                               data: PacerShareListData(rows: rows, sort: sort,
                                                        columns: UsageTableRender.todayColumns, maxSlices: 8),
                               labelTitle: "Model", accessibilityLabel: "", hoveredAngle: hover,
                               onSort: { sort = $0 })
        }
    }

    struct Project: PacerUsageExtra, Sendable {
        let sessions: Int
        let ago: String
        func sortKey(forColumn id: String) -> PacerUsageSortKey? {
            id == "sessions" ? .number(Double(sessions)) : nil
        }
        static func shareMetric(forColumn id: String) -> PacerShareMetric? {
            id == "sessions" ? PacerShareMetric(column: id, title: "Sessions") : nil
        }
        func shareValue(forColumn id: String) -> Double? {
            id == "sessions" ? Double(sessions) : nil
        }
    }

    static func projectRows() -> [PacerUsageRow<Project>] {
        let names = ["acme-web", "globex-api", "initech-tools", "hooli-infra", "umbrella-docs",
                     "stark-sim", "wayne-ops", "pied-piper"]
        return names.enumerated().map { i, name in
            let s = Double(8 - i)
            let parts = CostComponents(input: 0.4 * s, output: 30 * s + Double(i * 7), cacheRead: 70 * s,
                                       cacheWrite5m: 9 * s, cacheWrite1h: 14 * s)
            return PacerUsageRow(
                id: "/tmp/\(name)", label: name, subtitle: "~/Code/\(name)",
                color: pacerProjectColor(path: "/tmp/\(name)"),
                tokens: TokenBreakdown(inputTokens: 9_000 * Int64(8 - i), outputTokens: 400_000 * Int64(8 - i),
                                       cacheReadTokens: 90_000_000 * Int64(8 - i),
                                       cacheCreation5mTokens: 1_100_000 * Int64(8 - i),
                                       cacheCreation1hTokens: 1_600_000 * Int64(8 - i)),
                costParts: parts,
                extra: Project(sessions: [12, 40, 7, 22, 3, 9, 15, 4][i], ago: "\(i * 7 + 2) min ago"))
        }
    }

    static let topColumns: [PacerShareListColumn] = [
        .share(of: "cost", title: "Cost", format: .cost, help: "Share of the cost"),
        .share(of: "tokens", title: "Tokens", format: .tokens, help: "Share of every token"),
        .share(of: "sessions", title: "Sessions", format: .count, help: "Share of the sessions",
               width: 66),
    ]

    /// The Projects tab: Top projects over All projects, as the tab stacks
    /// them.
    private struct ProjectsPage: View {
        let store: UserDefaults
        @State var topSort: PacerUsageSort
        @State var sort = PacerUsageSort.costDescending
        var hover: Double? = nil
        var body: some View {
            let rows = UsageTableRender.projectRows()
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                PacerDonutListCard("Top projects",
                                   data: PacerShareListData(rows: rows, sort: topSort,
                                                            columns: UsageTableRender.topColumns, maxSlices: 5),
                                   labelTitle: "Project", accessibilityLabel: "", hoveredAngle: hover,
                                   onSort: { topSort = $0 }, onOpen: { _ in })
                PacerTableCard("All projects", trailing: {
                    Text("\(rows.count) projects").font(.system(size: 11)).foregroundStyle(.secondary)
                }) {
                    PacerUsageTable(rows: rows, tableId: "render-projects", labelTitle: "Project",
                                    sort: sort, onSort: { sort = $0 }, onOpen: { _ in }, store: store) {
                        PacerUsageColumns.extra("sessions", title: "Sessions", of: Project.self,
                                                minWidth: 28, idealWidth: 58) { row in
                            Text("\(row.extra.sessions)").font(.system(size: 12)).foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        PacerUsageColumns.extra("lastActive", title: "Last active", of: Project.self,
                                                minWidth: 36, idealWidth: 70) { row in
                            Text(row.extra.ago).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    struct InOut: PacerUsageExtra, Sendable {
        let uncached: Int64
        func sortKey(forColumn id: String) -> PacerUsageSortKey? {
            id == "inOut" ? .number(Double(uncached)) : nil
        }
        static func shareMetric(forColumn id: String) -> PacerShareMetric? {
            id == "inOut" ? PacerShareMetric(column: id, title: "In + out") : nil
        }
        func shareValue(forColumn id: String) -> Double? { id == "inOut" ? Double(uncached) : nil }
    }

    static func sessions() -> [SessionRow] {
        let now = Date()
        return (0..<5).map { i in
            let model = UsageTableRender.models[i % 3]
            let scale = Double(5 - i)
            let n = Int64(5 - i)
            let parts = CostComponents(input: 0.1 * scale, output: 4 * scale, cacheRead: 6 * scale,
                                       cacheWrite5m: 1.6 * scale, cacheWrite1h: 2.5 * scale)
            let first: Date = now.addingTimeInterval(-Double(i) * 5_400 - 3_600)
            let last: Date = now.addingTimeInterval(-Double(i * i) * 600 - 30)
            return SessionRow(
                sessionId: String(format: "%08x-0000-4000-8000-%012x", 0x3fa2_91c0 + i * 7919, i),
                firstSeenAt: first, lastSeenAt: last,
                projectPath: i % 2 == 0 ? "/tmp/acme-web" : "/tmp/globex-api",
                ccVersion: "2.1.4", cumulativeCostUSD: parts.total,
                cumulativeInputTokens: 9_000 * n, cumulativeOutputTokens: 310_000 * n,
                cumulativeCacheReadTokens: 41_000_000 * n,
                cumulativeCacheCreation5mTokens: 900_000 * n,
                cumulativeCacheCreation1hTokens: 1_200_000 * n, topModel: model,
                cost: parts)
        }
    }

    /// Project detail's lower half: By model over its Sessions.
    private struct ProjectDetail: View {
        let store: UserDefaults
        @State var modelSort = PacerUsageSort.costDescending
        @State var sort = PacerUsageSort(column: PacerSessionExtra.lastSeen, descending: true)
        var body: some View {
            let models: [PacerUsageRow<InOut>] = UsageTableRender.modelRows().map {
                PacerUsageRow(id: $0.id, label: $0.label, color: $0.color, tokens: .zero, costParts: .zero,
                              cost: $0.cost, extra: InOut(uncached: $0.tokens.uncached))
            }
            let columns: [PacerShareListColumn] = [
                .usage(.cost),
                .count("inOut", title: "In + out", format: .tokens, help: "Uncached input and output tokens"),
                .ringShare,
            ]
            let rows = PacerSessionsTable.rows(UsageTableRender.sessions())
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                PacerDonutListCard("By model",
                                   data: PacerShareListData(rows: models, sort: modelSort, columns: columns,
                                                            maxSlices: 8),
                                   labelTitle: "Model", accessibilityLabel: "", onSort: { modelSort = $0 })
                PacerTableCard("Sessions", trailing: {
                    Text("\(rows.count) total").font(.system(size: 11)).foregroundStyle(.secondary)
                }) {
                    PacerSessionsTable(rows: rows, tableId: "render-sessions", showProject: false,
                                       sort: sort, onSort: { sort = $0 }, onOpen: { _ in }, store: store)
                }
            }
        }
    }

    /// Day detail's two tables: the narrow Models (with its Share) and the
    /// wide Projects.
    private struct DayDetail: View {
        let store: UserDefaults
        @State var sort = PacerUsageSort.costDescending
        var body: some View {
            let models: [PacerUsageRow<PacerUsageNoExtra>] = UsageTableRender.modelRows().map {
                PacerUsageRow(id: $0.id, label: $0.label, color: $0.color, tokens: $0.tokens,
                              costParts: $0.costParts)
            }
            let projects: [PacerUsageRow<PacerUsageNoExtra>] = UsageTableRender.projectRows().prefix(4).map {
                PacerUsageRow(id: $0.id, label: $0.label, subtitle: $0.subtitle, tokens: $0.tokens,
                              costParts: $0.costParts)
            }
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                PacerTableCard("Models") {
                    PacerUsageTable(rows: models, tableId: "render-day-models", labelTitle: "Model",
                                    sort: sort, onSort: { sort = $0 },
                                    defaultColumns: UsageColumn.narrowDefaults, store: store)
                }
                PacerTableCard("Projects", trailing: {
                    Text("4 projects").font(.system(size: 11)).foregroundStyle(.secondary)
                }) {
                    PacerUsageTable(rows: projects, tableId: "render-day-projects", labelTitle: "Project",
                                    sort: sort, onSort: { sort = $0 }, store: store)
                }
            }
        }
    }

    /// The other option for a table card: the title above, as a section
    /// heading, over a bare rounded table.
    private struct TitleAboveOption: View {
        let store: UserDefaults
        @State var sort = PacerUsageSort(column: PacerSessionExtra.lastSeen, descending: true)
        var body: some View {
            let rows = PacerSessionsTable.rows(UsageTableRender.sessions())
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sessions").font(.title3).fontWeight(.semibold)
                    Spacer()
                    Text("\(rows.count) total").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                PacerSessionsTable(rows: rows, tableId: "render-sessions-above", showProject: false,
                                   sort: sort, onSort: { sort = $0 }, onOpen: { _ in }, store: store)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                        .fill(PacerDesign.cardBackground))
                    .overlay(RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                        .stroke(PacerDesign.cardStroke, lineWidth: 1))
            }
        }
    }

    private func render(_ view: some View, width: CGFloat, name: String, dir: String) throws {
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let framed = view.padding(24).frame(width: width)
                .background(Color(nsColor: .underPageBackgroundColor))
            let host = NSHostingView(rootView: framed)
            let window = NSWindow(contentRect: NSRect(x: -60_000, y: -60_000, width: width, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(look).png"))
        }
    }

    @Test func render() throws {
        let dir = ProcessInfo.processInfo.environment["PACER_RENDER_DIR"]
            ?? FileManager.default.temporaryDirectory.path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let suite = "pacer.tests.usageTable.render.\(UUID().uuidString)"
        var suites: [String] = [suite]
        defer { for name in suites { UserDefaults().removePersistentDomain(forName: name) } }
        func store(_ tag: String) -> UserDefaults {
            suites.append(suite + "." + tag)
            return UserDefaults(suiteName: suite + "." + tag)!
        }
        // 849: the page at the window's default size (1080, less the
        // sidebar); the card inside it is 48pt narrower. 760 and 660: the
        // Project and Day detail modals at their ideal widths.
        try render(ModelsCard(store: store("models")), width: 849, name: "models-table", dir: dir)
        try render(ModelsCard(store: store("wide")), width: 1100, name: "models-table-wide", dir: dir)
        // 649: the page at the window's minimum width (880): cells shorten
        // rather than the table scrolling.
        try render(ModelsCard(store: store("narrow")), width: 649, name: "models-table-min-window", dir: dir)
        try render(TodayCard(), width: 849, name: "today-by-model", dir: dir)
        try render(TodayCard(sort: PacerUsageSort(.tokens, descending: true), hover: 1_500_000_000),
                   width: 849, name: "today-by-model-by-total-hover", dir: dir)
        try render(ProjectsPage(store: store("projects"), topSort: .costDescending), width: 849,
                   name: "projects", dir: dir)
        try render(ProjectsPage(store: store("projects-sessions"),
                                topSort: PacerUsageSort(column: "sessions", descending: true), hover: 50),
                   width: 849, name: "projects-top-by-sessions-hover", dir: dir)
        try render(ProjectDetail(store: store("detail")), width: 760, name: "project-detail", dir: dir)
        try render(DayDetail(store: store("day")), width: 660, name: "day-detail", dir: dir)
        // A layout saved in a much wider window: refitted, not scrolled.
        let tooWide = store("too-wide")
        let wide = UsageTableLayoutTests.wideLayout(width: 160)
        tooWide.set(Data(wide.utf8), forKey: PacerUsageTableMetrics.columnsKey(tableId: "render-too-wide"))
        try render(ModelsCard(store: tooWide, tableId: "render-too-wide"), width: 849,
                   name: "models-table-saved-too-wide", dir: dir)
        try render(TitleAboveOption(store: store("above")), width: 760, name: "option-title-above", dir: dir)
    }
}
