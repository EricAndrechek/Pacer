import AppKit
import SwiftUI
import Testing
@testable import PacerCore
@testable import PacerUI

// The shared usage table hosted off-screen, measured against the real
// `NSTableView` SwiftUI builds for it: the frame it sets itself fits its rows,
// its columns start as specified, and the column layout a user makes
// (visibility, order) survives into the next table with the same id.
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
        var body: some View {
            PacerUsageTable(rows: rows, tableId: tableId, labelTitle: "Model",
                            sort: .costDescending, onSort: { _ in }, store: store)
                .frame(width: 900)
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
                cost: Double(i))
        }
    }

    private static func store() -> (UserDefaults, String) {
        let name = "pacer.tests.usageTable.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private static func host(_ view: some View) -> Hosted {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: -60_000, y: -60_000, width: 900, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: host.fittingSize.height)
        settle(host)
        return Hosted(host: host, window: window)
    }

    /// Lay out, make every cell, and let SwiftUI's run-loop work land.
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

    @Test("default columns: the five token parts, total and cost; the tiers hidden")
    func defaultColumns() throws {
        let (store, suite) = Self.store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let hosted = Self.host(Harness(rows: Self.rows(2, subtitles: false),
                                       tableId: "columns", store: store))
        let table = try #require(Self.table(in: hosted.host))
        let titles: [String] = table.tableColumns.map(\.title)
        #expect(titles == ["Model", "Input", "Output", "Cache read", "Cache write",
                           "5m write", "1h write", "Total", "Cost"])
        let hidden: [String] = table.tableColumns.filter(\.isHidden).map(\.title)
        #expect(hidden == ["5m write", "1h write"])
        // Every column sorts.
        let unsortable: [String] = table.tableColumns
            .filter { $0.sortDescriptorPrototype == nil }.map(\.title)
        #expect(unsortable.isEmpty)
        // Numbers sort largest first on a first click, the label A to Z.
        let model = try #require(Self.column("Model", in: table))
        let cost = try #require(Self.column("Cost", in: table))
        #expect(model.sortDescriptorPrototype?.ascending == true)
        #expect(cost.sortDescriptorPrototype?.ascending == false)
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
        #expect(hideable == ["Input", "Output", "Cache read", "Cache write",
                             "5m write", "1h write", "Total", "Cost"])
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
        // ticks "5m write" on in the header menu.
        let costIndex = try #require(table.tableColumns.firstIndex { $0.title == "Cost" })
        table.moveColumn(costIndex, toColumn: 1)
        let tier = try #require(Self.column("5m write", in: table))
        tier.isHidden = false
        delegate.outlineView?(table, userDidChangeVisibilityOf: [tier])
        Self.settle(first.host)

        let key = PacerUsageTableMetrics.columnsKey(tableId: "persist")
        let data = try #require(store.data(forKey: key))
        let saved = try JSONDecoder().decode(
            TableColumnCustomization<PacerUsageRow<PacerUsageNoExtra>>.self, from: data)
        #expect(saved[visibility: UsageColumn.cacheWrite5m.rawValue] == .visible)

        let second = Self.host(Harness(rows: Self.rows(2, subtitles: false),
                                       tableId: "persist", store: store))
        let reopened = try #require(Self.table(in: second.host))
        let titles: [String] = reopened.tableColumns.filter { !$0.isHidden }.map(\.title)
        #expect(titles == ["Model", "Cost", "Input", "Output", "Cache read",
                           "Cache write", "5m write", "Total"])

        // A different table id keeps its own, default, layout.
        let other = Self.host(Harness(rows: Self.rows(2, subtitles: false),
                                      tableId: "persist-other", store: store))
        let untouched = try #require(Self.table(in: other.host))
        let defaults: [String] = untouched.tableColumns.filter { !$0.isHidden }.map(\.title)
        #expect(defaults == ["Model", "Input", "Output", "Cache read", "Cache write",
                             "Total", "Cost"])
    }

    @Test("the stored layout encodes and decodes to the same visibility and order")
    func codableRoundTrip() throws {
        typealias Customization = TableColumnCustomization<PacerUsageRow<PacerUsageNoExtra>>
        var layout = Customization()
        layout[visibility: UsageColumn.input.rawValue] = .hidden
        layout[visibility: UsageColumn.cacheWrite1h.rawValue] = .visible
        let data: Data = try JSONEncoder().encode(layout)
        let back: Customization = try JSONDecoder().decode(Customization.self, from: data)
        #expect(back == layout)
        #expect(back[visibility: UsageColumn.input.rawValue] == .hidden)
        #expect(back[visibility: UsageColumn.cacheWrite1h.rawValue] == .visible)
        #expect(back[visibility: UsageColumn.cost.rawValue] == .automatic)
    }
}

// MARK: - Render (opt-in)

/// `PACER_RENDER_UI=1 PACER_RENDER_DIR=<dir> swift test --filter UsageTableRender`
/// draws the table, in a card, to PNGs in light and dark, for a person to look
/// at. A native `Table` does not draw through `ImageRenderer`, so this caches
/// the hosting view's own display. Off by default: nothing is written in CI.
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

    private struct Card: View {
        let rows: [PacerUsageRow<Mix>]
        let store: UserDefaults
        @State var sort = PacerUsageSort.costDescending
        var body: some View {
            PacerCard("All models") {
                PacerUsageTable(rows: rows, tableId: "render", labelTitle: "Model",
                                sort: sort, onSort: { sort = $0 }, store: store) {
                    PacerUsageColumns.extra("days", title: "Days", of: Mix.self) { row in
                        Text("\(row.extra.days)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    PacerUsageColumns.extra("lastSeen", title: "Last seen", of: Mix.self,
                                            minWidth: 70, idealWidth: 84) { row in
                        Text(row.extra.lastSeen).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(width: 900)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    @Test func render() throws {
        let dir = ProcessInfo.processInfo.environment["PACER_RENDER_DIR"]
            ?? FileManager.default.temporaryDirectory.path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let names = ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"]
        let rows: [PacerUsageRow<Mix>] = names.enumerated().map { i, model in
            let scale = Int64(3 - i)
            return PacerUsageRow(
                id: model, label: pacerModelDisplayName(model), subtitle: model,
                color: pacerModelColor(model),
                tokens: TokenBreakdown(inputTokens: 41_000 * scale, outputTokens: 2_300_000 * scale,
                                       cacheReadTokens: 910_000_000 * scale,
                                       cacheCreation5mTokens: 12_000_000 * scale,
                                       cacheCreation1hTokens: 31_000_000 * scale),
                cost: 812.40 * Double(scale),
                extra: Mix(days: 30 - i * 7, lastSeen: "2026-10-2\(i)"))
        }
        let suite = "pacer.tests.usageTable.render.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: Card(rows: rows, store: UserDefaults(suiteName: suite)!))
            let window = NSWindow(contentRect: NSRect(x: -60_000, y: -60_000, width: 900, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.frame = NSRect(x: 0, y: 0, width: 900, height: host.fittingSize.height)
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("usage-table-\(name).png"))
        }
    }
}
