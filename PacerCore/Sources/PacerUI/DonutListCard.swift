import SwiftUI
import PacerCore

// A share donut beside a short list of what it measures: Today by model,
// Projects' Top projects, the Models tab's Share card and Project detail's
// By model card.
//
// Round 3 put a native table beside the donut, and the owner found it very
// bad in a donut card: the table's header, dividers and rounded border were a
// second card inside the first. So beside a donut there is a light list, as
// the old Top projects card had, but with labelled columns: click a column's
// title to sort the list, and the donut turns to measure that column when its
// values add up (`PacerShareDonutData`). A full table, where a screen has
// one, is its own card below (`PacerTableCard`), never inside this one.

// MARK: - Columns

/// One column of a donut card's list. A plain value: a screen lists its
/// columns once.
public struct PacerShareListColumn: Identifiable, Sendable, Equatable {
    /// How a screen's own number prints.
    public enum Format: Sendable, Equatable {
        case cost
        case tokens
        /// A plain count: sessions.
        case count
    }

    enum Kind: Sendable, Equatable {
        /// A usage table column's number, printed as the table prints it.
        case usage(UsageColumn)
        /// A screen's own number that adds up (`PacerUsageExtra.shareValue`).
        case extra(Format)
        /// Each row's share of the whole of the column `id` measures.
        case share(Format)
        /// Each row's share of what the ring measures.
        case ringShare
    }

    /// What the column sorts by: a `UsageColumn` raw value or one of the
    /// screen's own column ids. A share column sorts by the amount it is a
    /// share of, which ranks the rows the same way.
    public let id: String
    public let title: String
    /// The title's tooltip, where the title alone does not say it.
    public let help: String?
    public let width: CGFloat
    let kind: Kind

    /// Whether a click on the title sorts by it. The ring's share does not:
    /// sorting by it is sorting by whatever the ring measures.
    public var isSortable: Bool { kind != .ringShare }

    /// A usage table column's own number: Total, Hit %, Out %, Cost, a part.
    public static func usage(_ column: UsageColumn, width: CGFloat? = nil, help: String? = nil) -> Self {
        let defaultWidth: CGFloat
        let defaultHelp: String?
        switch column {
        case .cost:
            defaultWidth = 60
            defaultHelp = nil
        case .cacheHitRate:
            defaultWidth = 52
            defaultHelp = "Share of prompt tokens served from the cache"
        case .outputShare:
            defaultWidth = 44
            defaultHelp = "Output's share of the cost"
        case .tokens:
            defaultWidth = 54
            defaultHelp = "Every token: cached, uncached and output"
        default:
            defaultWidth = 54
            defaultHelp = nil
        }
        return Self(id: column.rawValue, title: column.title(label: ""), help: help ?? defaultHelp,
                    width: width ?? defaultWidth, kind: .usage(column))
    }

    /// A screen's own number that adds up across rows, read through
    /// `PacerUsageExtra.shareValue(forColumn: id)`: a project's sessions, a
    /// model's uncached tokens.
    public static func count(_ id: String, title: String, format: Format, help: String? = nil,
                             width: CGFloat = 56) -> Self {
        Self(id: id, title: title, help: help, width: width, kind: .extra(format))
    }

    /// Each row's share of the whole of `id` as a percent: a Projects "Cost"
    /// column printing 38% for a project with 38% of the cost. For a card
    /// whose numbers a table further down the page already prints: the card
    /// says how the whole divides, the table how much.
    public static func share(of id: String, title: String, format: Format, help: String? = nil,
                             width: CGFloat = 56) -> Self {
        Self(id: id, title: title, help: help, width: width, kind: .share(format))
    }

    /// Each row's share of what the ring measures, which is what the list is
    /// sorted by when that adds up, and cost otherwise.
    public static let ringShare = Self(id: "__ringShare__", title: "Share", help: nil, width: 44,
                                       kind: .ringShare)
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
    public let sort: PacerUsageSort
    public let columns: [PacerShareListColumn]
    /// The listed rows, in the list's order.
    public let rows: [PacerUsageRow<Extra>]
    /// The tail the ring folds into one wedge, as one row.
    public let other: Other?
    /// Each share column's whole: the sum over every row, listed or folded.
    let wholes: [String: Double]

