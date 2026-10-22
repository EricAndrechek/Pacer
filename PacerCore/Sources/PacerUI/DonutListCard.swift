import AppKit
import SwiftUI
import PacerCore

// A share donut beside a short list of what it measures: Today by model,
// Projects' Top projects, the Models tab's Share card and the detail modals'
// By model cards.
//
// Round 3 put a native table beside the donut, and the owner found it very
// bad in a donut card: the table's header, dividers and rounded border were a
// second card inside the first. So beside a donut there is a light list, as
// the old Top projects card had, but with labelled columns: click a column's
// title to sort the list, and the donut turns to measure that column when its
// values add up (`PacerShareDonutData`). A full table, where a screen has
// one, is its own card below (`PacerTableCard`), never inside this one.
//
// Every donut list has the same columns, in the same order, under the same
// titles: Mix, Tokens, Cost, Share (`PacerShareListColumn.standard`), and no
// card picks its own. Round 4 let each card choose, and the owner found them
// disagreeing with each other and with the tables; round 6 gave the cards a
// table follows shares under "Tokens" and "Cost" and Today by model amounts
// under the same titles. The owner, round 7: "some of the pie chart views…
// [are] not showing the mix piece you added", Top projects "only showing
// [Tokens % / Cost %]… no mix or share columns on it like others have". So
// one set: Tokens and Cost are amounts, printed as a table prints them, and
// Share is each row's part of the ring. His consistency request outranks the
// "never the same number twice" rule here: a card's amounts may repeat the
// table under it.
//
// Mix is each row's cost by part as a slim bar (`PacerCostBar`), first after
// the name, at his ask ("make the mix the leftmost column instead of the
// rightmost there"). It is drawn, never a number: not a sort, and never what
// the ring measures. A list takes only amounts that add up (`UsageAmount`):
// Hit % and Out % are not shares of anything, so they cannot be a ring or be
// compared as one.

// MARK: - Columns

/// One column of a donut card's list. Every card has the same four
/// (`standard`); the type exists so the list can say what each one is.
public struct PacerShareListColumn: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// A usage table column's amount, printed as the table prints it.
        case usage(UsageAmount)
        /// Each row's share of what the ring measures.
        case ringShare
        /// The row's cost by part as one slim bar (`PacerCostBar`), as a
        /// table's Mix column draws it. Display only: not a sort, and never
        /// what the ring measures.
        case mixBar
    }

    /// What the column sorts by: a `UsageColumn` raw value, or an id of the
    /// list's own for the two columns that do not sort.
    public let id: String
    public let title: String
    /// The title's tooltip, where the title alone does not say it.
    public let help: String?
    /// A number column's width; the Mix bar's least, from which it takes
    /// what the card has left (`PacerShareListMetrics.maxMixWidth`).
    public let width: CGFloat
    let kind: Kind

    /// Whether a click on the title sorts by it. The ring's share does not:
    /// sorting by it is sorting by whatever the ring measures. Nor does the
    /// Mix bar: the ring follows the sort, and only an amount can be a ring.
    public var isSortable: Bool { kind != .ringShare && kind != .mixBar }

    /// Whether the column takes the list's spare width (the Mix bar) rather
    /// than its own fixed `width`, which is then its least.
    var isFlexible: Bool { kind == .mixBar }

    /// The columns of every donut list, the only ones: Mix, Tokens, Cost,
    /// Share. Tokens before Cost as every table has them; Mix first, beside
    /// the names. Sorted by cost unless the screen asks otherwise, as every
    /// table is.
    public static let standard: [PacerShareListColumn] = [.mixBar, .usage(.tokens), .usage(.cost), .ringShare]

    /// A usage table column's amount, under the table's title. Only amounts
    /// that add up have a `UsageAmount`, so a ratio (Hit %, Out %) cannot be
    /// put in a donut list.
    static func usage(_ amount: UsageAmount) -> Self {
        let width: CGFloat
        let help: String?
        switch amount {
        case .cost:
            width = 60
            help = nil
        case .tokens:
            width = 54
            help = "Every token: cached, uncached and output"
        default:
            width = 54
            help = nil
        }
        return Self(id: amount.column.rawValue, title: amount.column.title(label: ""),
                    help: help, width: width, kind: .usage(amount))
    }

    /// Each row's share of what the ring measures, which is what the list is
    /// sorted by when that adds up, and cost otherwise.
    static let ringShare = Self(id: "__ringShare__", title: "Share", help: nil, width: 44, kind: .ringShare)

    /// Each row's cost by part, the bar every table's Mix column draws. Its
    /// id is no usage column's, so nothing reads it as one.
    static let mixBar = Self(id: "__mixBar__", title: UsageColumn.mix.title(label: ""),
                             help: UsageColumn.mix.headerHelp, width: 64, kind: .mixBar)
}

