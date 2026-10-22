import AppKit
import SwiftUI
import PacerCore

// A usage table never scrolls sideways. Autoresizing keeps the columns
// filling the table as the window changes size, and each screen's defaults
// fit its card. The one case neither covers is a saved layout: SwiftUI
// restores the widths a user left as they were, so a layout saved in a wide
// window opened too wide in a narrow one and scrolled until the window grew,
// and one saved in a narrow window left a gap at the right of a wide one.
//
// There is no SwiftUI API to read or set a column's width
// (`TableColumnCustomization` exposes visibility and order only). What a
// saved width becomes is `NSTableColumn.width`, so the fit is done there:
// `PacerTableFitter` sits in the label cells, finds the `NSTableView` by
// walking up from that cell (it is inside it, so there is nothing to match or
// guess), and when the columns' widths and the table's visible width
// disagree it scales the columns to fit, through `NSTableColumn.width` and
// nothing else. SwiftUI sees the resize as it sees a user's, and saves the
// fitted widths. If a future SwiftUI hosts tables some other way, the walk
// finds no table and nothing happens: the table keeps the widths SwiftUI gave
// it.

/// The arithmetic of fitting columns to a width, apart from any view so it
/// can be tested.
public enum PacerTableFit {
    /// `widths` changed to sum to `target`, each staying at or above its
    /// minimum.
    ///
    /// Shrinking takes from each column in proportion to what it has above
    /// its minimum, so the columns keep their proportions and none is cut
    /// to its minimum while another still has room (AppKit's own
    /// `sizeToFit` takes the same amount from each, which squeezes the
    /// narrow number columns to their minimums first and leaves a wide
    /// label untouched). Growing scales every column alike. If even the
    /// minimums overflow `target`, every column sits at its minimum.
    public static func widths(_ widths: [CGFloat], minimums: [CGFloat], target: CGFloat) -> [CGFloat] {
        precondition(widths.count == minimums.count, "one minimum per column")
        let floors: [CGFloat] = zip(widths, minimums).map { Swift.min($0, $1) }
        let total: CGFloat = widths.reduce(0, +)
        guard !widths.isEmpty, abs(total - target) > 0.5 else { return widths }
        if target > total {
            guard total > 0 else { return widths }
            let scale: CGFloat = target / total
            return widths.map { $0 * scale }
        }
        let floorTotal: CGFloat = floors.reduce(0, +)
        let room: CGFloat = total - floorTotal
        guard room > 0 else { return floors }
        let kept: CGFloat = Swift.max(0, Swift.min(1, (target - floorTotal) / room))
        return zip(widths, floors).map { width, floor in floor + (width - floor) * kept }
    }

    /// `widths` in whole points, still summing to what they summed to: the
    /// fractions go to the widest column, so a fitted table's columns are
    /// not left at 58.19pt.
    public static func wholePoints(_ widths: [CGFloat]) -> [CGFloat] {
        guard let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) else { return widths }
        var rounded: [CGFloat] = widths.map { $0.rounded(.down) }
        let total: CGFloat = widths.reduce(0, +)
        let roundedTotal: CGFloat = rounded.reduce(0, +)
        rounded[widest] += total - roundedTotal
        return rounded
    }

    /// What the table's columns may add up to: its visible width less what
    /// it spends around the columns (intercell spacing and the style's
    /// insets), which is what the table's own width is beyond its columns.
    static func target(tableWidth: CGFloat, columnsWidth: CGFloat, visibleWidth: CGFloat) -> CGFloat {
        visibleWidth - (tableWidth - columnsWidth)
    }

    /// Fits `table`'s visible columns to the width its scroll view shows.
    /// Returns whether it changed anything.
    ///
    /// Too wide is plain to see: the table view is wider than its clip view,
    /// and the difference is exactly what the columns must give up. Too
    /// narrow is not: a table view never draws narrower than its clip view,
    /// whatever its columns add up to, so it is read from where the last
    /// column ends, plus the margin before the first, which the inset style
    /// keeps the same on both sides. A table first laid out at a passing
    /// narrow width and then widened is the case: SwiftUI puts back the
    /// widths it saved at the narrow width, and the columns stop short of
    /// the card's right edge.
    @MainActor
    @discardableResult
    static func fit(_ table: NSTableView) -> Bool {
        guard let clip = table.enclosingScrollView?.contentView else { return false }
        // Never while the user is dragging a column edge: that is the user
        // choosing a width, and fitting under the pointer fights the drag.
        if let header = table.headerView, header.resizedColumn >= 0 { return false }
        let indices: [Int] = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
        guard let firstIndex = indices.first, let lastIndex = indices.last else { return false }
        let columns: [NSTableColumn] = indices.map { table.tableColumns[$0] }
        let current: [CGFloat] = columns.map(\.width)
        let columnsWidth: CGFloat = current.reduce(0, +)
        let visible: CGFloat = clip.bounds.width
        guard visible > 0 else { return false }
        let target: CGFloat
        if table.frame.width > visible + 0.5 {
            target = Self.target(tableWidth: table.frame.width, columnsWidth: columnsWidth, visibleWidth: visible)
        } else {
            let used: CGFloat = table.rect(ofColumn: lastIndex).maxX + table.rect(ofColumn: firstIndex).minX
            guard visible - used > 1 else { return false }
            target = columnsWidth + (visible - used)
        }
        guard target > 0 else { return false }
        let fitted = wholePoints(widths(current, minimums: columns.map(\.minWidth), target: target))
        guard fitted != current else { return false }
        for (column, width) in zip(columns, fitted) {
            column.width = width
        }
        return true
    }
}