    /// The folded tail, summed.
    public struct Other: Sendable, Equatable {
        public let label: String
        public let count: Int
        public let tokens: TokenBreakdown
        public let costParts: CostComponents
        public let cost: Double
        /// The screen's own numbers, summed, by column id.
        let extras: [String: Double]
    }

    /// - `maxSlices`: rows with a wedge, and a line, of their own; the rest
    ///   fold into one (`PacerShareDonutData`).
    public init(rows: [PacerUsageRow<Extra>], sort: PacerUsageSort,
                columns: [PacerShareListColumn], maxSlices: Int = .max) {
        let donut = PacerShareDonutData(rows: rows, sort: sort, maxSlices: maxSlices)
        let folds = donut.slices.last?.id == PacerShareDonutData.otherID
        let named: Set<String> = Set(donut.slices.map(\.id))
        let listed: [PacerUsageRow<Extra>] = folds ? rows.filter { named.contains($0.id) } : rows
        self.donut = donut
        self.sort = sort
        self.columns = columns
        self.rows = listed.sortedForUsageTable(sort)

        var wholes: [String: Double] = [:]
        for column in columns {
            guard case .share = column.kind else { continue }
            wholes[column.id] = rows.reduce(0) { $0 + Self.value(of: $1, column: column.id) }
        }
        self.wholes = wholes

        if folds {
            let tail: [PacerUsageRow<Extra>] = rows.filter { !named.contains($0.id) }
            var tokens = TokenBreakdown.zero
            var parts = CostComponents.zero
            var cost: Double = 0
            var extras: [String: Double] = [:]
            for row in tail {
                tokens += row.tokens
                parts += row.costParts
                cost += row.cost
                for column in columns where UsageColumn(rawValue: column.id) == nil {
                    extras[column.id, default: 0] += row.extra.shareValue(forColumn: column.id) ?? 0
                }
            }
            other = Other(label: "\(tail.count) others", count: tail.count, tokens: tokens,
                          costParts: parts, cost: cost, extras: extras)
        } else {
            other = nil
        }
    }

    /// A row's amount in column `id`: its cost, a token count, or the
    /// screen's own number.
    static func value(of row: PacerUsageRow<Extra>, column id: String) -> Double {
        if let standard = UsageColumn(rawValue: id) {
            if standard == .cost { return row.cost }
            return Double(standard.tokenCount(of: row.tokens) ?? 0)
        }
        return row.extra.shareValue(forColumn: id) ?? 0
    }

    /// What the cell in `column` prints for `row`, and its tooltip.
    public func cell(_ column: PacerShareListColumn, row: PacerUsageRow<Extra>) -> PacerUsageCellText {
        let amount: Double = Self.value(of: row, column: column.id)
        switch column.kind {
        case .usage(let usage):
            return usage.cellText(tokens: row.tokens, cost: row.cost, costParts: row.costParts)
                ?? PacerUsageCellText(text: "–", help: "")
        case .extra(let format):
            return Self.amountText(row.extra.shareValue(forColumn: column.id) ?? 0, format)
        case .share(let format):
            return shareText(amount, of: wholes[column.id] ?? 0, format, title: column.title)
        case .ringShare:
            let ring: Double = Self.value(of: row, column: donut.metric.column)
            return ringShareText(ring)
        }
    }

    /// What the cell in `column` prints for the folded tail.
    public func otherCell(_ column: PacerShareListColumn, _ other: Other) -> PacerUsageCellText {
        switch column.kind {
        case .usage(let usage):
            return usage.cellText(tokens: other.tokens, cost: other.cost, costParts: other.costParts)
                ?? PacerUsageCellText(text: "–", help: "")
        case .extra(let format):
            return Self.amountText(other.extras[column.id] ?? 0, format)
        case .share(let format):
            return shareText(otherAmount(other, column: column.id), of: wholes[column.id] ?? 0,
                             format, title: column.title)
        case .ringShare:
            return ringShareText(otherAmount(other, column: donut.metric.column))
        }
    }