// MARK: - Data

/// What a donut card draws: the ring, and the rows of the list beside it,
/// built from the screen's rows and the list's sort.
///
/// The rows are the ring's named wedges, in the list's order, and the folded
/// tail as one last row, so the list is the ring's legend: a row with a
/// colour dot has that colour's wedge, and "4 others" is the grey one. Plain,
/// so a screen with many rows (Projects) builds it where it caches its rows,
/// and one with a handful (Today by model) builds it in its body.
public struct PacerShareListData<Extra: PacerUsageExtra> {
    /// The ring: what the sort measures when that adds up, cost otherwise.
    public let donut: PacerShareDonutData
    /// The sort the list runs in: the one asked for, or cost when that names
    /// a column the list does not have (`effectiveSort`).
    public let sort: PacerUsageSort
    /// The listed rows, in the list's order.
    public let rows: [PacerUsageRow<Extra>]
    /// The tail the ring folds into one wedge, as one row.
    public let other: Other?

    /// Every list's columns (`PacerShareListColumn.standard`).
    public var columns: [PacerShareListColumn] { PacerShareListColumn.standard }

    /// The folded tail, summed.
    public struct Other: Sendable, Equatable {
        public let label: String
        public let count: Int
        public let tokens: TokenBreakdown
        public let costParts: CostComponents
        public let cost: Double
    }

    /// - `maxSlices`: rows with a wedge, and a line, of their own; the rest
    ///   fold into one (`PacerShareDonutData`).
    /// - `sort`: as the screen stored it. A sort by a column the list does
    ///   not have (Hit %, a Sessions sort stored before round 5) sorts by
    ///   cost instead (`effectiveSort`), so the list never runs in an order
    ///   no title on it explains.
    public init(rows: [PacerUsageRow<Extra>], sort requested: PacerUsageSort, maxSlices: Int = .max) {
        let sort = Self.effectiveSort(requested)
        let donut = PacerShareDonutData(rows: rows, sort: sort, maxSlices: maxSlices)
        let folds = donut.slices.last?.id == PacerShareDonutData.otherID
        let named: Set<String> = Set(donut.slices.map(\.id))
        let listed: [PacerUsageRow<Extra>] = folds ? rows.filter { named.contains($0.id) } : rows
        self.donut = donut
        self.sort = sort
        self.rows = listed.sortedForUsageTable(sort)

        if folds {
            let tail: [PacerUsageRow<Extra>] = rows.filter { !named.contains($0.id) }
            var tokens = TokenBreakdown.zero
            var parts = CostComponents.zero
            var cost: Double = 0
            for row in tail {
                tokens += row.tokens
                parts += row.costParts
                cost += row.cost
            }
            other = Other(label: "\(tail.count) others", count: tail.count, tokens: tokens,
                          costParts: parts, cost: cost)
        } else {
            other = nil
        }
    }

    /// The sort a list runs in when asked for `sort`: `sort` itself when it
    /// names the label or one of the list's sortable columns (Tokens, Cost),
    /// otherwise cost, largest first, as every table opens.
    public static func effectiveSort(_ sort: PacerUsageSort) -> PacerUsageSort {
        if sort.column == UsageColumn.name.rawValue { return sort }
        let sortable: [String] = PacerShareListColumn.standard.filter(\.isSortable).map(\.id)
        if sortable.contains(sort.column) { return sort }
        return .costDescending
    }