/// An empty view, placed in every label cell, that keeps the table it is in
/// fitted to its width (see the top of this file), and gives its header the
/// tooltips (`PacerTableHeaderHelp`) and the Reset Columns item
/// (`PacerTableHeaderMenu`) SwiftUI has no API for. In every cell rather than
/// one: cells are reused as rows scroll and re-sort, and whichever are on
/// screen keep watching. Their fits are coalesced to one per table per turn
/// of the run loop (`PacerTableFitQueue`).
struct PacerTableFitter: NSViewRepresentable {
    /// The table's layout id, which "Reset Columns" resets.
    let tableId: String

    func makeNSView(context: Context) -> PacerTableFitterView {
        let view = PacerTableFitterView()
        view.tableId = tableId
        return view
    }

    func updateNSView(_ view: PacerTableFitterView, context: Context) {
        view.tableId = tableId
    }
}

/// The tables with a fit already scheduled this turn of the run loop.
@MainActor
enum PacerTableFitQueue {
    private static var pending: Set<ObjectIdentifier> = []

    /// Fits `table` on the next turn of the run loop, once however many
    /// cells ask: a restore or a resize moves several frames in one pass,
    /// and fitting in the middle of AppKit's own layout would be undone by
    /// the rest of it. A run-loop block rather than `DispatchQueue.main.async`,
    /// which a run loop already inside a main-queue block (a test's, a
    /// modal's) never drains.
    static func schedule(_ table: NSTableView) {
        let id = ObjectIdentifier(table)
        guard pending.insert(id).inserted else { return }
        RunLoop.main.perform(inModes: [.common]) { [weak table] in
            MainActor.assumeIsolated {
                pending.remove(id)
                if let table { PacerTableFit.fit(table) }
            }
        }
    }
}

final class PacerTableFitterView: NSView {
    var tableId: String = ""
    private weak var table: NSTableView?
    /// Removed when the view leaves its window; `deinit` is the backstop,
    /// and runs where nothing else can touch them.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    // The cell's content, not part of it: it takes no clicks and no space.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { .zero }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func attach() {
        let found: NSTableView? = window == nil ? nil : enclosingTable()
        guard found !== table else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        table = found
        guard let found else { return }
        PacerTableHeaderHelp.apply(to: found)
        if !tableId.isEmpty { PacerTableHeaderMenu.install(on: found, tableId: tableId) }
        guard let clip = found.enclosingScrollView?.contentView else { return }
        // The table's width changes when a column's does (a restored layout,
        // a column shown or hidden); the clip view's when the window's does.
        found.postsFrameChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for object in [found as NSView, clip] {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: object, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let table = self?.table { PacerTableFitQueue.schedule(table) }
                }
            })
        }
        PacerTableFitQueue.schedule(found)
    }

    private func enclosingTable() -> NSTableView? {
        var view: NSView? = superview
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
    }
}

// MARK: - The header: tooltips and Reset Columns

/// The header tooltips of the standard columns (`UsageColumn.headerHelp`),
/// on the `NSTableColumn`s SwiftUI made for them.
///
/// SwiftUI names its columns with identifiers of its own (a fresh UUID per
/// column), so a column is matched by its title, which is the one thing both
/// sides set. A title no standard column has (the label, a screen's own
/// column) is left alone.
enum PacerTableHeaderHelp {
    /// Title to tooltip, for every standard column that has one. The titles
    /// of all but the label column do not depend on the table.
    static let byTitle: [String: String] = {
        var help: [String: String] = [:]
        for column in UsageColumn.allCases where column != .name {
            if let text = column.headerHelp { help[column.title(label: "")] = text }
        }
        return help
    }()