    private func otherAmount(_ other: Other, column id: String) -> Double {
        if let standard = UsageColumn(rawValue: id) {
            if standard == .cost { return other.cost }
            return Double(standard.tokenCount(of: other.tokens) ?? 0)
        }
        return other.extras[id] ?? 0
    }

    private func shareText(_ amount: Double, of whole: Double, _ format: PacerShareListColumn.Format,
                           title: String) -> PacerUsageCellText {
        let exact = Self.amountText(amount, format).help
        let wholeExact = Self.amountText(whole, format).help
        return PacerUsageCellText(share: whole > 0 ? amount / whole : nil,
                                  help: "\(exact) of \(wholeExact)", none: "–")
    }

    private func ringShareText(_ amount: Double) -> PacerUsageCellText {
        let share: Double? = donut.total > 0 ? amount / donut.total : nil
        return PacerUsageCellText(share: share, help: "Share of the \(donut.metric.title.lowercased())",
                                  none: "–")
    }

    static func amountText(_ value: Double, _ format: PacerShareListColumn.Format) -> PacerUsageCellText {
        switch format {
        case .cost:
            return PacerUsageCellText(text: pacerCost(value), help: pacerCostExact(value))
        case .tokens:
            let count = Int64(value.rounded())
            return PacerUsageCellText(text: pacerTokens(count), help: pacerTokensExact(count))
        case .count:
            let count = Int(value.rounded())
            return PacerUsageCellText(text: "\(count)", help: "\(count)")
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

    public var body: some View {
        let data = self.data
        PacerCard(title, trailing: trailing) {
            HStack(alignment: .top, spacing: 24) {
                PacerShareDonut(data.donut, size: Self.donutSize,
                                accessibilityLabel: accessibilityLabel, hoveredAngle: hoveredAngle)
                PacerShareList(data: data, labelTitle: labelTitle, onSort: onSort, onOpen: onOpen)
            }
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

    static var columnSpacing: CGFloat { 10 }
    static var rowPadding: EdgeInsets { EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8) }

    public init(data: PacerShareListData<Extra>, labelTitle: String,
                onSort: @escaping (PacerUsageSort) -> Void,
                onOpen: ((PacerUsageRow<Extra>) -> Void)? = nil) {
        self.data = data
        self.labelTitle = labelTitle
        self.onSort = onSort
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(data.rows) { row in
                line(row)
            }
            if let other = data.other {
                otherLine(other)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: Self.columnSpacing) {
            // The colour dot's width, so the label's title sits over the
            // labels rather than over the dots.
            Color.clear.frame(width: 8, height: 1)
            title(labelTitle, id: UsageColumn.name.rawValue, sortable: true, help: nil, trailing: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(data.columns) { column in
                title(column.title, id: column.id, sortable: column.isSortable, help: column.help,
                      trailing: true)
                    .frame(width: column.width, alignment: .trailing)
            }
        }
        .padding(Self.rowPadding)
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
    private func line(_ row: PacerUsageRow<Extra>) -> some View {
        let content = lineContent(color: row.color ?? .gray, label: row.label, help: row.subtitle ?? row.label) { column in
            data.cell(column, row: row)
        }
        if let onOpen {
            HoverLine(action: { onOpen(row) }) { content }
        } else {
            content.padding(Self.rowPadding)
        }
    }

    private func otherLine(_ other: PacerShareListData<Extra>.Other) -> some View {
        lineContent(color: .secondary, label: other.label, help: other.label) { column in
            data.otherCell(column, other)
        }
        .padding(Self.rowPadding)
    }

    private func lineContent(color: Color, label: String, help: String,
                             cell: @escaping (PacerShareListColumn) -> PacerUsageCellText) -> some View {
        let sorted = data.sort.column
        return HStack(spacing: Self.columnSpacing) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(help)
            ForEach(data.columns) { column in
                let text = cell(column)
                let emphasised = column.id == sorted
                Text(text.text)
                    .font(emphasised
                          ? .system(size: 12, weight: .semibold, design: .rounded)
                          : .system(size: 12))
                    .foregroundStyle(emphasised ? Color.primary : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: column.width, alignment: .trailing)
                    .help(text.help)
            }
        }
        .accessibilityElement(children: .combine)
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
                .padding(PacerShareList<PacerUsageNoExtra>.rowPadding)
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