    /// An amount of `tokens` and `cost` in column `id`: the cost, or a token
    /// count. What the ring measures is one of these (`effectiveSort`).
    static func amount(tokens: TokenBreakdown, cost: Double, column id: String) -> Double {
        guard let standard = UsageColumn(rawValue: id) else { return 0 }
        if standard == .cost { return cost }
        return Double(standard.tokenCount(of: tokens) ?? 0)
    }

    /// What the cell in `column` prints for `row`, and its tooltip.
    public func cell(_ column: PacerShareListColumn, row: PacerUsageRow<Extra>) -> PacerUsageCellText {
        cell(column, tokens: row.tokens, cost: row.cost, costParts: row.costParts)
    }

    /// What the cell in `column` prints for the folded tail.
    public func otherCell(_ column: PacerShareListColumn, _ other: Other) -> PacerUsageCellText {
        cell(column, tokens: other.tokens, cost: other.cost, costParts: other.costParts)
    }

    private func cell(_ column: PacerShareListColumn, tokens: TokenBreakdown, cost: Double,
                      costParts: CostComponents) -> PacerUsageCellText {
        switch column.kind {
        case .usage(let amount):
            return amount.column.cellText(tokens: tokens, cost: cost, costParts: costParts)
                ?? PacerUsageCellText(text: "–", help: "")
        case .ringShare:
            let ring: Double = Self.amount(tokens: tokens, cost: cost, column: donut.metric.column)
            let share: Double? = donut.total > 0 ? ring / donut.total : nil
            return PacerUsageCellText(share: share, help: "Share of the \(donut.metric.title.lowercased())",
                                      none: "–")
        case .mixBar:
            return PacerUsageCellText(text: "", help: "")
        }
    }

    /// Sorting by `column`: a new column starts in the direction a usage
    /// table starts it (numbers largest first, the label A to Z); the sorted
    /// column flips.
    public func sort(byColumn column: String) -> PacerUsageSort {
        if column == sort.column { return PacerUsageSort(column: column, descending: !sort.descending) }
        let ascendingFirst = column == UsageColumn.name.rawValue
        return PacerUsageSort(column: column, descending: !ascendingFirst)
    }
}

// MARK: - Card

/// A share donut beside its list, as one card. See the top of this file.
///
/// The donut sits at the card's leading edge, where its content starts, and
/// the list runs from beside it towards the far edge: the label column as
/// wide as its longest label, then the Mix bar taking what the card has left
/// (between `PacerShareListMetrics.minMixWidth` and `.maxMixWidth`), then the
/// numbers. Past the bar's widest, the number columns take the rest, up to
/// `PacerShareListMetrics.maxNumberStretch` times their width, as a table spreads
/// spare width across its columns.
///
/// Round 6 centred the donut and a list that hugged its columns, as one
/// figure, with the Mix bar (Today by model's only) after the numbers. With
/// no bar, or a short one, that left a wide empty band either side, and the
/// owner's screenshot of a modal's By model showed it: "big empty gaps". With
/// the figure anchored at the leading edge and the bar flexing, the list
/// fills the card from a modal's 612pt up to a wide window's, and only a
/// window wider still leaves room after the numbers.
///
/// - `data`: the ring and the rows (`PacerShareListData`).
/// - `labelTitle`: the label column's title ("Model", "Project").
/// - `onSort`: a click on a column title, with the sort it asks for
///   (`PacerShareListData.sort(byColumn:)`). The screen keeps the sort.
/// - `onOpen`: a click on a row (a project opens its detail). Nil for rows
///   with nothing to open; they do not highlight.
/// - `trailing`: the card header's trailing slot.
public struct PacerDonutListCard<Extra: PacerUsageExtra, Trailing: View>: View {
    let title: String
    let data: PacerShareListData<Extra>
    let labelTitle: String
    let onSort: (PacerUsageSort) -> Void
    let onOpen: ((PacerUsageRow<Extra>) -> Void)?
    let accessibilityLabel: String
    let hoveredAngle: Double?
    let trailing: () -> Trailing