    @MainActor
    static func apply(to table: NSTableView) {
        for column in table.tableColumns {
            guard let help = byTitle[column.title], column.headerToolTip != help else { continue }
            column.headerToolTip = help
        }
    }
}

/// The header's right-click menu: AppKit's own column menu, every column the
/// user may show or hide and Show All, then "Reset Columns".
///
/// The owner looked for a way to reset a table where he had changed it, on
/// the header, and found it only in the body's context menu. The header's
/// menu is AppKit's automatic one (macOS 14+, which SwiftUI's
/// `TableColumnCustomization` turns on): `NSTableHeaderView` builds a fresh
/// one each time it is asked, but only while its `menu` is nil, and an
/// explicit `menu` replaces it outright. So this is the header's `menu`, and
/// each time it is about to open it asks the header for AppKit's menu (with
/// its own `menu` set aside for the moment) and takes that menu's items as
/// they are. Their targets and actions stay AppKit's and SwiftUI's, so
/// showing, hiding and Show All work exactly as before; only the item after
/// them is Pacer's. All of it is public API: `NSView.menu`,
/// `NSView.menu(for:)` and `NSMenuDelegate`.
///
/// If AppKit stops offering a menu there, this one holds Reset Columns alone;
/// if something else sets the header's menu first, Reset Columns is added to
/// the end of that one instead, and nothing of it is removed.
@MainActor
final class PacerTableHeaderMenu: NSMenu, NSMenuDelegate {
    /// The item's title, in the header's menu and the body's alike: title
    /// case, as AppKit's own Show All beside it.
    nonisolated static let resetTitle = "Reset Columns"

    let tableId: String
    private weak var header: NSTableHeaderView?

    init(tableId: String, header: NSTableHeaderView) {
        self.tableId = tableId
        self.header = header
        super.init(title: "")
        delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("not decoded")
    }

    /// Makes `table`'s header menu this one, once per header. A table SwiftUI
    /// builds afresh (a reset, a re-sort that rebuilds it) has a new header,
    /// which the next cell to attach installs it on.
    static func install(on table: NSTableView, tableId: String) {
        guard let header = table.headerView else { return }
        switch header.menu {
        case let mine as PacerTableHeaderMenu:
            guard mine.tableId != tableId else { return }
            header.menu = PacerTableHeaderMenu(tableId: tableId, header: header)
        case let other?:
            // Someone else's menu: keep it whole, and add the item to it.
            guard !other.items.contains(where: { $0 is ResetItem }) else { return }
            if !other.items.isEmpty { other.addItem(.separator()) }
            other.addItem(ResetItem(tableId: tableId))
        case nil:
            header.menu = PacerTableHeaderMenu(tableId: tableId, header: header)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        let automatic: [NSMenuItem] = Self.automaticItems(of: header)
        for item in automatic { addItem(item) }
        if !automatic.isEmpty { addItem(.separator()) }
        addItem(ResetItem(tableId: tableId))
    }

    /// The items of the menu AppKit would have shown on `header`, taken out
    /// of it.
    static func automaticItems(of header: NSTableHeaderView?) -> [NSMenuItem] {
        guard let header else { return [] }
        let own: NSMenu? = header.menu
        header.menu = nil
        defer { header.menu = own }
        guard let event = event(for: header), let automatic = header.menu(for: event) else { return [] }
        let items: [NSMenuItem] = automatic.items
        automatic.removeAllItems()
        return items
    }

    /// The event to ask the header with: the click that is opening the menu,
    /// or, when there is none (a test, VoiceOver's menu action), one made up
    /// over the header's middle. Made, never posted: nothing but the header
    /// sees it. AppKit's menu lists every column whichever was clicked.
    private static func event(for header: NSTableHeaderView) -> NSEvent? {
        if let current = NSApplication.shared.currentEvent, current.window === header.window,
           [.rightMouseDown, .leftMouseDown, .otherMouseDown].contains(current.type) {
            return current
        }
        let middle = NSPoint(x: header.bounds.midX, y: header.bounds.midY)
        return NSEvent.mouseEvent(
            with: .rightMouseDown, location: header.convert(middle, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: header.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// "Reset Columns": what the body's context menu item does
    /// (`PacerUsageTableMetrics.resetColumns`).
    @MainActor
    final class ResetItem: NSMenuItem {
        let tableId: String

        init(tableId: String) {
            self.tableId = tableId
            super.init(title: PacerTableHeaderMenu.resetTitle, action: #selector(reset(_:)), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) {
            fatalError("not decoded")
        }

        @objc private func reset(_ sender: Any?) {
            PacerUsageTableMetrics.resetColumns(tableId: tableId)
        }
    }
}
