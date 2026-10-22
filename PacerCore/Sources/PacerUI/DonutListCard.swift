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
// titles: Tokens, Cost, Share (`PacerShareListColumn.standard`), Tokens before
// Cost as every table has them. Round 4 let each card pick its own (Today's
// Total, Hit %, Out %, Cost and Share; Top projects' shares of cost, tokens
// and sessions; By model's Cost and In + out), and the owner found the cards
// disagreeing with each other and with the tables. A list takes only amounts
// that add up (`UsageAmount`, a screen's own count): Hit % and Out % are not
// shares of anything, so they cannot be a ring or be compared as one.
//
// A card that no table follows (Today by model) adds each row's Mix bar after
// the numbers (`PacerShareListColumn.mixBar`, round 6): display only, never a
// sort, so the ring still follows only amounts. A card a table follows leaves
// it to the table, whose Mix column draws the same bars.

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
        /// A usage table column's amount, printed as the table prints it.
        case usage(UsageAmount)
        /// A screen's own number that adds up (`PacerUsageExtra.shareValue`).
        case extra(Format)
        /// Each row's share of the whole of the column `id` measures.
        case share(Format)
        /// Each row's share of what the ring measures.
        case ringShare
        /// The row's cost by part as one slim bar (`PacerCostBar`), as a
        /// table's Mix column draws it. Display only: not a sort, and never
        /// what the ring measures.
        case mixBar
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
    /// sorting by it is sorting by whatever the ring measures. Nor does the
    /// Mix bar: the ring follows the sort, and only an amount can be a ring.
    public var isSortable: Bool { kind != .ringShare && kind != .mixBar }

    /// Whether the column takes the list's spare width (the Mix bar) rather
    /// than its own fixed `width`, which is then its least.
    var isFlexible: Bool { kind == .mixBar }

    /// The columns every donut list shows: Tokens, Cost, Share, under the
    /// titles and in the order a table gives them. Sorted by cost unless the
    /// screen asks otherwise, as every table is.
    public static let standard: [PacerShareListColumn] = standard()

    /// The columns of a donut card that a full table follows (Projects,
    /// Models, a modal's By model): each row's share of the tokens and of the
    /// cost, under the same titles and in the same order as `standard`. The
    /// table below prints the amounts, and a page prints a number once.
    public static let shares: [PacerShareListColumn] = [
        .share(of: UsageColumn.tokens.rawValue, title: "Tokens", format: .tokens, help: "Share of every token"),
        .share(of: UsageColumn.cost.rawValue, title: "Cost", format: .cost, help: "Share of the cost"),
    ]

    /// `standard`, for a card that holds less than every token for its rows
    /// (Project detail's models carry uncached input and output only): the
    /// same columns in the same places, with what the card has under Tokens,
    /// and a tooltip that says what it is.
    public static func standard(tokens: PacerShareListColumn = .usage(.tokens)) -> [PacerShareListColumn] {
        [tokens, .usage(.cost), .ringShare]
    }

    /// A usage table column's amount: Cost, Tokens or a token part. Only
    /// amounts that add up have a `UsageAmount`, so a ratio (Hit %, Out %)
    /// or the Mix bar cannot be put in a donut list.
    public static func usage(_ amount: UsageAmount, width: CGFloat? = nil, help: String? = nil) -> Self {
        let defaultWidth: CGFloat
        let defaultHelp: String?
        switch amount {
        case .cost:
            defaultWidth = 60
            defaultHelp = nil
        case .tokens:
            defaultWidth = 54
            defaultHelp = "Every token: cached, uncached and output"
        default:
            defaultWidth = 54
            defaultHelp = nil
        }
        return Self(id: amount.column.rawValue, title: amount.column.title(label: ""),
                    help: help ?? defaultHelp, width: width ?? defaultWidth, kind: .usage(amount))
    }

    /// A screen's own number that adds up across rows, read through
    /// `PacerUsageExtra.shareValue(forColumn: id)`: a project's sessions, a
    /// model's uncached tokens. `id` is the screen's, never a usage column's,
    /// which the list would read in its place.
    public static func count(_ id: String, title: String, format: Format, help: String? = nil,
                             width: CGFloat = 56) -> Self {
        precondition(UsageColumn(storedId: id) == nil,
                     "\(id) is a usage column's id: list it with .usage")
        return Self(id: id, title: title, help: help, width: width, kind: .extra(format))
    }

    /// Each row's share of the whole of `id` as a percent: a "Cost" column
    /// printing 38% for a project with 38% of the cost. `id` is an amount
    /// that adds up (`accepts(id:)`): a share of Hit % is a share of
    /// nothing.
    public static func share(of id: String, title: String, format: Format, help: String? = nil,
                             width: CGFloat = 56) -> Self {
        precondition(accepts(id: id), "\(id) does not add up: a donut list cannot share it")
        return Self(id: id, title: title, help: help, width: width, kind: .share(format))
    }

    /// Whether a column id may be in a donut list: one of the screen's own
    /// (whose `shareValue` adds up by contract), or a usage column that adds
    /// up (`UsageColumn.isAdditive`). Never the label, a ratio or Mix.
    public static func accepts(id: String) -> Bool {
        guard let standard = UsageColumn(storedId: id) else { return true }
        return standard.isAdditive
    }

    /// Each row's share of what the ring measures, which is what the list is
    /// sorted by when that adds up, and cost otherwise.
    public static let ringShare = Self(id: "__ringShare__", title: "Share", help: nil, width: 44,
                                       kind: .ringShare)

    /// Each row's cost by part, as the Mix bar every table has, after the
    /// numbers. For a donut card no table follows (Today by model): a table
    /// that follows has its own Mix, and a page draws a thing once. Its id is
    /// no usage column's, so nothing reads it as one.
    public static let mixBar = Self(id: "__mixBar__", title: UsageColumn.mix.title(label: ""),
                                    help: UsageColumn.mix.headerHelp, width: 60, kind: .mixBar)
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
    /// - `sort`: as the screen stored it. A sort by a column the list does
    ///   not have (a Hit % or a Sessions sort stored before round 5) sorts
    ///   by cost instead (`effectiveSort`), so the list never runs in an
    ///   order no title on it explains.
    public init(rows: [PacerUsageRow<Extra>], sort requested: PacerUsageSort,
                columns: [PacerShareListColumn], maxSlices: Int = .max) {
        let sort = Self.effectiveSort(requested, columns: columns)
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

    /// The sort a list with `columns` runs in when asked for `sort`: `sort`
    /// itself when it names the label or one of the list's sortable
    /// columns, otherwise cost, largest first, as every table opens (or the
    /// list's first column, for a list with no Cost).
    public static func effectiveSort(_ sort: PacerUsageSort, columns: [PacerShareListColumn]) -> PacerUsageSort {
        if sort.column == UsageColumn.name.rawValue { return sort }
        let sortable: [String] = columns.filter(\.isSortable).map(\.id)
        if sortable.contains(sort.column) { return sort }
        let cost: String = UsageColumn.cost.rawValue
        return PacerUsageSort(column: sortable.contains(cost) ? cost : sortable.first ?? cost, descending: true)
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
        case .usage(let amount):
            return amount.column.cellText(tokens: row.tokens, cost: row.cost, costParts: row.costParts)
                ?? PacerUsageCellText(text: "–", help: "")
        case .extra(let format):
            return Self.amountText(row.extra.shareValue(forColumn: column.id) ?? 0, format)
        case .share(let format):
            return shareText(amount, of: wholes[column.id] ?? 0, format, title: column.title)
        case .ringShare:
            let ring: Double = Self.value(of: row, column: donut.metric.column)
            return ringShareText(ring)
        case .mixBar:
            return PacerUsageCellText(text: "", help: "")
        }
    }

    /// What the cell in `column` prints for the folded tail.
    public func otherCell(_ column: PacerShareListColumn, _ other: Other) -> PacerUsageCellText {
        switch column.kind {
        case .usage(let amount):
            return amount.column.cellText(tokens: other.tokens, cost: other.cost, costParts: other.costParts)
                ?? PacerUsageCellText(text: "–", help: "")
        case .extra(let format):
            return Self.amountText(other.extras[column.id] ?? 0, format)
        case .share(let format):
            return shareText(otherAmount(other, column: column.id), of: wholes[column.id] ?? 0,
                             format, title: column.title)
        case .ringShare:
            return ringShareText(otherAmount(other, column: donut.metric.column))
        case .mixBar:
            return PacerUsageCellText(text: "", help: "")
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
/// The donut and the list are one figure, centred in the card and centred on
/// each other. The list is as wide as it needs: its label column as wide as
/// its longest label, the numbers just past the names, and a Mix bar, where
/// the screen lists one, taking what the card has left up to
/// `PacerShareList.maxMixWidth`.
///
/// Round 5's list took every point the donut left, its label column
/// stretching, so at a dashboard's width the numbers sat at the card's far
/// edge with a wide gap after the names, and a short list left a band under
/// its last row. The owner: "this pie chart card just feels like it has so
/// much empty space". Round 6 rendered five layouts at 3 to 8 rows, light and
/// dark: the list hugging and left-aligned left half the card empty, the Mix
/// bar running to the card's edge grew without limit in a wide window, and
/// this one read as one deliberate figure at every width.
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
            .frame(maxWidth: .infinity, alignment: .center)
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
    /// The narrowest a label column goes before its labels shorten.
    static var minLabelWidth: CGFloat { 48 }
    /// The widest a label column grows to hold its longest label.
    static var maxLabelWidth: CGFloat { 200 }
    /// The widest the Mix bar grows: at a dashboard's default width it takes
    /// what the card has left; in a wider window it stops here and the
    /// figure centres, rather than a bar running across the screen.
    static var maxMixWidth: CGFloat { 320 }

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
    /// lines draw in, so the numbers sit just past the names rather than at
    /// the far edge of the card. A handful of labels, so measured per body.
    var labelWidth: CGFloat {
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
        return Swift.min(Self.maxLabelWidth, Swift.max(Self.minLabelWidth, needed))
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
        HStack(spacing: Self.columnSpacing) {
            // The colour dot's width, so the label's title sits over the
            // labels rather than over the dots.
            Color.clear.frame(width: 8, height: 1)
            title(labelTitle, id: UsageColumn.name.rawValue, sortable: true, help: nil, trailing: false)
                .modifier(LabelColumn(width: labelWidth))
            ForEach(columns) { column in
                title(column.title, id: column.id, sortable: column.isSortable, help: column.help,
                      trailing: !column.isFlexible)
                    .modifier(NumberColumn(column: column))
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
    private func line(_ row: PacerUsageRow<Extra>, columns: [PacerShareListColumn], labelWidth: CGFloat) -> some View {
        let content = lineContent(color: row.color ?? .gray, label: row.label, help: row.subtitle ?? row.label,
                                  breakdown: row.breakdown, columns: columns, labelWidth: labelWidth) { column in
            data.cell(column, row: row)
        }
        if let onOpen {
            HoverLine(action: { onOpen(row) }) { content }
        } else {
            content.padding(Self.rowPadding)
        }
    }

    private func otherLine(_ other: PacerShareListData<Extra>.Other, columns: [PacerShareListColumn],
                           labelWidth: CGFloat) -> some View {
        lineContent(color: .secondary, label: other.label, help: other.label,
                    breakdown: CostBreakdown(cost: other.costParts, tokens: other.tokens),
                    columns: columns, labelWidth: labelWidth) { column in
            data.otherCell(column, other)
        }
        .padding(Self.rowPadding)
    }

    private func lineContent(color: Color, label: String, help: String, breakdown: CostBreakdown,
                             columns: [PacerShareListColumn], labelWidth: CGFloat,
                             cell: @escaping (PacerShareListColumn) -> PacerUsageCellText) -> some View {
        let sorted = data.sort.column
        return HStack(spacing: Self.columnSpacing) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(LabelColumn(width: labelWidth))
                .help(help)
            ForEach(columns) { column in
                if column.kind == .mixBar {
                    PacerCostBar(breakdown, height: 6)
                        .modifier(NumberColumn(column: column))
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
                        .modifier(NumberColumn(column: column))
                        .help(text.help)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The label column: `width` (its longest label's), shortening below it
/// when the card is too narrow for the list, never wider. The header's title
/// and every line take the same frame, so the columns line up.
private struct LabelColumn: ViewModifier {
    let width: CGFloat
    func body(content: Content) -> some View {
        content.frame(minWidth: PacerShareList<PacerUsageNoExtra>.minLabelWidth, idealWidth: width,
                      maxWidth: width, alignment: .leading)
    }
}

/// A number column at its width, or the Mix bar taking what the card has
/// left, from its `width` up to `PacerShareList.maxMixWidth`.
private struct NumberColumn: ViewModifier {
    let column: PacerShareListColumn
    func body(content: Content) -> some View {
        if column.isFlexible {
            let most: CGFloat = PacerShareList<PacerUsageNoExtra>.maxMixWidth
            content.frame(minWidth: column.width, idealWidth: most, maxWidth: most, alignment: .leading)
        } else {
            content.frame(width: column.width, alignment: .trailing)
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