    public static var donutSize: CGFloat { 140 }

    public init(
        _ title: String,
        data: PacerShareListData<Extra>,
        labelTitle: String,
        accessibilityLabel: String,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((PacerUsageRow<Extra>) -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.init(title, data: data, labelTitle: labelTitle, accessibilityLabel: accessibilityLabel,
                  hoveredAngle: nil, onSort: onSort, onOpen: onOpen, trailing: trailing)
    }

    /// With a hover already in place: for the render tests, which cannot
    /// move a pointer.
    init(
        _ title: String,
        data: PacerShareListData<Extra>,
        labelTitle: String,
        accessibilityLabel: String,
        hoveredAngle: Double?,
        onSort: @escaping (PacerUsageSort) -> Void,
        onOpen: ((PacerUsageRow<Extra>) -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.data = data
        self.labelTitle = labelTitle
        self.onSort = onSort
        self.onOpen = onOpen
        self.accessibilityLabel = accessibilityLabel
        self.hoveredAngle = hoveredAngle
        self.trailing = trailing
    }

    /// Between the ring and the list.
    static var spacing: CGFloat { 28 }

    public var body: some View {
        let data = self.data
        PacerCard(title, trailing: trailing) {
            HStack(alignment: .center, spacing: Self.spacing) {
                PacerShareDonut(data.donut, size: Self.donutSize,
                                accessibilityLabel: accessibilityLabel, hoveredAngle: hoveredAngle)
                PacerShareList(data: data, labelTitle: labelTitle, onSort: onSort, onOpen: onOpen)
            }
            // Leading: the ring where the card's content starts, as every
            // other card's content does, and the list from beside it.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - List

/// The list beside the donut: a header of column titles that sort, then one
/// line per wedge. The sorted column is the one the ring measures (when it
/// adds up), so its numbers are the ones in the primary colour.
public struct PacerShareList<Extra: PacerUsageExtra>: View {
    let data: PacerShareListData<Extra>
    let labelTitle: String
    let onSort: (PacerUsageSort) -> Void
    let onOpen: ((PacerUsageRow<Extra>) -> Void)?

    public init(data: PacerShareListData<Extra>, labelTitle: String,
                onSort: @escaping (PacerUsageSort) -> Void,
                onOpen: ((PacerUsageRow<Extra>) -> Void)? = nil) {
        self.data = data
        self.labelTitle = labelTitle
        self.onSort = onSort
        self.onOpen = onOpen
    }

    /// How wide the label column is: as wide as the longest label it holds,
    /// its title included, up to `maxLabelWidth`. Measured with the font the
    /// lines draw in, so the bar starts just past the names rather than after
    /// a gap. A handful of labels, so measured per body.
    var labelWidth: CGFloat {
        typealias Metrics = PacerShareListMetrics
        let labels: [String] = data.rows.map(\.label) + (data.other.map { [$0.label] } ?? [])
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        var widest: CGFloat = 0
        for label in labels {
            let width: CGFloat = (label as NSString).size(withAttributes: [.font: font]).width
            widest = Swift.max(widest, width)
        }
        // The title, semibold with its sort chevron when it is the sort.
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let title: CGFloat = (labelTitle as NSString).size(withAttributes: [.font: titleFont]).width + 14
        let needed: CGFloat = Swift.max(widest, title).rounded(.up) + 2
        return Swift.min(Metrics.maxLabelWidth, Swift.max(Metrics.minLabelWidth, needed))
    }

    public var body: some View {
        let columns = data.columns
        let labelWidth = self.labelWidth
        VStack(alignment: .leading, spacing: 0) {
            header(columns, labelWidth: labelWidth)
            ForEach(data.rows) { row in
                line(row, columns: columns, labelWidth: labelWidth)
            }
            if let other = data.other {
                otherLine(other, columns: columns, labelWidth: labelWidth)
            }
        }
    }

    private func header(_ columns: [PacerShareListColumn], labelWidth: CGFloat) -> some View {
        PacerShareListLineLayout(labelWidth: labelWidth, columns: columns) {
            // The colour dot's slot, so the label's title sits over the
            // labels rather than over the dots.
            Color.clear.frame(height: 1)
            title(labelTitle, id: UsageColumn.name.rawValue, sortable: true, help: nil, trailing: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { column in
                title(column.title, id: column.id, sortable: column.isSortable, help: column.help,
                      trailing: !column.isFlexible)
                    .frame(maxWidth: .infinity, alignment: column.isFlexible ? .leading : .trailing)
            }
        }
        .padding(PacerShareListMetrics.rowPadding)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func title(_ text: String, id: String, sortable: Bool, help: String?, trailing: Bool) -> some View {
        let active = sortable && data.sort.column == id
        let label = HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .lineLimit(1)
            if active {
                Image(systemName: data.sort.descending ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        if sortable {
            Button { onSort(data.sort(byColumn: id)) } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help ?? "")
            .accessibilityLabel("Sort by \(text)")
            .accessibilityAddTraits(active ? .isSelected : [])
        } else {
            label.help(help ?? "")
        }
    }

    @ViewBuilder
    private func line(_ row: PacerUsageRow<Extra>, columns: [PacerShareListColumn], labelWidth: CGFloat) -> some View {
        let content = lineContent(color: row.color ?? .gray, label: row.label, help: row.subtitle ?? row.label,
                                  breakdown: row.breakdown, columns: columns, labelWidth: labelWidth) { column in
            data.cell(column, row: row)
        }
        if let onOpen {
            HoverLine(action: { onOpen(row) }) { content }
        } else {
            content.padding(PacerShareListMetrics.rowPadding)
        }
    }

    private func otherLine(_ other: PacerShareListData<Extra>.Other, columns: [PacerShareListColumn],
                           labelWidth: CGFloat) -> some View {
        lineContent(color: .secondary, label: other.label, help: other.label,
                    breakdown: CostBreakdown(cost: other.costParts, tokens: other.tokens),
                    columns: columns, labelWidth: labelWidth) { column in
            data.otherCell(column, other)
        }
        .padding(PacerShareListMetrics.rowPadding)
    }

    private func lineContent(color: Color, label: String, help: String, breakdown: CostBreakdown,
                             columns: [PacerShareListColumn], labelWidth: CGFloat,
                             cell: @escaping (PacerShareListColumn) -> PacerUsageCellText) -> some View {
        let sorted = data.sort.column
        return PacerShareListLineLayout(labelWidth: labelWidth, columns: columns) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help)
            ForEach(columns) { column in
                if column.kind == .mixBar {
                    PacerCostBar(breakdown, height: 6)
                } else {
                    let text = cell(column)
                    let emphasised = column.id == sorted
                    Text(text.text)
                        .font(emphasised
                              ? .system(size: 12, weight: .semibold, design: .rounded)
                              : .system(size: 12))
                        .foregroundStyle(emphasised ? Color.primary : Color.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(text.help)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The list's measures. Apart from the view, which is main-actor isolated,
/// so the line layout and the tests read them from anywhere.
enum PacerShareListMetrics {
    static var columnSpacing: CGFloat { 10 }
    static var rowPadding: EdgeInsets { EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8) }
    /// The narrowest a label column goes before its labels shorten.
    static var minLabelWidth: CGFloat { 48 }
    /// The widest a label column grows to hold its longest label.
    static var maxLabelWidth: CGFloat { 200 }
    /// The narrowest the Mix bar goes: still five parts a reader can tell
    /// apart at a modal's narrowest.
    static var minMixWidth: CGFloat { PacerShareListColumn.mixBar.width }
    /// The widest the Mix bar grows: enough that a window about 1,400pt
    /// wide has no band after the numbers, and short of a bar running across
    /// a whole monitor. Past this the numbers take the rest.
    static var maxMixWidth: CGFloat { 720 }
    /// How far past its own width a number column grows once the Mix bar is
    /// at its widest, as a table's columns share a wide card's spare width.
    /// At 2 the numbers drifted apart in a wide window and read as three
    /// separate figures.
    static var maxNumberStretch: CGFloat { 1.5 }
}

/// Where each column of a list line goes: the label, then the Mix bar, then
/// the numbers. Worked out from the columns and the label width alone, never
/// from what a line holds, so the header and every line put each column at
/// the same x.
///
/// In order, as the width allows: the label up to its longest label's width
/// (shortening first only when even the least of everything else does not
/// fit), the Mix bar from its least up to `PacerShareListMetrics.maxMixWidth`, and
/// the number columns from their own widths up to
/// `PacerShareListMetrics.maxNumberStretch` times them, all in proportion. Round 7
/// first did this with an `HStack` and layout priorities, and the stack's
/// even split of what the bar left gave Share more than its width and Cost
/// less, so a list ran 9pt past its card.
struct PacerShareListLineLayout: Layout {
    let labelWidth: CGFloat
    let columns: [PacerShareListColumn]

    /// Each slot's width: the colour dot, the label, then one per column.
    struct Widths: Equatable {
        let dot: CGFloat
        let label: CGFloat
        let columns: [CGFloat]
        let spacing: CGFloat

        var slots: [CGFloat] { [dot, label] + columns }
        var total: CGFloat {
            let gaps: CGFloat = spacing * CGFloat(Swift.max(0, slots.count - 1))
            return slots.reduce(0, +) + gaps
        }
    }

    static var dot: CGFloat { 8 }

    /// The widths for a line offered `width`: nil for its ideal (the label
    /// at its width, the bar at its widest, the numbers at theirs).
    static func widths(for width: CGFloat?, labelWidth: CGFloat, columns: [PacerShareListColumn]) -> Widths {
        typealias List = PacerShareListMetrics
        let spacing: CGFloat = List.columnSpacing
        let gaps: CGFloat = spacing * CGFloat(columns.count + 1)
        let numbers: CGFloat = columns.filter { !$0.isFlexible }.reduce(CGFloat(0)) { $0 + $1.width }
        let hasBar: Bool = columns.contains { $0.isFlexible }
        let barLeast: CGFloat = hasBar ? List.minMixWidth : 0
        let barMost: CGFloat = hasBar ? List.maxMixWidth : 0
        let label: CGFloat
        let bar: CGFloat
        let growth: CGFloat
        if let width {
            let room: CGFloat = width - dot - gaps
            let labelRoom: CGFloat = room - numbers - barLeast
            label = Swift.min(labelWidth, Swift.max(List.minLabelWidth, labelRoom))
            bar = Swift.min(barMost, Swift.max(barLeast, room - numbers - label))
            let spare: CGFloat = Swift.max(0, room - numbers - label - bar)
            let most: CGFloat = List.maxNumberStretch - 1
            growth = numbers > 0 ? Swift.min(most, spare / numbers) : 0
        } else {
            label = labelWidth
            bar = barMost
            growth = 0
        }
        let factor: CGFloat = 1 + growth
        let slots: [CGFloat] = columns.map { $0.isFlexible ? bar : $0.width * factor }
        return Widths(dot: dot, label: label, columns: slots, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = Self.widths(for: proposal.width, labelWidth: labelWidth, columns: columns)
        let slots: [CGFloat] = widths.slots
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let slot: CGFloat? = index < slots.count ? slots[index] : nil
            let size: CGSize = subview.sizeThatFits(ProposedViewSize(width: slot, height: nil))
            height = Swift.max(height, size.height)
        }
        return CGSize(width: widths.total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = Self.widths(for: bounds.width, labelWidth: labelWidth, columns: columns)
        let slots: [CGFloat] = widths.slots
        var x: CGFloat = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let slot: CGFloat? = index < slots.count ? slots[index] : nil
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: slot, height: nil))
            let placed: CGFloat = slot ?? subview.sizeThatFits(.unspecified).width
            x += placed + widths.spacing
        }
    }
}

/// A list line that opens something: the hover highlight of `HoverRow`,
/// with the list's own padding so its numbers stay in their columns.
private struct HoverLine<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(PacerShareListMetrics.rowPadding)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
